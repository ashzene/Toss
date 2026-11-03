"""0.7 synthetic tests: developer image auto-mount, keep-warm, endpoint hint,
setup progress lines. No device, network, keyboard or window calls."""
import asyncio
import contextlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest import mock
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import capture_service as service
import setup_device
from remote_pairing_transport import ENDPOINT_HINT, load_endpoint_hint, save_endpoint_hint
from test_capture_service import png, private_fixture

SERVICES_WITH_IMAGE = {"Services": {service.DEVELOPER_SERVICE: {}, "other": {}}}
SERVICES_WITHOUT_IMAGE = {"Services": {"other": {}}}


class Provider:
    def __init__(self, peer_info):
        self.peer_info = peer_info


class DeveloperImageTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.events = []
        self.handshakes = []
        self.mounts = 0
        owner = self

        class Connection:
            async def __aenter__(self):
                owner.events.append("wifi_enter")
                return Provider(owner.handshakes.pop(0)), {}

            async def __aexit__(self, *_):
                owner.events.append("wifi_exit")

        class Dtx:
            async def wait_disconnected(self):
                await asyncio.Event().wait()

        class Dvt:
            def __init__(self, _provider):
                self.dtx = Dtx()

            async def __aenter__(self):
                owner.events.append("dvt_enter")
                return self

            async def __aexit__(self, *_):
                owner.events.append("dvt_exit")

        class Screenshot:
            def __init__(self, _dvt):
                pass

            async def __aenter__(self):
                return self

            async def __aexit__(self, *_):
                pass

        async def mount(_provider):
            owner.mounts += 1
            owner.events.append("mount")

        self.session = service.CaptureSession("unused", connection_factory=lambda _: Connection(),
                                              dvt_factory=Dvt, screenshot_factory=Screenshot, mount=mount)

    async def asyncTearDown(self):
        await self.session.close()

    async def test_mounted_image_opens_channel_without_mount(self):
        self.handshakes = [SERVICES_WITH_IMAGE]
        await self.session.__aenter__()
        self.assertEqual(self.mounts, 0)
        self.assertEqual(self.events, ["wifi_enter", "dvt_enter"])

    async def test_restarted_ipad_is_mounted_and_reconnected_once(self):
        self.handshakes = [SERVICES_WITHOUT_IMAGE, SERVICES_WITH_IMAGE]
        await self.session.__aenter__()
        self.assertEqual(self.mounts, 1)
        # The stale handshake is closed before the second one; then the channel opens.
        self.assertEqual(self.events, ["wifi_enter", "mount", "wifi_exit", "wifi_enter", "dvt_enter"])
        await self.session.close()
        self.assertEqual(self.events[-2:], ["dvt_exit", "wifi_exit"])

    async def test_still_missing_after_mount_fails_closed(self):
        self.handshakes = [SERVICES_WITHOUT_IMAGE, SERVICES_WITHOUT_IMAGE]
        with self.assertRaises(service.once.CaptureFailure) as raised:
            await self.session.__aenter__()
        self.assertEqual(str(raised.exception), "developer_image_unavailable")
        self.assertEqual(self.mounts, 1)
        self.assertNotIn("dvt_enter", self.events)

    def test_providers_without_handshake_are_not_treated_as_missing(self):
        self.assertFalse(service.developer_image_missing(object()))
        self.assertFalse(service.developer_image_missing(Provider(SERVICES_WITH_IMAGE)))
        self.assertTrue(service.developer_image_missing(Provider(SERVICES_WITHOUT_IMAGE)))


class KeepWarmTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.state, self.output = private_fixture(Path(self.temp.name))
        self.connects = self.closes = self.captures = 0
        self.fail_connects = 0
        self.providers = []
        owner = self

        class Session:
            closing = False

        class Connection:
            async def __aenter__(self):
                owner.connects += 1
                if owner.fail_connects:
                    owner.fail_connects -= 1
                    raise RuntimeError("synthetic unreachable iPad")
                session = Session()
                owner.providers.append(session)
                return session, {}

            async def __aexit__(self, *_):
                owner.closes += 1

        async def capture(_provider):
            owner.captures += 1
            started = time.monotonic()
            return png(), started, time.monotonic()

        self.patches = [mock.patch.object(service, "WARM_CHECK_SECONDS", 0.01),
                        mock.patch.object(service, "WARM_BACKOFF_SECONDS", (0.01,))]
        for patch in self.patches:
            patch.start()
        self.worker = service.CaptureService(self.state, self.output,
                                             connection_factory=lambda _: Connection(), capture=capture)

    async def asyncTearDown(self):
        await self.worker.shutdown()
        for patch in self.patches:
            patch.stop()
        self.temp.cleanup()

    async def wait_for(self, predicate, seconds=1.0):
        deadline = time.monotonic() + seconds
        while not predicate():
            if time.monotonic() > deadline:
                self.fail("condition not reached")
            await asyncio.sleep(0.005)

    async def test_connects_without_capturing_and_has_no_idle_expiry(self):
        self.worker.start_keep_warm()
        await self.wait_for(lambda: self.worker.provider is not None)
        await asyncio.sleep(0.05)
        self.assertEqual((self.connects, self.captures), (1, 0))
        self.assertIsNone(self.worker.idle_task)
        self.assertEqual(list(self.output.iterdir()), [])

    async def test_reconnects_after_device_drops_connection(self):
        self.worker.start_keep_warm()
        await self.wait_for(lambda: self.worker.provider is not None)
        self.providers[-1].closing = True  # Passive EOF: the iPad slept or restarted.
        await self.wait_for(lambda: self.connects == 2 and self.worker._connection_healthy())
        self.assertEqual((self.closes, self.captures), (1, 0))

    async def test_failed_attempts_back_off_and_recover(self):
        self.fail_connects = 3
        self.worker.start_keep_warm()
        await self.wait_for(lambda: self.worker._connection_healthy())
        self.assertEqual(self.connects, 4)
        self.assertEqual(self.captures, 0)

    async def test_capture_after_warm_reuses_connection_once(self):
        self.worker.start_keep_warm()
        await self.wait_for(lambda: self.worker._connection_healthy())
        identity = str(uuid.uuid4())
        receipts = []

        async def emit(receipt):
            receipts.append(receipt)
        await self.worker.accept(json.dumps({"action": "capture", "request_id": identity, "timeout": 8,
            "output_file": str(self.output / (identity + ".png"))}).encode(), emit)
        await self.worker.active
        self.assertTrue(receipts[-1]["ok"], receipts)
        self.assertTrue(receipts[-1]["connection_reused"])
        self.assertEqual((self.connects, self.captures), (1, 1))

    async def test_shutdown_stops_the_loop(self):
        self.fail_connects = 10**6
        self.worker.start_keep_warm()
        await self.wait_for(lambda: self.connects >= 2)
        await self.worker.shutdown()
        count = self.connects
        await asyncio.sleep(0.05)
        self.assertEqual(self.connects, count)
        self.assertIsNone(self.worker.warm_task)


class EndpointHintTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.state = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def test_round_trip_is_private(self):
        save_endpoint_hint(self.state, "192.168.1.20", 49152, "en0")
        self.assertEqual(load_endpoint_hint(self.state, ("en0",)), ("192.168.1.20", 49152, "en0"))
        self.assertEqual((self.state / ENDPOINT_HINT).stat().st_mode & 0o777, 0o600)

    def test_ethernet_interface_hint_round_trip(self):
        save_endpoint_hint(self.state, "10.0.0.2", 49152, "en5")
        self.assertEqual(load_endpoint_hint(self.state, ("en0", "en5")), ("10.0.0.2", 49152, "en5"))
        self.assertEqual(json.loads((self.state / ENDPOINT_HINT).read_text())["interface"], "en5")

    def test_ineligible_interface_or_public_address_ignored(self):
        save_endpoint_hint(self.state, "192.168.1.20", 49152, "en0")
        self.assertIsNone(load_endpoint_hint(self.state, ("en1",)))
        self.assertIsNone(load_endpoint_hint(self.state, ()))
        save_endpoint_hint(self.state, "192.168.1.20", 49152, "utun3")
        self.assertIsNone(load_endpoint_hint(self.state, ("en0", "utun3")))
        save_endpoint_hint(self.state, "8.8.8.8", 49152, "en0")
        self.assertIsNone(load_endpoint_hint(self.state, ("en0",)))

    def test_link_local_ipv6_gets_current_scope(self):
        save_endpoint_hint(self.state, "fe80::1%en0", 50000, "en0")
        self.assertEqual(load_endpoint_hint(self.state, ("en0",)), ("fe80::1%en0", 50000, "en0"))
        save_endpoint_hint(self.state, "fe80::1%en5", 50000, "en5")
        self.assertEqual(load_endpoint_hint(self.state, ("en0", "en5")), ("fe80::1%en5", 50000, "en5"))

    def test_unsafe_or_corrupt_file_ignored(self):
        save_endpoint_hint(self.state, "10.0.0.2", 49152, "en0")
        os.chmod(self.state / ENDPOINT_HINT, 0o644)
        self.assertIsNone(load_endpoint_hint(self.state, ("en0",)))
        (self.state / ENDPOINT_HINT).unlink()
        self.assertIsNone(load_endpoint_hint(self.state, ("en0",)))
        (self.state / ENDPOINT_HINT).write_text("{not json")
        os.chmod(self.state / ENDPOINT_HINT, 0o600)
        self.assertIsNone(load_endpoint_hint(self.state, ("en0",)))
        (self.state / ENDPOINT_HINT).write_text(json.dumps({"ip": "10.0.0.2", "port": 49152}))
        self.assertIsNone(load_endpoint_hint(self.state, ("en0",)))


class SetupProgressTests(unittest.TestCase):
    def test_repeated_progress_is_written_once_and_final_always(self):
        output = io.StringIO()
        emitter = setup_device.Emitter()
        with contextlib.redirect_stdout(output):
            emitter(False, "no_usb_ipad", final=False)
            emitter(False, "no_usb_ipad", final=False)
            emitter(False, "trust_needed", final=False, model="iPad14,3", ipados="18.7", udid="never")
            emitter(True, "ready", model="iPad14,3")
        lines = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual([line["code"] for line in lines], ["no_usb_ipad", "trust_needed", "ready"])
        self.assertEqual([line["final"] for line in lines], [False, False, True])
        self.assertNotIn("udid", lines[1])


if __name__ == "__main__":
    unittest.main()
