#!/usr/bin/env python3
"""First-time iPad setup, started by the app; the user only acts on the iPad.

`auto` watches USB and drives every step by itself, printing one JSON line per
state change: {"schema_version":1, "ok":bool, "code":"<fixed code>",
"final":bool, ...safe fields}. Only the last line has final=true. The app shows
each code as an instruction; nobody has to click "check again".

Steps (USB only until the RemotePairing record exists, then Wi-Fi only):
  1. exactly one USB-connected iPad on iPadOS 17+ (waits until plugged in)
  2. "Trust This Computer" (lockdown pairing; the user taps Trust on the iPad)
  3. Developer Mode. Without a passcode it is switched on and confirmed
     automatically (the iPad restarts by itself). With a passcode iPadOS only
     allows the user to turn it on: we reveal the toggle, wait through the
     restart and confirm the post-restart prompt when iPadOS lets us.
  4. RemotePairing record for Wi-Fi (existing strict bootstrap_usb)
  5. Developer Disk Image: mounted over USB while still plugged in, then the
     Wi-Fi screenshot channel is opened once to prove it works. No screenshot.
After setup, capture_service mounts the image again by itself after an iPad
restart, so there is no "prepare again" step for the user.
`next` (one round) and `prepare` (step 5 only) remain for older app builds.
Only bounded, redacted AMFI diagnostics are printed; no device names, IDs or paths.
"""
from __future__ import annotations

import asyncio
import json
import os
from pathlib import Path
import sys
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import capture_once as once  # noqa: E402  (also adds vendor/ to sys.path)
from ipad_probe import ProbeFailure, fingerprint

USBMUX = "/var/run/usbmuxd"
TRUST_TIMEOUT = 90
POLL_SECONDS = 1.5
AUTO_LIMIT_SECONDS = 30 * 60
RESTART_MIN_ABSENCE_SECONDS = 15
DEVELOPER_CONFIRM_SECONDS = 90
WIFI_ATTEMPTS = 6
DEVELOPER_SERVICE = "com.apple.instruments.dtservicehub"


class Emitter:
    """One line per change of (code, fields); the final line is always written."""
    def __init__(self):
        self.last = None

    def __call__(self, ok: bool, code: str, final: bool = True, **fields):
        safe = {k: v for k, v in fields.items()
                if k in {"model", "ipados"} and isinstance(v, str) and len(v) < 32}
        if type(fields.get("devmode_passcode")) is int and fields["devmode_passcode"] in (0, 1):
            safe["devmode_passcode"] = fields["devmode_passcode"]
        error = fields.get("devmode_enable_error")
        if isinstance(error, str) and len(error) <= 200:
            safe["devmode_enable_error"] = error  # Redacted by developer_mode.safe_error.
        key = (ok, code, tuple(sorted(safe.items())))
        if not final and key == self.last:
            return
        self.last = key
        sys.stdout.write(json.dumps({"schema_version": 1, "ok": ok, "code": code,
                                     "final": final, **safe}) + "\n")
        sys.stdout.flush()


emit = Emitter()


def private_state(state: Path) -> Path:
    state.mkdir(mode=0o700, parents=True, exist_ok=True)
    state.chmod(0o700)
    (state / "cache").mkdir(mode=0o700, exist_ok=True)
    return state


def use_private_cache(state: Path):
    import pymobiledevice3.common as common
    common._HOMEFOLDER = state / "cache"


def write_private(path: Path, data: bytes):
    temporary = path.with_name(path.name + ".tmp")
    if temporary.exists():
        temporary.unlink()
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as handle:
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


def has_pairing(state: Path) -> bool:
    return (state / "target.json").is_file() and (state / "strict-remote-pairing.plist").is_file()


def developer_image_missing(provider) -> bool:
    info = getattr(provider, "peer_info", None)
    services = info.get("Services") if isinstance(info, dict) else None
    return isinstance(services, dict) and DEVELOPER_SERVICE not in services


async def usb_ipads(cache: Path):
    from pymobiledevice3 import usbmux
    from pymobiledevice3.lockdown import create_using_usbmux
    found = []
    for device in await usbmux.list_devices(usbmux_address=USBMUX):
        if not device.is_usb:
            continue
        try:
            client = await create_using_usbmux(serial=device.serial, connection_type="USB", autopair=False,
                                               pairing_records_cache_folder=cache, usbmux_address=USBMUX)
        except Exception:
            # Present but not answering yet: still booting, or locked since boot.
            found.append((device.serial, None, None, None))
            continue
        async with client:
            if str(client.product_type).startswith("iPad"):
                found.append((device.serial, client.product_type, client.product_version, client.paired))
    return found


