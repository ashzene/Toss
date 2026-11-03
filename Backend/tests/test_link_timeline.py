import json
import os
import socket
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import link_timeline as lt


def info(rx_ooo=0, retx=0, unsent=0, rto=0, rtt=10):
    return {"rto": rto, "unsent": unsent, "rtt": rtt, "rttvar": 2, "tx_packets": 1,
            "rx_bytes": 0, "rx_ooo_bytes": rx_ooo, "tx_retx_packets": retx}


class SummaryTests(unittest.TestCase):
    def test_steady_transfer_has_first_byte_and_no_stalls(self):
        packets = [(0.05 + i * 0.002, 1400) for i in range(40)] + [(0.06, 80)]
        summary, detail = lt.summarize(0.0, 0.2, packets, [(0.0, info()), (0.2, info())], "ok")
        self.assertAlmostEqual(summary["link_first_byte"], 50.0)
        self.assertEqual(summary["link_stalls"], 0)
        self.assertAlmostEqual(summary["link_rx_kb"], 40 * 1400 / 1024)
        self.assertEqual(detail["stalls_ms"], [])

    def test_stall_and_socket_state_during_it(self):
        packets = [(0.05, 1400), (0.06, 1400), (1.10, 1400), (1.11, 1400)]
        samples = [(0.0, info()), (0.5, info(unsent=512, rto=400)), (1.2, info(rx_ooo=2800, retx=3))]
        summary, detail = lt.summarize(0.0, 1.2, packets, samples, "ok")
        self.assertEqual(summary["link_stalls"], 1)
        self.assertAlmostEqual(summary["link_stall_max"], 1040.0)
        self.assertEqual(summary["link_stall_unsent"], 512)
        self.assertEqual(summary["link_stall_rto"], 400)
        self.assertAlmostEqual(summary["link_rx_ooo_kb"], 2800 / 1024)
        self.assertEqual(summary["link_tx_retx"], 3)
        self.assertEqual(detail["stalls_ms"], [[60, 1040]])

    def test_timeout_with_nothing_received_is_one_stall(self):
        summary, _ = lt.summarize(0.0, 2.0, [(0.5, 60)], [], "error")
        self.assertEqual(summary["link_stalls"], 1)
        self.assertAlmostEqual(summary["link_stall_max"], 2000.0)
        self.assertNotIn("link_rtt", summary)

    def test_trailing_stall_counts_only_on_failure(self):
        packets = [(0.05, 1400), (0.10, 1400)]
        ok, _ = lt.summarize(0.0, 0.5, packets, [], "ok")
        failed, _ = lt.summarize(0.0, 0.5, packets, [], "error")
        self.assertEqual((ok["link_stalls"], failed["link_stalls"]), (0, 1))

    def test_projected_finish(self):
        self.assertIsNone(lt.projected_finish(None, 1.0, 0, 1000))
        self.assertEqual(lt.projected_finish(0.0, 1.0, 1000, 1000), 1.0)
        self.assertAlmostEqual(lt.projected_finish(0.0, 1.0, 100, 400), 4.0)

    def test_usb_previous_large_frame_does_not_abort_current_progress(self):
        # A previous wide-colour frame can be 11 MiB while this frame is only
        # 400 KiB. At 500 KiB/s the latter completes in 0.8 s, inside the cap.
        class Tun:
            def write(self, data):
                return len(data)
        link = lt.Link(Tun(), None)
        link.allow_size_prediction = False
        link.packets = [(10 + i * 0.1, 50 * 1024) for i in range(8)]
        recording = lt.Recording.__new__(lt.Recording)
        recording.link, recording.started = link, 10.0
        with mock.patch.object(lt, "expected_bytes", 11 * 1024 * 1024):
            self.assertIsNone(recording.verdict(10.7, 0.8, 1.2, 14.5))
            self.assertGreater(recording.projected, 14.5)  # estimate stays diagnostic

    def test_usb_still_enforces_first_byte_and_stall_limits(self):
        class Tun:
            def write(self, data):
                return len(data)
        link = lt.Link(Tun(), None)
        link.allow_size_prediction = False
        recording = lt.Recording.__new__(lt.Recording)
        recording.link, recording.started = link, 10.0
        link.packets = []
        self.assertIsNone(recording.verdict(10.79, 0.8, 1.2, 14.5))
        self.assertEqual(recording.verdict(10.81, 0.8, 1.2, 14.5), "first_byte_timeout")
        link.packets = [(10.2, 1400)]
        self.assertIsNone(recording.verdict(11.39, 0.8, 1.2, 14.5))
        self.assertEqual(recording.verdict(11.41, 0.8, 1.2, 14.5), "stall_timeout")

    def test_no_tunnel_records_nothing(self):
        lt._current = None
        self.assertEqual(lt.Recording().finish("ok"), (None, None))

    def test_hook_passes_packets_through_unchanged(self):
        class Tun:
            def __init__(self):
                self.seen = []
            def write(self, data):
                self.seen.append(data)
                return len(data)
        class Tunnel:
            tun = Tun()
        tunnel = Tunnel()
        lt.attach(tunnel, None)
        self.assertEqual(tunnel.tun.write(b"x" * 300), 300)
        lt._current.packets = []
        tunnel.tun.write(b"y" * 500)
        self.assertEqual(tunnel.tun.seen, [b"x" * 300, b"y" * 500])
        self.assertEqual([n for _, n in lt._current.packets], [500])
        lt._current = None

    def test_socket_info_on_a_real_local_socket(self):
        # TCP_CONNECTION_INFO is available before connect on Darwin. This tests
        # the real kernel layout without opening a listener or requiring network
        # permission; RTT/traffic values are not asserted by this shape test.
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as client:
            value = lt.socket_info(client)
            if sys.platform == "darwin":
                self.assertEqual(set(value), {"rto", "unsent", "rtt", "rttvar", "tx_packets", "rx_bytes",
                                              "rx_ooo_bytes", "tx_retx_packets"})
            self.assertIsNone(lt.socket_info(None))

    def test_log_is_owner_only_and_bounded(self):
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "link-timeline.jsonl")
            for i in range(lt.LOG_LINES + 5):
                lt.append_log(path, {"n": i})
            lines = Path(path).read_text().splitlines()
            self.assertEqual(len(lines), lt.LOG_LINES)
            self.assertEqual(json.loads(lines[-1])["n"], lt.LOG_LINES + 4)
            self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
