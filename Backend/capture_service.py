#!/usr/bin/env python3
"""Private JSONL screenshot worker. Imports may be warm; screenshots never are.

stdin: {action:"capture", request_id:UUID, output_file:ABS, timeout:4..45}
stdout: one sanitized schema_version=1 receipt per complete request line.
With --connection-events, separate connection metadata events are also emitted.
No pairing, UI, clipboard, USB fallback, or screenshot retry.
"""
from __future__ import annotations

import argparse
import asyncio
import contextlib
import importlib
import json
import math
import os
from pathlib import Path
import signal
import stat
import sys
import threading
import time
import uuid

import capture_once as once
import link_timeline
from capture_timing import MAX_TRANSFER_BUDGET, SuccessTimingStore, TransferBudget

MAX_LINE_BYTES = 64 * 1024
MAX_REQUEST_IDS = 4096
DEFAULT_IDLE_SECONDS = 1800.0
MAX_IDLE_SECONDS = 3600.0
PRECONNECT_TIMEOUT = 20.0
# A keep-warm attempt may also mount the developer image after an iPad restart
# (upload plus Apple's per-boot personalization), which takes longer.
WARM_PRECONNECT_TIMEOUT = 150.0
WARM_CHECK_SECONDS = 1.0   # was 3.0: reconnect sooner after a drop (2026-10-24)
WARM_BACKOFF_SECONDS = (2.0, 5.0, 10.0, 20.0, 30.0, 60.0)
MOUNT_TIMEOUT = 120.0
DEVELOPER_SERVICE = "com.apple.instruments.dtservicehub"
SCREENSHOT_TIMEOUT = MAX_TRANSFER_BUDGET
# A large Wi-Fi frame can still be arriving at 8 s. The shared cap is 30 s;
# no-byte and stalled transfers retain their shorter, progress-based deadlines.
USB_FIRST_BYTE_LIMIT = 2.5
# Fail fast on a flaky Wi-Fi link (2026-10-24: 3 keypresses waited 5.5 s each during a link
# drop). The first screenshot attempt gets FIRST_ATTEMPT_TIMEOUT (the slowest successful one
# that day took 1.87 s); if it times out, its channel is discarded (a late reply can never be
# published or reused), the session reconnects, and one retry runs. The request gives up
# CAPTURE_BUDGET seconds after it started; a retry needs at least MIN_RETRY_SECONDS left.
# Any other error still stops at once, without a retry.
FIRST_ATTEMPT_TIMEOUT = 4.5
CAPTURE_BUDGET = 4.5       # screenshot phase, counted from the moment the connection is ready
MIN_RETRY_SECONDS = 1.5
# The whole request (waiting for a reconnect already in flight, connecting, screenshots) gives
# up REQUEST_BUDGET seconds after the keypress. Before 2026-10-24 16:25 a keypress during a
# failing reconnect waited up to its full 40 s timeout, silently, and swallowed later presses.
# Owner report (16:33): past 5 s it has failed. A cold reconnect after the iPad dozed (about 7 s)
# then fails that one keypress fast; the background reconnect keeps going for the next one.
# Owner report (2026-10-25 17:21): 5 s is far too long, as short as possible. Of 151 successful
# keypresses, p50 0.48 s, p95 1.52 s, slowest 3.58 s; at 2.5 s about 2.6 % of eventual successes
# fail fast instead (they waited 2.5-3.6 s), and there is no time left for a retry.
# 17:23 (agreed with the owner): fail on evidence, not by waiting. Measured since v17: successful
# transfers had their first byte by 239 ms and stalled at most 1128 ms (one 1.5 s success);
# failed ones waited 161-1733 ms for a first byte. Defaults below; the app may pass its own
# (defaults firstByteLimitMs / stallLimitMs / pressCapMs) in the request's "limits_ms".
# 17:47: a fixed 2 s cap cut 10 slow-but-moving transfers (400+ KB at 47-399 KB per 2 s). Dead
# links still used to fail on first byte/stall/rate heuristics. Wi-Fi now reports those
# as advisory progress only: a one-second radio outage can recover before the cap.
REQUEST_BUDGET = 4.5           # press cap ("timeout")
FIRST_BYTE_LIMIT = 0.8         # Wi-Fi advisory; USB uses USB_FIRST_BYTE_LIMIT
# Wi-Fi retransmits were seen taking up to 2.1 s to recover (2026-11-05), so 1.2 s gave up too early.
STALL_LIMIT = 2.5              # Wi-Fi hedge hint; neither is proof of disconnection
USB_STALL_LIMIT = 1.2          # A cable has no retransmit wait: after this, fall back to Wi-Fi
WATCH_INTERVAL = 0.025
PROGRESS_INTERVAL = 0.25
RPC_CANCEL_SECONDS = 0.05  # Never let a cancellation-resistant RPC block session teardown.
# Content rejections after a complete screenshot reply; must match CaptureWorker.linkSafeFailures.
LINK_SAFE_FAILURES = frozenset({"black_frame_rejected", "invalid_png", "empty_frame",
                                "frame_too_large", "unexpected_dimensions"})
SERVICE_REASONS = once.SAFE_REASONS | { "first_byte_timeout", "stall_timeout", "too_slow",
    "busy", "duplicate_request_id", "output_outside_private_cache", "request_limit_reached",
    "developer_image_unavailable", "disconnected", "slow_threshold",
}


def reason(error):
    if isinstance(error, once.CaptureFailure) and str(error) in SERVICE_REASONS:
        return str(error)
    return once.safe_reason(error)


def failure(request_id, started, code, attempts=None, link=None):
    value = {"schema_version": 1, "request_id": request_id, "ok": False,
             "reason": code if code in SERVICE_REASONS else "capture_failed",
             "request_started_monotonic": started,
             "request_completed_monotonic": time.monotonic()}
    if attempts:
        value["timings_ms"] = {"attempts": attempts, **(link or {})}
    return value


def prewarm_dependencies():
    """Imports only. Never creates a provider, browses a network, or captures."""
    for name in ("PIL.Image", "PIL.ImageStat", "remote_pairing_transport",
                 "pymobiledevice3.remote.userspace_tunnel",
                 "pymobiledevice3.services.dvt.instruments.dvt_provider",
                 "pymobiledevice3.services.dvt.instruments.screenshot"):
        importlib.import_module(name)


def wifi_context(state):
    from remote_pairing_transport import open_remote_wifi_rsd
    return open_remote_wifi_rsd(state, browse_seconds=12.0)


