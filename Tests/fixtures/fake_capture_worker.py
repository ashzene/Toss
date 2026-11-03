#!/usr/bin/env python3
"""Synthetic anonymous-pipe worker. No device, network, UI or image operations."""
import argparse
import json
import os
from pathlib import Path
import signal
import sys
import time
import threading


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--idle-seconds")
    parser.add_argument("--timings-file")
    parser.add_argument("--preconnect", action="store_true")
    parser.add_argument("--keep-warm", action="store_true")
    parser.add_argument("--connection-events", action="store_true")
    parser.add_argument("--transport", default="wifi")
    parser.add_argument("--worker-role", default="wifi_primary")
    parser.add_argument("--watch-usb", action="store_true")
    args = parser.parse_args()
    output_lock = threading.Lock()
    def emit(value):
        value.update(worker_role=args.worker_role, transport="authenticated_" + args.transport)
        with output_lock:
            print(json.dumps(value, separators=(",", ":")), flush=True)
    sequence = 0
    def audit(event, **values):
        with (args.state_dir / "audit.jsonl").open("a") as handle:
            handle.write(json.dumps({"event": event, "worker_pid": os.getpid(), "transport": args.transport, "worker_role": args.worker_role, **values}) + "\n")
    audit("started", preconnect=args.preconnect, idle_seconds=args.idle_seconds, timings_file=args.timings_file)
    if args.preconnect and (args.state_dir / "mode").read_text().strip() == "prepare-exit":
        audit("preconnect_exiting")
        return 3
    def connection(state, reason):
        emit({"schema_version": 1, "event": "connection", "state": state, "reason": reason})
    if args.connection_events and (args.state_dir / "mode").read_text().strip() == "connection-events":
        connection("connecting", "connecting")
        connection("ready", "ready")
    initial_mode = (args.state_dir / "mode").read_text().strip()
    if initial_mode.startswith(("wifi-", "adaptive-", "flow-")):
        connection("ready", "ready")
        audit("ready")
    if initial_mode.startswith("usb-"):
        if args.transport == "usb" and initial_mode in ("usb-version", "usb-version-delayed"):
            connection("failed", "unexpected_library_version")
            return 0
        else:
            state = "connecting" if initial_mode == "usb-reconnecting" and args.transport == "usb" else "ready"
            connection(state, state)
    if args.watch_usb:
        def presence():
            previous = None
            while True:
                crash = args.state_dir / "crash-wifi"
                if crash.exists():
                    crash.unlink()
                    audit("watcher_crashed")
                    os._exit(9)
                # File-backed fake events: never touches usbmux or a device.
                present = (args.state_dir / "usb-present").exists()
                if present != previous:
                    emit({"schema_version": 1, "event": "usb_presence", "present": present})
                    previous = present
                time.sleep(0.01)
        threading.Thread(target=presence, daemon=True).start()
    for line in sys.stdin:
        request = json.loads(line)
        sequence += 1
        mode = (args.state_dir / "mode").read_text().strip()
        if mode == "late":
            # Exercise the native generation guard after an old child ignores
            # graceful cancellation briefly. The native fallback still kills it.
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
        audit("request", request_id=request.get("request_id"), sequence=sequence, mode=mode, attempt_id=request.get("attempt_id"),
              deadline=request.get("deadline_monotonic"), press_started=request.get("press_started_monotonic"), limits=request.get("limits_ms"),
              screenshot_deadline=request.get("screenshot_deadline_monotonic"),
              output_file=request.get("output_file"))
        response = {"schema_version": 1, "request_id": request.get("request_id"),
                    "ok": True, "worker_pid": os.getpid(), "sequence": sequence}
        if "attempt_id" in request: response["attempt_id"] = request["attempt_id"]
        if mode.startswith("flow-"):
            started = time.monotonic()
            identity = {"schema_version": 1, "request_id": request["request_id"]}
            if "attempt_id" in request: identity["attempt_id"] = request["attempt_id"]
            emit({**identity, "event": "capture_started", "capture_started_monotonic": started,
                  "screenshot_deadline_monotonic": request.get("deadline_monotonic", request.get("press_started_monotonic", started) + 8),
                  "slow_threshold_ms": 1000, "slow_sample_count": 20, "slow_threshold_exempt": False})
            duration = 5.6 if mode == "flow-12mb" else 10 if mode == "flow-too-long" else 1.3
            total = 12 * 1024 * 1024
            while time.monotonic() - started < duration:
                elapsed = time.monotonic() - started
                received = max(0, min(total, (elapsed - 0.5) / (duration - 0.5) * total))
                if mode == "flow-no-bytes": received = 0
                if mode == "flow-stalled": received = min(received, total / 4)
                emit({**identity, "event": "capture_progress", "elapsed_ms": elapsed * 1000,
                      "received_bytes": received, "rpc_received_bytes": received,
                      "expected_bytes": total, "idle_ms": 0, "reason": "progress", "source": "rpc"})
                time.sleep(0.25)
            if mode in ("flow-no-bytes", "flow-stalled"): time.sleep(30)
            completed = time.monotonic()
            emit({**identity, "event": "capture_completed", "capture_completed_monotonic": completed})
            out = Path(request["output_file"])
            out.write_bytes(mode.encode()); out.chmod(0o600)
            response.update(capture_started_monotonic=started, capture_completed_monotonic=completed)
        if mode.startswith("adaptive-"):
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            if mode == "adaptive-validation-connecting-hedge" and args.worker_role == "wifi_standby":
                time.sleep(30)  # No capture_started event: the primary's group timer must retire it.
            if mode in ("adaptive-connect", "adaptive-cold"): time.sleep(0.55)
            if mode == "adaptive-cap": time.sleep(3.9)
            started = time.monotonic()
            threshold = 4.5 if mode == "adaptive-cold" else 0.6 if args.transport == "usb" else 1.0
            exempt = mode == "adaptive-ddi"
            # Match the backend protocol: this is the RPC threshold deadline; the
            # coordinator independently clamps it to the earlier press cap.
            end = min(started + threshold, request.get("screenshot_deadline_monotonic", started + threshold))
            identity = {"schema_version": 1, "request_id": request["request_id"]}
            if "attempt_id" in request: identity["attempt_id"] = request["attempt_id"]
            emit({**identity, "event": "capture_started", "capture_started_monotonic": started,
                  "screenshot_deadline_monotonic": end, "slow_threshold_ms": threshold * 1000,
                  "slow_sample_count": 0 if mode == "adaptive-cold" else 20, "slow_threshold_exempt": exempt})
            audit("rpc_started", at=started, screenshot_deadline=end)
            if mode in ("adaptive-validation-black-hedge", "adaptive-validation-connecting-hedge"):
                if args.worker_role == "wifi_primary":
                    time.sleep(0.65)
                    emit({**identity, "event": "capture_progress", "elapsed_ms": 650,
                          "received_bytes": 0, "idle_ms": 650, "reason": "first_byte_timeout", "source": "rpc"})
                    time.sleep(0.1)
                    emit({**identity, "event": "capture_completed", "capture_completed_monotonic": time.monotonic()})
                    time.sleep(0.65)  # PNG rejection happens after the sibling's deadline.
                    response.update(ok=False, reason="black_frame_rejected")
                    emit(response)
                    continue
                time.sleep(30)  # Must be retired even while the completed candidate validates.
            if mode.startswith("adaptive-hedge") and args.worker_role == "wifi_primary":
                time.sleep(0.65)
                emit({**identity, "event": "capture_progress", "elapsed_ms": 650,
                      "received_bytes": 0, "idle_ms": 650, "reason": "first_byte_timeout", "source": "rpc"})
                time.sleep(30)
            elif mode == "adaptive-hedge-win": time.sleep(0.08)
            elif mode in ("adaptive-relay", "adaptive-relay-slow") and args.transport == "usb":
                time.sleep(2.5)
                emit({**identity, "event": "attempt_failed", "reason": "first_byte_timeout"})
                time.sleep(30)
            elif mode in ("adaptive-slow", "adaptive-hedge", "adaptive-relay-slow", "adaptive-cap"):
                time.sleep(30)
            elif mode == "adaptive-ddi": time.sleep(1.2)
            elif mode == "adaptive-validation": time.sleep(0.6)
            else: time.sleep(0.8)
            completed = time.monotonic()
            emit({**identity, "event": "capture_completed", "capture_completed_monotonic": completed})
            if mode == "adaptive-validation": time.sleep(0.7)
            out = Path(request["output_file"])
            out.write_bytes(args.worker_role.encode())
            out.chmod(0o600)
            response.update(capture_started_monotonic=started, capture_completed_monotonic=completed)
        if mode in ("delay", "late"):
            time.sleep(0.3)
        elif mode == "timeout":
            time.sleep(30)
        elif mode == "wrong-id":
            response["request_id"] = "00000000-0000-4000-8000-000000000099"
        elif mode == "eof":
            return 0
        elif mode == "malformed":
            print("{not-valid-json}", flush=True)
            continue
        elif mode == "malformed-event":
            emit({"schema_version": 1, "event": "connection", "state": "ready", "reason": "SECRET_DEVICE"})
            continue
        elif mode == "connection-events":
            connection("disconnected", "disconnected")
            connection("connecting", "connecting")
            connection("ready", "ready")
            time.sleep(0.05)
        elif mode == "oversize":
            print("x" * 20_000, flush=True)
            continue
        elif mode == "no-newline-oversize":
            sys.stdout.write("x" * 20_000)
            sys.stdout.flush()
            continue
        elif mode == "failure":
            response.update(ok=False, reason="synthetic_transport_failure")
        elif mode == "timeout-reply":
            response.update(ok=False, reason="timeout")
        elif mode == "black":
            response.update(ok=False, reason="black_frame_rejected")
        elif mode == "close-stdin":
            # Parent must survive EPIPE/SIGPIPE and discard this alive worker.
            os.close(0)
            audit("stdin_closed")
        if mode.startswith("wifi-"):
            def progress(reason="progress", source="tunnel", received=4096):
                event = {"schema_version": 1, "event": "capture_progress",
                         "request_id": request["request_id"], "attempt_id": request["attempt_id"],
                         "elapsed_ms": 800, "received_bytes": received,
                         "idle_ms": 800 if received == 0 else 1200,
                         "reason": reason, "source": source}
                if mode == "wifi-bad-progress": event["received_bytes"] = True
                emit(event)
            primary = args.worker_role == "wifi_primary"
            if mode == "wifi-no-progress":
                time.sleep(30)
            elif mode == "wifi-notice":
                time.sleep(2.25)
            elif mode in ("wifi-healthy", "wifi-too-slow", "wifi-unknown"):
                for _ in range(12):
                    progress("too_slow" if mode == "wifi-too-slow" else
                             "stall_timeout" if mode == "wifi-unknown" else "progress",
                             source="unknown" if mode == "wifi-unknown" else "tunnel")
                    time.sleep(0.1)
            elif mode == "wifi-bad-progress":
                progress()
                time.sleep(0.3)
            elif mode == "wifi-late-timeout":
                # Python's own cap reply arrives after the Swift cap: the session stays warm.
                time.sleep(1.0)
                response.update(ok=False, reason="timeout")
            elif mode == "wifi-black":
                response.update(ok=False, reason="black_frame_rejected")
            elif mode in ("wifi-stall", "wifi-first-byte", "wifi-primary-wins", "wifi-both-fail"):
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                if primary:
                    time.sleep(0.82 if mode == "wifi-first-byte" else 1.22)
                    progress("first_byte_timeout" if mode == "wifi-first-byte" else "stall_timeout",
                             received=0 if mode == "wifi-first-byte" else 4096)
                    time.sleep(0.08 if mode == "wifi-primary-wins" else 0.7)
                else:
                    time.sleep(0.7 if mode == "wifi-primary-wins" else 0.05)
                if mode == "wifi-both-fail": response.update(ok=False, reason="disconnected")
            if response["ok"]:
                out = Path(request["output_file"])
                out.write_bytes(args.worker_role.encode())
                out.chmod(0o600)
        if mode.startswith("usb-"):
            if mode == "usb-cap-hang":
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                if args.transport == "usb":
                    emit({"schema_version": 1, "event": "attempt_failed", "request_id": request["request_id"],
                          "attempt_id": request["attempt_id"], "reason": "first_byte_timeout"})
                time.sleep(30)
            if mode == "usb-version-delayed" and args.transport == "wifi":
                time.sleep(0.3)
            if args.transport == "usb":
                if mode in ("usb-progress-late", "usb-stall-late", "usb-tooslow-late", "usb-budget", "usb-held-after-fallback"):
                    time.sleep(1.25 if mode == "usb-budget" else 0.08)
                    emit({"schema_version": 1, "event": "attempt_failed", "request_id": request["request_id"],
                          "attempt_id": request["attempt_id"],
                          "reason": {"usb-stall-late": "stall_timeout", "usb-tooslow-late": "too_slow"}.get(mode, "first_byte_timeout")})
                    if mode == "usb-held-after-fallback":
                        while not (args.state_dir / "release-usb").exists(): time.sleep(0.01)
                    else:
                        time.sleep(0.35)
                elif mode == "usb-unplug":
                    time.sleep(0.08)
                    (args.state_dir / "usb-present").unlink(missing_ok=True)
                    time.sleep(0.35)
                elif mode == "usb-failure":
                    response.update(ok=False, reason="capture_failed")
                elif mode == "usb-wrong-attempt":
                    response["attempt_id"] = "00000000-0000-4000-8000-000000000099"
                elif mode == "usb-late-stop":
                    signal.signal(signal.SIGTERM, signal.SIG_IGN)
                    time.sleep(0.3)
            elif mode == "usb-budget":
                time.sleep(1.0)
            elif mode in ("usb-progress-late", "usb-stall-late", "usb-tooslow-late"):
                time.sleep(0.06)
            if response["ok"]:
                out = Path(request["output_file"])
                out.write_bytes(args.transport.encode())
                out.chmod(0o600)
        audit("response", sequence=sequence)
        try:
            if mode == "late":
                connection("ready", "ready")
            emit(response)
        except BrokenPipeError:
            return 0
        if mode == "close-stdin":
            time.sleep(30)
            return 0
        # Deliberately keep stdin/stdout open after each successful response.
        # A consumer waiting for EOF or for a 4096-byte block will be caught.
    return 0


if __name__ == "__main__":
    sys.exit(main())