async def lockdown_for(serial: str, cache: Path):
    from pymobiledevice3.lockdown import create_using_usbmux
    return await create_using_usbmux(serial=serial, connection_type="USB", autopair=False,
                                     pairing_records_cache_folder=cache, usbmux_address=USBMUX)


async def mount_over_usb(serial: str, cache: Path):
    """Best effort while the cable is still in: faster and independent of Wi-Fi."""
    from pymobiledevice3.services.mobile_image_mounter import auto_mount
    try:
        client = await lockdown_for(serial, cache)
    except Exception:
        return
    async with client:
        try:
            async with asyncio.timeout(240):
                await auto_mount(client)
        except Exception:
            pass  # Already mounted, needs a tunnel (iPadOS 27+), or offline: Wi-Fi retries below.


async def wifi_prepare(state: Path) -> str:
    """Return "ready" or a fixed failure code. Mounts the image if it is missing."""
    from remote_pairing_transport import open_remote_wifi_rsd
    from pymobiledevice3.exceptions import AlreadyMountedError
    from pymobiledevice3.services.mobile_image_mounter import auto_mount
    from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
    from pymobiledevice3.services.dvt.instruments.screenshot import Screenshot
    for attempt in range(2):
        try:
            async with asyncio.timeout(30):
                context = open_remote_wifi_rsd(state, browse_seconds=12.0)
                rsd, _ = await context.__aenter__()
        except BaseException:
            return "wifi_unreachable"
        try:
            if developer_image_missing(rsd):
                if attempt:
                    return "developer_image_failed"
                # Mounting may download Apple's image once (cached afterwards)
                # and asks Apple to personalize it for this boot of the iPad.
                try:
                    async with asyncio.timeout(240):
                        await auto_mount(rsd)
                except AlreadyMountedError:
                    pass
                except BaseException:
                    return "developer_image_failed"
                continue  # Reconnect: only a new handshake lists the new services.
            try:
                async with asyncio.timeout(20):
                    async with DvtProvider(rsd) as dvt, Screenshot(dvt):
                        pass  # Channel opened: capture will work. No frame requested.
            except BaseException:
                return "developer_image_failed"
            return "ready"
        finally:
            try:
                async with asyncio.timeout(5):
                    await context.__aexit__(None, None, None)
            except BaseException:
                pass
    return "developer_image_failed"


async def wifi_prepare_with_retries(state: Path, model=None, ipados=None) -> str:
    """Wi-Fi may need a moment: the first run asks for Local Network access."""
    code = "wifi_unreachable"
    for attempt in range(WIFI_ATTEMPTS):
        code = await wifi_prepare(state)
        if code == "ready":
            return code
        emit(False, "wifi_waiting" if code == "wifi_unreachable" else code, final=False,
             model=model, ipados=ipados)
        await asyncio.sleep(min(2 + attempt * 2, 8))
    return code


async def try_enable_developer_mode(client, *, diagnostics=None, state=None,
                                    model=None, ipados=None, deadline=None, revealer=None) -> str:
    """Keep the legacy string outcome; optional fields record sanitized failures."""
    from developer_mode import enable
    return await enable(client, progress=emit,
                        diagnostics=diagnostics if diagnostics is not None else {}, state=state,
                        reconnect=(lambda: lockdown_for(client.udid, state / "cache")) if state is not None else None,
                        model=model, ipados=ipados, deadline=deadline, revealer=revealer)


async def try_accept_developer_mode(client) -> bool:
    """Answer the post-restart "Turn On Developer Mode?" prompt when iPadOS allows it."""
    from pymobiledevice3.services.amfi import AmfiService
    try:
        from developer_mode import REQUEST_TIMEOUT
        async with asyncio.timeout(REQUEST_TIMEOUT):
            await AmfiService(client).enable_developer_mode_post_restart()
        return True
    except Exception:
        return False


async def finish_pairing(state: Path, serial: str, cache: Path, udid: str, model, version) -> str:
    from remote_pairing_transport import bootstrap_usb
    write_private(state / "target.json",
                  json.dumps({"model": model, "device_hash": fingerprint(udid)}).encode())
    emit(False, "pairing_wireless", final=False, model=model, ipados=version)
    try:
        async with asyncio.timeout(120):
            await bootstrap_usb(state, apply_device_change=True)
    except BaseException:
        return "pairing_failed"
    emit(False, "preparing_image", final=False, model=model, ipados=version)
    await mount_over_usb(serial, cache)
    return await wifi_prepare_with_retries(state, model=model, ipados=version)


