"""Synthetic iPhone regression tests. No real device, pairing, network or UI.

IPHONE_BACKEND_UNDER_TEST selects the untouched baseline for the negative run.
The same tests then run against patched/ with the normal backend test script.
"""
import asyncio
import contextlib
import io
import json
import os
from pathlib import Path
import socket
import struct
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, patch
import uuid
import zlib

BACKEND = Path(os.environ.get("IPHONE_BACKEND_UNDER_TEST", Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(BACKEND))
sys.path.insert(0, str(BACKEND / "vendor"))
import capture_once as once
import capture_service as service
import ipad_probe as identity
import remote_pairing_transport as remote
import setup_device as setup
import usb_transport as usb
import wifi_transport as wifi
import pymobiledevice3.common as common
from pymobiledevice3 import lockdown, usbmux

PHONE_SIZES = ((750, 1334), (1170, 2532), (1290, 2796), (1320, 2868), (1260, 2736))
PAD_SIZES = ((1668, 2388), (1488, 2266), (2064, 2752))


def png(size=(750, 1334), color="white", depth=8):
    if depth == 16:
        def chunk(kind, data):
            return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
        width, height = size
        pixel = b"\x00" * 6 if color == "black" else b"\xff" * 6
        raw = (b"\x00" + pixel * width) * height
        return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 16, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
    from PIL import Image
    output = io.BytesIO()
    Image.new("RGB", size, color).save(output, format="PNG")
    return output.getvalue()


async def phone_capture(_state):
    started = time.monotonic()
    return png(), started, time.monotonic()


async def phone_landscape_capture(_state):
    started = time.monotonic()
    return png((1334, 750)), started, time.monotonic()


async def pad_capture(_state):
    started = time.monotonic()
    return png(PAD_SIZES[0]), started, time.monotonic()


class PrivateState:
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.state, self.output = self.base / "state", self.base / "output"
        self.state.mkdir(mode=0o700)
        self.output.mkdir(mode=0o700)
        (self.state / "cache").mkdir(mode=0o700)
        cache_patch = patch.object(common, "_HOMEFOLDER", self.state / "cache")
        cache_patch.start()
        self.addCleanup(cache_patch.stop)
        self.serial = "synthetic-iphone"
        self.device_hash = identity.fingerprint(self.serial)

    def pin(self, model="iPhone17,3", **extra):
        value = {"model": model, "device_hash": self.device_hash, **extra}
        self.write_pin(value)
        return value

    def write_pin(self, value):
        for name, contents in (("target.json", json.dumps(value)),
                               ("strict-remote-pairing.plist", "synthetic-only")):
            path = self.state / name
            path.write_text(contents)
            path.chmod(0o600)


class FakeLockdown:
    def __init__(self, model="iPhone17,3", version="18.7", paired=True, serial="synthetic-iphone"):
        self.product_type, self.product_version, self.paired = model, version, paired
        self.udid = serial
        self.close = AsyncMock()
        self.get_developer_mode_status = AsyncMock(return_value=True)

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_):
        await self.close()


@contextlib.contextmanager
def inventory(models, *, version="18.7", network=False):
    devices = [SimpleNamespace(serial=f"synthetic-{i}", is_usb=not network)
               for i in range(len(models))]
    async def create(**kwargs):
        index = next(i for i, device in enumerate(devices) if device.serial == kwargs["serial"])
        if models[index] is None:
            raise OSError("synthetic locked device")
        return FakeLockdown(models[index], version, serial=devices[index].serial)
    with patch.object(usbmux, "list_devices", AsyncMock(return_value=devices)), \
         patch.object(lockdown, "create_using_usbmux", AsyncMock(side_effect=create)) as factory:
        yield factory


