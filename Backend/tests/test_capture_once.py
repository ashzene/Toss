"""Synthetic images/fake pairing metadata only. No device, UI, or network calls."""
import asyncio
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import stat
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import capture_once as capture


def png(landscape=False, color="white"):
    from PIL import Image
    image = Image.new("RGB", (2388, 1668) if landscape else (1668, 2388), color)
    output = io.BytesIO()
    image.save(output, format="PNG")
    return output.getvalue()


async def synthetic_capture(_state):
    start = time.monotonic()
    return png(), start, time.monotonic()


async def landscape_capture(_state):
    start = time.monotonic()
    return png(landscape=True), start, time.monotonic()


async def black_capture(_state):
    start = time.monotonic()
    return png(color="black"), start, time.monotonic()


async def exception_capture(_state):
    raise RuntimeError("PRIVATE_KEY=SECRET_DEVICE host=192.0.2.88 SECRET_SERIAL")


async def hanging_capture(_state):
    (_state / "synthetic-worker-pid").write_text(str(os.getpid()))
    await asyncio.sleep(60)
    raise AssertionError("unreachable")


async def old_capture(_state):
    return png(), time.monotonic() - 10, time.monotonic() - 8


class CaptureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.state = self.base / "state"
        self.state.mkdir(mode=0o700)
        # Deliberately not real secrets or pairing data. The mock never reads them.
        for name in ("target.json", "strict-remote-pairing.plist"):
            fd = os.open(self.state / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w") as handle:
                handle.write("synthetic-placeholder")
        self.output = self.base / "new.png"
        self.request_id = str(uuid.uuid4())

    def tearDown(self):
        self.temp.cleanup()

    def request(self, fn=synthetic_capture, timeout=8):
        return capture.run_request(self.state, self.output, self.request_id, timeout, capture=fn)

    def test_success_request_id_dimensions_permissions_and_hash(self):
        result = self.request()
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["request_id"], self.request_id)
        self.assertEqual((result["width"], result["height"]), (1668, 2388))
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o600)
        self.assertEqual(result["sha256"], capture.hashlib.sha256(self.output.read_bytes()).hexdigest())
        self.assertLessEqual(result["request_started_monotonic"], result["capture_started_monotonic"])
        self.assertLessEqual(result["capture_completed_monotonic"], result["request_completed_monotonic"])
        self.assertFalse(list(self.base.glob(".toss-*")))

    def test_landscape_dimensions_preserved(self):
        result = self.request(landscape_capture)
        self.assertTrue(result["ok"], result)
        self.assertEqual((result["width"], result["height"]), (2388, 1668))

    def test_existing_output_is_never_read_or_replaced(self):
        self.output.write_bytes(b"old image sentinel")
        result = self.request(exception_capture)
        self.assertFalse(result["ok"])
        self.assertEqual(result["reason"], "output_already_exists")
        self.assertEqual(self.output.read_bytes(), b"old image sentinel")

    def test_dangling_output_symlink_is_rejected(self):
        self.output.symlink_to(self.base / "missing")
        result = self.request()
        self.assertEqual(result["reason"], "output_already_exists")
        self.assertTrue(self.output.is_symlink())

    def test_black_frame_rejected_without_publishing(self):
        result = self.request(black_capture)
        self.assertEqual(result["reason"], "black_frame_rejected")
        self.assertFalse(self.output.exists())
        self.assertFalse(list(self.base.glob(".toss-*")))

    def test_exception_text_is_not_leaked(self):
        result = self.request(exception_capture)
        self.assertEqual(result["reason"], "capture_failed")
        serialized = json.dumps(result)
        for secret in ("SECRET", "192.0.2.88", "RuntimeError", "PRIVATE_KEY"):
            self.assertNotIn(secret, serialized)
        self.assertFalse(self.output.exists())

    def test_invalid_request_id_not_echoed(self):
        result = capture.run_request(self.state, self.output, "SECRET/../../INVALID", 8,
                                     capture=synthetic_capture)
        self.assertEqual(result["reason"], "invalid_request_id")
        self.assertIsNone(result["request_id"])
        self.assertNotIn("SECRET", json.dumps(result))

    def test_frame_from_before_request_rejected(self):
        result = self.request(old_capture)
        self.assertEqual(result["reason"], "capture_integrity_failed")
        self.assertFalse(self.output.exists())

    def test_timeout_cancels_worker_and_cleans_scratch(self):
        start = time.monotonic()
        result = self.request(hanging_capture, timeout=4)
        self.assertEqual(result["reason"], "timeout")
        self.assertLess(time.monotonic() - start, 4.0)
        self.assertFalse(self.output.exists())
        self.assertFalse(list(self.base.glob(".toss-*")))

    def test_insecure_parent_rejected(self):
        self.base.chmod(0o755)
        result = self.request()
        self.assertEqual(result["reason"], "output_parent_not_private")
        self.assertFalse(self.output.exists())

    def test_insecure_pairing_metadata_rejected(self):
        (self.state / "target.json").chmod(0o644)
        result = self.request()
        self.assertEqual(result["reason"], "pairing_state_not_private")

    def test_unknown_probe_failure_cannot_leak_details(self):
        self.assertEqual(capture.safe_reason(capture.ProbeFailure("SECRET_DEVICE")), "capture_failed")

    def test_16_bit_frame_becomes_8_bit_with_same_pixels_and_profile(self):
        import struct, zlib
        from PIL import Image
        width, height = 2388, 1668
        def chunk(kind, body):
            return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))
        # Every channel sample is 0xAB?? (16-bit, big-endian); the high byte must survive.
        row = b"\x00" + bytes([0xAB, 0x12, 0x40, 0x34, 0xF0, 0x56]) * width
        profile = b"synthetic-icc-profile-bytes"
        source = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 16, 2, 0, 0, 0))
                  + chunk(b"iCCP", b"DisplayP3\x00\x00" + zlib.compress(profile))
                  + chunk(b"IDAT", zlib.compress(row * height)) + chunk(b"IEND", b""))
        result = capture.normalize_png(source)
        self.assertEqual(result[24], 8)
        self.assertLess(len(result), len(source))
        with Image.open(io.BytesIO(result)) as image:
            self.assertEqual((image.mode, image.size), ("RGB", (width, height)))
            self.assertEqual(image.getpixel((0, 0)), (0xAB, 0x40, 0xF0))
            self.assertEqual(image.info.get("icc_profile"), profile)
        self.assertEqual(capture.validate_png(result)["bytes"], len(result))

    @mock.patch.dict(os.environ, {"TOSS_CAPTURE_PNG_MODE": "original"})
    def test_prepare_png_publishes_16_bit_frame_unchanged_after_checks(self):
        import struct, zlib
        width, height = 2388, 1668
        def chunk(kind, body):
            return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))
        row = b"\x00" + bytes([0xAB, 0x12, 0x40, 0x34, 0xF0, 0x56]) * width
        def frame(rows, w=width, h=height):
            return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 16, 2, 0, 0, 0))
                    + chunk(b"iCCP", b"DisplayP3\x00\x00" + zlib.compress(b"icc"))
                    + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))
        source = frame(row * height)
        out, meta = capture.prepare_png(source)
        self.assertIs(out, source)
        self.assertEqual(out[24], 16)
        self.assertEqual((meta["width"], meta["height"], meta["bytes"]), (width, height, len(source)))
        self.assertEqual(meta["bit_depth"], 16)
        self.assertEqual(meta["sha256"], hashlib.sha256(source).hexdigest())
        # Same rejections as validate_png: black, broken and wrong-size 16-bit frames.
        with self.assertRaises(capture.CaptureFailure) as black:
            capture.prepare_png(frame((b"\x00" + b"\x00" * 6 * width) * height))
        self.assertEqual(str(black.exception), "black_frame_rejected")
        broken = bytearray(source); broken[-30] ^= 0xFF
        with self.assertRaises(capture.CaptureFailure):
            capture.prepare_png(bytes(broken))
        small = b"\x00" + bytes([0xAB, 0x12, 0x40, 0x34, 0xF0, 0x56]) * 800
        with self.assertRaises(capture.CaptureFailure) as size:
            capture.prepare_png(frame(small * 600, 800, 600))
        self.assertEqual(str(size.exception), "unexpected_dimensions")
        # 8-bit frames are untouched.
        data = png()
        same, meta8 = capture.prepare_png(data)
        self.assertIs(same, data)
        self.assertEqual(meta8, capture.validate_png(data))
        self.assertEqual(meta8["bit_depth"], 8)

    def test_reduced_black_precheck_matches_full_resolution_rule(self):
        # Speed: the 4x reduced pre-check must decide exactly like the old
        # full-resolution mean/stddev < 3 rule, including near-threshold frames.
        import random
        from PIL import Image, ImageStat
        def old_rule(image):
            stats = ImageStat.Stat(image.convert("RGB"))
            return max(stats.mean) < 3 and max(stats.stddev) < 3
        rng = random.Random(7)
        cases = []
        for level in (0, 1, 2, 3, 4):
            cases.append(Image.new("RGB", (1668, 2388), (level, level, level)))
        for count in (0, 50, 500, 3000, 20000):
            image = Image.new("RGB", (1668, 2388), (2, 2, 2))
            for _ in range(count):
                image.putpixel((rng.randrange(1668), rng.randrange(2388)), (255, 255, 255))
            cases.append(image)
        noisy = Image.effect_noise((1668, 2388), 2).point(lambda v: max(0, min(255, v - 126))).convert("RGB")
        cases.append(noisy)
        for image in cases:
            try:
                capture._check_decoded_pixels(image)
                rejected = False
            except capture.CaptureFailure as error:
                self.assertEqual(str(error), "black_frame_rejected")
                rejected = True
            self.assertEqual(rejected, old_rule(image))

    def test_any_ipad_screen_size_accepted_others_rejected(self):
        for size in [(1668, 2388), (2388, 1668), (1488, 2266), (1640, 2360), (2064, 2752),
                     (2048, 2732), (1620, 2160), (1668, 2420), (2752, 2064)]:
            self.assertTrue(capture.screen_dimensions_ok(size), size)
        for size in [(1668, 1668), (1179, 2556), (800, 1200), (3000, 4000), (0, 2388),
                     (1668.0, 2388), None, (1, 2, 3)]:
            self.assertFalse(capture.screen_dimensions_ok(size), size)

    def test_8_bit_frame_is_returned_byte_for_byte(self):
        data = png()
        self.assertIs(capture.normalize_png(data), data)
        self.assertEqual(capture.normalize_png(b"not a png"), b"not a png")

    def test_invalid_image_and_partial_png_rejected(self):
        for value in (b"", b"not a png", b"\x89PNG\r\n\x1a\n"):
            with self.subTest(value=value), self.assertRaises(capture.CaptureFailure):
                capture.validate_png(value)

    def test_cli_invalid_arguments_do_not_echo_paths(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = capture.main(["--unknown=SECRET_PATH"])
        self.assertEqual(status, 1)
        self.assertEqual(json.loads(output.getvalue())["reason"], "invalid_arguments")
        self.assertNotIn("SECRET", output.getvalue())

    def start_cancellation_harness(self):
        process = subprocess.Popen([
            sys.executable, str(Path(__file__).resolve()), "--cancellation-harness",
            str(self.state), str(self.output), self.request_id,
        ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        marker = self.state / "synthetic-worker-pid"
        deadline = time.monotonic() + 3.0
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        if not marker.exists():
            process.kill()
            process.communicate()
            self.fail("synthetic worker did not start")
        return process, int(marker.read_text())

    def assert_worker_exited(self, pid):
        deadline = time.monotonic() + 1.0
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return
            time.sleep(0.02)
        self.fail("synthetic capture worker remained alive")

    def test_sigterm_cleans_worker_under_native_grace_period(self):
        process, worker_pid = self.start_cancellation_harness()
        started = time.monotonic()
        process.terminate()
        stdout, stderr = process.communicate(timeout=1.0)
        self.assertLess(time.monotonic() - started, 1.0)
        self.assertEqual(json.loads(stdout)["reason"], "cancelled")
        self.assertEqual(stderr, "")
        self.assert_worker_exited(worker_pid)
        self.assertFalse(self.output.exists())
        self.assertFalse(list(self.base.glob(".toss-*")))

    def test_worker_exits_if_supervisor_is_force_killed(self):
        process, worker_pid = self.start_cancellation_harness()
        process.kill()
        process.communicate(timeout=1.0)
        self.assert_worker_exited(worker_pid)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--cancellation-harness":
        def cancel(_signum, _frame):
            raise KeyboardInterrupt
        signal.signal(signal.SIGTERM, cancel)
        result = capture.run_request(Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4], 40,
                                     capture=hanging_capture)
        print(json.dumps(result), flush=True)
    else:
        unittest.main()
