"""Adaptive thresholds and the on-disk private, cross-worker timing store."""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from capture_timing import SuccessTimingStore, threshold


def rows(count, seconds=0.1):
    return [{"seconds": seconds, "timestamp": 1.0 + i} for i in range(count)]


class CalculationTests(unittest.TestCase):
    def test_less_than_ten_successes_uses_full_cap(self):
        for lane in ("usb", "wifi"):
            for count in (0, 1, 9):
                self.assertEqual(threshold(rows(count), lane).seconds, 4.5)

    def test_floors_and_fixed_margin(self):
        self.assertEqual(threshold(rows(10), "usb").seconds, 2.5)
        self.assertEqual(threshold(rows(10), "wifi").seconds, 2.5)
        self.assertEqual(threshold(rows(10, 0.501), "usb").seconds, 2.5)  # 0.751 is under the floor
        self.assertAlmostEqual(threshold(rows(10, 1.1), "usb").seconds, 2.5)
        # 16-bit frames (~0.8 s over USB) still pass after a run of 8-bit ones (~0.15 s).
        self.assertGreater(threshold(rows(100, 0.15), "usb").seconds, 0.814)

    def test_twenty_percent_margin_and_ceiling(self):
        self.assertEqual(threshold(rows(10, 1.358), "wifi").seconds, 2.5)  # 1.63 is under the floor
        self.assertAlmostEqual(threshold(rows(10, 2.5), "wifi").seconds, 3.0)
        self.assertAlmostEqual(threshold(rows(10, 3.584), "wifi").seconds, 4.3008)
        self.assertEqual(threshold(rows(10, 4), "usb").seconds, 4.5)

    def test_only_latest_hundred_are_used(self):
        sample = rows(100, 4) + rows(100, 0.3)
        result = threshold(sample, "wifi")
        self.assertEqual((result.count, result.maximum, result.seconds), (100, 0.3, 2.5))
        self.assertEqual(threshold(sample[:-1], "wifi").seconds, 4.5)


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.store = SuccessTimingStore(self.base / "screenshot-success-times.json")

    def tearDown(self):
        self.temp.cleanup()

    def write(self, value):
        self.store.path.write_text(json.dumps(value))
        self.store.path.chmod(0o600)

    def test_private_atomic_replacement_and_independent_lanes(self):
        self.assertTrue(self.store.record("usb", 0.501, 1234))
        old_inode = self.store.path.stat().st_ino
        self.assertTrue(self.store.record("wifi", 1.358, 1235))
        self.assertNotEqual(old_inode, self.store.path.stat().st_ino)
        self.assertEqual(self.store.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.base / "screenshot-success-times.json.lock").stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.store.load(), {"usb": [{"seconds": 0.501, "timestamp": 1234}],
                                            "wifi": [{"seconds": 1.358, "timestamp": 1235}]})
        self.assertFalse(list(self.base.glob(".screenshot-success-times-*")))

    def test_slow_success_is_retained_without_relaxing_the_history_limit(self):
        self.assertTrue(self.store.record("wifi", 10, 1234))
        self.assertEqual(self.store.load()["wifi"], [{"seconds": 10, "timestamp": 1234}])
        self.assertFalse(self.store.record("wifi", 30.01, 1235))
        self.assertEqual(len(self.store.load()["wifi"]), 1)

    def test_retains_two_hundred_per_lane_independent_of_capture_history(self):
        self.write({"schema_version": 1, "usb": rows(200, 0.2), "wifi": rows(200, 0.3)})
        (self.base / "capture-history.jsonl").write_text("")
        self.assertTrue(self.store.record("usb", 1.1, 999))
        loaded = self.store.load()
        self.assertEqual((len(loaded["usb"]), len(loaded["wifi"])), (200, 200))
        self.assertEqual(loaded["usb"][0]["timestamp"], 2)
        self.assertAlmostEqual(self.store.threshold("usb").seconds, 2.5)
        self.assertEqual(self.store.threshold("usb").count, 100)

    def test_missing_corrupt_nonfinite_and_wrong_shape_are_empty(self):
        self.assertEqual(self.store.threshold("wifi").seconds, 4.5)
        for bad in ("{broken", "null", "[]", '{"schema_version":1,"usb":[],"wifi":[{"seconds":NaN,"timestamp":1}]}',
                    '{"schema_version":true,"usb":[],"wifi":[]}',
                    '{"schema_version":1,"usb":[],"wifi":[{"seconds":true,"timestamp":1}]}',
                    '{"schema_version":1,"usb":[],"wifi":[{"seconds":1,"timestamp":-1}]}'):
            self.store.path.write_text(bad)
            self.store.path.chmod(0o600)
            self.assertEqual(self.store.load(), {"usb": [], "wifi": []})
        self.assertTrue(self.store.record("wifi", 0.2, 10))
        self.assertEqual(len(self.store.load()["wifi"]), 1)

    def test_recent_samples_follow_timestamps_even_when_writers_finish_out_of_order(self):
        self.write({"schema_version": 1, "usb": list(reversed(rows(100, 0.3))) +
                    [{"seconds": 4, "timestamp": 0.5}], "wifi": []})
        self.assertEqual(self.store.threshold("usb").seconds, 2.5)
        self.assertTrue(self.store.record("usb", 4, 0.2))
        self.assertEqual(self.store.threshold("usb").seconds, 2.5)

    def test_insecure_file_symlink_and_oversize_are_empty(self):
        self.write({"schema_version": 1, "usb": rows(10), "wifi": rows(10)})
        self.store.path.chmod(0o644)
        self.assertEqual(self.store.threshold("usb").count, 0)
        target = self.base / "other.json"
        self.store.path.rename(target)
        self.store.path.symlink_to(target)
        self.assertEqual(self.store.threshold("usb").count, 0)
        self.store.path.unlink()
        self.store.path.write_bytes(b" " * (128 * 1024 + 1))
        self.store.path.chmod(0o600)
        self.assertEqual(self.store.threshold("usb").count, 0)

    def test_locked_store_is_bounded_and_does_not_replace_data(self):
        self.assertTrue(self.store.record("wifi", 0.2))
        fd = os.open(str(self.store.path) + ".lock", os.O_WRONLY)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            started = time.monotonic()
            self.assertFalse(self.store.record("wifi", 0.3))
            self.assertLess(time.monotonic() - started, 0.3)
            self.assertEqual(len(self.store.load()["wifi"]), 1)
        finally:
            os.close(fd)

    def test_nonregular_lock_file_does_not_block(self):
        os.mkfifo(str(self.store.path) + ".lock", 0o600)
        started = time.monotonic()
        self.assertFalse(self.store.record("wifi", 0.2))
        self.assertLess(time.monotonic() - started, 0.1)
        self.assertFalse(self.store.path.exists())

    def test_concurrent_workers_do_not_lose_each_others_samples(self):
        program = ("import sys; from capture_timing import SuccessTimingStore; "
                   "s=SuccessTimingStore(sys.argv[1]); "
                   "assert all(s.record(sys.argv[2], 0.2) for _ in range(12))")
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1", PYTHONPATH=str(Path(__file__).resolve().parents[1]))
        workers = [subprocess.Popen([sys.executable, "-c", program, str(self.store.path), lane], env=env,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                   for lane in ("wifi", "usb", "wifi")]
        for process in workers:
            out, error = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 0, (out, error))
        self.assertEqual({lane: len(samples) for lane, samples in self.store.load().items()},
                         {"usb": 12, "wifi": 24})