class SetupTests(PrivateState, unittest.IsolatedAsyncioTestCase):
    async def next_result(self, models, *, version="18.7"):
        output = io.StringIO()
        with inventory(models, version=version), contextlib.redirect_stdout(output), \
             patch.object(setup, "emit", setup.Emitter()), \
             patch.object(setup, "lockdown_for", AsyncMock(return_value=FakeLockdown())), \
             patch.object(setup, "finish_pairing", AsyncMock(return_value="ready")) as finish:
            code = await setup.next_step(self.state)
        return code, [json.loads(line) for line in output.getvalue().splitlines()], finish

    async def test_iphone_inventory_carries_class_without_pairing(self):
        with inventory(["iPhone17,3"]) as factory:
            devices = await setup.usb_ipads(self.state / "cache")
        self.assertEqual(len(devices), 1)
        self.assertEqual(devices[0][1:], ("iPhone17,3", "18.7", True, "iPhone"))
        self.assertFalse(factory.call_args.kwargs["autopair"])

    async def test_ipad_inventory_carries_class(self):
        with inventory(["iPad14,3"]):
            devices = await setup.usb_ipads(self.state / "cache")
        self.assertEqual(devices[0][1:], ("iPad14,3", "18.7", True, "iPad"))

    async def test_network_device_is_not_a_usb_candidate(self):
        with inventory(["iPhone17,3"], network=True) as factory:
            self.assertEqual(await setup.usb_ipads(self.state / "cache"), [])
        factory.assert_not_awaited()

    async def test_mixed_usb_devices_legacy_next(self):
        code, lines, finish = await self.next_result(["iPad14,3", "iPhone17,3"])
        self.assertEqual(code, "mixed_usb_devices")
        self.assertTrue(lines[-1]["final"])
        finish.assert_not_awaited()

    async def test_same_class_multiple_devices_keep_existing_code(self):
        for models in (["iPhone17,3", "iPhone15,2"], ["iPad14,3", "iPad8,1"]):
            with self.subTest(models=models):
                code, _, finish = await self.next_result(models)
                self.assertEqual(code, "multiple_usb_ipads")
                finish.assert_not_awaited()

    async def test_unsupported_models_never_pair(self):
        for model in ("iPod9,1", "AppleTV14,1", "Watch7,1", "RealityDevice14,1"):
            with self.subTest(model=model):
                code, _, finish = await self.next_result([model])
                self.assertEqual(code, "unsupported_device")
                finish.assert_not_awaited()
                self.assertFalse((self.state / "target.json").exists())

    async def test_supported_phone_with_ipod_can_pair_and_emits_aliases(self):
        code, lines, finish = await self.next_result(["iPod9,1", "iPhone17,3"])
        self.assertEqual(code, "ready")
        self.assertEqual(lines[-1]["device_class"], "iPhone")
        self.assertEqual(lines[-1]["ipados"], lines[-1]["os_version"])
        self.assertEqual(finish.call_args.args[-2:], ("iPhone17,3", "18.7"))

    async def test_ios_16_rejected_and_17_accepted_with_existing_version_code(self):
        code, lines, finish = await self.next_result(["iPhone17,3"], version="16.7")
        self.assertEqual(code, "unsupported_ipados")
        self.assertEqual(lines[-1]["os_version"], "16.7")
        finish.assert_not_awaited()
        code, _, _ = await self.next_result(["iPhone17,3"], version="17.0")
        self.assertEqual(code, "ready")

    async def test_auto_reports_new_selection_codes_and_waits(self):
        for models, code in ((["iPad14,3", "iPhone17,3"], "mixed_usb_devices"),
                             (["iPod9,1"], "unsupported_device"),
                             (["iPhone17,3", "iPhone15,2"], "multiple_usb_ipads"),
                             ([None, "iPhone17,3"], "multiple_usb_ipads"),
                             ([], "no_usb_ipad")):
            with self.subTest(models=models):
                output = io.StringIO()
                with inventory(models), contextlib.redirect_stdout(output), \
                     patch.object(setup, "emit", setup.Emitter()), \
                     patch.object(asyncio, "sleep", AsyncMock(side_effect=asyncio.CancelledError)), \
                     patch.object(setup, "finish_pairing", AsyncMock()) as finish:
                    with self.assertRaises(asyncio.CancelledError):
                        await setup.auto(self.state)
                event = json.loads(output.getvalue().splitlines()[0])
                self.assertEqual(event["code"], code)
                self.assertFalse(event["final"])
                finish.assert_not_awaited()

    async def test_auto_phone_ready_has_new_fields(self):
        output = io.StringIO()
        with inventory(["iPhone17,3"]), contextlib.redirect_stdout(output), \
             patch.object(setup, "emit", setup.Emitter()), \
             patch.object(setup, "lockdown_for", AsyncMock(return_value=FakeLockdown())), \
             patch.object(setup, "finish_pairing", AsyncMock(return_value="ready")):
            self.assertEqual(await asyncio.wait_for(setup.auto(self.state), timeout=1), "ready")
        event = json.loads(output.getvalue().splitlines()[-1])
        self.assertEqual((event["device_class"], event["os_version"], event["ipados"]),
                         ("iPhone", "18.7", "18.7"))

    async def test_finish_pairing_writes_private_phone_target_and_same_mount_path(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output), patch.object(setup, "emit", setup.Emitter()), \
             patch.object(remote, "bootstrap_usb", AsyncMock()) as bootstrap, \
             patch.object(setup, "mount_over_usb", AsyncMock()) as mount, \
             patch.object(setup, "wifi_prepare_with_retries", AsyncMock(return_value="ready")):
            code = await setup.finish_pairing(self.state, self.serial, self.state / "cache",
                                              self.serial, "iPhone17,3", "18.7")
        self.assertEqual(code, "ready")
        self.assertEqual(json.loads((self.state / "target.json").read_text()),
                         {"model": "iPhone17,3", "device_hash": self.device_hash, "device_class": "iPhone"})
        self.assertEqual((self.state / "target.json").stat().st_mode & 0o777, 0o600)
        bootstrap.assert_awaited_once_with(self.state, apply_device_change=True)
        mount.assert_awaited_once_with(self.serial, self.state / "cache", model="iPhone17,3", ipados="18.7")
        for line in output.getvalue().splitlines():
            self.assertEqual(json.loads(line)["device_class"], "iPhone")

    async def test_existing_legacy_phone_pairing_infers_class_for_progress(self):
        self.pin()
        output = io.StringIO()
        with patch.object(setup, "wifi_prepare_with_retries", AsyncMock(return_value="ready")), \
             patch.object(setup, "emit", setup.Emitter()), contextlib.redirect_stdout(output):
            self.assertEqual(await setup.auto(self.state), "ready")
        event = json.loads(output.getvalue().splitlines()[-1])
        self.assertEqual(event["device_class"], "iPhone")
        self.assertNotIn("os_version", event)  # No live version was obtained.

    async def test_amfi_phone_enable_reveal_and_post_restart(self):
        from pymobiledevice3.exceptions import DeviceHasPasscodeSetError
        client = FakeLockdown()
        for passcode in (False, True):
            fake = SimpleNamespace(enable_developer_mode=AsyncMock(
                side_effect=DeviceHasPasscodeSetError() if passcode else None),
                reveal_developer_mode_option_in_ui=AsyncMock(), enable_developer_mode_post_restart=AsyncMock())
            with patch("pymobiledevice3.services.amfi.AmfiService", return_value=fake) as factory:
                self.assertEqual(await setup.try_enable_developer_mode(client), "manual" if passcode else "rebooting")
                fake.enable_developer_mode.assert_awaited_once_with(enable_post_restart=False)
                self.assertEqual(fake.reveal_developer_mode_option_in_ui.await_count, int(passcode))
                self.assertTrue(await setup.try_accept_developer_mode(client))
                fake.enable_developer_mode_post_restart.assert_awaited_once()
                factory.assert_called_with(client)

    async def test_ddi_iphone_uses_same_personalized_dispatch(self):
        from pymobiledevice3.services import mobile_image_mounter as images
        for model in ("iPhone17,3", "iPad14,3"):
            for version in ("17.0", "18.7", "26.0"):
                client = FakeLockdown(model, version)
                with patch.object(setup, "lockdown_for", AsyncMock(return_value=client)), \
                     patch.object(images, "auto_mount_personalized", AsyncMock()) as personalized, \
                     patch.object(images, "auto_mount_developer", AsyncMock()) as legacy:
                    await setup.mount_over_usb(self.serial, self.state / "cache")
                personalized.assert_awaited_once_with(client)
                legacy.assert_not_awaited()

    async def test_ddi_download_reports_bytes_before_returning_to_install(self):
        from developer_disk_image.repo import DeveloperDiskImageRepository
        from pymobiledevice3.services import mobile_image_mounter as images

        async def fake_mount(_):
            DeveloperDiskImageRepository.create().get_personalized_disk_image()

        def fake_download(url, headers, progress=None):
            if url.endswith("/Image.dmg"):
                self.assertEqual(headers["Accept-Encoding"], "identity")
                for percent in (0, 37, 100):
                    progress(percent)
            else:
                self.assertIsNone(progress)
            return b"component"

        original = DeveloperDiskImageRepository._get_blob
        output = io.StringIO()
        with contextlib.redirect_stdout(output), patch.object(setup, "emit", setup.Emitter()), \
             patch.object(images, "auto_mount", side_effect=fake_mount), \
             patch("developer_image_download.download_blob", side_effect=fake_download):
            await setup.mount_image(FakeLockdown(), model="iPhone17,3", ipados="18.7")
        events = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual([(event["code"], event.get("download_percent")) for event in events], [
            ("downloading_image", None), ("downloading_image", 0), ("downloading_image", 37),
            ("downloading_image", 100), ("preparing_image", None),
        ])
        self.assertTrue(all(not event["final"] and event["device_class"] == "iPhone" for event in events))
        self.assertIs(DeveloperDiskImageRepository._get_blob, original)