def worker_session(state, transport, worker_role=None):
    from usb_transport import developer_image_lock, open_usb_rsd

    async def mount_locked(provider):
        async with developer_image_lock(state):
            return await mount_developer_image(provider)

    session = CaptureSession(state, connection_factory=open_usb_rsd if transport == "usb" else wifi_context,
                             mount=mount_locked)
    # Each process has its own timeline; the recorder uses a fixed temporary
    # filename, so USB must not race Wi-Fi's log publication.
    if transport == "usb":
        session.timeline_path = Path(state).parent / "link-timeline-usb.jsonl"
    elif worker_role == "wifi_standby":
        session.timeline_path = Path(state).parent / "link-timeline-wifi-standby.jsonl"
    session.progress_fail_fast = transport == "usb"
    return session


def developer_image_missing(provider) -> bool:
    """The RSD handshake lists developer services only while the image is mounted.

    A restarted iPad unmounts it. Providers without a handshake (tests, older
    transports) are treated as ready; the channel open is still the real test.
    """
    info = getattr(provider, "peer_info", None)
    services = info.get("Services") if isinstance(info, dict) else None
    return isinstance(services, dict) and DEVELOPER_SERVICE not in services


async def mount_developer_image(provider):
    """Mount the cached personalized image; only Apple's per-boot ticket is fetched."""
    from pymobiledevice3.exceptions import AlreadyMountedError
    from pymobiledevice3.services.mobile_image_mounter import auto_mount
    try:
        async with asyncio.timeout(MOUNT_TIMEOUT):
            await auto_mount(provider)
        return True
    except AlreadyMountedError:
        return False


class CaptureSession:
    """One authenticated transport, DVT provider, and screenshot channel.

    pymobiledevice3 11.31.0 source contracts:
    * dtx_service.py: connect() acquires a channel; close() does not capture.
    * screenshot.py: get_screenshot() invokes takeScreenshot each time.
    * dtx/_sender.py: every dispatch gets a fresh message ID. Cancellation can
      leave a pending reply, so an uncertain session is always closed in full.
    No screenshot bytes are retained on this object or obtained during entry.
    """
    def __init__(self, state, *, connection_factory=wifi_context,
                 dvt_factory=None, screenshot_factory=None, mount=mount_developer_image):
        self.state = state
        self.connection_factory = connection_factory
        self.mount = mount
        self.dvt_factory = dvt_factory
        self.screenshot_factory = screenshot_factory
        self.stack = contextlib.AsyncExitStack()
        self.screenshot = None
        self.ready = False
        self.closing = False
        self.inflight = False
        self.watcher = None
        self.close_task = None
        self.last_link = None
        self.disconnected = asyncio.Event()
        self.progress_fail_fast = False
        self.pending_rpc = None
        self.developer_image_mounted = False

    def _check_live(self):
        if self.closing:
            raise once.CaptureFailure("worker_failed")
        task = asyncio.current_task()
        if task is not None and task.cancelling():
            # A third-party handshake must not turn a swallowed cancellation
            # into permission to open the next channel or accept a late frame.
            raise asyncio.CancelledError()

    async def __aenter__(self):
        self._check_live()
        if self.ready:
            raise once.CaptureFailure("worker_failed")
        if self.dvt_factory is None:
            from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
            self.dvt_factory = DvtProvider
        if self.screenshot_factory is None:
            from pymobiledevice3.services.dvt.instruments.screenshot import Screenshot
            self.screenshot_factory = Screenshot
        try:
            connection = self.connection_factory(self.state)
            # Register before entering, including partial/cancelled entry. The
            # outer service owns a bounded cleanup deadline and process watchdog.
            self.stack.push_async_exit(connection)
            provider, evidence = await connection.__aenter__()
            self._check_live()
            if self.mount is not None and developer_image_missing(provider):
                # The iPad restarted: mount the developer image automatically
                # (no user step), then reconnect once so the new RSD handshake
                # lists the developer services. No frame is requested here.
                mounted = await self.mount(provider)
                # Another worker may have mounted while this one waited for the
                # lock. Only the session that performed the mount gets exemption.
                self.developer_image_mounted = mounted is not False
                self._check_live()
                previous, self.stack = self.stack, contextlib.AsyncExitStack()
                # Registered first: a cancelled close still finishes in close().
                self.stack.push_async_callback(previous.aclose)
                await previous.aclose()
                connection = self.connection_factory(self.state)
                self.stack.push_async_exit(connection)
                provider, evidence = await connection.__aenter__()
                self._check_live()
                if developer_image_missing(provider):
                    raise once.CaptureFailure("developer_image_unavailable")
            link_timeline.install_rpc_hook()
            dvt = self.dvt_factory(provider)
            self.stack.push_async_exit(dvt)
            await dvt.__aenter__()
            self._check_live()
            screenshot = self.screenshot_factory(dvt)
            self.stack.push_async_exit(screenshot)
            await screenshot.__aenter__()
            self._check_live()
            self.screenshot = screenshot
            self.ready = True
            # Public DTX lifecycle signal; this wait sends no request. The
            # existing relay watcher turns outer tunnel loss into DTX EOF.
            self.watcher = asyncio.create_task(self._watch_disconnected(dvt.dtx))
            return self, evidence
        except BaseException:
            # CaptureService stores this context before entry and closes it even
            # after failed entry. Do not hide its bounded cleanup behind a second
            # unbounded __aenter__ cleanup await.
            self.ready = False
            raise

    async def _watch_disconnected(self, dtx):
        try:
            await dtx.wait_disconnected()
        except asyncio.CancelledError:
            return
        except Exception:
            pass
        if not self.closing:
            self.disconnected.set()
            with contextlib.suppress(Exception):
                await self.close()

    @staticmethod
    def _consume_rpc(task):
        # A discarded reply is never published. Retrieve failures even if the
        # RPC outlives its caller, so the event loop does not retain a warning.
        if not task.cancelled():
            with contextlib.suppress(Exception):
                task.exception()

    async def _cancel_rpc(self, rpc):
        if not rpc.done():
            rpc.cancel()
            # wait_for() and directly awaiting the cancelled task can both wait
            # forever if the dependency suppresses CancelledError. Keep ownership
            # in pending_rpc; close() must finish it or retire this worker.
            await asyncio.wait({rpc}, timeout=RPC_CANCEL_SECONDS)
        if rpc.done() and self.pending_rpc is rpc:
            self.pending_rpc = None

    async def capture(self):
        self._check_live()
        if not self.ready or self.screenshot is None:
            raise once.CaptureFailure("worker_failed")
        if self.inflight:
            raise once.CaptureFailure("busy")
        self.inflight = True
        recording = link_timeline.Recording()
        rpc_recording = link_timeline.RPCRecording(self.screenshot, recording.started)
        outcome = "error"
        try:
            started = time.monotonic()
            on_started = getattr(self, "on_capture_started", None)
            if on_started is not None:
                await on_started(started)
            first_byte, stall, *rest = getattr(self, "limits", (FIRST_BYTE_LIMIT, STALL_LIMIT))
            deadline = rest[0] if rest else None
            rpc = asyncio.ensure_future(self.screenshot.get_screenshot())
            self.pending_rpc = rpc
            rpc.add_done_callback(self._consume_rpc)
            lost = asyncio.create_task(self.disconnected.wait())
            next_progress = 0.0
            try:
                while True:
                    done, _ = await asyncio.wait({rpc, lost}, timeout=WATCH_INTERVAL,
                                                 return_when=asyncio.FIRST_COMPLETED)
                    if lost in done:
                        raise once.CaptureFailure("disconnected")
                    if rpc in done:
                        data = rpc.result()
                        break
                    now = time.monotonic()
                    progress = recording.progress(now, first_byte, stall, deadline)
                    progress.update(rpc_recording.progress(now) or {"rpc_received_bytes": 0, "expected_bytes": 0})
                    notify_progress = getattr(self, "on_progress", None)
                    if notify_progress is not None and now >= next_progress:
                        await notify_progress(progress)
                        next_progress = now + PROGRESS_INTERVAL
                    verdict = progress["reason"]
                    # Wi-Fi may take longer to produce its first byte. After data
                    # starts, both links must fail a real 1.2 s receive stall; the
                    # normal 4.5 s budget must not mask that shorter watchdog.
                    if verdict == "stall_timeout" or (self.progress_fail_fast and verdict != "progress"):
                        notify = getattr(self, "on_progress_failure", None)
                        if notify is not None:
                            await notify(verdict)
                        raise once.CaptureFailure(verdict)
                    if now - started > SCREENSHOT_TIMEOUT:
                        # Same as the old wait_for: cancel; a reply that still comes back is
                        # judged too old below, otherwise it is a timeout (retried once).
                        await self._cancel_rpc(rpc)
                        if not rpc.done():
                            raise TimeoutError()
                        try:
                            data = rpc.result()
                        except asyncio.CancelledError:
                            task = asyncio.current_task()
                            if task is not None and task.cancelling():
                                raise
                            raise TimeoutError() from None
                        except Exception:
                            raise TimeoutError() from None
                        break
            finally:
                lost.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await lost
                await self._cancel_rpc(rpc)
            completed = time.monotonic()
            self._check_live()
            if completed - started > SCREENSHOT_TIMEOUT:
                raise once.CaptureFailure("capture_response_too_old")
            outcome = "ok"
            return data, started, completed
        except BaseException:
            # Do not reuse a channel with an uncertain/late reply. Closing the
            # outer CaptureService context also closes DVT, RSD, and the tunnel.
            self.ready = False
            self.closing = True
            raise
        finally:
            self.inflight = False
            # Measurement only (2026-10-25): first byte, stalls, outer socket state.
            summary, detail = recording.finish(outcome)
            fragments = rpc_recording.finish()
            if fragments["rpc_fragments_available"]:
                rows = fragments["rpc_fragments"]
                summary = {**(summary or {}), "rpc_fragment_count": len(rows)}
                if rows:
                    summary.update(rpc_first_fragment=rows[0]["at_ms"], rpc_last_fragment=rows[-1]["at_ms"])
                link_timeline.last_summary = summary
            self.last_link = summary
            if detail is None and fragments["rpc_fragments_available"]:
                detail = {"outcome": outcome, "duration_ms": (time.monotonic() - recording.started) * 1000}
            if detail is not None:
                detail.update(fragments)
                link_timeline.append_log(getattr(self, "timeline_path",
                    self.state.parent / "link-timeline.jsonl"), detail)

    async def close(self):
        self.ready = False
        self.closing = True
        self.screenshot = None
        if self.watcher is not None and self.watcher is not asyncio.current_task():
            self.watcher.cancel()
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await self.watcher
        if self.close_task is None:
            self.close_task = asyncio.create_task(self.stack.aclose())
        # If a bounded caller gives up, teardown continues until the supervisor
        # retires the process. Cancelling its waiter cannot orphan half a stack.
        await asyncio.shield(self.close_task)
        if self.pending_rpc is not None:
            # Resource closure usually releases the RPC. If it does not, the
            # service's bounded _close_session() retires the process instead of
            # reusing a session while a discarded request is still running.
            await asyncio.wait({self.pending_rpc})
            self.pending_rpc = None

    async def __aexit__(self, *_args):
        await self.close()


