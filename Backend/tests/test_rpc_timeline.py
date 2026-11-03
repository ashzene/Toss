"""Pinned DTX codec + synthetic StreamReader: no sockets or device access."""
import asyncio
from pathlib import Path
import sys
import time
import tempfile
import json
from types import SimpleNamespace
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import link_timeline as lt
import capture_service as service


class FragmentTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.assertTrue(lt.install_rpc_hook())
        self.stream = asyncio.StreamReader()
        screenshot = SimpleNamespace(dtx=SimpleNamespace(_reader=self.stream, _pending_replies={12: object(), 0: object()}),
            service=SimpleNamespace(_channel=SimpleNamespace(code=7)))
        self.recording = lt.RPCRecording(screenshot, time.monotonic())

    async def asyncTearDown(self):
        self.recording.finish()

    async def test_each_real_codec_fragment_is_timed_without_retaining_payload(self):
        from pymobiledevice3.dtx.fragment import DTXFragment
        fragments = [DTXFragment(index=0, count=3, data_size=6, channel_code=7,
                        conversation_index=1, identifier=12),
                     DTXFragment(index=1, count=3, data_size=3, channel_code=7,
                        conversation_index=1, identifier=12, payload=memoryview(b"abc")),
                     DTXFragment(index=2, count=3, data_size=3, channel_code=7,
                        conversation_index=1, identifier=12, payload=memoryview(b"def"))]
        self.assertIsNone(self.recording.progress(time.monotonic()))
        for index, fragment in enumerate(fragments):
            for chunk in fragment.chunks():
                self.stream.feed_data(chunk)
            returned = await DTXFragment.read(self.stream)
            self.assertEqual(bytes(returned.payload), bytes(fragment.payload))
            self.assertEqual(self.recording.progress(time.monotonic()),
                             {"rpc_received_bytes": index * 3, "expected_bytes": 6})
            await asyncio.sleep(0.002)
        detail = self.recording.finish()
        self.assertTrue(detail["rpc_fragments_available"])
        self.assertEqual([f["index"] for f in detail["rpc_fragments"]], [0, 1, 2])
        self.assertEqual([f["bytes"] for f in detail["rpc_fragments"]], [0, 3, 3])
        self.assertTrue(all(f["read_ms"] >= 0 for f in detail["rpc_fragments"]))
        self.assertGreater(detail["rpc_fragments"][-1]["at_ms"], detail["rpc_fragments"][0]["at_ms"])
        self.assertNotIn("abc", str(detail))
        self.assertNotIn(self.stream, lt._rpc_recordings)

    async def test_control_events_and_other_channels_are_not_screenshot_fragments(self):
        from pymobiledevice3.dtx.fragment import DTXFragment
        for channel, conversation in [(0, 1), (8, 1), (7, 0)]:
            f = DTXFragment(index=0, count=1, data_size=3, channel_code=channel,
                conversation_index=conversation, payload=memoryview(b"xyz"))
            self.stream.feed_data(b"".join(f.chunks()))
            returned = await DTXFragment.read(self.stream)
            self.assertEqual(bytes(returned.payload), b"xyz")
        self.assertEqual(self.recording.finish()["rpc_fragments"], [])

    async def test_completed_capture_unsubscribes_late_fragments(self):
        from pymobiledevice3.dtx.fragment import DTXFragment
        self.recording.finish()
        f = DTXFragment(index=0, count=1, data_size=3, channel_code=7,
            conversation_index=1, payload=memoryview(b"xyz"))
        self.stream.feed_data(b"".join(f.chunks()))
        await DTXFragment.read(self.stream)
        self.assertEqual(self.recording.fragments, [])

    async def test_observer_is_bounded_and_does_not_change_codec_exceptions(self):
        from pymobiledevice3.dtx.fragment import DTXFragment
        f = DTXFragment(index=0, count=1, data_size=3, channel_code=7,
            conversation_index=1, payload=memoryview(b"xyz"))
        with mock.patch.object(lt, "MAX_RPC_FRAGMENTS", 2):
            for _ in range(5):
                self.stream.feed_data(b"".join(f.chunks()))
                await DTXFragment.read(self.stream)
        self.assertEqual(len(self.recording.fragments), 2)
        self.assertEqual(self.recording.dropped, 3)
        self.stream.feed_eof()
        with self.assertRaises(asyncio.IncompleteReadError):
            await DTXFragment.read(self.stream)

    async def test_stale_message_id_on_same_channel_is_excluded(self):
        from pymobiledevice3.dtx.fragment import DTXFragment
        f = DTXFragment(index=0, count=1, data_size=3, channel_code=7,
            conversation_index=1, identifier=99, payload=memoryview(b"xyz"))
        self.stream.feed_data(b"".join(f.chunks()))
        await DTXFragment.read(self.stream)
        self.assertEqual(self.recording.fragments, [])

    async def test_session_emits_bounded_summary_and_keeps_fragments_in_log_only(self):
        from pymobiledevice3.dtx.fragment import DTXFragment
        self.recording.finish()
        async def rpc():
            f = DTXFragment(index=0, count=1, data_size=3, channel_code=7,
                conversation_index=1, identifier=12, payload=memoryview(b"xyz"))
            self.stream.feed_data(b"".join(f.chunks()))
            await DTXFragment.read(self.stream)
            return b"synthetic-frame"
        screenshot = SimpleNamespace(dtx=SimpleNamespace(_reader=self.stream, _pending_replies={12: object()}),
            service=SimpleNamespace(_channel=SimpleNamespace(code=7)), get_screenshot=rpc)
        with tempfile.TemporaryDirectory() as folder, mock.patch.object(lt, "_current", None):
            session = service.CaptureSession(Path(folder) / "state")
            session.screenshot, session.ready = screenshot, True
            data, _, _ = await session.capture()
            self.assertEqual(data, b"synthetic-frame")
            self.assertEqual(session.last_link["rpc_fragment_count"], 1)
            self.assertGreaterEqual(session.last_link["rpc_first_fragment"], 0)
            self.assertEqual(session.last_link["rpc_first_fragment"], session.last_link["rpc_last_fragment"])
            detail = json.loads((Path(folder) / "link-timeline.jsonl").read_text())
            self.assertEqual(len(detail["rpc_fragments"]), 1)
            self.assertNotIn("rpc_fragments", session.last_link)
            self.assertNotIn(self.stream, lt._rpc_recordings)

    def test_roles_have_distinct_logs_and_usb_retains_fast_fallback(self):
        state = Path("/synthetic/private/state")
        primary = service.worker_session(state, "wifi", "wifi_primary")
        standby = service.worker_session(state, "wifi", "wifi_standby")
        usb = service.worker_session(state, "usb", "usb_primary")
        self.assertFalse(hasattr(primary, "timeline_path"))
        self.assertEqual(standby.timeline_path.name, "link-timeline-wifi-standby.jsonl")
        self.assertEqual(usb.timeline_path.name, "link-timeline-usb.jsonl")
        self.assertFalse(primary.progress_fail_fast)
        self.assertFalse(standby.progress_fail_fast)
        self.assertTrue(usb.progress_fail_fast)


if __name__ == "__main__":
    unittest.main()