class PinTests(PrivateState, unittest.TestCase):
    def test_old_target_infers_both_classes_without_rewriting(self):
        for model, device_class in (("iPhone17,3", "iPhone"), ("iPad14,3", "iPad")):
            self.pin(model)
            before = (self.state / "target.json").read_bytes()
            _, pin, _ = remote.configure(self.state)
            self.assertEqual(pin["device_class"], device_class)
            self.assertEqual((self.state / "target.json").read_bytes(), before)

    def test_usb_accepts_old_and_new_iphone_pins(self):
        for extra in ({}, {"device_class": "iPhone"}):
            self.pin(**extra)
            with patch.object(usb, "load_record", return_value={"pinned_udid": self.serial}):
                self.assertEqual(usb.pinned_identity(self.state), (self.serial, self.device_hash))

    def test_mismatching_and_invalid_classes_rejected_by_both_transports(self):
        for model, device_class in (("iPhone17,3", "iPad"), ("iPad14,3", "iPhone"),
                                    ("iPhone17,3", None), ("iPad14,3", "Watch")):
            self.pin(model, device_class=device_class)
            for reader in (usb.pinned_identity, remote.configure):
                with self.subTest(model=model, device_class=device_class, reader=reader.__name__), \
                     patch.object(usb, "load_record", return_value={"pinned_udid": self.serial}):
                    with self.assertRaisesRegex(identity.ProbeFailure, "^unexpected_device_pin$"):
                        reader(self.state)

    def test_corrupt_or_unsupported_pins_are_unpaired_without_crashing(self):
        for value in ({"model": "iPod9,1", "device_hash": "synthetic"},
                      {"model": None}, {}, [], None):
            with self.subTest(value=value):
                self.write_pin(value)
                self.assertFalse(setup.has_pairing(self.state))
                with self.assertRaisesRegex(identity.ProbeFailure, "^unexpected_device_pin$"):
                    remote.configure(self.state)
        (self.state / "target.json").write_text("{broken")
        self.assertFalse(setup.has_pairing(self.state))

    def test_emitter_aliases_keep_sanitization_and_deduplication(self):
        emitter = setup.Emitter()
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            for _ in range(2):
                emitter(False, "trust_needed", final=False, model="iPhone17,3", ipados="18.7",
                        os_version="wrong", device_class="iPad", udid="SECRET")
            emitter(True, "ready", model="iPhone17,3", ipados="18.7")
        lines = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(len(lines), 2)
        for line in lines:
            self.assertEqual(line["device_class"], "iPhone")
            self.assertEqual(line["os_version"], line["ipados"])
            self.assertNotIn("udid", line)

    def test_iphone_usb_network_never_becomes_lan(self):
        ports = (("Wi-Fi", "en0"), ("iPhone USB", "en5"), ("iPad USB", "en6"),
                 ("USB 10/100/1000 LAN", "en7"))
        addresses = {name: [SimpleNamespace(family=socket.AF_INET, address="192.168.1.2")]
                     for _, name in ports}
        stats = {name: SimpleNamespace(isup=True) for _, name in ports}
        self.assertEqual(wifi.select_lan_interfaces(ports, addresses, stats), ("en0", "en7"))


