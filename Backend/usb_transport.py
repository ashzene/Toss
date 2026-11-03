"""Pinned-device USB only. No discovery on the LAN, pairing, or capture on import."""
from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager, suppress
import fcntl
import importlib.metadata
import json
import os
from pathlib import Path
import stat

import capture_once as once
import link_timeline
from ipad_probe import ProbeFailure, fingerprint
from remote_pairing_transport import configure, load_record

LIBRARY_VERSION = "11.31.0"
USBMUX_SOCKET = "/var/run/usbmuxd"


def pinned_identity(state):
    once.check_state(Path(state))
    pin = json.loads((Path(state) / "target.json").read_text())
    if not isinstance(pin.get("model"), str) or not pin["model"].startswith("iPad"):
        raise ProbeFailure("unexpected_device_pin")
    record = load_record(Path(state), pin)
    if record is None:
        raise ProbeFailure("initial_usb_remote_pairing_required")
    return record["pinned_udid"], pin["device_hash"]


def is_pinned_usb(device, serial, device_hash):
    return (device.is_usb and device.serial == serial
            and fingerprint(device.serial) == device_hash)


def supported_usb_version(value):
    try:
        parts = str(value).split(".")
        return (int(parts[0]), int(parts[1]) if len(parts) > 1 else 0) >= (17, 4)
    except (ValueError, TypeError):
        return False


def require_library_version():
    if importlib.metadata.version("pymobiledevice3") != LIBRARY_VERSION:
        raise ProbeFailure("unexpected_library_version")


async def _create_usb_client(serial, cache):
    """Own the socket before initialization, including task cancellation.

    11.31.0's create_using_usbmux only catches Exception after opening the
    service, so CancelledError during initialization bypasses its close().
    Use its client constructor with the same BUID selection, but retain the
    service here until the fully initialized client takes ownership.
    """
    from pymobiledevice3 import lockdown, usbmux

    service = await lockdown.ServiceConnection.create_using_usbmux(
        serial, lockdown.SERVICE_PORT, connection_type="USB", usbmux_address=USBMUX_SOCKET)
    try:
        client_type = lockdown.UsbmuxLockdownClient
        buid = lockdown.SYSTEM_BUID
        async with await usbmux.create_mux(usbmux_address=USBMUX_SOCKET) as mux:
            if isinstance(mux, lockdown.PlistMuxConnection):
                buid = await mux.get_buid()
                client_type = lockdown.PlistUsbmuxLockdownClient
        return await client_type.create(
            service, identifier=serial, system_buid=buid, autopair=False,
            pairing_records_cache_folder=cache, usbmux_address=USBMUX_SOCKET)
    except BaseException:
        await service.close()
        raise


@asynccontextmanager
async def open_usb_rsd(state):
    require_library_version()
    state, pin, cache = configure(Path(state))
    serial, device_hash = pinned_identity(state)
    from pymobiledevice3 import usbmux
    from pymobiledevice3.remote import userspace_tunnel as us, tunnel_service as ts

    # Keep the upstream singleton protection as well as the Wi-Fi path's guard.
    if us._active_tunnel is not None or ts.USE_USERSPACE_TUNNEL:
        raise ProbeFailure("another_userspace_tunnel_active_in_process")
    devices = await usbmux.list_devices(usbmux_address=USBMUX_SOCKET)
    if sum(is_pinned_usb(d, serial, device_hash) for d in devices) != 1:
        raise ProbeFailure("exact_pinned_usb_device_required")

    async def usb_only_factory(*, serial=None, autopair=True):
        # 11.31.0's factory otherwise permits usbmux Network devices. Patch only
        # this worker's module symbol for aopen(), never asyncio or the package.
        if serial != expected_serial or autopair is not False:
            raise ProbeFailure("unexpected_device_pin")
        client = await _create_usb_client(serial, cache)
        try:
            if (not client.paired or client.udid != expected_serial
                    or fingerprint(client.udid) != device_hash
                    or client.product_type != pin["model"]):
                raise ProbeFailure("rsd_device_identity_mismatch")
            if not supported_usb_version(client.product_version):
                raise ProbeFailure("usb_ipados_unsupported")
            return client
        except BaseException:
            await client.close()
            raise

    expected_serial = serial
    original = us.create_using_usbmux
    tunnel = us.UserspaceRsdTunnel(serial=serial, autopair=False, remotepairing_fallback=False)
    progress_link = None
    try:
        us.create_using_usbmux = usb_only_factory
        try:
            rsd = await tunnel.aopen()
        finally:
            us.create_using_usbmux = original
        if rsd.udid != serial or fingerprint(rsd.udid) != device_hash:
            raise ProbeFailure("rsd_device_identity_mismatch")
        # Same inbound-byte watchdog as Wi-Fi. USB has no outer TCP counters.
        # Construct directly: a missing hook must fail, not disable the watchdog.
        progress_link = link_timeline.Link(tunnel.tun, None, allow_size_prediction=False)
        link_timeline._current = progress_link
        yield rsd, {"transport": "authenticated_usb", "root_used": False}
    finally:
        try:
            await tunnel.aclose()
        finally:
            if progress_link is not None and link_timeline._current is progress_link:
                link_timeline._current = None


async def watch_usb(state, emit, *, mux_factory=None, list_devices=None, retry_seconds=1):
    """Listen on the local usbmux socket in the existing Wi-Fi worker. No polling
    of the iPad, lockdownd calls, extra processes, or screenshot requests.
    """
    if mux_factory is None or list_devices is None:
        from pymobiledevice3 import usbmux
        mux_factory = mux_factory or usbmux.create_mux
        list_devices = list_devices or usbmux.list_devices
    previous = None
    while True:
        mux = None
        try:
            # Read inside the retry loop: a pairing written later (or a transient read error)
            # must not end the watcher for the life of the Wi-Fi worker.
            serial, device_hash = pinned_identity(state)
            async with asyncio.timeout(2):
                mux = await mux_factory(usbmux_address=USBMUX_SOCKET)
                # Subscribe before taking the snapshot; queued attach/detach
                # events cover changes while the second socket lists devices.
                await mux.listen()
                mux.devices = list(await list_devices(usbmux_address=USBMUX_SOCKET))
            while True:
                present = any(is_pinned_usb(d, serial, device_hash) for d in mux.devices)
                if present != previous:
                    await emit({"schema_version": 1, "event": "usb_presence", "present": present})
                    previous = present
                await mux.receive_device_state_update()
        except asyncio.CancelledError:
            raise
        except Exception:
            # An observer failure is not evidence that a healthy USB tunnel
            # unplugged. Its own transport watcher detects that independently.
            await asyncio.sleep(retry_seconds)
        finally:
            if mux is not None:
                with suppress(Exception):
                    await mux.close()


@asynccontextmanager
async def developer_image_lock(state):
    """Cross-process per-pairing-state lock; cancellation never leaves it held."""
    once.check_state(Path(state))
    fd = os.open(Path(state) / "developer-image.lock",
                 os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or stat.S_IMODE(info.st_mode) != 0o600):
            raise once.CaptureFailure("state_not_private")
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                await asyncio.sleep(0.05)
        yield
    finally:
        os.close(fd)