async def fresh_screenshot(session):
    """Reuse only the channel; each accepted request still invokes one new RPC."""
    return await session.capture()


class CaptureService:
    def __init__(self, state_dir, output_dir, idle_seconds=DEFAULT_IDLE_SECONDS, *,
                 connection_factory=CaptureSession, capture=fresh_screenshot,
                 cleanup_seconds=0.75, keep_warm=False, connection_events=None, transport="wifi",
                 attempt_events=None, progress_events=None, timing_path=None):
        self.state_dir = Path(os.path.abspath(state_dir))
        self.output_dir = Path(os.path.abspath(output_dir))
        self.idle_seconds = idle_seconds
        self.connection_factory, self.capture = connection_factory, capture
        self.cleanup_seconds = cleanup_seconds
        self.context = None
        self.provider = None
        self.idle_task = None
        self.idle_generation = 0
        self.preconnect_task = None
        self.preconnect_cancelled = False
        self.keep_warm = keep_warm
        self.warm_task = None
        self.active = None
        self.seen = set()
        self.lock = asyncio.Lock()
        self.terminal = False
        self.stop_event = asyncio.Event()
        self.staging_names = set()
        self.connection_events = connection_events
        if transport not in {"wifi", "usb"}:
            raise once.CaptureFailure("invalid_arguments")
        self.transport = transport
        self.attempt_events = attempt_events
        self.progress_events = progress_events
        # The native app pins this to Application Support even when legacy
        # config points pairing state elsewhere. Standalone/injected services
        # remain isolated beside their state directory unless explicitly set.
        timing_path = Path(timing_path) if timing_path is not None else self.state_dir.parent / "screenshot-success-times.json"
        if not timing_path.is_absolute():
            raise once.CaptureFailure("invalid_arguments")
        self.success_timings = SuccessTimingStore(timing_path)
        self.last_connection_event = None
        if os.geteuid() == 0:
            raise once.CaptureFailure("root_execution_not_allowed")
        if not math.isfinite(idle_seconds) or not 0 < idle_seconds <= MAX_IDLE_SECONDS:
            raise once.CaptureFailure("invalid_arguments")
        once.check_state(self.state_dir)
        once.check_private_directory(self.output_dir, "output_parent_not_private")
        self.directory_fd = os.open(self.output_dir, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        self.directory_identity = self._directory_identity(os.fstat(self.directory_fd))

    @staticmethod
    def _directory_identity(info):
        return info.st_dev, info.st_ino

    async def _notify_connection(self, state, code):
        """Metadata only, over the existing pipe. Never probes or takes a frame."""
        if self.connection_events is None:
            return
        if self.terminal and state in {"connecting", "ready"}:
            return
        safe = code if code in SERVICE_REASONS | {"ready", "connecting", "disconnected"} else "capture_failed"
        event = (state, safe)
        if event == self.last_connection_event:
            return
        await self.connection_events({"schema_version": 1, "event": "connection",
                                      "state": state, "reason": safe})
        self.last_connection_event = event

    def _default_stall(self):
        return USB_STALL_LIMIT if self.transport == "usb" else STALL_LIMIT

    def _check_output_directory(self):
        once.check_private_directory(self.output_dir, "output_parent_not_private")
        if self._directory_identity(self.output_dir.lstat()) != self.directory_identity:
            raise once.CaptureFailure("output_parent_not_private")

    def _exists(self, name):
        try:
            os.stat(name, dir_fd=self.directory_fd, follow_symlinks=False)
            return True
        except FileNotFoundError:
            return False

    def _parse(self, raw, started):
        request_id = None
        attempt_id = None
        try:
            if not isinstance(raw, bytes) or len(raw) > MAX_LINE_BYTES:
                raise once.CaptureFailure("invalid_arguments")
            value = json.loads(raw)
            if not isinstance(value, dict):
                raise once.CaptureFailure("invalid_arguments")
            supplied_id = value.get("request_id")
            try:
                parsed = uuid.UUID(supplied_id)
                if str(parsed) != supplied_id:
                    raise ValueError()
            except (ValueError, TypeError, AttributeError):
                raise once.CaptureFailure("invalid_request_id") from None
            request_id = supplied_id
            # Rejections must retain a well-formed attempt identity as well as
            # the logical request identity, including duplicate/busy responses.
            supplied_attempt = value.get("attempt_id")
            if isinstance(supplied_attempt, str):
                with contextlib.suppress(ValueError, TypeError, AttributeError):
                    if str(uuid.UUID(supplied_attempt)) == supplied_attempt:
                        attempt_id = supplied_attempt
            if request_id in self.seen:
                raise once.CaptureFailure("duplicate_request_id")
            if len(self.seen) >= MAX_REQUEST_IDS:
                self.terminal = True
                raise once.CaptureFailure("request_limit_reached")
            # Never evict UUIDs and accidentally allow an old request again.
            self.seen.add(request_id)
            base_keys = {"action", "request_id", "output_file", "timeout"}
            attempt_keys = {"attempt_id", "deadline_monotonic"}
            limit_keys = {"limits_ms", "screenshot_deadline_monotonic", "press_started_monotonic"}
            if (set(value) - limit_keys) not in (base_keys, base_keys | attempt_keys) or value["action"] != "capture":
                raise once.CaptureFailure("invalid_arguments")
            limits = {}
            if "limits_ms" in value:
                given = value["limits_ms"]
                if not isinstance(given, dict) or set(given) != {"first_byte", "stall", "press_cap"}:
                    raise once.CaptureFailure("invalid_arguments")
                for key, (low, high) in {"first_byte": (200, 5000), "stall": (200, 5000), "press_cap": (800, MAX_TRANSFER_BUDGET * 1000)}.items():
                    ms = given[key]
                    if type(ms) not in (float, int) or not math.isfinite(ms) or not low <= ms <= high:
                        raise once.CaptureFailure("invalid_timeout")
                    limits[key] = float(ms) / 1000
            attempt = {}
            if "attempt_id" in value:
                identity = value["attempt_id"]
                if not isinstance(identity, str) or str(uuid.UUID(identity)) != identity:
                    raise once.CaptureFailure("invalid_arguments")
                end = value["deadline_monotonic"]
                if type(end) not in (float, int) or not math.isfinite(end) or end > started + MAX_TRANSFER_BUDGET:
                    raise once.CaptureFailure("invalid_timeout")
                attempt = {"attempt_id": identity, "deadline_monotonic": float(end)}
            if "screenshot_deadline_monotonic" in value:
                end = value["screenshot_deadline_monotonic"]
                if ("attempt_id" not in value or type(end) not in (float, int)
                        or not math.isfinite(end) or end <= 0 or end > started + MAX_TRANSFER_BUDGET):
                    raise once.CaptureFailure("invalid_timeout")
                attempt["screenshot_deadline_monotonic"] = float(end)
            if "press_started_monotonic" in value:
                origin = value["press_started_monotonic"]
                if (type(origin) not in (float, int) or not math.isfinite(origin)
                        or not started - MAX_TRANSFER_BUDGET <= origin <= started + 0.05):
                    raise once.CaptureFailure("invalid_timeout")
                attempt["press_started_monotonic"] = float(origin)
            timeout = value["timeout"]
            if type(timeout) not in (float, int) or not math.isfinite(timeout) or not 4 <= timeout <= 45:
                raise once.CaptureFailure("invalid_timeout")
            output = value["output_file"]
            if not isinstance(output, str) or not Path(output).is_absolute():
                raise once.CaptureFailure("output_outside_private_cache")
            output = Path(os.path.abspath(output))
            if output.parent != self.output_dir or output.name in {"", ".", ".."}:
                raise once.CaptureFailure("output_outside_private_cache")
            return {"request_id": request_id, "output_file": output, "timeout": float(timeout), **attempt,
                    **({"limits": limits} if limits else {})}, None
        except BaseException as error:
            receipt = failure(request_id, started, reason(error))
            if attempt_id is not None:
                receipt["attempt_id"] = attempt_id
            return None, receipt

    async def _close_session(self):
        context, self.context, self.provider = self.context, None, None
        if context is None:
            return
        # asyncio.wait_for waits indefinitely if a dependency ignores cancellation.
        # Bound the cleanup wait instead; an uncertain teardown retires this process.
        task = asyncio.create_task(context.__aexit__(None, None, None))
        try:
            done, _ = await asyncio.wait({task}, timeout=self.cleanup_seconds)
            if not done:
                self._retire()
                task.cancel()
                return
            try:
                task.result()
            except BaseException:
                self._retire()
        except BaseException:
            self._retire()
            task.cancel()
            raise
        finally:
            await self._notify_connection("disconnected", "disconnected")

    def _retire(self):
        self.terminal = True
        if self.active is None or self.active.done():
            self.stop_event.set()

    def _cancel_idle(self):
        self.idle_generation += 1
        if self.idle_task is not None:
            self.idle_task.cancel()
            self.idle_task = None

    def _restart_idle(self):
        self._cancel_idle()
        if self.keep_warm:
            return  # The connection stays ready; the device may still end it.
        self.idle_task = asyncio.create_task(self._expire_idle(self.idle_generation))

    async def _expire_idle(self, generation):
        try:
            await asyncio.sleep(self.idle_seconds)
            # Once cleanup starts, a new request waits for its lock rather than
            # cancelling teardown halfway through and reopening a second tunnel.
            if self.idle_task is asyncio.current_task():
                self.idle_task = None
            async with self.lock:
                if generation == self.idle_generation:
                    await self._close_session()
        except asyncio.CancelledError:
            pass

    async def _connect(self):
        if self.provider is not None:
            if not getattr(self.provider, "closing", False):
                return True
            # The device ended an idle session (passive DTX EOF). That is not a
            # failed capture: tear the dead stack down and authenticate afresh for
            # this same keypress instead of failing it. The RPC is still sent once.
            await self._close_session()
            if self.terminal:
                raise once.CaptureFailure("worker_failed")
        await self._notify_connection("connecting", "connecting")
        context = self.connection_factory(self.state_dir)
        # Store before entry so even a partial failed connection gets teardown.
        self.context = context
        self.provider, _ = await context.__aenter__()
        if self.provider is None:
            raise once.CaptureFailure("capture_failed")
        return False

    def start_preconnect(self):
        """An explicit enable-time attempt only; never a reconnect loop or capture."""
        if self.preconnect_task is not None or self.terminal:
            return
        self.preconnect_task = asyncio.create_task(self._preconnect())

    def start_keep_warm(self):
        """Keep an authenticated connection ready between keypresses.

        Whenever no request is running and the connection is missing or was
        closed by the device (iPad slept, restarted, network change), connect
        again in the background with backoff. Connection only: this never
        requests a frame, so the one-RPC-per-keypress rule is unchanged.
        """
        if self.warm_task is not None or self.terminal:
            return
        self.keep_warm = True
        self._cancel_idle()
        self.warm_task = asyncio.create_task(self._keep_warm())

    @property
    def preconnect_timeout(self):
        return WARM_PRECONNECT_TIMEOUT if self.keep_warm else PRECONNECT_TIMEOUT

    def _connection_healthy(self):
        return self.provider is not None and not getattr(self.provider, "closing", False)

    def _request_running(self):
        return self.active is not None and not self.active.done()

    async def _keep_warm(self):
        failures = 0
        try:
            while not self.terminal:
                pending = self.preconnect_task
                if pending is not None and not pending.done():
                    # wait() neither cancels the attempt nor raises if a capture
                    # request cancelled it; this loop then simply looks again.
                    await asyncio.wait({pending})
                    continue
                if self._request_running() or self.lock.locked() or self._connection_healthy():
                    failures = 0 if self._connection_healthy() else failures
                    await asyncio.sleep(WARM_CHECK_SECONDS)
                    continue
                self.preconnect_task = None
                self.preconnect_cancelled = False
                self.start_preconnect()
                attempt = self.preconnect_task
                if attempt is None:
                    break
                await asyncio.wait({attempt})
                outcome = "cancelled" if attempt.cancelled() else attempt.result()
                if outcome is None:
                    failures = 0
                    continue
                failures += 1
                await asyncio.sleep(WARM_BACKOFF_SECONDS[min(failures, len(WARM_BACKOFF_SECONDS)) - 1])
        except asyncio.CancelledError:
            pass

    async def _cancel_keep_warm(self):
        task, self.warm_task = self.warm_task, None
        if task is not None and not task.done():
            task.cancel()
            await asyncio.wait({task}, timeout=self.cleanup_seconds)

    async def _preconnect(self):
        # Keep failures as sanitized results: a capture accepted while this task
        # runs must observe the same outcome, never silently try a second tunnel.
        async with self.lock:
            try:
                deadline = time.monotonic() + self.preconnect_timeout
                async with asyncio.timeout(self.preconnect_timeout):
                    if self.terminal or self.preconnect_cancelled:
                        raise once.CaptureFailure("cancelled")
                    once.check_state(self.state_dir)
                    await self._connect()
                    # A dependency may swallow cancellation and still return a
                    # connection. Shutdown must never commit that late success.
                    if self.terminal or self.preconnect_cancelled:
                        raise once.CaptureFailure("cancelled")
                    if time.monotonic() >= deadline:
                        raise once.CaptureFailure("timeout")
                    await self._notify_connection("ready", "ready")
                    self._restart_idle()
                    return None
            except BaseException as error:
                await self._close_session()
                await self._notify_connection("failed", reason(error))
                return reason(error)

    async def _cancel_preconnect(self):
        task = self.preconnect_task
        if task is not None and not task.done():
            self.preconnect_cancelled = True
            task.cancel()
            done, _ = await asyncio.wait({task}, timeout=self.cleanup_seconds)
            if not done:
                self._retire()

    def _publish(self, data, request, started, completed):
        self._check_output_directory()
        output_name = request["output_file"].name
        if self._exists(output_name):
            raise once.CaptureFailure("output_already_exists")
        if time.monotonic() - completed > 5:
            raise once.CaptureFailure("capture_result_too_old")
        if time.monotonic() - started >= request["timeout"]:
            raise once.CaptureFailure("timeout")
        staging = f".capture-service-{uuid.uuid4()}.png"
        self.staging_names.add(staging)
        try:
            fd = os.open(staging, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                         0o600, dir_fd=self.directory_fd)
            with os.fdopen(fd, "wb") as handle:
                handle.write(data)
                handle.flush()
                # Speed (提速副本): no fsync. This is a private cache file the
                # native app reads back from the page cache within milliseconds,
                # and it re-checks size and SHA-256 before use; forcing it to
                # disk only added latency (most for 8-11 MiB wide-colour frames).
                info = os.fstat(handle.fileno())
                if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                        or stat.S_IMODE(info.st_mode) != 0o600 or info.st_size != len(data)):
                    raise once.CaptureFailure("capture_integrity_failed")
            self._check_output_directory()
            if time.monotonic() - completed > 5:
                raise once.CaptureFailure("capture_result_too_old")
            if time.monotonic() - started >= request["timeout"]:
                raise once.CaptureFailure("timeout")
            try:
                os.link(staging, output_name, src_dir_fd=self.directory_fd,
                        dst_dir_fd=self.directory_fd, follow_symlinks=False)
            except FileExistsError:
                raise once.CaptureFailure("output_already_exists") from None
            except OSError:
                raise once.CaptureFailure("output_publish_failed") from None
        finally:
            with contextlib.suppress(OSError):
                os.unlink(staging, dir_fd=self.directory_fd)
            self.staging_names.discard(staging)

    async def _capture_phase(self, request, limit, flags, budget=None):
        """Track RPC lifecycle within the byte-driven, shared press budget.

        Success-history thresholds remain diagnostic metadata. Both processes
        enforce the absolute deadline even when a dependency ignores cancellation.
        """
        threshold = self.success_timings.threshold(self.transport)
        exempt = bool(getattr(self.provider, "developer_image_mounted", False))
        with contextlib.suppress(AttributeError, TypeError):
            self.provider.developer_image_mounted = False
        phase = asyncio.get_running_loop().create_future()
        identity = {"schema_version": 1, "request_id": request["request_id"],
                    **({"attempt_id": request["attempt_id"]} if "attempt_id" in request else {})}

        async def started(at):
            # Historical small-frame durations remain diagnostics, never a cutoff.
            hard_end = budget.hard_end if budget else at + limit
            end = min(hard_end, request.get("deadline_monotonic", hard_end))
            flags.update(slow_threshold=threshold.seconds * 1000,
                         slow_sample_count=threshold.count, slow_threshold_exempt=float(exempt))
            if not phase.done():
                phase.set_result((at, end))
            if self.progress_events is not None:
                await self.progress_events({**identity, "event": "capture_started",
                    "capture_started_monotonic": at, "screenshot_deadline_monotonic": end,
                    "slow_threshold_ms": threshold.seconds * 1000,
                    "slow_sample_count": threshold.count, "slow_threshold_exempt": exempt})

        native_session = isinstance(self.provider, CaptureSession) and self.capture is fresh_screenshot
        if native_session:
            self.provider.on_capture_started = started

        async def capture():
            if not native_session:
                await started(time.monotonic())
            return await self.capture(self.provider)

        task = asyncio.create_task(capture())
        task.add_done_callback(CaptureSession._consume_rpc)
        legacy_end = time.monotonic() + limit
        try:
            # CaptureSession calls started just before scheduling get_screenshot.
            done, _ = await asyncio.wait({task, phase}, timeout=max(0, legacy_end - time.monotonic()),
                                         return_when=asyncio.FIRST_COMPLETED)
            if not phase.done():
                if task in done:
                    return task.result()
                raise TimeoutError()
            at, end = phase.result()
            while True:
                expires = min(end, max(legacy_end, budget.deadline if budget and budget.received else legacy_end))
                done, _ = await asyncio.wait({task}, timeout=max(0, min(WATCH_INTERVAL, expires - time.monotonic())))
                if done or time.monotonic() >= expires:
                    break
            result = task.result() if task in done else None
            if not done:
                raise TimeoutError()
            if (isinstance(result, tuple) and len(result) == 3
                    and all(type(x) in (int, float) and math.isfinite(x) for x in result[1:])
                    and at <= result[1] <= result[2] <= time.monotonic()
                    and self.progress_events is not None):
                await self.progress_events({**identity, "event": "capture_completed",
                                           "capture_completed_monotonic": result[2]})
            return result
        finally:
            if not phase.done():
                phase.cancel()
            if not task.done():
                task.cancel()
                # Never await a cancellation-resistant dependency without a bound.
                await asyncio.wait({task}, timeout=RPC_CANCEL_SECONDS)

    async def _capture_request(self, request, started, preconnect=None):
        request_id = request["request_id"]
        published = False
        attempts = 0
        link_timeline.last_summary = None
        connect_started = time.monotonic()
        # Diagnostics (17:47): was a reconnect still running at the press, and was the session reused.
        flags = {"reconnect_in_progress": float(preconnect is not None and not preconnect.done()),
                 "session_reused": 0.0}
        try:
            limits = request.get("limits", {})
            cap = limits.get("press_cap", MAX_TRANSFER_BUDGET)
            origin = request.get("press_started_monotonic", started)
            hard = min(MAX_TRANSFER_BUDGET, cap, request["timeout"] - 1,
                       request.get("deadline_monotonic", origin + MAX_TRANSFER_BUDGET) - origin)
            budget = TransferBudget(origin, normal=min(REQUEST_BUDGET, hard), hard=hard,
                                    stall=limits.get("stall", self._default_stall()))
            request_end = budget.deadline
            if preconnect is not None:
                async with asyncio.timeout(max(0.0, request_end - time.monotonic())):
                    outcome = await asyncio.shield(preconnect)
                # A failed enable/wake warm-up is not this keypress's result: the
                # preconnect already closed its session, so _connect() below makes
                # one fresh attempt within the remaining deadline. Shutdown or a
                # cancelled warm-up still stops the request.
                if outcome == "cancelled" or self.terminal:
                    raise once.CaptureFailure("cancelled")
            async with self.lock:
                try:
                    # Waiting for an enable-time connection consumes this same
                    # request's deadline; it does not grant a second full budget.
                    remaining = request_end - time.monotonic()
                    if remaining <= 0:
                        raise once.CaptureFailure("timeout")
                    async with asyncio.timeout(remaining) as deadline:
                        self._check_output_directory()
                        if self._exists(request["output_file"].name):
                            raise once.CaptureFailure("output_already_exists")
                        once.check_state(self.state_dir)
                        if self.terminal:
                            raise once.CaptureFailure("worker_failed")
                        self._cancel_idle()
                        budget_end = request_end
                        while True:
                            attempts += 1
                            reused = await self._connect()
                            flags["session_reused"] = float(bool(reused))
                            if self.terminal:
                                raise once.CaptureFailure("cancelled")
                            if deadline.expired() or time.monotonic() >= budget_end:
                                raise once.CaptureFailure("timeout")
                            await self._notify_connection("ready", "ready")
                            connect_complete = time.monotonic()
                            if attempts == 1:
                                budget_end = budget.hard_end
                            # Always a new RPC. Only a first-attempt timeout is retried, once.
                            limit = min(FIRST_ATTEMPT_TIMEOUT if attempts == 1 else SCREENSHOT_TIMEOUT, budget_end - time.monotonic())
                            if self.provider is not None:
                                # Progress rules for this keypress (CaptureSession.capture).
                                with contextlib.suppress(AttributeError, TypeError):
                                    self.provider.progress_fail_fast = self.transport == "usb"
                                    self.provider.limits = (max(USB_FIRST_BYTE_LIMIT, limits.get("first_byte", FIRST_BYTE_LIMIT))
                                                            if self.transport == "usb" else limits.get("first_byte", FIRST_BYTE_LIMIT),
                                                            limits.get("stall", self._default_stall()), budget_end)
                                    async def progressed(progress):
                                        budget.observe(time.monotonic(), progress["received_bytes"], progress["idle_ms"])
                                        if not deadline.expired():
                                            deadline.reschedule(budget.deadline)
                                        if self.progress_events is not None:
                                            await self.progress_events({"schema_version": 1,
                                                "event": "capture_progress", "request_id": request_id,
                                                **({"attempt_id": request["attempt_id"]} if "attempt_id" in request else {}),
                                                **progress})
                                    self.provider.on_progress = progressed
                                    if self.transport == "usb" and self.attempt_events and "attempt_id" in request:
                                        async def progress_failed(code):
                                            # Notify before cancelling/closing the uncertain USB RPC.
                                            # The other process can use the remaining shared budget now.
                                            await self.attempt_events({"schema_version": 1,
                                                "event": "attempt_failed", "request_id": request_id,
                                                "attempt_id": request["attempt_id"], "reason": code,
                                                "timings_ms": {
                                                    "connect": (connect_complete - connect_started) * 1000,
                                                    "screenshot": (time.monotonic() - connect_complete) * 1000}})
                                        self.provider.on_progress_failure = progress_failed
                            try:
                                data, capture_started, captured = await self._capture_phase(request, limit, flags, budget)
                                break
                            except (TimeoutError, asyncio.TimeoutError):
                                if deadline.expired() or self.terminal:
                                    raise
                                await self._close_session()
                                if self.terminal:
                                    raise once.CaptureFailure("worker_failed") from None
                                if attempts >= 2 or budget_end - time.monotonic() < MIN_RETRY_SECONDS:
                                    raise once.CaptureFailure("timeout") from None
                        if self.terminal:
                            raise once.CaptureFailure("cancelled")
                        if deadline.expired():
                            raise once.CaptureFailure("timeout")
                        if (type(capture_started) not in (float, int) or type(captured) not in (float, int)
                                or not all(math.isfinite(x) for x in (capture_started, captured))
                                or not started <= capture_started <= captured <= time.monotonic()):
                            raise once.CaptureFailure("capture_integrity_failed")
                        if captured - capture_started > MAX_TRANSFER_BUDGET:
                            raise once.CaptureFailure("capture_response_too_old")
                        if captured > budget.deadline:
                            raise once.CaptureFailure("timeout")
                        validation_started = time.monotonic()
                        data, metadata = once.prepare_png(data, timings=flags)
                        if time.monotonic() > budget.deadline:
                            raise once.CaptureFailure("timeout")
                        self._publish(data, request, started, captured)
                        published = True
                        finished = time.monotonic()
                        if finished > budget.deadline:
                            raise once.CaptureFailure("timeout")
                        if finished - captured > 5:
                            raise once.CaptureFailure("capture_result_too_old")
                        # Only complete, validated, published screenshots train T.
                        # A black frame or a discarded late reply never becomes a success.
                        self.success_timings.record(self.transport, captured - capture_started)
                        receipt = {"schema_version": 1, "request_id": request_id, "ok": True,
                            "reason": "captured", **metadata,
                            "request_started_monotonic": started, "request_completed_monotonic": finished,
                            "capture_started_monotonic": capture_started, "capture_completed_monotonic": captured,
                            "transport": "authenticated_" + self.transport, "source": "DVT_takeScreenshot",
                            "device_frame_timestamp_available": False, "lock_state_verified": False,
                            "connection_reused": reused,
                            "timings_ms": {
                                "attempts": attempts,
                                "connect": (connect_complete - connect_started) * 1000,
                                "screenshot": (captured - capture_started) * 1000,
                                "validation": (finished - validation_started) * 1000,
                                "total": (finished - started) * 1000,
                                **(link_timeline.last_summary or {}), **flags}}
                        self._restart_idle()
                        return receipt
                except BaseException as error:
                    # A complete reply rejected only on its content leaves the link healthy:
                    # keep the session for the next keypress (2026-10-25: black frames each
                    # tore down a good connection). Everything else discards it.
                    if isinstance(error, once.CaptureFailure) and str(error) in LINK_SAFE_FAILURES:
                        self._restart_idle()
                    else:
                        await self._close_session()
                    raise
        except BaseException as error:
            # A keypress that ran out of budget leaves a reconnect still in flight running in
            # the background, so the next keypress finds the iPad ready. Shutdown cancels it.
            if preconnect is not None and not preconnect.done() and self.terminal:
                await self._cancel_preconnect()
            if published:
                with contextlib.suppress(OSError):
                    os.unlink(request["output_file"].name, dir_fd=self.directory_fd)
            if not self._connection_healthy():
                await self._notify_connection("failed", reason(error))
            return failure(request_id, started, reason(error), attempts, {**(link_timeline.last_summary or {}), **flags})

    async def accept(self, raw: bytes, emit):
        """Called when one whole line is received; never queues capture work."""
        started = time.monotonic()
        request, error = self._parse(raw, started)
        if error is not None:
            await emit(error)
            return
        async def reject(code):
            receipt = failure(request["request_id"], started, code)
            if "attempt_id" in request:
                receipt["attempt_id"] = request["attempt_id"]
            await emit(receipt)

        if self.active is not None and not self.active.done():
            await reject("busy")
            return
        if self.terminal:
            await reject("worker_failed")
            return
        self._cancel_idle()
        # Snapshot before scheduling perform(): the preconnect may finish between
        # receipt of the key request and the next loop turn.
        preconnect = self.preconnect_task
        if preconnect is not None and preconnect.done():
            preconnect = None

        async def perform():
            try:
                receipt = await self._capture_request(request, started, preconnect)
                if "attempt_id" in request:
                    receipt["attempt_id"] = request["attempt_id"]
                await emit(receipt)
            except BaseException:
                self.terminal = True
            finally:
                if self.terminal:
                    self.stop_event.set()

        self.active = asyncio.create_task(perform())

    async def shutdown(self):
        if self.directory_fd is None:
            return
        # Invalidate before the first await. A cancelled preconnect can complete
        # and wake a capture waiter while shutdown is still awaiting its cleanup.
        self.terminal = True
        self.stop_event.set()
        self._cancel_idle()
        await self._cancel_keep_warm()
        await self._cancel_preconnect()
        if self.active is not None and not self.active.done():
            self.active.cancel()
            done, _ = await asyncio.wait({self.active}, timeout=self.cleanup_seconds)
            if not done:
                self.terminal = True
        await self._close_session()
        for name in list(self.staging_names):
            with contextlib.suppress(OSError):
                os.unlink(name, dir_fd=self.directory_fd)
        os.close(self.directory_fd)
        self.directory_fd = None