class DimensionTests(unittest.TestCase):
    def test_all_required_phone_sizes_both_orientations(self):
        for size in PHONE_SIZES:
            for oriented in (size, size[::-1]):
                with self.subTest(size=oriented):
                    self.assertTrue(once.screen_dimensions_ok(oriented, "iPhone"))
                    self.assertFalse(once.screen_dimensions_ok(oriented, "iPad"))

    def test_ipad_rules_unchanged_and_phone_pin_rejects_ipad_sizes(self):
        for size in PAD_SIZES:
            for oriented in (size, size[::-1]):
                self.assertTrue(once.screen_dimensions_ok(oriented))
                self.assertTrue(once.screen_dimensions_ok(oriented, "iPad"))
                self.assertFalse(once.screen_dimensions_ok(oriented, "iPhone"))

    def test_phone_boundaries_and_malformed_dimensions(self):
        for size in ((700, 1300), (1400, 3000), (1000, 1700), (1000, 2250)):
            self.assertTrue(once.screen_dimensions_ok(size, "iPhone"), size)
        for size in ((699, 1400), (750, 1299), (1401, 2802), (1400, 3001),
                     (1000, 1699), (1000, 2251), (1000, 1000), (True, 1400),
                     (750.0, 1334), (0, 1400), (-750, 1334), (750,), None):
            self.assertFalse(once.screen_dimensions_ok(size, "iPhone"), size)
        for device_class in (None, "Watch", "iphone"):
            self.assertFalse(once.screen_dimensions_ok(PAD_SIZES[0], device_class))

    def test_all_phone_png_sizes_preserved_without_resizing(self):
        for size in PHONE_SIZES:
            for oriented in (size, size[::-1]):
                data = png(oriented)
                prepared, metadata = once.prepare_png(data, "iPhone")
                self.assertEqual(prepared, data)
                self.assertEqual((metadata["width"], metadata["height"]), oriented)

    def test_16bit_phone_validation_and_normalization(self):
        source = png(depth=16)
        prepared, metadata = once.prepare_png(source, "iPhone")
        self.assertEqual(prepared, source)
        self.assertEqual(metadata["bit_depth"], 16)
        normalized = once.normalize_png(source, "iPhone")
        self.assertEqual(normalized[24], 8)
        self.assertEqual(once.validate_png(normalized, "iPhone")["width"], 750)

    def test_cross_class_pngs_rejected_in_both_validation_paths(self):
        for depth in (8, 16):
            for size, device_class in ((PHONE_SIZES[0], "iPad"), (PAD_SIZES[0], "iPhone")):
                for validate in (once.validate_png, once.prepare_png):
                    with self.subTest(depth=depth, size=size, validate=validate.__name__):
                        with self.assertRaisesRegex(once.CaptureFailure, "^unexpected_dimensions$"):
                            validate(png(size, depth=depth), device_class)

    def test_iphone_black_and_broken_frames_still_fail(self):
        for depth in (8, 16):
            with self.assertRaisesRegex(once.CaptureFailure, "^black_frame_rejected$"):
                once.prepare_png(png(color="black", depth=depth), "iPhone")
        with self.assertRaisesRegex(once.CaptureFailure, "^invalid_png$"):
            once.prepare_png(png()[:-20], "iPhone")


