#!/usr/bin/env python3
"""One authenticated Wi-Fi screenshot. No UI, clipboard, pairing, or USB calls.

The stdout protocol is one sanitized JSON object. A successful output is a new,
owner-only PNG atomically published after the capture worker and its tunnel exit.
"""
from __future__ import annotations

import argparse
import asyncio
import hashlib
import io
import json
import logging
import math
import multiprocessing
import os
from pathlib import Path
import shutil
import signal
import stat
import sys
import tempfile
import threading
import time
import uuid
from typing import Awaitable, Callable

VENDOR = Path(__file__).resolve().parent / "vendor"
sys.path.insert(0, str(VENDOR))
from ipad_probe import ProbeFailure

SCHEMA_VERSION = 1
MAX_BYTES = 40 * 1024 * 1024
DEFAULT_PNG_MODE = "png8-rle"


def screen_dimensions_ok(size) -> bool:
    """Any iPad screen in either orientation (mini 1488x2266 … Pro 13" 2064x2752).

    Short side 1000-2400 px, long side 1400-3000 px, aspect 1.2-1.6. Squares,
    iPhone-shaped and absurd sizes stay rejected. No resizing ever happens.
    """
    try:
        width, height = size
    except (TypeError, ValueError):
        return False
    if type(width) is not int or type(height) is not int or width <= 0 or height <= 0:
        return False
    short, long = min(width, height), max(width, height)
    return 1000 <= short <= 2400 and 1400 <= long <= 3000 and 1.2 <= long / short <= 1.6
# Explanations belong in the UI, never in dynamically generated exception text.
SAFE_REASONS = frozenset({
    "invalid_arguments", "invalid_request_id", "invalid_timeout", "root_execution_not_allowed",
    "output_already_exists", "output_parent_not_private", "state_not_private",
    "pairing_state_missing", "pairing_state_not_private", "dependency_unavailable",
    "empty_frame", "frame_too_large", "invalid_png", "unexpected_dimensions",
    "black_frame_rejected", "capture_response_too_old", "capture_result_too_old",
    "timeout", "cancelled", "worker_failed", "capture_failed", "output_publish_failed",
    "capture_integrity_failed", "initial_usb_remote_pairing_required",
    "no_authenticated_remote_wifi_connection", "unexpected_library_version",
    "remote_peer_signature_not_verified", "remote_peer_identifier_mismatch",
    "strict_remote_pairing_record_mismatch", "strict_remote_pairing_record_incomplete",
    "remote_pairing_record_not_private", "lan_interface_not_identified",
    "python_313_openssl_psk_required", "tcp_route_not_uniquely_lan",
    "rsd_device_identity_mismatch", "private_existing_state_directory_required",
    "unexpected_device_pin", "system_dns_sd_requires_macos",
    "exact_pinned_usb_device_required", "usb_ipados_unsupported",
    "another_userspace_tunnel_active_in_process",
})


class CaptureFailure(Exception):
    """Only literal allowlisted codes may cross the stdout boundary."""


def safe_reason(error: BaseException) -> str:
    if isinstance(error, (asyncio.TimeoutError, TimeoutError)):
        return "timeout"
    if isinstance(error, (KeyboardInterrupt, asyncio.CancelledError)):
        return "cancelled"
    if isinstance(error, (ModuleNotFoundError, ImportError)):
        return "dependency_unavailable"
    if isinstance(error, (CaptureFailure, ProbeFailure)) and str(error) in SAFE_REASONS:
        return str(error)
    return "capture_failed"