async def request_lines(reader):
    """Bound memory and discard an entire oversized line, including its suffix."""
    discarding = False
    while True:
        try:
            raw = await reader.readuntil(b"\n")
        except asyncio.LimitOverrunError as error:
            await reader.readexactly(error.consumed)
            discarding = True
            continue
        except asyncio.IncompleteReadError as error:
            if error.partial or discarding:
                yield None
            return
        if discarding or len(raw) > MAX_LINE_BYTES:
            yield None
        else:
            yield raw[:-1]
        discarding = False


class ReceiptWriter:
    def __init__(self, descriptor):
        self.descriptor = descriptor
        self.lock = asyncio.Lock()
        os.set_blocking(descriptor, False)

    async def emit(self, receipt):
        # allow_nan=False is a last boundary against unknown/infinite values.
        data = (json.dumps(receipt, separators=(",", ":"), allow_nan=False) + "\n").encode()
        if len(data) >= 16384:
            raise once.CaptureFailure("capture_integrity_failed")
        async with self.lock:
            offset = 0
            loop = asyncio.get_running_loop()
            while offset < len(data):
                try:
                    count = os.write(self.descriptor, data[offset:])
                    if count <= 0:
                        raise BrokenPipeError()
                    offset += count
                except BlockingIOError:
                    ready = loop.create_future()
                    def writable():
                        if not ready.done():
                            ready.set_result(None)
                    loop.add_writer(self.descriptor, writable)
                    try:
                        await ready
                    finally:
                        loop.remove_writer(self.descriptor)