class CaptureTests(PrivateState, unittest.TestCase):
    def request(self, capture):
        output = self.output / f"{uuid.uuid4()}.png"
        result = once.run_request(self.state, output, str(uuid.uuid4()), 8, capture=capture)
        return result, output

    def test_single_capture_legacy_phone_pin_including_parent_revalidation(self):
        self.pin()
        for capture, size in ((phone_capture, (750, 1334)), (phone_landscape_capture, (1334, 750))):
            result, output = self.request(capture)
            self.assertTrue(result["ok"], result)
            self.assertEqual((result["width"], result["height"]), size)
            self.assertTrue(output.exists())

    def test_single_capture_wrong_class_never_publishes(self):
        for model, capture in (("iPhone17,3", pad_capture), ("iPad14,3", phone_capture)):
            self.pin(model)
            result, output = self.request(capture)
            self.assertEqual(result["reason"], "unexpected_dimensions")
            self.assertFalse(output.exists())

    def test_single_capture_rejects_mismatching_pin_before_capturing(self):
        self.pin("iPad14,3", device_class="iPhone")
        result, output = self.request(pad_capture)
        self.assertEqual(result["reason"], "unexpected_device_pin")
        self.assertFalse(output.exists())


class ServiceTests(PrivateState, unittest.IsolatedAsyncioTestCase):
    async def capture_result(self, size, transport):
        @contextlib.asynccontextmanager
        async def context(_state):
            yield object(), {}
        async def capture(_provider):
            started = time.monotonic()
            return png(size), started, time.monotonic()
        worker = service.CaptureService(self.state, self.output, connection_factory=context,
                                        capture=capture, transport=transport)
        receipts = []
        async def emit(receipt):
            receipts.append(receipt)
        output = self.output / f"{uuid.uuid4()}.png"
        try:
            await worker.accept(json.dumps({"action": "capture", "request_id": str(uuid.uuid4()),
                                           "output_file": str(output), "timeout": 8}).encode(), emit)
            if worker.active:
                await worker.active
        finally:
            await worker.shutdown()
        return receipts[-1], output

    async def test_usb_and_wifi_workers_take_class_from_phone_pin(self):
        for extra in ({}, {"device_class": "iPhone"}):
            self.pin(**extra)
            for transport in ("usb", "wifi"):
                result, output = await self.capture_result((1334, 750), transport)
                self.assertTrue(result["ok"], result)
                self.assertEqual((result["width"], result["height"]), (1334, 750))
                self.assertEqual(output.read_bytes(), png((1334, 750)))

    async def test_workers_reject_frames_from_other_class(self):
        for model, size in (("iPhone17,3", PAD_SIZES[0]), ("iPad14,3", PHONE_SIZES[0])):
            self.pin(model)
            for transport in ("usb", "wifi"):
                result, output = await self.capture_result(size, transport)
                self.assertEqual(result["reason"], "unexpected_dimensions")
                self.assertFalse(output.exists())

    async def test_workers_reject_mismatching_pin(self):
        self.pin("iPad14,3", device_class="iPhone")
        result, output = await self.capture_result(PAD_SIZES[0], "wifi")
        self.assertEqual(result["reason"], "unexpected_device_pin")
        self.assertFalse(output.exists())


