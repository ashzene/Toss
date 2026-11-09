"""Synthetic service/pipe tests only: no device, network, keyboard, or window calls."""
import asyncio
import contextlib
import hashlib
import io
import json
import math
import os
from pathlib import Path
import select
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import capture_service as service
from capture_timing import Threshold


def png(color="white", landscape=False):
    from PIL import Image
    output = io.BytesIO()
    Image.new("RGB", (2388, 1668) if landscape else (1668, 2388), color).save(output, format="PNG")
    return output.getvalue()


def private_fixture(base):
    state, output = base / "state", base / "output"
    state.mkdir(mode=0o700)
    output.mkdir(mode=0o700)
    for name in ("target.json", "strict-remote-pairing.plist"):
        fd = os.open(state / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as handle:
            handle.write("synthetic-placeholder-not-real-pairing")
    return state, output


class FakeConnection:
    def __init__(self, owner):
        self.owner = owner

    async def __aenter__(self):
        self.owner.connects += 1
        return object(), {"never_print": "SECRET_HOST"}

    async def __aexit__(self, *_args):
        self.owner.closes += 1


class ServiceTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.state, self.output = private_fixture(self.base)
        self.connects = self.closes = self.captures = 0
        self.receipts = []
        self.frames = [png(), png("yellow", landscape=True)]
        self.worker = service.CaptureService(
            self.state, self.output, connection_factory=lambda _: FakeConnection(self), capture=self.capture)

    async def asyncTearDown(self):
        await self.worker.shutdown()
        self.temp.cleanup()

    async def capture(self, _provider):
        started = time.monotonic()
        frame = self.frames[self.captures % len(self.frames)]
        self.captures += 1
        await asyncio.sleep(0)
        return frame, started, time.monotonic()

    async def emit(self, receipt):
        self.receipts.append(receipt)

    def request(self, **overrides):
        identity = str(uuid.uuid4())
        value = {"action": "capture", "request_id": identity,
                 "output_file": str(self.output / (identity + ".png")), "timeout": 8}
        value.update(overrides)
        return value

    async def accept(self, value, wait=True):
        await self.worker.accept(json.dumps(value).encode(), self.emit)
        if wait and self.worker.active is not None:
            await self.worker.active
        return self.receipts[-1] if self.receipts else None

    async def test_startup_has_no_connection_or_capture(self):
        await asyncio.sleep(0.01)
        self.assertEqual((self.connects, self.captures, self.receipts), (0, 0, []))

    async def test_developer_mount_distinguishes_actual_mount_from_other_workers_mount(self):
        from pymobiledevice3.exceptions import AlreadyMountedError
        with mock.patch("pymobiledevice3.services.mobile_image_mounter.auto_mount", new_callable=mock.AsyncMock) as mount:
            self.assertTrue(await service.mount_developer_image(object()))
            mount.side_effect = AlreadyMountedError()
            self.assertFalse(await service.mount_developer_image(object()))

    async def test_success_records_rpc_duration_but_black_frame_does_not(self):
        first = await self.accept(self.request())
        samples = self.worker.success_timings.load()["wifi"]
        self.assertEqual(len(samples), 1)
        self.assertAlmostEqual(samples[0]["seconds"], first["timings_ms"]["screenshot"] / 1000)
        self.assertLess(abs(samples[0]["timestamp"] - time.time()), 2)
        self.frames = [png("black")]
        result = await self.accept(self.request())
        self.assertEqual(result["reason"], "black_frame_rejected")
        self.assertEqual(len(self.worker.success_timings.load()["wifi"]), 1)

    async def test_explicit_timing_path_is_independent_of_pairing_state(self):
        await self.worker.shutdown()
        timing_dir = self.base / "private-app-support"
        timing_dir.mkdir(mode=0o700)
        timing_path = timing_dir / "screenshot-success-times.json"
        self.worker = service.CaptureService(self.state, self.output,
            connection_factory=lambda _: FakeConnection(self), capture=self.capture, timing_path=timing_path)
        result = await self.accept(self.request())
        self.assertTrue(result["ok"], result)
        self.assertEqual(self.worker.success_timings.path, timing_path)
        self.assertEqual(len(json.loads(timing_path.read_text())["wifi"]), 1)
        self.assertFalse((self.state.parent / "screenshot-success-times.json").exists())

    async def test_adaptive_expiry_cancels_once_records_reason_and_does_not_train(self):
        cancelled = asyncio.Event()
        async def hanging(_provider):
            self.captures += 1
            try: await asyncio.sleep(60)
            finally: cancelled.set()
        self.worker.capture = hanging
        with mock.patch.object(self.worker.success_timings, "threshold", return_value=Threshold(0.02, 10, 0.01)), \
             mock.patch.object(service, "REQUEST_BUDGET", 0.08):
            at = time.monotonic()
            result = await self.accept(self.request())
        self.assertEqual(result["reason"], "timeout")
        self.assertGreaterEqual(time.monotonic() - at, 0.07)
        self.assertTrue(cancelled.is_set())
        self.assertEqual(self.captures, 1)
        self.assertEqual(self.worker.success_timings.load()["wifi"], [])
        self.assertEqual(list(self.output.iterdir()), [])
    async def test_connect_time_is_excluded_and_completed_event_precedes_validation(self):
        events = []
        owner = self
        class SlowConnection(FakeConnection):
            async def __aenter__(self):
                await asyncio.sleep(0.1)
                return await super().__aenter__()
        self.worker.connection_factory = lambda _: SlowConnection(self)
        async def capture(_provider):
            started = time.monotonic()
            await asyncio.sleep(0.02)
            return owner.frames[0], started, time.monotonic()
        async def emit(event):
            events.append(event)
        self.worker.capture = capture
        self.worker.progress_events = emit
        original = service.once.prepare_png
        def validate(data, *, timings=None):
            self.assertEqual(events[-1]["event"], "capture_completed")
            time.sleep(0.06)  # validation exceeds T, but the full image already arrived
            return original(data, timings=timings)
        with mock.patch.object(self.worker.success_timings, "threshold", return_value=Threshold(0.05, 10, 0.02)), \
             mock.patch.object(service.once, "prepare_png", side_effect=validate):
            trigger = time.monotonic()
            result = await self.accept(self.request())
        self.assertTrue(result["ok"], result)
        self.assertGreater(events[0]["capture_started_monotonic"] - trigger, 0.09)
        self.assertEqual([e["event"] for e in events], ["capture_started", "capture_completed"])
        self.assertGreater(events[0]["screenshot_deadline_monotonic"] - events[0]["capture_started_monotonic"], 4.5)
        self.assertLess(result["timings_ms"]["screenshot"], 50)

    async def test_wifi_hedge_uses_original_phase_deadline(self):
        async def slow(_provider):
            started = time.monotonic()
            await asyncio.sleep(0.15)
            return self.frames[0], started, time.monotonic()
        self.worker.capture = slow
        at = time.monotonic()
        result = await self.accept(self.request(attempt_id=str(uuid.uuid4()),
            deadline_monotonic=at + 0.8, screenshot_deadline_monotonic=at + 0.02))
        self.assertTrue(result["ok"], result)  # old adaptive phase deadline is advisory
        self.assertLess(time.monotonic() - at, 0.8)
    async def test_usb_reports_threshold_before_slow_teardown(self):
        self.worker.transport = "usb"
        async def delayed(_provider):
            started = time.monotonic()
            await asyncio.sleep(0.1)
            return self.frames[0], started, time.monotonic()
        self.worker.capture = delayed
        with mock.patch.object(self.worker.success_timings, "threshold", return_value=Threshold(0.02, 12, 0.01)):
            result = await self.accept(self.request())
        self.assertTrue(result["ok"], result)
        self.assertGreater(result["timings_ms"]["screenshot"], 90)
    async def test_invalid_shared_deadline_is_rejected(self):
        for value in (True, float("nan"), -1, time.monotonic() + 31):
            result = await self.accept(self.request(attempt_id=str(uuid.uuid4()),
                deadline_monotonic=time.monotonic() + 4, screenshot_deadline_monotonic=value))
            self.assertEqual(result["reason"], "invalid_timeout")

    async def test_fallback_does_not_reset_original_no_byte_deadline(self):
        async def hanging(_provider): await asyncio.sleep(60)
        self.worker.capture = hanging
        at = time.monotonic()
        result = await self.accept(self.request(press_started_monotonic=at - 4.4,
            attempt_id=str(uuid.uuid4()), deadline_monotonic=at + 3.6))
        self.assertEqual(result["reason"], "timeout")
        self.assertLess(time.monotonic() - at, 0.4)

    async def test_invalid_press_origin_is_rejected(self):
        for origin in (True, float("nan"), time.monotonic() + 1, time.monotonic() - 31):
            result = await self.accept(self.request(press_started_monotonic=origin))
            self.assertEqual(result["reason"], "invalid_timeout")
        self.assertEqual(self.captures, 0)

    async def test_validation_cannot_publish_past_shared_press_deadline(self):
        original = service.once.prepare_png
        def slow_validation(data, *, timings=None):
            time.sleep(0.2)
            return original(data, timings=timings)
        with mock.patch.object(service.once, "prepare_png", side_effect=slow_validation):
            result = await self.accept(self.request(attempt_id=str(uuid.uuid4()),
                deadline_monotonic=time.monotonic() + 0.15))
        self.assertEqual(result["reason"], "timeout")
        self.assertEqual(list(self.output.iterdir()), [])
        self.assertEqual(self.worker.success_timings.load()["wifi"], [])

    async def test_connection_events_observe_preconnect_without_capture(self):
        events = []
        async def emit(event):
            events.append(event)
        self.worker.connection_events = emit
        self.worker.start_preconnect()
        await self.worker.preconnect_task
        self.assertEqual([e["state"] for e in events], ["connecting", "ready"])
        self.assertEqual((self.connects, self.captures, self.receipts), (1, 0, []))
        self.assertNotIn("SECRET", json.dumps(events))
        request = self.request()
        receipt = await self.accept(request)
        self.assertTrue(receipt["ok"])
        self.assertEqual(receipt["request_id"], request["request_id"])
        self.assertEqual(self.captures, 1)
        await self.worker._close_session()
        self.assertEqual(events[-1]["state"], "disconnected")

    async def test_failed_connection_event_is_sanitized_and_can_recover(self):
        events = []
        async def emit(event):
            events.append(event)
        self.worker.connection_events = emit
        class Broken(FakeConnection):
            async def __aenter__(self):
                raise RuntimeError("SECRET_DEVICE_HOST_KEY")
        self.worker.connection_factory = lambda _: Broken(self)
        self.worker.start_preconnect()
        await self.worker.preconnect_task
        self.assertEqual(events[-1]["state"], "failed")
        self.assertNotIn("ready", [e["state"] for e in events])
        self.assertNotIn("SECRET", json.dumps(events))
        self.assertEqual(self.captures, 0)
        self.worker.connection_factory = lambda _: FakeConnection(self)
        self.worker.preconnect_task = None
        self.worker.start_preconnect()
        await self.worker.preconnect_task
        self.assertEqual(events[-1]["state"], "ready")
        self.assertEqual(self.captures, 0)

    async def test_cancelled_preconnect_never_publishes_ready(self):
        events = []
        entered = asyncio.Event()
        async def emit(event):
            events.append(event)
        self.worker.connection_events = emit
        class Slow(FakeConnection):
            async def __aenter__(self):
                entered.set()
                try:
                    await asyncio.sleep(10)
                except asyncio.CancelledError:
                    return object(), {}
        self.worker.connection_factory = lambda _: Slow(self)
        self.worker.start_preconnect()
        await entered.wait()
        await self.worker.shutdown()
        self.assertNotIn("ready", [e["state"] for e in events])
        self.assertEqual(self.captures, 0)
        self.assertEqual(self.worker.idle_seconds, 1800)

    async def test_explicit_preconnect_is_quiet_and_never_captures(self):
        self.worker.start_preconnect()
        self.assertIsNone(await self.worker.preconnect_task)
        self.assertEqual((self.connects, self.captures, self.receipts), (1, 0, []))
        self.assertEqual(list(self.output.iterdir()), [])
        receipt = await self.accept(self.request())
        self.assertTrue(receipt["ok"], receipt)
        self.assertTrue(receipt["connection_reused"])
        self.assertEqual((self.connects, self.captures), (1, 1))

    async def test_capture_waits_for_one_preconnect_other_requests_are_busy(self):
        entered, release = asyncio.Event(), asyncio.Event()
        owner = self
        class SlowConnection(FakeConnection):
            async def __aenter__(self):
                owner.connects += 1
                entered.set()
                await release.wait()
                return object(), {}
        self.worker.connection_factory = lambda _: SlowConnection(self)
        self.worker.start_preconnect()
        await entered.wait()
        trigger = time.monotonic()
        request = self.request()
        await self.accept(request, wait=False)
        busy = await self.accept(self.request(), wait=False)
        self.assertEqual(busy["reason"], "busy")
        self.assertEqual(self.captures, 0)
        release.set()
        await self.worker.active
        result = self.receipts[-1]
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["request_id"], request["request_id"])
        self.assertGreaterEqual(result["capture_started_monotonic"], trigger)
        self.assertEqual((self.connects, self.captures), (1, 1))

    async def test_failed_preconnect_gets_one_fresh_connect_for_waiting_request(self):
        entered, release = asyncio.Event(), asyncio.Event()
        owner = self
        class FailingConnection(FakeConnection):
            async def __aenter__(self):
                owner.connects += 1
                entered.set()
                await release.wait()
                raise RuntimeError("SECRET_CONNECTION_ENDPOINT")
        self.worker.connection_factory = lambda _: FailingConnection(self)
        self.worker.start_preconnect()
        await entered.wait()
        request = self.request()
        await self.accept(request, wait=False)
        release.set()
        await self.worker.active
        # The warm-up failed, then the keypress made exactly one attempt of its own.
        self.assertEqual(self.receipts[-1]["reason"], "capture_failed")
        self.assertEqual(self.receipts[-1]["request_id"], request["request_id"])
        self.assertEqual((self.connects, self.captures, self.closes), (2, 0, 2))
        self.assertNotIn("SECRET", json.dumps(self.receipts))
        self.worker.start_preconnect()  # Repeated enable hint is not a retry.
        await asyncio.sleep(0.01)
        self.assertEqual(self.connects, 2)
        self.worker.connection_factory = lambda _: FakeConnection(self)
        result = await self.accept(self.request())  # New user request may reconnect.
        self.assertTrue(result["ok"], result)
        self.assertFalse(result["connection_reused"])
        self.assertEqual((self.connects, self.captures), (3, 1))

    async def test_failed_preconnect_then_healthy_connect_captures_once(self):
        entered, release = asyncio.Event(), asyncio.Event()
        owner = self
        class FailOnce(FakeConnection):
            async def __aenter__(self):
                owner.connects += 1
                if owner.connects == 1:
                    entered.set()
                    await release.wait()
                    raise RuntimeError("SECRET_CONNECTION_ENDPOINT")
                return object(), {}
        self.worker.connection_factory = lambda _: FailOnce(self)
        self.worker.start_preconnect()
        await entered.wait()
        await self.accept(self.request(), wait=False)
        release.set()
        await self.worker.active
        result = self.receipts[-1]
        self.assertTrue(result["ok"], result)
        self.assertFalse(result["connection_reused"])
        self.assertEqual((self.connects, self.captures), (2, 1))

    async def test_preconnect_timeout_destroys_session_and_never_retries(self):
        owner = self
        class HangingConnection(FakeConnection):
            async def __aenter__(self):
                owner.connects += 1
                await asyncio.sleep(60)
        self.worker.connection_factory = lambda _: HangingConnection(self)
        with mock.patch.object(service, "PRECONNECT_TIMEOUT", 0.02):
            self.worker.start_preconnect()
            self.assertEqual(await self.worker.preconnect_task, "timeout")
        await asyncio.sleep(0.02)
        self.assertEqual((self.connects, self.closes, self.captures, self.receipts), (1, 1, 0, []))
        self.assertIsNone(self.worker.provider)

    async def test_preconnect_internal_timeout_cannot_commit_swallowed_cancellation(self):
        owner = self
        class CancellationSwallowingConnection(FakeConnection):
            async def __aenter__(self):
                owner.connects += 1
                try:
                    await asyncio.sleep(60)
                except asyncio.CancelledError:
                    return object(), {}
        self.worker.connection_factory = lambda _: CancellationSwallowingConnection(self)
        with mock.patch.object(service, "PRECONNECT_TIMEOUT", 0.02):
            self.worker.start_preconnect()
            self.assertEqual(await self.worker.preconnect_task, "timeout")
        self.assertEqual((self.connects, self.closes, self.captures), (1, 1, 0))
        self.assertIsNone(self.worker.provider)
        self.assertIsNone(self.worker.idle_task)

    async def test_capture_deadline_includes_waiting_for_preconnect(self):
        entered = asyncio.Event()
        owner = self
        class HangingConnection(FakeConnection):
            async def __aenter__(self):
                owner.connects += 1
                entered.set()
                await asyncio.sleep(60)
        self.worker.connection_factory = lambda _: HangingConnection(self)
        self.worker.start_preconnect()
        await entered.wait()
        started = time.monotonic()
        result = await self.accept(self.request(timeout=4))
        self.assertEqual(result["reason"], "timeout")
        self.assertLess(time.monotonic() - started, 4)
        # 2026-10-24: the keypress gives up, but the reconnect in flight keeps running in
        # the background for the next keypress (it used to be cancelled and restarted).
        self.assertEqual((self.connects, self.captures, self.closes), (1, 0, 0))
        self.assertFalse(self.worker.preconnect_task.done())

    async def test_preconnect_idle_expiry_only_closes_and_never_reconnects(self):
        self.worker.idle_seconds = 0.02
        self.worker.start_preconnect()
        await self.worker.preconnect_task
        await asyncio.sleep(0.06)
        self.assertEqual((self.connects, self.closes, self.captures), (1, 1, 0))
        self.assertIsNone(self.worker.provider)
        result = await self.accept(self.request())
        self.assertTrue(result["ok"], result)
        self.assertFalse(result["connection_reused"])

    async def test_shutdown_before_cancelled_preconnect_returns_cannot_start_capture(self):
        entered = asyncio.Event()
        owner = self
        class CancellationSwallowingConnection(FakeConnection):
            async def __aenter__(self):
                owner.connects += 1
                entered.set()
                try:
                    await asyncio.sleep(60)
                except asyncio.CancelledError:
                    return object(), {}
        self.worker.connection_factory = lambda _: CancellationSwallowingConnection(self)
        self.worker.start_preconnect()
        await entered.wait()
        await self.accept(self.request(), wait=False)
        await self.worker.shutdown()
        self.assertTrue(self.worker.terminal)
        self.assertEqual((self.connects, self.captures, self.closes), (1, 0, 1))
        self.assertIsNone(self.worker.provider)
        self.assertIsNone(self.worker.idle_task)
        self.assertEqual(list(self.output.iterdir()), [])
        self.assertTrue(all(not receipt["ok"] for receipt in self.receipts))

    async def test_cancel_preconnect_rejects_late_success_and_does_not_rearm_idle(self):
        entered = asyncio.Event()
        owner = self
        class CancellationSwallowingConnection(FakeConnection):
            async def __aenter__(self):
                owner.connects += 1
                entered.set()
                try:
                    await asyncio.sleep(60)
                except asyncio.CancelledError:
                    return object(), {}
        self.worker.connection_factory = lambda _: CancellationSwallowingConnection(self)
        self.worker.start_preconnect()
        await entered.wait()
        await self.accept(self.request(), wait=False)
        await self.worker._cancel_preconnect()
        await self.worker.active
        self.assertEqual(self.receipts[-1]["reason"], "cancelled")
        self.assertEqual((self.connects, self.captures, self.closes), (1, 0, 1))
        self.assertIsNone(self.worker.provider)
        self.assertIsNone(self.worker.idle_task)

    async def test_shutdown_during_cold_connection_cannot_start_late_capture(self):
        entered = asyncio.Event()
        owner = self
        class CancellationSwallowingConnection(FakeConnection):
            async def __aenter__(self):
                owner.connects += 1
                entered.set()
                try:
                    await asyncio.sleep(60)
                except asyncio.CancelledError:
                    return object(), {}
        self.worker.connection_factory = lambda _: CancellationSwallowingConnection(self)
        await self.accept(self.request(), wait=False)
        await entered.wait()
        await self.worker.shutdown()
        self.assertEqual((self.connects, self.captures, self.closes), (1, 0, 1))
        self.assertIsNone(self.worker.provider)
        self.assertIsNone(self.worker.idle_task)
        self.assertEqual(list(self.output.iterdir()), [])
        self.assertTrue(all(not receipt["ok"] for receipt in self.receipts))

    async def test_expired_timer_waiting_for_lock_cannot_close_reused_connection(self):
        self.worker.idle_seconds = 0.02
        self.worker.start_preconnect()
        await self.worker.preconnect_task
        await self.worker.lock.acquire()
        try:
            await asyncio.sleep(0.04)  # Idle task is now waiting for this lock.
            await self.accept(self.request(), wait=False)
            self.worker.idle_seconds = 600
        finally:
            self.worker.lock.release()
        await self.worker.active
        result = self.receipts[-1]
        self.assertTrue(result["ok"], result)
        self.assertTrue(result["connection_reused"])
        self.assertEqual((self.connects, self.closes), (1, 0))

    async def test_reuse_connection_but_new_capture_and_receipt_each_request(self):
        first = await self.accept(self.request())
        second_trigger = time.monotonic()
        second_request = self.request()
        second = await self.accept(second_request)
        self.assertTrue(first["ok"], first)
        self.assertTrue(second["ok"], second)
        self.assertEqual((self.connects, self.captures, self.closes), (1, 2, 0))
        self.assertFalse(first["connection_reused"])
        self.assertTrue(second["connection_reused"])
        self.assertNotEqual(first["sha256"], second["sha256"])
        self.assertEqual((second["width"], second["height"]), (2388, 1668))
        self.assertGreaterEqual(second["request_started_monotonic"], second_trigger)
        times = [second[k] for k in ("request_started_monotonic", "capture_started_monotonic",
                 "capture_completed_monotonic", "request_completed_monotonic")]
        self.assertEqual(times, sorted(times))
        path = Path(second_request["output_file"])
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(second["sha256"], hashlib.sha256(path.read_bytes()).hexdigest())
        self.assertEqual(second["bytes"], path.stat().st_size)
        self.assertTrue(all(math.isfinite(v) and v >= 0 for v in second["timings_ms"].values()))
        self.assertFalse(list(self.output.glob(".capture-service-*")))

    async def test_duplicate_uuid_never_captures_again(self):
        request = self.request()
        await self.accept(request)
        duplicate = await self.accept(request)
        self.assertEqual(duplicate["reason"], "duplicate_request_id")
        self.assertEqual((self.connects, self.captures), (1, 1))

    async def test_busy_request_rejected_immediately_and_not_queued(self):
        entered, release = asyncio.Event(), asyncio.Event()
        original = self.worker.capture
        async def delayed(provider):
            entered.set()
            await release.wait()
            return await original(provider)
        self.worker.capture = delayed
        await self.accept(self.request(), wait=False)
        await entered.wait()
        second = self.request()
        result = await self.accept(second, wait=False)
        self.assertEqual(result["reason"], "busy")
        release.set()
        await self.worker.active
        self.assertEqual(self.captures, 1)
        self.assertFalse(Path(second["output_file"]).exists())
        self.assertEqual((await self.accept(second))["reason"], "duplicate_request_id")

    async def test_routed_early_rejections_keep_attempt_identity(self):
        attempt = str(uuid.uuid4())
        request = self.request(attempt_id=attempt, deadline_monotonic=time.monotonic() + 4)
        first = await self.accept(request)
        self.assertTrue(first["ok"])
        duplicate = await self.accept(request)
        self.assertEqual((duplicate["reason"], duplicate.get("attempt_id")),
                         ("duplicate_request_id", attempt))

        invalid = self.request(attempt_id=attempt, deadline_monotonic=time.monotonic() + 4,
                               timeout=True)
        rejected = await self.accept(invalid)
        self.assertEqual((rejected["reason"], rejected.get("attempt_id")),
                         ("invalid_timeout", attempt))

        gate = asyncio.Event()
        original_capture = self.worker.capture
        async def wait_for_release(provider):
            await gate.wait()
            return await original_capture(provider)
        self.worker.capture = wait_for_release
        await self.accept(self.request(), wait=False)
        try:
            busy = await self.accept(self.request(attempt_id=attempt,
                deadline_monotonic=time.monotonic() + 4), wait=False)
            self.assertEqual((busy["reason"], busy.get("attempt_id")), ("busy", attempt))
        finally:
            gate.set()
            await self.worker.active
        self.worker.terminal = True
        stopped = await self.accept(self.request(attempt_id=attempt,
            deadline_monotonic=time.monotonic() + 4))
        self.assertEqual((stopped["reason"], stopped.get("attempt_id")),
                         ("worker_failed", attempt))

    async def test_idle_expiry_destroys_connection_and_next_request_reconnects(self):
        self.worker.idle_seconds = 0.02
        await self.accept(self.request())
        await asyncio.sleep(0.05)
        self.assertEqual(self.closes, 1)
        self.assertIsNone(self.worker.provider)
        receipt = await self.accept(self.request())
        self.assertFalse(receipt["connection_reused"])
        self.assertEqual((self.connects, self.captures), (2, 2))

    async def test_unknown_error_destroys_session_without_retry_and_redacts(self):
        original = self.worker.capture
        async def fail(_provider):
            self.captures += 1
            raise RuntimeError("SECRET_KEY 192.0.2.88 DEVICE_ID")
        self.worker.capture = fail
        request = self.request()
        receipt = await self.accept(request)
        self.assertEqual(receipt["reason"], "capture_failed")
        self.assertEqual((self.connects, self.captures, self.closes), (1, 1, 1))
        self.assertFalse(Path(request["output_file"]).exists())
        for secret in ("SECRET", "192.0.2.88", "DEVICE_ID", "RuntimeError"):
            self.assertNotIn(secret, json.dumps(receipt))
        self.worker.capture = original
        self.assertFalse((await self.accept(self.request()))["connection_reused"])
        self.assertEqual(self.connects, 2)

    async def test_timeout_cancels_single_capture_and_closes_session(self):
        async def hang(_provider):
            self.captures += 1
            await asyncio.sleep(60)
        self.worker.capture = hang
        before = time.monotonic()
        receipt = await self.accept(self.request(timeout=4))
        self.assertEqual(receipt["reason"], "timeout")
        self.assertLess(time.monotonic() - before, 4)
        self.assertEqual((self.captures, self.closes), (1, 1))
        self.assertIsNone(self.worker.provider)

    async def test_stale_or_unknown_timestamp_never_published(self):
        for start, complete in ((0, 1), (float("nan"), 1), (False, 1)):
            async def invalid(_provider):
                return self.frames[0], start, complete
            self.worker.capture = invalid
            request = self.request()
            receipt = await self.accept(request)
            self.assertEqual(receipt["reason"], "capture_integrity_failed")
            self.assertFalse(Path(request["output_file"]).exists())
        self.assertEqual((self.connects, self.closes), (3, 3))

    async def test_black_frame_keeps_healthy_session_without_output(self):
        # 2026-10-25: a complete reply rejected on content leaves the link healthy; the next
        # keypress reuses the session instead of reconnecting. The black frame is still refused.
        self.frames = [png("black"), png()]
        request = self.request()
        receipt = await self.accept(request)
        self.assertEqual(receipt["reason"], "black_frame_rejected")
        self.assertEqual(self.closes, 0)
        self.assertFalse(Path(request["output_file"]).exists())
        second = self.request()
        receipt = await self.accept(second)
        self.assertTrue(receipt["ok"])
        self.assertTrue(receipt["connection_reused"])
        self.assertEqual((self.connects, self.closes), (1, 0))

    async def test_fixed_output_directory_and_symlink_fail_closed(self):
        outside = self.request(output_file=str(self.base / "outside.png"))
        self.assertEqual((await self.accept(outside))["reason"], "output_outside_private_cache")
        request = self.request()
        Path(request["output_file"]).symlink_to(self.base / "missing")
        self.assertEqual((await self.accept(request))["reason"], "output_already_exists")
        self.assertTrue(Path(request["output_file"]).is_symlink())
        self.assertEqual((self.connects, self.captures), (0, 0))

    async def test_replaced_output_directory_rejected(self):
        self.output.rename(self.base / "original-output")
        self.output.mkdir(mode=0o700)
        self.assertEqual((await self.accept(self.request()))["reason"], "output_parent_not_private")
        self.assertEqual((self.connects, self.captures), (0, 0))

    async def test_invalid_control_and_id_are_redacted_and_never_capture(self):
        invalid = await self.accept(self.request(request_id="SECRET_ID"))
        self.assertIsNone(invalid["request_id"])
        self.assertNotIn("SECRET", json.dumps(invalid))
        for changed in ({"action": "cancel"}, {"timeout": True}, {"timeout": float("inf")},
                        {"timeout": 2}, {"extra": "SECRET"}):
            self.assertFalse((await self.accept(self.request(**changed)))["ok"])
        self.assertEqual((self.connects, self.captures), (0, 0))

    async def test_uncooperative_cleanup_retires_worker(self):
        class SlowClose(FakeConnection):
            async def __aexit__(self, *_args):
                await asyncio.sleep(60)
        self.worker.connection_factory = lambda _: SlowClose(self)
        self.worker.cleanup_seconds = 0.02
        self.worker.idle_seconds = 0.02
        await self.accept(self.request())
        await asyncio.wait_for(self.worker.stop_event.wait(), 0.3)
        self.assertTrue(self.worker.terminal)
        self.assertIsNone(self.worker.provider)


class CaptureSessionTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.state, self.output = private_fixture(self.base)
        self.events, self.receipts, self.sessions, self.dvts = [], [], [], []
        self.frames = [png(), png("yellow", landscape=True)]
        self.rpcs = 0
        self.rpc_hook = None
        self.dvt_entry_hook = None
        self.fail_entry = None
        owner = self
        class Connection:
            async def __aenter__(self):
                owner.events.append("wifi_enter")
                return object(), {}
            async def __aexit__(self, *_):
                owner.events.append("wifi_exit")
        class Dtx:
            def __init__(self):
                self.disconnected = asyncio.Event()
            async def wait_disconnected(self):
                await self.disconnected.wait()
        class Dvt:
            def __init__(self, _provider):
                self.dtx = Dtx()
                owner.dvts.append(self)
            async def __aenter__(self):
                owner.events.append("dvt_enter")
                if owner.dvt_entry_hook is not None:
                    await owner.dvt_entry_hook()
                if owner.fail_entry == "dvt":
                    raise RuntimeError("synthetic DVT entry failure")
                return self
            async def __aexit__(self, *_):
                owner.events.append("dvt_exit")
                self.dtx.disconnected.set()
        class Screenshot:
            def __init__(self, dvt):
                self.dvt = dvt
            async def __aenter__(self):
                owner.events.append("screenshot_enter")
                if owner.fail_entry == "screenshot":
                    raise RuntimeError("synthetic channel entry failure")
                return self
            async def __aexit__(self, *_):
                owner.events.append("screenshot_exit")
            async def get_screenshot(self):
                owner.rpcs += 1
                owner.events.append("rpc")
                if owner.rpc_hook is not None:
                    return await owner.rpc_hook(self.dvt)
                await asyncio.sleep(0)
                return owner.frames[(owner.rpcs - 1) % len(owner.frames)]
        def session_factory(state):
            capture_session = service.CaptureSession(state, connection_factory=lambda _: Connection(),
                dvt_factory=Dvt, screenshot_factory=Screenshot)
            self.sessions.append(capture_session)
            return capture_session
        self.worker = service.CaptureService(self.state, self.output, connection_factory=session_factory)

    async def asyncTearDown(self):
        await self.worker.shutdown()
        self.temp.cleanup()

    async def emit(self, receipt):
        self.receipts.append(receipt)

    async def capture_request(self, wait=True, limits_ms=None, timeout=8):
        identity = str(uuid.uuid4())
        value = {"action": "capture", "request_id": identity, "timeout": timeout,
                 "output_file": str(self.output / (identity + ".png"))}
        if limits_ms is not None:
            value["limits_ms"] = limits_ms
        await self.worker.accept(json.dumps(value).encode(), self.emit)
        if wait:
            await self.worker.active
            return self.receipts[-1]
        return value

    async def test_creation_alone_opens_nothing(self):
        await asyncio.sleep(0)
        self.assertEqual((self.sessions, self.events, self.rpcs), ([], [], 0))

    async def test_preconnect_reuses_dvt_and_channel_but_each_key_gets_new_rpc(self):
        self.worker.start_preconnect()
        self.assertIsNone(await self.worker.preconnect_task)
        self.assertEqual(self.events, ["wifi_enter", "dvt_enter", "screenshot_enter"])
        self.assertEqual(self.rpcs, 0)
        self.assertEqual(list(self.output.iterdir()), [])
        first = await self.capture_request()
        second_trigger = time.monotonic()
        second = await self.capture_request()
        self.assertTrue(first["ok"], first)
        self.assertTrue(second["ok"], second)
        self.assertNotEqual(first["sha256"], second["sha256"])
        self.assertEqual((second["width"], second["height"]), (2388, 1668))
        self.assertGreaterEqual(second["capture_started_monotonic"], second_trigger)
        self.assertTrue(first["connection_reused"])
        self.assertTrue(second["connection_reused"])
        self.assertEqual(self.events, ["wifi_enter", "dvt_enter", "screenshot_enter", "rpc", "rpc"])
        self.assertEqual((len(self.sessions), self.rpcs), (1, 2))
        self.assertFalse(any(isinstance(value, bytes) for value in vars(self.sessions[0]).values()))
        await self.worker.shutdown()
        self.assertEqual(self.events[-3:], ["screenshot_exit", "dvt_exit", "wifi_exit"])

    async def test_idle_closes_all_layers_and_next_key_creates_new_session(self):
        self.worker.idle_seconds = 0.02
        self.worker.start_preconnect()
        await self.worker.preconnect_task
        await asyncio.sleep(0.05)
        self.assertEqual(self.events[-3:], ["screenshot_exit", "dvt_exit", "wifi_exit"])
        self.assertEqual(self.rpcs, 0)
        result = await self.capture_request()
        self.assertTrue(result["ok"], result)
        self.assertFalse(result["connection_reused"])
        self.assertEqual((len(self.sessions), self.rpcs), (2, 1))

    async def test_rpc_failure_destroys_all_layers_without_retry(self):
        async def fail(_dvt):
            raise RuntimeError("SECRET_RPC_FAILURE")
        self.rpc_hook = fail
        result = await self.capture_request()
        self.assertEqual(result["reason"], "capture_failed")
        self.assertEqual(self.rpcs, 1)
        self.assertEqual(self.events[-3:], ["screenshot_exit", "dvt_exit", "wifi_exit"])
        self.assertFalse(self.sessions[0].ready)
        self.assertNotIn("SECRET", json.dumps(result))
        self.rpc_hook = None
        self.assertTrue((await self.capture_request())["ok"])
        self.assertEqual((len(self.sessions), self.rpcs), (2, 2))

    async def test_rpc_timeout_destroys_channel_and_retries_once_on_a_new_session(self):
        async def hanging(_dvt):
            await asyncio.sleep(60)
        self.rpc_hook = hanging
        with mock.patch.object(service, "SCREENSHOT_TIMEOUT", 0.02):
            result = await self.capture_request()
        self.assertEqual(result["reason"], "timeout")
        self.assertEqual({k: result["timings_ms"][k] for k in ("attempts", "reconnect_in_progress", "session_reused")},
                         {"attempts": 2, "reconnect_in_progress": 0.0, "session_reused": 0.0})
        self.assertEqual((self.rpcs, len(self.sessions)), (2, 2))   # one retry, on a fresh channel
        self.assertEqual(self.events[-3:], ["screenshot_exit", "dvt_exit", "wifi_exit"])
        self.assertEqual(list(self.output.iterdir()), [])

    async def _check_uncooperative_rpc_retirement(self, progress_watchdog):
        release = asyncio.Event()
        async def ignores_cancel(_dvt):
            while not release.is_set():
                try:
                    await release.wait()
                except asyncio.CancelledError:
                    pass
            return self.frames[0]
        self.rpc_hook = ignores_cancel
        self.worker.cleanup_seconds = 0.03
        if progress_watchdog:
            self.fake_link()
            # Only USB abandons on progress evidence; Wi-Fi treats it as advisory.
            self.worker.transport = "usb"
        with mock.patch.object(service, "RPC_CANCEL_SECONDS", 0.005, create=True), \
             mock.patch.object(service, "SCREENSHOT_TIMEOUT", 0.02 if not progress_watchdog else 5), \
             mock.patch.object(service, "FIRST_BYTE_LIMIT", 0.02), \
             mock.patch.object(service, "USB_FIRST_BYTE_LIMIT", 0.02):
            try:
                await self.capture_request(wait=False)
                done, _ = await asyncio.wait({self.worker.active}, timeout=0.4)
                self.assertTrue(done, "discarded RPC must not block the receipt/teardown forever")
                result = self.receipts[-1]
                self.assertFalse(result["ok"])
                self.assertIn(result["reason"], {"first_byte_timeout", "worker_failed"})
                self.assertTrue(self.worker.terminal)
                self.assertEqual(self.rpcs, 1)
                self.assertEqual(len(self.sessions), 1)
                self.assertEqual(self.events[-3:], ["screenshot_exit", "dvt_exit", "wifi_exit"])
                self.assertEqual(list(self.output.iterdir()), [])
            finally:
                release.set()
                if self.worker.active is not None:
                    await self.worker.active
                await asyncio.sleep(0)

    async def test_progress_failure_does_not_await_uncooperative_rpc_forever(self):
        await self._check_uncooperative_rpc_retirement(progress_watchdog=True)

    async def test_screenshot_timeout_does_not_await_uncooperative_rpc_forever(self):
        await self._check_uncooperative_rpc_retirement(progress_watchdog=False)

    async def test_slow_first_attempt_is_retried_and_the_retry_is_published(self):
        async def slow_then_fast(_dvt):
            if self.rpcs == 1:
                await asyncio.sleep(60)
            await asyncio.sleep(0)
            return self.frames[1]
        self.rpc_hook = slow_then_fast
        with mock.patch.object(service, "FIRST_ATTEMPT_TIMEOUT", 0.05):
            result = await self.capture_request()
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["timings_ms"]["attempts"], 2)
        self.assertFalse(result["connection_reused"])
        self.assertEqual((self.rpcs, len(self.sessions)), (2, 2))
        self.assertEqual(len(list(self.output.iterdir())), 1)
        self.assertFalse(self.sessions[0].ready)               # the first channel is gone

    async def test_late_first_reply_is_never_published(self):
        late = asyncio.Event()
        async def first_late(_dvt):
            if self.rpcs == 1:
                try:
                    await asyncio.sleep(60)
                except asyncio.CancelledError:
                    late.set()
                    return self.frames[0]                       # a reply that arrives too late
            await asyncio.sleep(0)
            return self.frames[1]
        self.rpc_hook = first_late
        with mock.patch.object(service, "FIRST_ATTEMPT_TIMEOUT", 0.05):
            result = await self.capture_request()
        self.assertTrue(late.is_set())
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["timings_ms"]["attempts"], 2)
        files = list(self.output.iterdir())
        self.assertEqual(len(files), 1)                         # never two outputs, never a second paste
        expected = hashlib.sha256(service.once.prepare_png(self.frames[1])[0]).hexdigest()
        self.assertEqual(result["sha256"], expected)

    async def test_no_retry_without_enough_budget_left(self):
        async def hanging(_dvt):
            await asyncio.sleep(60)
        self.rpc_hook = hanging
        with mock.patch.object(service, "FIRST_ATTEMPT_TIMEOUT", 0.05), \
             mock.patch.object(service, "MAX_TRANSFER_BUDGET", 0.5), mock.patch.object(service, "MIN_RETRY_SECONDS", 1.0):
            result = await self.capture_request()
        self.assertEqual(result["reason"], "timeout")
        self.assertEqual({k: result["timings_ms"][k] for k in ("attempts", "reconnect_in_progress", "session_reused")},
                         {"attempts": 1, "reconnect_in_progress": 0.0, "session_reused": 0.0})
        self.assertEqual(self.rpcs, 1)

    async def test_keypress_during_a_hanging_reconnect_fails_at_5_s_and_reconnect_continues(self):
        # 2026-10-24 16:25: a keypress waited 45 s for a failing reconnect, silently.
        # Ashley 16:33: past 5 s it has failed. The reconnect keeps going for the next press.
        gate = asyncio.Event()
        owner = self
        class Slow(service.CaptureSession):
            async def __aenter__(self):
                await gate.wait()
                owner.events.append("slow_reconnect_done")
                return self
        self.worker.connection_factory = lambda state: Slow(state)
        self.worker.start_preconnect()
        await asyncio.sleep(0)
        started = time.monotonic()
        result = await self.capture_request()
        elapsed = time.monotonic() - started
        print(f"\n  press -> failure: {elapsed:.3f} s", flush=True)
        self.assertFalse(result["ok"])
        self.assertEqual(result["reason"], "timeout")
        self.assertGreaterEqual(elapsed, service.REQUEST_BUDGET - 0.1)
        self.assertLess(elapsed, service.REQUEST_BUDGET + 0.3)
        self.assertEqual(self.rpcs, 0)
        self.assertEqual(list(self.output.iterdir()), [])
        self.assertFalse(self.worker.preconnect_task.done())    # the reconnect is still running
        gate.set()
        await self.worker.preconnect_task
        self.assertIn("slow_reconnect_done", self.events)

    async def test_retry_only_with_at_least_1_5_s_left(self):
        self.assertEqual((service.REQUEST_BUDGET, service.FIRST_ATTEMPT_TIMEOUT, service.MIN_RETRY_SECONDS), (4.5, 4.5, 1.5))

    async def test_first_attempt_success_records_one_attempt(self):
        result = await self.capture_request()
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["timings_ms"]["attempts"], 1)

    async def test_real_rpc_uses_learned_usb_floor_and_cancels_without_retry(self):
        for _ in range(10): self.assertTrue(self.worker.success_timings.record("usb", 0.1))
        self.worker.transport = "usb"
        link = self.fake_link()
        async def delayed(_dvt):
            await asyncio.sleep(1.3)
            link.packets.append((time.monotonic(), 65504))
            return self.frames[0]
        self.rpc_hook = delayed
        at = time.monotonic()
        result = await self.capture_request()
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["timings_ms"]["slow_threshold"], 2500)
        self.assertGreater(time.monotonic() - at, 1.29)
        self.assertEqual(self.rpcs, 1)
    async def test_real_rpc_lifecycle_events_match_receipt_and_precede_validation(self):
        events = []
        async def event(value):
            events.append(value)
        self.worker.progress_events = event
        original = service.once.prepare_png
        def validate(data, *, timings=None):
            self.assertEqual(events[-1]["event"], "capture_completed")
            return original(data, timings=timings)
        with mock.patch.object(service.once, "prepare_png", side_effect=validate):
            result = await self.capture_request()
        self.assertTrue(result["ok"], result)
        start = next(row for row in events if row["event"] == "capture_started")
        complete = next(row for row in events if row["event"] == "capture_completed")
        self.assertEqual(start["capture_started_monotonic"], result["capture_started_monotonic"])
        self.assertEqual(complete["capture_completed_monotonic"], result["capture_completed_monotonic"])
        self.assertEqual(start["request_id"], result["request_id"])
        self.assertEqual(complete["request_id"], result["request_id"])

    async def test_mount_during_preconnect_exempts_only_first_screenshot(self):
        from types import SimpleNamespace
        mounted = False
        original_factory = self.worker.connection_factory
        class Connection:
            async def __aenter__(self):
                return SimpleNamespace(peer_info={"Services": {service.DEVELOPER_SERVICE: {}} if mounted else {}}), {}
            async def __aexit__(self, *_):
                pass
        async def mount(_provider):
            nonlocal mounted
            mounted = True
        def factory(state):
            session = original_factory(state)
            session.connection_factory = lambda _: Connection()
            session.mount = mount
            return session
        async def slow(_dvt):
            await asyncio.sleep(0.09)
            return self.frames[0]
        self.worker.connection_factory = factory
        self.rpc_hook = slow
        self.worker.start_preconnect()
        await self.worker.preconnect_task
        self.assertTrue(mounted)
        self.assertEqual(self.rpcs, 0)
        with mock.patch.object(self.worker.success_timings, "threshold", return_value=Threshold(0.05, 20, 0.02)):
            first = await self.capture_request()
            second = await self.capture_request()
        self.assertTrue(first["ok"], first)
        self.assertEqual(first["timings_ms"]["slow_threshold_exempt"], 1)
        self.assertTrue(second["ok"], second)
        self.assertEqual(second["timings_ms"]["slow_threshold_exempt"], 0)
        self.assertEqual(self.rpcs, 2)

    async def test_adaptive_timeout_bounds_cancellation_resistant_rpc(self):
        release = asyncio.Event()
        async def ignores_cancel(_dvt):
            while not release.is_set():
                try:
                    await release.wait()
                except asyncio.CancelledError:
                    pass
            return self.frames[0]
        self.rpc_hook = ignores_cancel
        self.worker.cleanup_seconds = 0.03
        with mock.patch.object(self.worker.success_timings, "threshold", return_value=Threshold(0.05, 20, 0.02)), \
             mock.patch.object(service, "RPC_CANCEL_SECONDS", 0.005), \
             mock.patch.object(service, "REQUEST_BUDGET", 0.08):
            try:
                await self.capture_request(wait=False)
                done, _ = await asyncio.wait({self.worker.active}, timeout=0.3)
                self.assertTrue(done)
                self.assertEqual(self.receipts[-1]["reason"], "timeout")
                self.assertTrue(self.worker.terminal)
                self.assertEqual(self.rpcs, 1)
                self.assertEqual(list(self.output.iterdir()), [])
            finally:
                release.set()
                await asyncio.sleep(0.01)

    async def test_late_reply_after_timeout_is_never_published_or_reused(self):
        async def swallowed_cancel(_dvt):
            try:
                await asyncio.sleep(60)
            except asyncio.CancelledError:
                return self.frames[0]
        self.rpc_hook = swallowed_cancel
        with mock.patch.object(service, "SCREENSHOT_TIMEOUT", 0.02):
            result = await self.capture_request()
        # The watchdog abandons the RPC at its limit; the late reply is dropped, never published.
        self.assertIn(result["reason"], {"timeout", "capture_response_too_old"})
        self.assertEqual(self.rpcs, 1)
        self.assertEqual(list(self.output.iterdir()), [])
        self.assertEqual(self.events[-3:], ["screenshot_exit", "dvt_exit", "wifi_exit"])
        self.rpc_hook = None
        self.assertTrue((await self.capture_request())["ok"])
        self.assertEqual((len(self.sessions), self.rpcs), (2, 2))

    # Progress rules (2026-10-25): fail on evidence instead of waiting for the press cap.
    def fake_link(self):
        class Link:
            sock = None
            packets = None
        service.link_timeline._current = Link()
        self.addCleanup(setattr, service.link_timeline, "_current", None)
        return service.link_timeline._current

    async def test_no_first_byte_is_advisory_until_hard_cap(self):
        self.fake_link()
        async def silent(_dvt):
            await asyncio.sleep(60)
        self.rpc_hook = silent
        started = time.monotonic()
        events = []
        async def progress(event):
            if event["event"] == "capture_progress": events.append(event)
        self.worker.progress_events = progress
        result = await self.capture_request(limits_ms={"first_byte": 200, "stall": 300, "press_cap": 800})
        elapsed = time.monotonic() - started
        self.assertEqual(result["reason"], "timeout")
        self.assertGreaterEqual(elapsed, 0.75)
        self.assertLess(elapsed, 1.2)
        self.assertIn("first_byte_timeout", [e["reason"] for e in events])
        self.assertEqual(list(self.output.iterdir()), [])

    async def test_stall_mid_transfer_fails_after_one_point_two_seconds(self):
        link = self.fake_link()
        async def stalls(_dvt):
            link.packets.append((time.monotonic(), 1400))
            await asyncio.sleep(service.STALL_LIMIT + 0.15)
            link.packets.append((time.monotonic(), 1400))
            return self.frames[0]
        self.rpc_hook = stalls
        started = time.monotonic()
        result = await self.capture_request()
        elapsed = time.monotonic() - started
        self.assertFalse(result["ok"], result)
        self.assertEqual(result["reason"], "stall_timeout")
        self.assertGreaterEqual(elapsed, service.STALL_LIMIT)
        self.assertLess(elapsed, service.STALL_LIMIT + 0.6)
        self.assertEqual(self.rpcs, 1)
        self.assertIn("wifi_exit", self.events)

    async def test_slow_but_moving_transfer_still_succeeds(self):
        # First byte at 0.6 s, a 1.0 s stall, done at 1.8 s: inside every rule and the 2 s cap.
        link = self.fake_link()
        async def slow(_dvt):
            await asyncio.sleep(0.6)
            link.packets.append((time.monotonic(), 1400))
            await asyncio.sleep(1.0)
            link.packets.append((time.monotonic(), 1400))
            await asyncio.sleep(0.2)
            return self.frames[0]
        self.rpc_hook = slow
        result = await self.capture_request()
        self.assertTrue(result["ok"], result)

    async def test_slow_but_finishing_transfer_may_use_the_cap(self):
        # 17:47: a 420 KB frame arriving at ~150 KB/s (finishes at ~2.9 s) must not be cut at 2 s.
        link = self.fake_link()
        service.link_timeline.expected_bytes = 420 * 1024
        async def trickle(_dvt):
            await asyncio.sleep(0.2)
            for _ in range(14):
                link.packets.append((time.monotonic(), 30 * 1024))
                await asyncio.sleep(0.19)
            return self.frames[0]
        self.rpc_hook = trickle
        result = await self.capture_request()
        self.assertTrue(result["ok"], result)
        self.assertGreater(result["timings_ms"]["screenshot"], 2000)

    async def test_early_pause_then_finish_is_not_too_slow(self):
        # 17:15:47 shape: first byte 0.17 s, 1.1 s pause, finished at 1.5 s.
        link = self.fake_link()
        service.link_timeline.expected_bytes = 360 * 1024
        async def pause_then_burst(_dvt):
            await asyncio.sleep(0.17)
            link.packets.append((time.monotonic(), 40 * 1024))
            await asyncio.sleep(1.1)
            for _ in range(8):
                link.packets.append((time.monotonic(), 40 * 1024))
                await asyncio.sleep(0.03)
            return self.frames[0]
        self.rpc_hook = pause_then_burst
        result = await self.capture_request()
        self.assertTrue(result["ok"], result)

    async def test_rate_estimate_is_advisory_and_later_burst_can_finish(self):
        # ~40 KB/s for a 420 KB frame: projected far past the 4.5 s cap -> too_slow after ~1 s of data.
        link = self.fake_link()
        service.link_timeline.expected_bytes = 420 * 1024
        async def crawl(_dvt):
            await asyncio.sleep(0.1)
            for _ in range(10):
                link.packets.append((time.monotonic(), 4 * 1024))
                await asyncio.sleep(0.1)
            link.packets.append((time.monotonic(), 400 * 1024))
            return self.frames[0]
        self.rpc_hook = crawl
        events = []
        async def progress(event):
            if event["event"] == "capture_progress": events.append(event)
        self.worker.progress_events = progress
        result = await self.capture_request()
        self.assertTrue(result["ok"], result)
        self.assertIn("too_slow", [e["reason"] for e in events])
        self.assertEqual(len(self.sessions), 1)

    async def test_press_cap_and_limits_from_the_request(self):
        self.fake_link()
        async def silent(_dvt):
            await asyncio.sleep(60)
        self.rpc_hook = silent
        started = time.monotonic()
        result = await self.capture_request(limits_ms={"first_byte": 300, "stall": 300, "press_cap": 1000})
        self.assertEqual(result["reason"], "timeout")
        self.assertGreaterEqual(time.monotonic() - started, 0.95)
        self.assertLess(time.monotonic() - started, 1.4)
        bad = await self.capture_request(limits_ms={"first_byte": 50, "stall": 300, "press_cap": 1000})
        self.assertEqual(bad["reason"], "invalid_timeout")

    async def test_one_second_first_byte_outage_recovers_and_reports_progress(self):
        link = self.fake_link()
        events = []
        async def progress(event):
            if event["event"] == "capture_progress": events.append(event)
        self.worker.progress_events = progress
        async def pause_then_reply(_dvt):
            await asyncio.sleep(1.05)
            link.packets.append((time.monotonic(), 400 * 1024))
            return self.frames[0]
        self.rpc_hook = pause_then_reply
        result = await self.capture_request()
        self.assertTrue(result["ok"], result)
        self.assertEqual((len(self.sessions), self.rpcs), (1, 1))
        self.assertTrue(any(e["reason"] == "first_byte_timeout" for e in events))
        for event in events:
            self.assertEqual(set(event), {"schema_version", "event", "request_id", "elapsed_ms",
                                          "received_bytes", "idle_ms", "reason", "source", "rpc_received_bytes", "expected_bytes"})
            self.assertEqual(event["source"], "tunnel")
            self.assertEqual(event["request_id"], result["request_id"])
        self.assertLessEqual(len(events), 12)

    async def test_twelve_mb_live_progress_survives_old_adaptive_and_press_deadlines(self):
        link = self.fake_link()
        async def flowing(_dvt):
            # A fake 12 MiB response at 2.4 MiB/s, after 0.5 s generation.
            await asyncio.sleep(0.5)
            for _ in range(20):
                link.packets.append((time.monotonic(), int(12 * 1024 * 1024 / 20)))
                await asyncio.sleep(0.25)
            return self.frames[0]
        self.rpc_hook = flowing
        with mock.patch.object(self.worker.success_timings, "threshold", return_value=Threshold(1, 20, 0.1)):
            at = time.monotonic()
            result = await self.capture_request(limits_ms={"first_byte": 800, "stall": 1200, "press_cap": 8000})
        self.assertTrue(result["ok"], result)
        self.assertGreater(time.monotonic() - at, 5.4)
        self.assertLess(time.monotonic() - at, 8)
        self.assertEqual(self.rpcs, 1)

    async def test_flowing_wifi_finishes_after_old_eight_second_cap(self):
        link = self.fake_link()
        async def flowing(_dvt):
            # Burst arrivals separated by half-second pauses continue beyond 8 s.
            for _ in range(18):
                link.packets.append((time.monotonic(), 440000))
                await asyncio.sleep(0.5)
            return self.frames[0]
        self.rpc_hook = flowing
        at = time.monotonic()
        result = await self.capture_request(timeout=40,
            limits_ms={"first_byte": 800, "stall": 2500, "press_cap": 30000})
        self.assertTrue(result["ok"], result)
        self.assertGreaterEqual(time.monotonic() - at, 9)
        self.assertLess(time.monotonic() - at, 12)
        self.assertEqual(self.rpcs, 1)
        self.assertGreater(self.worker.success_timings.load()["wifi"][-1]["seconds"], 8)

    async def test_usb_silence_waits_full_two_and_a_half_seconds(self):
        self.fake_link()
        self.worker.transport = "usb"
        async def silent(_dvt): await asyncio.sleep(60)
        self.rpc_hook = silent
        for _ in range(10): self.worker.success_timings.record("usb", 0.1)
        at = time.monotonic()
        result = await self.capture_request()
        self.assertEqual(result["reason"], "first_byte_timeout")
        self.assertGreaterEqual(time.monotonic() - at, 2.5)
        self.assertLess(time.monotonic() - at, 2.9)
        self.assertEqual(self.rpcs, 1)

    async def test_confirmed_disconnect_interrupts_a_hanging_rpc(self):
        async def disconnect_then_hang(dvt):
            await asyncio.sleep(0.04)
            dvt.dtx.disconnected.set()
            await asyncio.sleep(10)
        self.rpc_hook = disconnect_then_hang
        started = time.monotonic()
        result = await self.capture_request()
        self.assertEqual(result["reason"], "disconnected")
        self.assertLess(time.monotonic() - started, 0.4)
        self.assertEqual(self.rpcs, 1)
        self.assertEqual(list(self.output.iterdir()), [])

    async def test_cancel_during_rpc_destroys_session_without_output(self):
        entered = asyncio.Event()
        async def hanging(_dvt):
            entered.set()
            await asyncio.sleep(60)
        self.rpc_hook = hanging
        await self.capture_request(wait=False)
        await entered.wait()
        await self.worker.shutdown()
        self.assertEqual(self.rpcs, 1)
        self.assertEqual(self.events[-3:], ["screenshot_exit", "dvt_exit", "wifi_exit"])
        self.assertEqual(list(self.output.iterdir()), [])
        self.assertTrue(all(not r["ok"] for r in self.receipts))

    async def test_passive_dtx_disconnect_closes_entire_idle_session(self):
        self.worker.start_preconnect()
        await self.worker.preconnect_task
        self.dvts[0].dtx.disconnected.set()
        await asyncio.wait_for(self.sessions[0].watcher, 0.2)
        self.assertEqual(self.rpcs, 0)
        self.assertEqual(self.events[-3:], ["screenshot_exit", "dvt_exit", "wifi_exit"])
        # The next keypress replaces the dead session instead of failing.
        result = await self.capture_request()
        self.assertTrue(result["ok"], result)
        self.assertFalse(result["connection_reused"])
        self.assertEqual((len(self.sessions), self.rpcs), (2, 1))
        self.assertTrue((await self.capture_request())["connection_reused"])
        self.assertEqual((len(self.sessions), self.rpcs), (2, 2))

    async def test_disconnect_during_rpc_drops_result_and_never_retries(self):
        entered = asyncio.Event()
        async def disconnecting(dvt):
            entered.set()
            dvt.dtx.disconnected.set()
            await asyncio.sleep(0.01)
            return self.frames[0]  # Even a late plausible frame must be discarded.
        self.rpc_hook = disconnecting
        result = await self.capture_request()
        self.assertFalse(result["ok"])
        self.assertEqual(self.rpcs, 1)
        self.assertEqual(list(self.output.iterdir()), [])
        self.assertEqual(self.events.count("wifi_exit"), 1)

    async def test_partial_channel_entry_failure_closes_all_prior_layers(self):
        self.fail_entry = "screenshot"
        self.worker.start_preconnect()
        self.assertEqual(await self.worker.preconnect_task, "capture_failed")
        self.assertEqual(self.rpcs, 0)
        self.assertEqual(self.events, ["wifi_enter", "dvt_enter", "screenshot_enter",
                                     "screenshot_exit", "dvt_exit", "wifi_exit"])
        self.assertIsNone(self.worker.provider)

    async def test_cancelled_dvt_entry_cannot_open_screenshot_channel_after_late_success(self):
        entered = asyncio.Event()
        async def swallowing_entry():
            entered.set()
            try:
                await asyncio.sleep(60)
            except asyncio.CancelledError:
                return
        self.dvt_entry_hook = swallowing_entry
        self.worker.start_preconnect()
        await entered.wait()
        await self.capture_request(wait=False)
        await self.worker.shutdown()
        self.assertEqual(self.rpcs, 0)
        self.assertEqual(self.events, ["wifi_enter", "dvt_enter", "dvt_exit", "wifi_exit"])
        self.assertIsNone(self.worker.provider)
        self.assertIsNone(self.worker.idle_task)
        self.assertEqual(list(self.output.iterdir()), [])

    async def test_black_frame_keeps_reusable_session(self):
        self.frames = [png("black")]
        result = await self.capture_request()
        self.assertEqual(result["reason"], "black_frame_rejected")
        self.assertEqual(self.rpcs, 1)
        self.assertNotIn("screenshot_exit", self.events)
        self.assertIsNotNone(self.worker.provider)
        self.assertEqual(list(self.output.iterdir()), [])

    async def test_only_content_rejections_keep_the_session(self):
        for code in ("timeout", "capture_integrity_failed", "capture_response_too_old", "worker_failed"):
            self.assertNotIn(code, service.LINK_SAFE_FAILURES)
        self.assertEqual(service.LINK_SAFE_FAILURES,
                         {"black_frame_rejected", "invalid_png", "empty_frame", "frame_too_large", "unexpected_dimensions"})