def validate_png(data: bytes) -> dict:
    """Inspect without rotating, resizing, cropping, or transcoding pixels."""
    if not isinstance(data, bytes) or not data:
        raise CaptureFailure("empty_frame")
    if len(data) > MAX_BYTES:
        raise CaptureFailure("frame_too_large")
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise CaptureFailure("invalid_png")
    from PIL import Image, ImageStat
    try:
        with Image.open(io.BytesIO(data)) as image:
            if image.format != "PNG" or getattr(image, "n_frames", 1) != 1:
                raise CaptureFailure("invalid_png")
            if not screen_dimensions_ok(image.size):
                raise CaptureFailure("unexpected_dimensions")
            image.verify()
        with Image.open(io.BytesIO(data)) as image:
            image.load()
            _check_decoded_pixels(image)
            return {"width": image.width, "height": image.height, "bit_depth": data[24],
                    "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
    except CaptureFailure:
        raise
    except Exception:
        raise CaptureFailure("invalid_png") from None


def normalize_png(data: bytes) -> bytes:
    """Re-encode a 16-bit-per-channel frame as 8-bit; return 8-bit frames as-is.

    2026-10-30 (user choice, smaller uploads): prepare_png now defaults to
    PNG8 RLE, measured at ~70 ms more local work for ~62% fewer upload bytes.
    It preserves ICC and supported colour/EXIF metadata without resizing,
    cropping, rotation or colour conversion; 16-to-8-bit precision is lossy.
    This older helper remains for compatibility, not the publishing path:
    it does not preserve all metadata. TOSS_CAPTURE_PNG_MODE=original makes
    prepare_png validate and publish the original bytes instead.
    """
    # IHDR is always the first chunk; byte 24 is its bit depth.
    if (not isinstance(data, bytes) or len(data) < 33 or not data.startswith(b"\x89PNG\r\n\x1a\n")
            or data[12:16] != b"IHDR" or data[24] != 16):
        return data
    from PIL import Image
    try:
        with Image.open(io.BytesIO(data)) as image:
            # Pillow decodes 16-bit RGB(A) PNGs to 8-bit RGB(A) by keeping the high byte.
            if image.format != "PNG" or image.mode not in ("RGB", "RGBA") or not screen_dimensions_ok(image.size):
                return data
            image.load()
            options = {"compress_level": 3}
            if image.info.get("icc_profile"):
                options["icc_profile"] = image.info["icc_profile"]
            output = io.BytesIO()
            image.save(output, format="PNG", **options)
            return output.getvalue()
    except Exception:
        raise CaptureFailure("invalid_png") from None


def _near_black(image, limit=3) -> bool:
    from PIL import ImageStat
    stats = ImageStat.Stat(image.convert("RGB"))
    return max(stats.mean) < limit and max(stats.stddev) < limit


def _check_decoded_pixels(image) -> None:
    # Speed: look at a 4x box-reduced copy first. Box averaging keeps
    # the mean and can only lower the spread (rounding moves each by <= 0.5, so
    # the pre-check uses a limit of 4 instead of 3). A reduced frame that is
    # clearly not near-black proves the full frame is not either; anything else
    # gets the exact full-resolution test, as before.
    # (Pillow reduces RGB/L quickly; for RGBA the reduce costs as much as it saves.)
    if image.mode in ("RGB", "L") and min(image.size) >= 64:
        maybe_black = _near_black(image.reduce(4), limit=4)
    else:
        maybe_black = True
    if maybe_black and _near_black(image):
        raise CaptureFailure("black_frame_rejected")
    if "A" in image.getbands() and image.getchannel("A").getextrema() != (255, 255):
        raise CaptureFailure("invalid_png")


def prepare_png(data: bytes, *, timings=None) -> tuple[bytes, dict]:
    """Default: PNG8 RLE. TOSS_CAPTURE_PNG_MODE=original keeps original bytes.

    2026-10-30 (user choice, smaller uploads): measured RGB16 frames take
    ~70 ms more local work but produce ~62% fewer bytes for the app to upload.
    This cannot shorten device generation or transfer. Unsupported layouts
    and 8-bit frames keep their original bytes after the usual checks.
    Freshness, atomic publication and native attachment checks remain in place.
    """
    mode = os.environ.get("TOSS_CAPTURE_PNG_MODE", DEFAULT_PNG_MODE)
    started = time.perf_counter()
    measurements = {"png_input_bytes": len(data) if isinstance(data, bytes) else 0,
                    "png_encoded": 0}
    if mode not in {"original", "png8-rle"}:
        mode = DEFAULT_PNG_MODE
        # Numeric flag for timing receipts; never echo raw environment text.
        measurements["png_mode_warning"] = 1
    try:
        if (mode == "png8-rle" and isinstance(data, bytes) and len(data) >= 33
                and data.startswith(b"\x89PNG\r\n\x1a\n") and data[24] == 16):
            if len(data) > MAX_BYTES:
                raise CaptureFailure("frame_too_large")
            from capture_encoding import prepare_png8
            result = prepare_png8(data, original_prepare=_prepare_png_original,
                                  check_pixels=_check_decoded_pixels,
                                  dimensions_ok=screen_dimensions_ok,
                                  failure=CaptureFailure, timings=measurements)
        else:
            result = _prepare_png_original(data)
        measurements["png_output_bytes"] = len(result[0])
        return result
    finally:
        measurements["png_prepare_ms"] = (time.perf_counter() - started) * 1000
        if timings is not None:
            timings.update(measurements)


def _prepare_png_original(data: bytes) -> tuple[bytes, dict]:
    """Validate a frame for publishing with one decode; publish its bytes as-is.

    2026-10-30: this is the original-mode and fallback path. The user chose
    PNG8 RLE by default for smaller uploads (~70 ms more local work, ~62%
    fewer bytes in measured RGB16 frames). TOSS_CAPTURE_PNG_MODE=original
    opts out. Here a 16-bit Display P3 frame is decoded once and must pass
    the same dimension, black-frame and opaque-alpha checks as validate_png;
    its original bytes are published unchanged.
    8-bit frames and any unusual layout take the unchanged validate_png path.
    """
    if (not isinstance(data, bytes) or len(data) < 33 or not data.startswith(b"\x89PNG\r\n\x1a\n")
            or data[12:16] != b"IHDR" or data[24] != 16):
        return data, validate_png(data)
    if len(data) > MAX_BYTES:
        raise CaptureFailure("frame_too_large")
    from PIL import Image
    try:
        with Image.open(io.BytesIO(data)) as image:
            if (image.format != "PNG" or getattr(image, "n_frames", 1) != 1
                    or image.mode not in ("RGB", "RGBA")):
                return data, validate_png(data)
            if not screen_dimensions_ok(image.size):
                raise CaptureFailure("unexpected_dimensions")
            image.load()
            _check_decoded_pixels(image)
            width, height = image.size
    except CaptureFailure:
        raise
    except Exception:
        raise CaptureFailure("invalid_png") from None
    return data, {"width": width, "height": height, "bit_depth": data[24], "bytes": len(data),
                  "sha256": hashlib.sha256(data).hexdigest()}


async def capture_wifi(state_dir: Path) -> tuple[bytes, float, float]:
    """No cached image or transport fallback. Each call performs takeScreenshot."""
    from remote_pairing_transport import open_remote_wifi_rsd
    from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
    from pymobiledevice3.services.dvt.instruments.screenshot import Screenshot
    async with open_remote_wifi_rsd(state_dir, browse_seconds=12.0) as (provider, _):
        async with DvtProvider(provider) as dvt, Screenshot(dvt) as screenshot:
            capture_start = time.monotonic()
            # One request, no retry that could silently return a previous frame.
            data = await asyncio.wait_for(screenshot.get_screenshot(), timeout=5.0)
            capture_complete = time.monotonic()
    return data, capture_start, capture_complete


def check_private_directory(path: Path, reason: str) -> None:
    try:
        value = path.lstat()
        valid = (stat.S_ISDIR(value.st_mode) and not path.is_symlink()
                 and value.st_uid == os.getuid() and not value.st_mode & 0o077)
    except OSError:
        valid = False
    if not valid:
        raise CaptureFailure(reason)


def check_state(state_dir: Path) -> None:
    check_private_directory(state_dir, "state_not_private")
    for name in ("target.json", "strict-remote-pairing.plist"):
        try:
            info = (state_dir / name).lstat()
        except FileNotFoundError:
            raise CaptureFailure("pairing_state_missing") from None
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or info.st_mode & 0o077):
            raise CaptureFailure("pairing_state_not_private")
    if (state_dir / "cache").exists():
        check_private_directory(state_dir / "cache", "state_not_private")