class TransportTests(PrivateState, unittest.IsolatedAsyncioTestCase):
    async def test_bootstrap_phone_accepts_legacy_pin_and_verifies_identity(self):
        self.pin()
        client = FakeLockdown()
        device = SimpleNamespace(is_usb=True, serial=self.serial)
        fake = SimpleNamespace(peer_signature_verified=True, connect=AsyncMock(), close=AsyncMock())
        strict = SimpleNamespace(create=AsyncMock(return_value=fake))
        with patch.object(usbmux, "list_devices", AsyncMock(return_value=[device])), \
             patch.object(lockdown, "create_using_usbmux", AsyncMock(return_value=client)), \
             patch.object(remote, "protocol_classes", return_value=(strict, None)), \
             patch.object(remote, "load_record", return_value={"synthetic": True}):
            result = await remote.bootstrap_usb(self.state, apply_device_change=True)
        self.assertTrue(result["ok"])
        self.assertEqual(result["device_model"], "iPhone17,3")
        fake.connect.assert_awaited_once_with(autopair=False)
        fake.close.assert_awaited_once()

    async def test_phone_usb_transport_keeps_exact_identity_and_version_guards(self):
        from pymobiledevice3.remote import userspace_tunnel as userspace, tunnel_service
        self.pin(device_class="iPhone")
        device = SimpleNamespace(is_usb=True, serial=self.serial)
        for model, version, expected in (("iPhone17,3", "17.4", None),
                                         ("iPad14,3", "18.7", "rsd_device_identity_mismatch"),
                                         ("iPhone17,3", "17.3", "usb_ipados_unsupported")):
            client = FakeLockdown(model, version)
            closed = AsyncMock()
            owner = self
            class Tunnel:
                def __init__(self, **kwargs):
                    owner.assertEqual(kwargs, {"serial": owner.serial, "autopair": False,
                                               "remotepairing_fallback": False})
                    self.tun = SimpleNamespace(write=lambda data: None)
                async def aopen(self):
                    await userspace.create_using_usbmux(serial=owner.serial, autopair=False)
                    return SimpleNamespace(udid=owner.serial)
                aclose = closed
            with patch.object(usb, "load_record", return_value={"pinned_udid": self.serial}), \
                 patch.object(usbmux, "list_devices", AsyncMock(return_value=[device])), \
                 patch.object(usb, "_create_usb_client", AsyncMock(return_value=client)), \
                 patch.object(userspace, "_active_tunnel", None), \
                 patch.object(tunnel_service, "USE_USERSPACE_TUNNEL", False), \
                 patch.object(userspace, "UserspaceRsdTunnel", Tunnel):
                if expected:
                    with self.assertRaisesRegex(identity.ProbeFailure, "^" + expected + "$"):
                        async with usb.open_usb_rsd(self.state):
                            self.fail("unsafe provider yielded")
                else:
                    async with usb.open_usb_rsd(self.state) as (_, evidence):
                        self.assertEqual(evidence["transport"], "authenticated_usb")
            closed.assert_awaited_once()


if __name__ == "__main__":
    unittest.main()