async def auto(state: Path) -> str:
    """Drive the whole first-time setup; returns the final code."""
    state = private_state(state)
    cache = state / "cache"
    use_private_cache(state)
    if has_pairing(state):
        pin = json.loads((state / "target.json").read_text())
        code = await wifi_prepare_with_retries(state, model=pin.get("model"))
        return emit_final(code == "ready", code, model=pin.get("model"))

    deadline = time.monotonic() + AUTO_LIMIT_SECONDS
    devmode = {}                       # last sanitized enable failure, kept in the final result
    developer_mode_requested = False   # we asked the user (or iPadOS) to switch it on
    seen_restart = False
    usb_absent_since = None
    confirm_until = None
    accept_tries = 0
    manual_needed = False
    model = version = None
    from developer_mode import RevealRepeater
    revealer = RevealRepeater(state)
    try:
        while time.monotonic() < deadline:
            ipads = await usb_ipads(cache)
            if not ipads:
                if developer_mode_requested:
                    if usb_absent_since is None:
                        usb_absent_since = time.monotonic()
                    emit(False, "ipad_restarting", final=False, model=model, ipados=version)
                else:
                    emit(False, "no_usb_ipad", final=False)
                await asyncio.sleep(POLL_SECONDS)
                continue
            if len(ipads) > 1:
                emit(False, "multiple_usb_ipads", final=False)
                await asyncio.sleep(POLL_SECONDS)
                continue
            if usb_absent_since is not None:
                now = time.monotonic()
                # An automatic enable already requested a reboot. Only the manual
                # path needs to distinguish a quick cable replug from a restart.
                seen_restart = (not manual_needed or
                                now - usb_absent_since >= RESTART_MIN_ABSENCE_SECONDS)
                confirm_until = now + DEVELOPER_CONFIRM_SECONDS if seen_restart else None
                accept_tries = 0
                usb_absent_since = None
            serial, model, version, paired = ipads[0]
            if model is None:
                emit(False, "ipad_restarting" if seen_restart else "unlock_needed", final=False)
                await asyncio.sleep(POLL_SECONDS)
                continue
            from remote_pairing_transport import supported_ipados
            if not supported_ipados(version):
                return emit_final(False, "unsupported_ipados", model=model, ipados=version)

            if not paired:
                # Shows "Trust This Computer?" on the iPad; the user taps Trust and
                # enters the passcode. Nothing else on the device is changed here.
                emit(False, "trust_needed", final=False, model=model, ipados=version)
                from pymobiledevice3.lockdown import create_using_usbmux
                try:
                    client = await create_using_usbmux(serial=serial, connection_type="USB", autopair=True,
                                                       pair_timeout=TRUST_TIMEOUT, pairing_records_cache_folder=cache,
                                                       usbmux_address=USBMUX)
                    await client.close()
                except BaseException as error:
                    if not isinstance(error, Exception):
                        raise
                    await asyncio.sleep(POLL_SECONDS)
                continue

            try:
                client = await lockdown_for(serial, cache)
            except Exception:
                emit(False, "unlock_needed", final=False, model=model, ipados=version)
                await asyncio.sleep(POLL_SECONDS)
                continue
            async with client:
                if not client.paired:
                    continue
                udid = client.udid
                try:
                    developer_mode = await client.get_developer_mode_status()
                except Exception:
                    developer_mode = False
                if not developer_mode:
                    if seen_restart:
                        # After the restart iPadOS asks "Turn On Developer Mode?".
                        if accept_tries < 5 and time.monotonic() < confirm_until:
                            accept_tries += 1
                            if await try_accept_developer_mode(client):
                                continue
                        if time.monotonic() < confirm_until:
                            emit(False, "developer_mode_confirm", final=False, model=model, ipados=version)
                        else:
                            seen_restart = False
                            accept_tries = 0
                            manual_needed = True
                    elif not developer_mode_requested:
                        outcome = await try_enable_developer_mode(client, diagnostics=devmode, state=state,
                                                                  model=model, ipados=version, deadline=deadline, revealer=revealer)
                        if outcome == "locked":
                            return emit_final(False, "setup_timeout", model=model, ipados=version, **devmode)
                        developer_mode_requested = True
                        manual_needed = outcome == "manual"
                        emit(False, "developer_mode_auto" if outcome == "rebooting" else "developer_mode_needed",
                             final=False, model=model, ipados=version, **devmode)
                    if manual_needed:
                        revealer.tick(lambda: lockdown_for(serial, cache))
                        if not seen_restart:
                            emit(False, "developer_mode_needed", final=False, model=model, ipados=version, **devmode)
                    await asyncio.sleep(POLL_SECONDS)
                    continue
            await revealer.close()
            code = await finish_pairing(state, serial, cache, udid, model, version)
            return emit_final(code == "ready", code, model=model, ipados=version, **devmode)
        return emit_final(False, "setup_timeout", model=model, ipados=version, **devmode)
    finally:
        await revealer.close()