def private_write_new(path: Path, content: bytes) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as handle:
        handle.write(content)
        handle.flush()
        os.fsync(handle.fileno())


async def _worker_async(state: Path, capture: Callable[..., Awaitable], budget: float) -> dict:
    async with asyncio.timeout(budget):
        data, capture_start, capture_complete = await capture(state)
        if capture_complete < capture_start or capture_complete - capture_start > 5.0:
            raise CaptureFailure("capture_response_too_old")
        timings = {}
        data, metadata = prepare_png(data, timings=timings)
        return {"data": data, **metadata, "capture_started_monotonic": capture_start,
                "capture_completed_monotonic": capture_complete, "timings_ms": timings}


def _worker_entry(state: str, scratch: str, request_id: str, budget: float,
                  capture: Callable[..., Awaitable], supervisor_pid: int) -> None:
    # Library logs can include peer addresses or identifiers. Suppress at the FD
    # boundary as well as Python logging; the parent emits the only public JSON.
    os.umask(0o077)
    try:
        os.setsid()
    except OSError:
        pass
    null = os.open(os.devnull, os.O_WRONLY)
    os.dup2(null, 1)
    os.dup2(null, 2)
    os.close(null)
    logging.disable(logging.CRITICAL)
    # If the native app forcibly kills our supervisor, don't leave a capture
    # worker behind. macOS has no PR_SET_PDEATHSIG; this watchdog exits the worker
    # once it is reparented. Its sockets are then closed by the OS.
    def supervise_parent():
        while True:
            if os.getppid() != supervisor_pid:
                os._exit(2)
            time.sleep(0.2)
    threading.Thread(target=supervise_parent, daemon=True).start()
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    task = loop.create_task(_worker_async(Path(state), capture, budget))
    for signum in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(signum, task.cancel)
    result = {"request_id": request_id, "ok": False, "reason": "worker_failed"}
    try:
        payload = loop.run_until_complete(task)
        data = payload.pop("data")
        private_write_new(Path(scratch) / "frame.png", data)
        result = {"request_id": request_id, "ok": True, **payload}
    except BaseException as error:
        result["reason"] = safe_reason(error)
    finally:
        # Capture context managers close normal/cancelled tunnels and DNS-SD.
        # The supervisor terminates the worker if a dependency cannot clean up.
        for pending in asyncio.all_tasks(loop):
            pending.cancel()
        loop.close()
        private_write_new(Path(scratch) / "result.json",
                          json.dumps(result, separators=(",", ":")).encode())