class FramingTests(unittest.IsolatedAsyncioTestCase):
    async def test_real_screenshot_channel_sends_distinct_correlated_requests_in_memory(self):
        # Exercise the pinned Screenshot decorator, DTXChannel, sender, and reply
        # waiters with an in-memory writer. No connect(), socket, or device exists.
        from pymobiledevice3.dtx import DTXConnection
        from pymobiledevice3.dtx.channel import DTXChannel
        from pymobiledevice3.dtx.message import DTXMessage, DTXMessageType
        from pymobiledevice3.services.dvt.instruments.screenshot import Screenshot, ScreenshotService
        class Writer:
            def __init__(self):
                self.chunks = []
                self.closed = False
            def write(self, data):
                self.chunks.append(data)
            async def drain(self):
                await asyncio.sleep(0)
            def close(self):
                self.closed = True
            def is_closing(self):
                return self.closed
            async def wait_closed(self):
                return
        writer = Writer()
        dtx = DTXConnection(asyncio.StreamReader(), writer)
        channel = DTXChannel(1, ScreenshotService.IDENTIFIER, dtx)
        screenshot = Screenshot(None, service=ScreenshotService(dtx.ctx.child(channel=channel)))
        identifiers = []
        try:
            for expected in (b"first new frame", b"second new frame"):
                request = asyncio.create_task(screenshot.get_screenshot())
                async with asyncio.timeout(0.2):
                    while not dtx._pending_replies:
                        await asyncio.sleep(0)
                self.assertEqual(len(dtx._pending_replies), 1)
                identifier, future = next(iter(dtx._pending_replies.items()))
                identifiers.append(identifier)
                reply = DTXMessage(type=DTXMessageType.OBJECT, identifier=identifier,
                                   conversation_index=1, channel_code=1)
                reply.payload = expected
                future.set_result(reply)
                self.assertEqual(await request, expected)
                self.assertFalse(dtx._pending_replies)
            self.assertEqual(identifiers, [1, 2])
            self.assertTrue(writer.chunks)
        finally:
            await dtx.aclose()


    async def test_oversized_line_discards_entire_suffix_then_reads_next_line(self):
        reader = asyncio.StreamReader(limit=service.MAX_LINE_BYTES)
        reader.feed_data(b"x" * (service.MAX_LINE_BYTES + 10) + b'{"action":"capture"}\nvalid\n')
        reader.feed_eof()
        self.assertEqual([line async for line in service.request_lines(reader)], [None, b"valid"])

    async def test_partial_eof_is_not_executed_as_request(self):
        reader = asyncio.StreamReader(limit=service.MAX_LINE_BYTES)
        reader.feed_data(b'{"action":"capture"}')
        reader.feed_eof()
        self.assertEqual([line async for line in service.request_lines(reader)], [None])


