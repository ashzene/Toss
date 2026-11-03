"""Fake usbmux and providers only; never opens the local daemon or an iPad."""
import asyncio
import contextlib
import importlib.metadata
import inspect
import json
import os
import subprocess
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, patch
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import capture_service as service
import usb_transport as usb
from test_capture_service import private_fixture, FakeConnection, png


class USBTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.state, self.output = private_fixture(Path(self.temp.name))
        self.serial = "synthetic-ipad"
        self.hash = usb.fingerprint(self.serial)

    async def asyncTearDown(self):
        self.temp.cleanup()

    def device(self, serial=None, wired=True):
        return SimpleNamespace(serial=serial or self.serial, is_usb=wired)

    def test_pinned_version_and_upstream_factory_contract(self):
        from pymobiledevice3.remote import userspace_tunnel as us
        self.assertEqual(importlib.metadata.version("pymobiledevice3"), "11.31.0")
        self.assertEqual(list(inspect.signature(us.UserspaceRsdTunnel).parameters),
                         ["serial", "autopair", "remotepairing_fallback"])
        self.assertIn("create_using_usbmux(serial=serial, autopair=autopair)",
                      inspect.getsource(us._create_no_root_tunnel_provider))

    def test_only_exact_wired_ipad_matches(self):
        self.assertTrue(usb.is_pinned_usb(self.device(), self.serial, self.hash))
        for d in (self.device(wired=False), self.device("another-ipad")):
            self.assertFalse(usb.is_pinned_usb(d, self.serial, self.hash))
        self.assertFalse(usb.is_pinned_usb(self.device(), self.serial, "wrong-hash"))
        for v in ("17.0", "17.3.9", "invalid", None):
            self.assertFalse(usb.supported_usb_version(v))
        for v in ("17.4", "18.7.8", "26.0"):
            self.assertTrue(usb.supported_usb_version(v))

    async def test_usb_factory_enforces_route_identity_and_restores_on_every_exit(self):
        from pymobiledevice3.remote import userspace_tunnel as us, tunnel_service as ts
        from pymobiledevice3 import usbmux, lockdown
        original = us.create_using_usbmux
        for wrong_identity, old_os, cancel in ((False, False, False), (True, False, False),
                                               (False, True, False), (False, False, True)):
            client = SimpleNamespace(paired=True, udid="other" if wrong_identity else self.serial,
                product_type="iPad14,3", product_version="17.3" if old_os else "18.7.8", close=AsyncMock())
            create = AsyncMock(return_value=client)
            proxy = SimpleNamespace(close=AsyncMock())
            handles = []
            class FakeTunnel:
                def __init__(inner, serial, autopair, remotepairing_fallback):
                    self.assertEqual((serial, autopair, remotepairing_fallback), (self.serial, False, False))
                    handles.append(inner)
                    inner.closed = False
                    inner.tun = SimpleNamespace(write=lambda data: None)
                async def aopen(inner):
                    # Exercise the actual pinned upstream provider selector, with
                    # only the physical connection and CoreDeviceProxy faked.
                    await us._create_no_root_tunnel_provider(self.serial, False, False)
                    if cancel:
                        raise asyncio.CancelledError()
                    return SimpleNamespace(udid=self.serial)
                async def aclose(inner):
                    inner.closed = True
            with contextlib.ExitStack() as stack:
                stack.enter_context(patch.object(usb, "configure", return_value=(self.state, {"model":"iPad14,3"}, self.state)))
                stack.enter_context(patch.object(usb, "pinned_identity", return_value=(self.serial,self.hash)))
                stack.enter_context(patch.object(us, "_active_tunnel", None))
                stack.enter_context(patch.object(ts, "USE_USERSPACE_TUNNEL", False))
                stack.enter_context(patch.object(us, "UserspaceRsdTunnel", FakeTunnel))
                stack.enter_context(patch.object(usbmux, "list_devices", AsyncMock(return_value=[self.device()])))
                stack.enter_context(patch.object(usb, "_create_usb_client", create))
                stack.enter_context(patch.object(ts.CoreDeviceTunnelProxy, "create", AsyncMock(return_value=proxy)))
                if wrong_identity or old_os or cancel:
                    with self.assertRaises((usb.ProbeFailure, asyncio.CancelledError)):
                        async with usb.open_usb_rsd(self.state):
                            self.fail("unsafe provider yielded")
                else:
                    async with usb.open_usb_rsd(self.state) as (_, evidence):
                        self.assertEqual(evidence["transport"], "authenticated_usb")
                        recording = service.link_timeline.Recording()
                        handles[0].tun.write(bytes(500))
                        self.assertEqual(len(recording.link.packets), 1)
                        self.assertIsNone(recording.verdict(recording.started + 0.1, 0.8, 1.2))
                        recording.finish("ok")
                    self.assertIsNone(service.link_timeline._current)
                self.assertIs(us.create_using_usbmux, original)
                self.assertTrue(handles[0].closed)
                create.assert_awaited_once_with(self.serial, self.state)

    async def test_cancelled_usb_initialization_closes_owned_service(self):
        from pymobiledevice3 import usbmux, lockdown
        from pymobiledevice3.remote import userspace_tunnel as us, tunnel_service as ts

        # Exercise the production factory selection. Only the local daemon and
        # device I/O are faked; cancellation crosses the real ownership boundary.
        for phase in ("buid", "initialize", "pairing"):
            with self.subTest(phase=phase):
                entered = asyncio.Event()
                raw_service = SimpleNamespace(mux_device=self.device(), close=AsyncMock())
                mux = lockdown.PlistMuxConnection(SimpleNamespace(close=lambda: None))
                mux.close = AsyncMock()

                async def initialize(_client):
                    if phase == "initialize":
                        entered.set()
                        await asyncio.Event().wait()

                async def pairing(_client, autopair, *_args, **_kwargs):
                    self.assertFalse(autopair)
                    if phase == "pairing":
                        entered.set()
                        await asyncio.Event().wait()

                async def buid():
                    if phase == "buid":
                        entered.set()
                        await asyncio.Event().wait()
                    return "synthetic-buid"

                mux.get_buid = buid
                class FakeTunnel:
                    def __init__(inner, **_kwargs): pass
                    async def aopen(inner):
                        await us._create_no_root_tunnel_provider(self.serial, False, False)
                    async def aclose(inner): pass

                async def connect():
                    async with usb.open_usb_rsd(self.state):
                        self.fail("cancelled initialization yielded a session")

                with contextlib.ExitStack() as stack:
                    stack.enter_context(patch.object(usb, "configure", return_value=(self.state, {"model": "iPad14,3"}, self.state)))
                    stack.enter_context(patch.object(usb, "pinned_identity", return_value=(self.serial, self.hash)))
                    stack.enter_context(patch.object(us, "_active_tunnel", None))
                    stack.enter_context(patch.object(ts, "USE_USERSPACE_TUNNEL", False))
                    stack.enter_context(patch.object(us, "UserspaceRsdTunnel", FakeTunnel))
                    stack.enter_context(patch.object(usbmux, "list_devices", AsyncMock(return_value=[self.device()])))
                    stack.enter_context(patch.object(usbmux, "create_mux", AsyncMock(return_value=mux)))
                    create = stack.enter_context(patch.object(lockdown.ServiceConnection, "create_using_usbmux", AsyncMock(return_value=raw_service)))
                    stack.enter_context(patch.object(lockdown.LockdownClient, "_initialize", initialize))
                    stack.enter_context(patch.object(lockdown.LockdownClient, "_handle_autopair", pairing))
                    task = asyncio.create_task(connect())
                    await asyncio.wait_for(entered.wait(), 0.5)
                    task.cancel()
                    with self.assertRaises(asyncio.CancelledError):
                        await task
                    raw_service.close.assert_awaited_once()
                    mux.close.assert_awaited_once()
                    self.assertEqual(create.await_args.kwargs["connection_type"], "USB")
                    self.assertEqual(create.await_args.kwargs["usbmux_address"], usb.USBMUX_SOCKET)

    async def test_usb_client_success_transfers_ownership_and_keeps_pairing_disabled(self):
        from pymobiledevice3 import usbmux, lockdown
        raw_service = SimpleNamespace(mux_device=self.device(), close=AsyncMock())
        mux = lockdown.PlistMuxConnection(SimpleNamespace(close=lambda: None))
        mux.get_buid, mux.close = AsyncMock(return_value="synthetic-buid"), AsyncMock()
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(usbmux, "create_mux", AsyncMock(return_value=mux)))
            create = stack.enter_context(patch.object(lockdown.ServiceConnection, "create_using_usbmux", AsyncMock(return_value=raw_service)))
            initialize = stack.enter_context(patch.object(lockdown.LockdownClient, "_initialize", AsyncMock()))
            pairing = stack.enter_context(patch.object(lockdown.LockdownClient, "_handle_autopair", AsyncMock()))
            client = await usb._create_usb_client(self.serial, self.state)
        self.assertIsInstance(client, lockdown.PlistUsbmuxLockdownClient)
        self.assertIs(client.service, raw_service)
        self.assertEqual(client.identifier, self.serial)
        self.assertEqual(client.system_buid, "synthetic-buid")
        self.assertEqual(client.usbmux_address, usb.USBMUX_SOCKET)
        self.assertEqual(create.await_args.kwargs["connection_type"], "USB")
        initialize.assert_awaited_once()
        pairing.assert_awaited_once_with(False, None, private_key=None)
        raw_service.close.assert_not_awaited()
        mux.close.assert_awaited_once()
        await client.close()
        raw_service.close.assert_awaited_once()

    async def test_wrong_version_fails_before_any_device_access(self):
        with patch.object(usb.importlib.metadata, "version", return_value="11.32.0"):
            with self.assertRaisesRegex(usb.ProbeFailure, "unexpected_library_version"):
                async with usb.open_usb_rsd(self.state):
                    self.fail("version mismatch yielded")

    def test_usb_startup_reports_version_before_dependency_imports(self):
        code = '''
import sys
sys.path.insert(0, sys.argv[1])
import capture_service as service, usb_transport
usb_transport.importlib.metadata.version = lambda _: "11.32.0"
def forbidden(): raise AssertionError("must not import changed upstream API")
service.prewarm_dependencies = forbidden
sys.exit(service.main(sys.argv[2:]))
'''
        result = subprocess.run([sys.executable, "-c", code, str(Path(service.__file__).parent),
            "--state-dir", str(self.state), "--output-dir", str(self.output),
            "--transport", "usb", "--worker-role", "usb_primary", "--connection-events"],
            input="", capture_output=True, text=True, timeout=3)
        event = json.loads(result.stdout)
        self.assertEqual(event["reason"], "unexpected_library_version")
        self.assertEqual(event["worker_role"], "usb_primary")
        self.assertEqual(event["transport"], "authenticated_usb")
        self.assertEqual(event["state"], "failed")

    async def test_listener_filters_network_other_devices_and_closes_on_cancel(self):
        queue = asyncio.Queue()
        events = []
        mux = SimpleNamespace(devices=[], listen=AsyncMock(), close=AsyncMock())
        async def update():
            mux.devices = await queue.get()
        mux.receive_device_state_update = update
        async def emit(event): events.append(event)
        factory, snapshot = AsyncMock(return_value=mux), AsyncMock(return_value=[])
        with patch.object(usb, "pinned_identity", return_value=(self.serial,self.hash)):
            task = asyncio.create_task(usb.watch_usb(self.state, emit, mux_factory=factory, list_devices=snapshot))
            await asyncio.sleep(0.01)
            for devices in ([self.device(wired=False)], [self.device("other")], [self.device()], [self.device()], []):
                await queue.put(devices)
                await asyncio.sleep(0.01)
            task.cancel()
            with self.assertRaises(asyncio.CancelledError): await task
        self.assertEqual([e["present"] for e in events], [False,True,False])
        mux.close.assert_awaited_once()
        self.assertNotIn(self.serial, json.dumps(events))

    async def test_mount_lock_serializes_and_cancellation_releases(self):
        entered = []
        release = asyncio.Event()
        async def owner(n):
            async with usb.developer_image_lock(self.state):
                entered.append(n)
                if n == 1: await release.wait()
        first = asyncio.create_task(owner(1))
        await asyncio.sleep(0.01)
        second = asyncio.create_task(owner(2))
        await asyncio.sleep(0.06)
        self.assertEqual(entered,[1])
        first.cancel()
        with self.assertRaises(asyncio.CancelledError): await first
        await asyncio.wait_for(second, 0.3)
        self.assertEqual(entered,[1,2])
        self.assertEqual((self.state/'developer-image.lock').stat().st_mode & 0o777,0o600)

    async def test_attempt_deadline_usb_receipt_and_fresh_rpc(self):
        self.connects=self.closes=0
        frame=png()
        async def capture(_):
            now=asyncio.get_running_loop().time()
            return frame,now,now
        worker=service.CaptureService(self.state,self.output,transport="usb",
            connection_factory=lambda _:FakeConnection(self),capture=capture)
        replies=[]
        async def emit(r): replies.append(r)
        attempt=str(uuid.uuid4()); identity=str(uuid.uuid4())
        request={"action":"capture","request_id":identity,"output_file":str(self.output/'attempt.png'),
                 "timeout":40,"attempt_id":attempt,"deadline_monotonic":asyncio.get_running_loop().time()+1}
        try:
            await worker.accept(json.dumps(request).encode(),emit)
            await worker.active
            self.assertTrue(replies[-1]['ok'],replies)
            self.assertEqual(replies[-1]['attempt_id'],attempt)
            self.assertEqual(replies[-1]['transport'],'authenticated_usb')
            request.update(request_id=str(uuid.uuid4()),attempt_id=str(uuid.uuid4()),
                output_file=str(self.output/'expired.png'),deadline_monotonic=asyncio.get_running_loop().time()-1)
            await worker.accept(json.dumps(request).encode(),emit);await worker.active
            self.assertEqual(replies[-1]['reason'],'timeout')
            self.assertEqual(replies[-1]['attempt_id'],request['attempt_id'])
            self.assertFalse((self.output/'expired.png').exists())
        finally:
            await worker.shutdown()

    async def test_progress_event_precedes_rpc_cleanup_for_both_rules(self):
        for expected in ("first_byte_timeout", "stall_timeout"):
            release = asyncio.Event()
            events = []
            async def rpc():
                try:
                    await asyncio.sleep(10)
                except asyncio.CancelledError:
                    await release.wait()
                    raise
            async def notify(code): events.append(code)
            session = service.CaptureSession(self.state)
            session.ready = True
            session.screenshot = SimpleNamespace(get_screenshot=rpc)
            session.progress_fail_fast = True
            session.on_progress_failure = notify
            with patch.object(service.link_timeline.Recording, "verdict", return_value=expected):
                task = asyncio.create_task(session.capture())
                await asyncio.sleep(0.06)
                self.assertEqual(events, [expected])
                self.assertFalse(task.done(), "fallback signal must precede slow cleanup")
                release.set()
                with self.assertRaisesRegex(service.once.CaptureFailure, expected): await task

    async def test_service_progress_signal_keeps_attempt_limits_and_does_not_change_wifi(self):
        for transport in ("usb", "wifi"):
            events, replies = [], []
            cleanup = asyncio.Event()
            session = service.CaptureSession(self.state)
            session.ready = True
            async def rpc(): await asyncio.sleep(10)
            session.screenshot = SimpleNamespace(get_screenshot=rpc)
            class Context:
                async def __aenter__(self): return session, {}
                async def __aexit__(self, *_): await cleanup.wait()
            async def emit(value): events.append(value)
            async def reply(value): replies.append(value)
            worker = service.CaptureService(self.state, self.output, transport=transport,
                connection_factory=lambda _: Context(), attempt_events=emit)
            identity, attempt = str(uuid.uuid4()), str(uuid.uuid4())
            request = {"action": "capture", "request_id": identity, "attempt_id": attempt,
                "deadline_monotonic": asyncio.get_running_loop().time() + 0.5,
                "output_file": str(self.output / (transport + ".png")), "timeout": 40,
                "limits_ms": {"first_byte": 200, "stall": 300, "press_cap": 2000}}
            try:
                with patch.object(service.link_timeline.Recording, "verdict", return_value="first_byte_timeout"):
                    await worker.accept(json.dumps(request).encode(), reply)
                    await asyncio.sleep(0.08)
                    self.assertFalse(worker.active.done(), "cleanup should still be blocked")
                    self.assertEqual(session.limits[:2], (2.5 if transport == "usb" else 0.2, 0.3))   # plus the shared deadline
                    if transport == "usb":
                        self.assertEqual(len(events), 1)
                        self.assertEqual(events[0]["attempt_id"], attempt)
                        self.assertEqual(events[0]["request_id"], identity)
                        self.assertEqual(set(events[0]["timings_ms"]), {"connect", "screenshot"})
                    else:
                        self.assertEqual(events, [])
                    cleanup.set()
                    await worker.active
                    self.assertEqual(replies[0]["reason"], "first_byte_timeout" if transport == "usb" else "timeout")
                    self.assertEqual(replies[0]["attempt_id"], attempt)
            finally:
                cleanup.set()
                await worker.shutdown()


if __name__ == '__main__': unittest.main()