def stop_worker(process) -> None:
    if not process or not process.is_alive():
        return
    process.terminate()
    process.join(timeout=0.3)
    if process.is_alive():
        process.kill()
        process.join(timeout=0.2)


def run_request(state_dir: Path, output_file: Path, request_id: str, timeout: float,
                *, capture: Callable[..., Awaitable] = capture_wifi) -> dict:
    """Public contract, also injectable with an in-memory capture in pure tests."""
    started = time.monotonic()
    result = {"schema_version": SCHEMA_VERSION, "request_id": None, "ok": False,
              "request_started_monotonic": started}
    scratch = None
    process = None
    published = False
    try:
        try:
            parsed = uuid.UUID(request_id)
        except (ValueError, TypeError, AttributeError):
            raise CaptureFailure("invalid_request_id") from None
        if str(parsed) != request_id:
            raise CaptureFailure("invalid_request_id")
        result["request_id"] = request_id
        if not math.isfinite(timeout) or not 4.0 <= timeout <= 45.0:
            raise CaptureFailure("invalid_timeout")
        if os.geteuid() == 0:
            raise CaptureFailure("root_execution_not_allowed")
        state_dir = Path(os.path.abspath(state_dir))
        output_file = Path(os.path.abspath(output_file))
        # lexists, unlike exists, also rejects a dangling symlink as an old output.
        if os.path.lexists(output_file):
            raise CaptureFailure("output_already_exists")
        check_private_directory(output_file.parent, "output_parent_not_private")
        check_state(state_dir)
        scratch = Path(tempfile.mkdtemp(prefix=".toss-", dir=output_file.parent))
        # spawn has a fresh process/interpreter: no previously active tunnel/cache.
        process = multiprocessing.get_context("spawn").Process(
            target=_worker_entry,
            args=(str(state_dir), str(scratch), request_id, timeout - 3.0, capture, os.getpid()),
            daemon=True,
        )
        process.start()
        process.join(timeout=max(0.0, timeout - 2.0 - (time.monotonic() - started)))
        if process.is_alive():
            raise CaptureFailure("timeout")
        if process.exitcode != 0 or not (scratch / "result.json").is_file():
            raise CaptureFailure("worker_failed")
        metadata = json.loads((scratch / "result.json").read_text())
        if metadata.get("request_id") != request_id:
            raise CaptureFailure("capture_integrity_failed")
        if metadata.get("ok") is not True:
            code = metadata.get("reason")
            raise CaptureFailure(code if code in SAFE_REASONS else "capture_failed")
        complete = metadata.get("capture_completed_monotonic")
        capture_started = metadata.get("capture_started_monotonic")
        if (type(complete) not in (int, float) or type(capture_started) not in (int, float)
                or not started <= capture_started <= complete <= time.monotonic()):
            raise CaptureFailure("capture_integrity_failed")
        if time.monotonic() - complete > 5.0:
            raise CaptureFailure("capture_result_too_old")
        info = (scratch / "frame.png").lstat()
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or info.st_mode & 0o077 or not 0 < info.st_size <= MAX_BYTES):
            raise CaptureFailure("capture_integrity_failed")
        data = (scratch / "frame.png").read_bytes()
        verified = validate_png(data)
        if any(metadata.get(key) != value for key, value in verified.items()):
            raise CaptureFailure("capture_integrity_failed")
        if time.monotonic() - started >= timeout:
            raise CaptureFailure("timeout")
        # Same-volume hard-link publication is atomic and cannot replace a file
        # another process created after our first existence check.
        try:
            os.link(scratch / "frame.png", output_file, follow_symlinks=False)
        except FileExistsError:
            raise CaptureFailure("output_already_exists") from None
        except OSError:
            raise CaptureFailure("output_publish_failed") from None
        published = True
        result.update(ok=True, reason="captured", **verified,
                      capture_started_monotonic=capture_started,
                      capture_completed_monotonic=complete,
                      timings_ms=metadata.get("timings_ms", {}),
                      transport="authenticated_wifi", source="DVT_takeScreenshot",
                      device_frame_timestamp_available=False, lock_state_verified=False)
    except BaseException as error:
        result.update(ok=False, reason=safe_reason(error))
        # We only remove an output this invocation actually published. Existing
        # files, including symlinks, are rejected and never read, modified/deleted.
        if published:
            output_file.unlink(missing_ok=True)
    finally:
        stop_worker(process)
        if scratch is not None:
            shutil.rmtree(scratch, ignore_errors=True)
        if process is not None:
            process.close()
    result["request_completed_monotonic"] = time.monotonic()
    return result


class QuietParser(argparse.ArgumentParser):
    def error(self, message):
        raise CaptureFailure("invalid_arguments")


def main(argv=None) -> int:
    os.umask(0o077)
    logging.disable(logging.CRITICAL)
    try:
        parser = QuietParser(description=__doc__)
        parser.add_argument("--state-dir", type=Path, required=True)
        parser.add_argument("--output-file", type=Path, required=True)
        parser.add_argument("--request-id", required=True)
        parser.add_argument("--timeout", type=float, default=45.0)
        args = parser.parse_args(argv)
        # SIGTERM from the native companion follows the same cleanup path as ^C.
        def cancel(_signum, _frame):
            raise KeyboardInterrupt
        signal.signal(signal.SIGTERM, cancel)
        result = run_request(args.state_dir, args.output_file, args.request_id, args.timeout)
    except BaseException as error:
        if isinstance(error, SystemExit) and error.code == 0:
            return 0
        result = {"schema_version": SCHEMA_VERSION, "request_id": None,
                  "ok": False, "reason": safe_reason(error)}
    print(json.dumps(result, separators=(",", ":")), flush=True)
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
