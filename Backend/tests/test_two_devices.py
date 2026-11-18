"""Offline registry/setup/request isolation; no USB, network or real pairing state."""
import asyncio
import contextlib
import io
import json
import os
from pathlib import Path
import sys
import subprocess
import tempfile
import time
import unittest
from unittest.mock import AsyncMock, patch
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import capture_service as service
import setup_device as setup
import paired_devices as devices
from ipad_probe import ProbeFailure, fingerprint


def pin(kind):
    return dict(model=kind + "14,3", device_class=kind, device_hash=fingerprint(kind))


def save_state(state, kind, legacy=False):
    state.mkdir(mode=0o700, parents=True, exist_ok=True)
    value = pin(kind)
    if legacy:
        value.pop("device_class")
    setup.write_private(state / "target.json", json.dumps(value).encode())
    setup.write_private(state / "strict-remote-pairing.plist", ("synthetic-" + kind).encode())
    (state / "cache").mkdir(mode=0o700, exist_ok=True)
    setup.write_private(state / "cache/token", kind.encode())


class RegistryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def two(self):
        (self.root / "devices").mkdir(mode=0o700, exist_ok=True)
        for kind in devices.CLASSES:
            save_state(devices.device_directory(self.root, kind), kind)
            devices.register_device(self.root, kind)

    def test_legacy_read_does_not_write(self):
        for kind in devices.CLASSES:
            save_state(self.root, kind, legacy=True)
            before = (self.root / "target.json").read_bytes()
            self.assertEqual(devices.resolve_state(self.root, kind), self.root)
            self.assertEqual((self.root / "target.json").read_bytes(), before)

    def test_legacy_migration_preserves_credentials_and_cache(self):
        save_state(self.root, "iPad", legacy=True)
        setup.write_private(self.root / "endpoint-hint.json", b'{"ip":"10.0.0.2"}')
        before = {str(p.relative_to(self.root)): p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        devices.migrate_legacy(self.root)
        state = devices.resolve_state(self.root, "iPad")
        for name, data in before.items():
            self.assertEqual((state / name).read_bytes(), data)
        self.assertFalse((self.root / "strict-remote-pairing.plist").exists())
        self.assertEqual((self.root / "target.json").stat().st_mode & 0o777, 0o600)
        self.assertEqual(devices.migrate_legacy(self.root), {"iPad": pin("iPad")})

    def test_iphone_legacy_migration(self):
        save_state(self.root, "iPhone", legacy=True)
        devices.migrate_legacy(self.root)
        self.assertEqual(devices.resolve_state(self.root).name, "iPhone")

    def test_incomplete_legacy_pin_does_not_occupy_a_slot(self):
        save_state(self.root, "iPad", legacy=True)
        (self.root / "strict-remote-pairing.plist").unlink()
        self.assertEqual(devices.migrate_legacy(self.root), {})
        self.assertEqual(devices.read_targets(self.root), ({}, False))

    def test_add_second_preserves_first_bytes(self):
        self.two()
        self.assertEqual(set(devices.read_targets(self.root)[0]), set(devices.CLASSES))
        for kind in devices.CLASSES:
            state = devices.resolve_state(self.root, kind)
            self.assertEqual((state / "strict-remote-pairing.plist").read_bytes(), ("synthetic-" + kind).encode())

    def test_two_require_explicit_capture_class(self):
        self.two()
        with self.assertRaises(ProbeFailure):
            devices.resolve_state(self.root)

    def test_forget_each_independently(self):
        for kind in devices.CLASSES:
            self.two()
            other = next(k for k in devices.CLASSES if k != kind)
            before = (devices.resolve_state(self.root, other) / "cache/token").read_bytes()
            devices.forget_device(self.root, kind)
            self.assertEqual(set(devices.read_targets(self.root)[0]), {other})
            self.assertFalse(devices.device_directory(self.root, kind).exists())
            self.assertEqual((devices.resolve_state(self.root) / "cache/token").read_bytes(), before)
            devices.forget_device(self.root, kind)  # idempotent, cannot resurrect it

    def test_forget_legacy_does_not_resurrect_it(self):
        save_state(self.root, "iPad", legacy=True)
        devices.forget_device(self.root, "iPad")
        self.assertEqual(devices.read_targets(self.root), ({}, False))
        self.assertFalse((self.root / "strict-remote-pairing.plist").exists())

    def test_forget_requires_supported_class(self):
        self.two()
        before = (self.root / "target.json").read_bytes()
        for kind in (None, "../../", "iPod"):
            with self.assertRaises(ProbeFailure):
                devices.forget_device(self.root, kind)
            self.assertEqual((self.root / "target.json").read_bytes(), before)

    def test_cli_forget_is_scoped_and_keeps_existing_code_contract(self):
        self.two()
        script = Path(setup.__file__)
        result = subprocess.run([sys.executable, str(script), "forget", "--state-dir", str(self.root),
                                 "--device-class", "iPhone"], capture_output=True, text=True,
                                env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"}, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"schema_version": 1, "ok": True, "code": "not_paired", "final": True})
        self.assertEqual(set(devices.read_targets(self.root)[0]), {"iPad"})

    def test_corrupt_or_conflicting_registry_rejected(self):
        for value in ([], {"schema_version": 9}, {"schema_version": True, "devices": {}},
                      {"schema_version": 2, "devices": {"iPad": pin("iPhone")}},
                      {"schema_version": 2, "devices": {"iPod": pin("iPad")}}):
            setup.write_private(self.root / "target.json", json.dumps(value).encode())
            with self.assertRaises(ProbeFailure):
                devices.read_targets(self.root)

    def test_child_pin_must_match_registry(self):
        self.two()
        save_state(devices.device_directory(self.root, "iPad"), "iPhone")
        with self.assertRaises(ProbeFailure):
            devices.resolve_state(self.root, "iPad")

    def test_registry_symlink_rejected(self):
        save_state(self.root, "iPad")
        (self.root / "target.json").rename(self.root / "original.json")
        (self.root / "target.json").symlink_to(self.root / "original.json")
        with self.assertRaises(ProbeFailure):
            devices.read_targets(self.root)

    def test_failed_commit_retains_readable_legacy(self):
        save_state(self.root, "iPad", legacy=True)
        with patch.object(devices, "write_targets", side_effect=OSError("synthetic interruption")):
            with self.assertRaises(OSError):
                devices.migrate_legacy(self.root)
        self.assertEqual(devices.resolve_state(self.root), self.root)
        devices.migrate_legacy(self.root)
        self.assertEqual(devices.resolve_state(self.root).name, "iPad")

    def test_retry_cleans_legacy_credentials_after_interrupted_committed_migration(self):
        save_state(self.root, "iPad", legacy=True)
        with patch.object(devices, "cleanup_legacy", side_effect=OSError("synthetic interruption")):
            with self.assertRaises(OSError):
                devices.migrate_legacy(self.root)
        self.assertEqual(devices.resolve_state(self.root).name, "iPad")
        devices.forget_device(self.root, "iPad")
        self.assertFalse((self.root / "strict-remote-pairing.plist").exists())
        self.assertFalse(devices.device_directory(self.root, "iPad").exists())


class SetupTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    async def test_add_phone_auto_does_not_prepare_or_overwrite_pad(self):
        save_state(self.root, "iPad", legacy=True)
        async def fake_auto(state, **kwargs):
            self.assertEqual(state.name, "iPhone")
            self.assertEqual(kwargs, dict(expected_class="iPhone", expected_hash=fingerprint("iPhone")))
            save_state(state, "iPhone")
            return "wifi_unreachable"
        with patch.object(setup, "usb_ipads", AsyncMock(return_value=[("iPhone", "iPhone14,3", "18.0", True, "iPhone")])), \
             patch.object(setup, "auto", side_effect=fake_auto), patch.object(setup, "use_private_cache"):
            self.assertEqual(await setup.auto_devices(self.root), "wifi_unreachable")
        self.assertEqual(set(devices.read_targets(self.root)[0]), {"iPad", "iPhone"})

    async def test_selected_hash_is_emitted_and_cleared_even_on_cancellation(self):
        output = io.StringIO()
        emitter = setup.Emitter()
        async def fake_auto(*args, **kwargs):
            setup.emit(False, "developer_mode_needed", final=False, model="iPhone14,3")
            raise asyncio.CancelledError
        with patch.object(setup, "usb_ipads", AsyncMock(return_value=[("iPhone", "iPhone14,3", "18.0", True, "iPhone")])), \
             patch.object(setup, "auto", side_effect=fake_auto), patch.object(setup, "emit", emitter), \
             patch.object(setup, "use_private_cache"), contextlib.redirect_stdout(output):
            with self.assertRaises(asyncio.CancelledError):
                await setup.auto_devices(self.root)
        row = json.loads(output.getvalue())
        self.assertEqual(row["setup_device_hash"], fingerprint("iPhone"))
        self.assertIsNone(emitter.target_hash)

    async def test_failed_second_setup_keeps_first(self):
        save_state(self.root, "iPad", legacy=True)
        with patch.object(setup, "usb_ipads", AsyncMock(return_value=[("iPhone", "iPhone14,3", "18.0", True, "iPhone")])), \
             patch.object(setup, "auto", AsyncMock(return_value="pairing_failed")), patch.object(setup, "use_private_cache"):
            self.assertEqual(await setup.auto_devices(self.root), "pairing_failed")
        self.assertEqual(set(devices.read_targets(self.root)[0]), {"iPad"})

    async def test_occupied_class_cannot_silently_replace_device(self):
        save_state(self.root, "iPad")
        with patch.object(setup, "usb_ipads", AsyncMock(return_value=[("other", "iPad14,3", "18.0", True, "iPad")])), \
             patch.object(setup, "auto", AsyncMock()) as auto, patch.object(setup, "use_private_cache"), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(await setup.auto_devices(self.root), "pairing_failed")
            auto.assert_not_awaited()

    async def test_mixed_usb_does_not_select_or_start_pairing(self):
        entries = [(k, k + "14,3", "18.0", True, k) for k in devices.CLASSES]
        with patch.object(setup, "usb_ipads", AsyncMock(return_value=entries)), \
             patch.object(setup, "auto", AsyncMock()) as auto, patch.object(setup, "emit") as emit, \
             patch.object(setup, "use_private_cache"), patch.object(setup.asyncio, "sleep", side_effect=asyncio.CancelledError):
            with self.assertRaises(asyncio.CancelledError):
                await setup.auto_devices(self.root)
            emit.assert_called_once_with(False, "mixed_usb_devices", final=False)
            auto.assert_not_awaited()


class CaptureRoutingTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "devices").mkdir(mode=0o700)
        self.output = self.root / "output"
        self.output.mkdir(mode=0o700)
        self.workers = {}
        for kind in devices.CLASSES:
            save_state(devices.device_directory(self.root, kind), kind)
            devices.register_device(self.root, kind)
        for kind in devices.CLASSES:
            self.workers[kind] = service.CaptureService(self.root, self.output, device_class=kind)

    async def asyncTearDown(self):
        for worker in self.workers.values():
            await worker.shutdown()

    def request(self, kind):
        return json.dumps(dict(action="capture", request_id=str(uuid.uuid4()), timeout=8,
            output_file=str(self.output / (str(uuid.uuid4()) + ".png")), device_class=kind)).encode()

    async def test_explicit_requests_bind_to_separate_states(self):
        for kind, worker in self.workers.items():
            self.assertEqual(worker.state_dir, devices.device_directory(self.root, kind))
            _, failure = worker._parse(self.request(kind), time.monotonic())
            self.assertIsNone(failure)

    async def test_cross_device_request_rejected_before_any_capture(self):
        for kind, worker in self.workers.items():
            other = next(k for k in devices.CLASSES if k != kind)
            request, failure = worker._parse(self.request(other), time.monotonic())
            self.assertIsNone(request)
            self.assertEqual(failure["reason"], "unexpected_device_pin")
            self.assertIsNone(worker.context)

    async def test_missing_class_in_explicit_worker_rejected(self):
        raw = json.loads(self.request("iPad"))
        del raw["device_class"]
        _, failure = self.workers["iPad"]._parse(json.dumps(raw).encode(), time.monotonic())
        self.assertEqual(failure["reason"], "unexpected_device_pin")

    async def test_legacy_worker_still_accepts_old_requests(self):
        worker = service.CaptureService(devices.resolve_state(self.root, "iPad"), self.output)
        try:
            raw = json.loads(self.request("iPad"))
            del raw["device_class"]
            self.assertIsNone(worker._parse(json.dumps(raw).encode(), time.monotonic())[1])
        finally:
            await worker.shutdown()

    async def test_forgetting_other_class_does_not_invalidate_pad(self):
        devices.forget_device(self.root, "iPhone")
        self.assertIsNone(self.workers["iPad"]._parse(self.request("iPad"), time.monotonic())[1])

    async def test_two_services_capture_concurrently_with_correct_identity_and_dimensions(self):
        from PIL import Image
        receipts, connections = {}, []
        @contextlib.asynccontextmanager
        async def connect(state):
            connections.append(state)
            yield object(), {}
        async def capture(kind, _):
            started = time.monotonic()
            output = io.BytesIO()
            Image.new("RGB", (1668, 2388) if kind == "iPad" else (750, 1334), "white").save(output, "PNG")
            await asyncio.sleep(0.01)
            return output.getvalue(), started, time.monotonic()
        for kind, worker in self.workers.items():
            worker.connection_factory = connect
            worker.capture = lambda provider, kind=kind: capture(kind, provider)
        async def run(kind, worker):
            async def emit(value):
                receipts[kind] = value
            await worker.accept(self.request(kind), emit)
            await worker.active
        await asyncio.gather(*(run(k, w) for k, w in self.workers.items()))
        for kind, receipt in receipts.items():
            self.assertTrue(receipt["ok"], receipt)
            self.assertEqual((receipt["width"], receipt["height"]), (1668, 2388) if kind == "iPad" else (750, 1334))
        self.assertEqual(set(connections), {devices.device_directory(self.root, k) for k in devices.CLASSES})
        self.assertEqual(len(list(self.output.glob("*.png"))), 2)