def harness():
    """Use the real CLI/FD boundary/watchdog with wholly synthetic dependencies."""
    mode, state, output = sys.argv[2:5]
    frames = [png()]
    class FakeOwner:
        connects = closes = 0
    owner = FakeOwner()
    class HarnessConnection(FakeConnection):
        async def __aenter__(self):
            result = await super().__aenter__()
            if mode == "preconnect":
                (Path(state) / "preconnected").write_text("synthetic")
            return result
    async def fake_capture(_provider):
        if mode == "hang":
            child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
            (Path(state) / "harness-pids").write_text(json.dumps([os.getpid(), child.pid]))
            await asyncio.sleep(60)
        started = time.monotonic()
        print("SECRET_LOG_stdout", flush=True)
        os.write(2, b"SECRET_LOG_stderr\n")
        return frames[0], started, time.monotonic()
    original_class = service.CaptureService
    def harness_service(*a, **kw):
        kw.update(connection_factory=lambda _: HarnessConnection(owner), capture=fake_capture)
        return original_class(*a, **kw)
    service.CaptureService = harness_service
    service.prewarm_dependencies = lambda: None
    args = ["--state-dir", state, "--output-dir", output, "--idle-seconds", "600"]
    if mode == "preconnect":
        args.append("--preconnect")
    if mode == "timing-path":
        args += ["--timings-file", str(Path(output).parent / "private-app-support" / "screenshot-success-times.json")]
    return service.main(args)


class PipeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.state, self.output = private_fixture(self.base)
        self.processes = []

    def tearDown(self):
        for process in self.processes:
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=3)
        self.temp.cleanup()

    def start(self, mode="success", process_group=None):
        process = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "--service-harness",
            mode, str(self.state), str(self.output)], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, process_group=process_group)
        self.processes.append(process)
        return process

    def send(self, process):
        request = {"action": "capture", "request_id": str(uuid.uuid4()),
                   "output_file": str(self.output / "frame.png"), "timeout": 40}
        process.stdin.write(json.dumps(request).encode() + b"\n")
        process.stdin.flush()
        return request

    def wait_marker(self):
        marker = self.state / "harness-pids"
        deadline = time.monotonic() + 4
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(marker.exists(), "synthetic process did not start")
        return json.loads(marker.read_text())

    def assert_exited(self, pid):
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return
            time.sleep(0.02)
        # Failure cleanup is scoped to the pid created by this synthetic harness.
        with contextlib.suppress(ProcessLookupError):
            os.kill(pid, signal.SIGKILL)
        self.fail("synthetic descendant survived service shutdown")

    def test_cli_is_quiet_until_request_and_suppresses_upstream_logs(self):
        process = self.start()
        self.assertFalse(select.select([process.stdout], [], [], 0.2)[0])
        request = self.send(process)
        self.assertTrue(select.select([process.stdout], [], [], 4)[0])
        line = process.stdout.readline()
        result = json.loads(line)
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["request_id"], request["request_id"])
        self.assertNotIn(b"SECRET", line)
        self.assertFalse(select.select([process.stdout], [], [], 0.1)[0])
        process.stdin.close()
        process.stdin = None
        rest, errors = process.communicate(timeout=3)
        self.assertEqual((rest, errors), (b"", b""))

    def test_cli_forwards_explicit_timing_path(self):
        timing_dir = self.base / "private-app-support"
        timing_dir.mkdir(mode=0o700)
        process = self.start(mode="timing-path")
        self.send(process)
        self.assertTrue(select.select([process.stdout], [], [], 4)[0])
        result = json.loads(process.stdout.readline())
        self.assertTrue(result["ok"], result)
        timing_file = timing_dir / "screenshot-success-times.json"
        self.assertEqual(len(json.loads(timing_file.read_text())["wifi"]), 1)
        self.assertFalse((self.state.parent / "screenshot-success-times.json").exists())
        process.stdin.close()
        process.stdin = None
        rest, errors = process.communicate(timeout=3)
        self.assertEqual((rest, errors), (b"", b""))

    def test_existing_private_launcher_group_is_accepted(self):
        # Same POSIX topology as Foundation.Process: child is already a pgrp
        # leader, so setsid fails with EPERM; its parent belongs to another pgrp.
        process = self.start(process_group=0)
        self.assertEqual(os.getpgid(process.pid), process.pid)
        self.assertNotEqual(os.getpgrp(), process.pid)
        request = self.send(process)
        self.assertTrue(select.select([process.stdout], [], [], 4)[0])
        result = json.loads(process.stdout.readline())
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["request_id"], request["request_id"])
        process.stdin.close()
        process.stdin = None
        process.communicate(timeout=3)

    def test_preconnect_cli_emits_no_ready_or_image_before_request(self):
        process = self.start("preconnect")
        marker = self.state / "preconnected"
        deadline = time.monotonic() + 4
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertTrue(marker.exists())
        self.assertFalse(select.select([process.stdout], [], [], 0.05)[0])
        self.assertEqual(list(self.output.iterdir()), [])
        self.send(process)
        self.assertTrue(select.select([process.stdout], [], [], 4)[0])
        result = json.loads(process.stdout.readline())
        self.assertTrue(result["ok"], result)
        self.assertTrue(result["connection_reused"])
        process.stdin.close()
        process.stdin = None
        rest, errors = process.communicate(timeout=3)
        self.assertEqual((rest, errors), (b"", b""))

    def test_sigterm_cancels_worker_and_its_descendant(self):
        process = self.start("hang")
        self.send(process)
        worker_pid, child_pid = self.wait_marker()
        self.assertEqual(worker_pid, process.pid)
        process.terminate()
        stdout, stderr = process.communicate(timeout=3)
        self.assert_exited(child_pid)
        self.assertNotIn(b"SECRET", stdout + stderr)
        self.assertFalse((self.output / "frame.png").exists())

    def test_eof_cancels_inflight_and_its_descendant(self):
        process = self.start("hang")
        self.send(process)
        _, child_pid = self.wait_marker()
        process.stdin.close()
        process.stdin = None
        process.communicate(timeout=3)
        self.assert_exited(child_pid)
        self.assertFalse((self.output / "frame.png").exists())

    def test_parent_death_watchdog_kills_worker_and_descendant(self):
        parent = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "--parent-harness",
            str(self.state), str(self.output)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.processes.append(parent)
        worker_pid, child_pid = self.wait_marker()
        parent.kill()
        parent.communicate(timeout=3)
        self.assert_exited(worker_pid)
        self.assert_exited(child_pid)
        self.assertFalse((self.output / "frame.png").exists())


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--service-harness":
        sys.exit(harness())
    if len(sys.argv) > 1 and sys.argv[1] == "--parent-harness":
        state, output = sys.argv[2:4]
        child = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "--service-harness",
            "hang", state, output], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        child.stdin.write(json.dumps({"action": "capture", "request_id": str(uuid.uuid4()),
            "output_file": str(Path(output) / "frame.png"), "timeout": 40}).encode() + b"\n")
        child.stdin.flush()
        time.sleep(60)
        sys.exit(0)
    unittest.main()