async def serve(service, reader, emit):
    lines = request_lines(reader)
    line_task = stop_task = None
    try:
        while True:
            line_task = asyncio.create_task(anext(lines))
            stop_task = asyncio.create_task(service.stop_event.wait())
            done, _ = await asyncio.wait({line_task, stop_task}, return_when=asyncio.FIRST_COMPLETED)
            if stop_task in done:
                break
            stop_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await stop_task
            try:
                raw = line_task.result()
            except StopAsyncIteration:
                break
            if raw is None:
                await emit(failure(None, time.monotonic(), "invalid_arguments"))
            else:
                await service.accept(raw, emit)
            if service.terminal:
                break
    finally:
        for task in (line_task, stop_task):
            if task is not None and not task.done():
                task.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await task
        await lines.aclose()
        await service.shutdown()


def isolate_output():
    """Only ReceiptWriter receives a duplicate of the original anonymous pipe."""
    original = os.dup(1)
    null = os.open(os.devnull, os.O_WRONLY)
    try:
        os.dup2(null, 1)
        os.dup2(null, 2)
    finally:
        os.close(null)
    once.logging.disable(once.logging.CRITICAL)
    return original


def start_watchdog(parent_pid, terminating):
    """Kill our isolated process group if the native parent exits or cancels."""
    def hard_exit():
        # Own process group includes any short-lived vendor subprocess. Never
        # signal the application's group if setsid was unavailable.
        if os.getpgrp() == os.getpid():
            with contextlib.suppress(OSError):
                os.killpg(os.getpid(), signal.SIGKILL)
        os._exit(2)

    def watch():
        deadline = None
        while True:
            if os.getppid() != parent_pid:
                hard_exit()
            if terminating.is_set():
                if deadline is None:
                    deadline = time.monotonic() + 0.8
                if time.monotonic() >= deadline:
                    hard_exit()
            time.sleep(0.1)
    threading.Thread(target=watch, daemon=True).start()