def emit_final(ok: bool, code: str, **fields) -> str:
    emit(ok, code, final=True, **fields)
    return code


async def next_step(state: Path):
    """Legacy single round for 0.6 app builds."""
    state = private_state(state)
    cache = state / "cache"
    use_private_cache(state)
    if has_pairing(state):
        pin = json.loads((state / "target.json").read_text())
        code = await wifi_prepare(state)
        return emit_final(code == "ready", code, model=pin.get("model"))
    ipads = [entry for entry in await usb_ipads(cache) if entry[1] is not None]
    if not ipads:
        return emit_final(False, "no_usb_ipad")
    if len(ipads) > 1:
        return emit_final(False, "multiple_usb_ipads")
    serial, model, version, paired = ipads[0]
    from remote_pairing_transport import supported_ipados
    if not supported_ipados(version):
        return emit_final(False, "unsupported_ipados", model=model, ipados=version)
    from pymobiledevice3.lockdown import create_using_usbmux
    if not paired:
        try:
            client = await create_using_usbmux(serial=serial, connection_type="USB", autopair=True,
                                               pair_timeout=TRUST_TIMEOUT, pairing_records_cache_folder=cache,
                                               usbmux_address=USBMUX)
            await client.close()
        except BaseException:
            return emit_final(False, "trust_needed", model=model, ipados=version)
    client = await lockdown_for(serial, cache)
    async with client:
        if not client.paired:
            return emit_final(False, "trust_needed", model=model, ipados=version)
        udid = client.udid
        try:
            developer_mode = await client.get_developer_mode_status()
        except Exception:
            developer_mode = False
        if not developer_mode:
            devmode = {}
            outcome = await try_enable_developer_mode(client, diagnostics=devmode, state=state,
                                                      model=model, ipados=version)
            code = {"rebooting": "developer_mode_auto", "manual": "developer_mode_needed",
                    "locked": "unlock_needed"}[outcome]
            return emit_final(False, code, model=model, ipados=version, **devmode)
    code = await finish_pairing(state, serial, cache, udid, model, version)
    return emit_final(code == "ready", code, model=model, ipados=version)


def exit_with_parent(poll_seconds=1.0):
    """End this process when Toss goes away, even inside a long pairing step.

    Same effect as the SIGTERM Toss sends when it stops setup itself; this covers a crash or a
    quit that never sent it. Nobody is left to read the result, so there is nothing to report.
    """
    parent = os.getppid()
    if parent <= 1:  # Toss was already gone while Python was starting.
        os._exit(0)

    def watch():
        while os.getppid() == parent:
            time.sleep(poll_seconds)
        os._exit(0)

    threading.Thread(target=watch, daemon=True).start()


def main(argv=None):
    os.umask(0o077)
    exit_with_parent()
    parser = once.QuietParser(description=__doc__)
    parser.add_argument("action", choices=["auto", "next", "prepare"])
    parser.add_argument("--state-dir", type=Path, required=True)
    args = parser.parse_args(argv)
    # Library logging must never reach the JSON lines on stdout.
    original = os.dup(1)
    null = os.open(os.devnull, os.O_WRONLY)
    os.dup2(null, 1)
    os.dup2(null, 2)
    os.close(null)
    sys.stdout = os.fdopen(original, "w")
    once.logging.disable(once.logging.CRITICAL)
    try:
        if args.action == "prepare":
            state = private_state(args.state_dir)
            if not has_pairing(state):
                emit_final(False, "not_paired")
                return 1
            use_private_cache(state)
            code = asyncio.run(wifi_prepare_with_retries(state))
            emit_final(code == "ready", code)
        elif args.action == "auto":
            asyncio.run(auto(args.state_dir))
        else:
            asyncio.run(next_step(args.state_dir))
        return 0
    except BaseException:
        emit_final(False, "setup_failed")
        return 1


if __name__ == "__main__":
    sys.exit(main())