def main(argv=None):
    os.umask(0o077)
    original_stdout = isolate_output()
    loop = None
    isolated_group = False
    try:
        parent_pid = os.getppid()
        if parent_pid <= 1:
            return 1
        try:
            os.setsid()
            isolated_group = True
        except OSError:
            # Foundation.Process can create its child as an existing process
            # group leader: setsid then fails with EPERM. It is still safe to
            # own that group only when it cannot include the native parent.
            if (os.getpgrp() != os.getpid()
                    or os.getpgid(parent_pid) == os.getpid()):
                return 1
            isolated_group = True
        terminating = threading.Event()
        start_watchdog(parent_pid, terminating)
        parser = once.QuietParser(description=__doc__)
        parser.add_argument("--state-dir", type=Path, required=True)
        parser.add_argument("--output-dir", type=Path, required=True)
        parser.add_argument("--timings-file", type=Path,
                            help="Private success-timing JSON, independent of the pairing-state location")
        parser.add_argument("--idle-seconds", type=float, default=DEFAULT_IDLE_SECONDS)
        parser.add_argument("--preconnect", action="store_true",
                            help="Once on explicit enable: authenticate a connection, never capture")
        parser.add_argument("--keep-warm", action="store_true",
                            help="Reconnect in the background whenever the connection is lost, never capture")
        parser.add_argument("--connection-events", action="store_true",
                            help="Emit sanitized connection metadata on stdout; never request a frame")
        parser.add_argument("--transport", choices=("wifi", "usb"), default="wifi")
        parser.add_argument("--worker-role", choices=("wifi_primary", "usb_primary", "wifi_standby"))
        parser.add_argument("--watch-usb", action="store_true")
        args = parser.parse_args(argv)
        routing_metadata = args.worker_role is not None
        args.worker_role = args.worker_role or args.transport + "_primary"
        if (args.worker_role.startswith("usb") != (args.transport == "usb")
                or args.watch_usb and args.worker_role != "wifi_primary"):
            raise once.CaptureFailure("invalid_arguments")
        if args.transport == "wifi":
            prewarm_dependencies()
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)

        async def run():
            writer = ReceiptWriter(original_stdout)
            async def emit(value):
                # Routing metadata only; no device identifier or endpoint leaves the worker.
                routed = {**value, "worker_role": args.worker_role,
                          "transport": value.get("transport", "authenticated_" + args.transport)}
                await writer.emit(routed if routing_metadata else value)
            if args.transport == "usb":
                from usb_transport import require_library_version
                try:
                    require_library_version()
                except Exception:
                    # Report the pinned-version error before importing a changed
                    # upstream API. EOF alone would hide it as a worker failure.
                    await emit({"schema_version": 1, "event": "connection",
                                "state": "failed", "reason": "unexpected_library_version"})
                    return
                prewarm_dependencies()
            service = CaptureService(args.state_dir, args.output_dir, args.idle_seconds,
                                     connection_factory=lambda state: worker_session(state, args.transport, args.worker_role),
                                     transport=args.transport, timing_path=args.timings_file,
                                     attempt_events=emit if routing_metadata and args.transport == "usb" else None,
                                     progress_events=emit if routing_metadata and args.connection_events else None,
                                     connection_events=emit if args.connection_events else None)
            reader = asyncio.StreamReader(limit=MAX_LINE_BYTES)
            transport, _ = await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin.buffer)
            observer = None
            try:
                if args.keep_warm:
                    service.start_keep_warm()
                elif args.preconnect:
                    service.start_preconnect()
                if args.watch_usb:
                    from usb_transport import watch_usb
                    observer = asyncio.create_task(watch_usb(args.state_dir, emit))
                await serve(service, reader, emit)
            finally:
                if observer is not None:
                    observer.cancel()
                    with contextlib.suppress(asyncio.CancelledError, Exception):
                        await observer
                transport.close()

        task = loop.create_task(run())
        def cancel(_signum, _frame):
            terminating.set()
            loop.call_soon_threadsafe(task.cancel)
        signal.signal(signal.SIGTERM, cancel)
        signal.signal(signal.SIGINT, cancel)
        loop.run_until_complete(task)
        return 0
    except BaseException:
        # A malformed startup or dead pipe produces EOF, never exception text or
        # an unsolicited receipt that could be confused with a request result.
        return 1
    finally:
        if loop is not None:
            for pending in asyncio.all_tasks(loop):
                pending.cancel()
            loop.close()
        os.close(original_stdout)
        # A fast graceful exit must not outrun the watchdog and orphan a vendor
        # subprocess. The receipt pipe is already drained/closed; terminate only
        # this invocation's private group (setsid or the verified launcher group).
        if isolated_group and os.getpgrp() == os.getpid():
            with contextlib.suppress(OSError):
                os.killpg(os.getpid(), signal.SIGKILL)


if __name__ == "__main__":
    sys.exit(main())
