"""Bounded AMFI enable retries and private setup diagnostics (no UI policy)."""
from __future__ import annotations

import asyncio
from contextlib import AsyncExitStack
import json
from pathlib import Path
import re
import time
import unicodedata
from urllib.parse import quote

ENABLE_ATTEMPTS = 3
RETRY_SECONDS = (2, 4)
REQUEST_TIMEOUT = 10
UNLOCK_POLL_SECONDS = 1.5
UNLOCK_TIMEOUT = 90
ERROR_LIMIT = 200


def safe_error(error, client=None) -> str:
    """Redact before truncating, including cached names/IDs and escaped forms."""
    from pymobiledevice3.exceptions import DeviceHasPasscodeSetError

    message = str(error)
    if not message and isinstance(error, DeviceHasPasscodeSetError):
        # 11.31.0 discards this exact AMFI reply when constructing the exception.
        message = "Device has a passcode set"
    message = unicodedata.normalize("NFKC", message)
    values = getattr(client, "all_values", {})
    values = values if isinstance(values, dict) else {}
    secrets = [values.get(key) for key in
               ("DeviceName", "UniqueDeviceID", "SerialNumber", "WiFiAddress", "BluetoothAddress")]
    secrets += [getattr(client, key, None) for key in ("udid", "identifier", "serial", "device_name")]
    variants = set()
    for value in secrets:
        if isinstance(value, str) and value:
            # JSON/URL escapes are ASCII, so normalizing the error cannot
            # normalize their contents. Keep escapes of both original and NFKC.
            for form in (value, unicodedata.normalize("NFKC", value)):
                variants.update((unicodedata.normalize("NFKC", form), json.dumps(form)[1:-1],
                                 repr(form)[1:-1], quote(form, safe="")))
    if variants:
        # One substitution also avoids re-matching a short name inside the marker.
        pattern = "|".join(re.escape(value) for value in sorted(variants, key=len, reverse=True))
        message = re.sub(pattern, "[redacted]", message, flags=re.IGNORECASE)
    # Also cover labelled identities when a failed handshake has no cached name.
    message = re.sub(
        r'''(?i)(\b(?:DeviceName|device_name|device name|UniqueDeviceID|UDID|SerialNumber|Identifier)\b["']?\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^,;\n}\]]+)''',
        r"\1[redacted]", message)
    message = re.sub(
        r"(?i)\b(?:[0-9a-f]{8}-[0-9a-f]{16}|[0-9a-f]{40}|[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})\b",
        "[redacted]", message)
    # Quoted paths can contain spaces. For ambiguous unquoted paths, discard
    # through the next delimiter rather than leak a trailing folder/device name.
    message = re.sub(r'''"[^"\r\n]*[/\\][^"\r\n]*"|'[^'\r\n]*[/\\][^'\r\n]*' ''',
                     "[path]", message, flags=re.VERBOSE)
    message = re.sub(
        r'''(?<![\w])(?:[A-Za-z]:[\\/]|(?:file://)?/|~[/\\]|\.\.?[/\\]|\\\\)[^,;\r\n"']*''',
        "[path]", message)
    message = re.sub(r'''\b[\w.-]+[/\\][^\s,;<>"']+''', "[path]", message)
    message = " ".join(message.split())
    name = re.sub(r"[^A-Za-z0-9_]", "", type(error).__name__)[:64] or "Exception"
    return f"{name}: {message}"[:ERROR_LIMIT]


def needs_unlock(error) -> bool:
    from pymobiledevice3.exceptions import PasswordRequiredError

    if isinstance(error, PasswordRequiredError):
        return True
    return bool(re.search(r"\b(?:DeviceLocked|PasswordProtected|device (?:is )?locked|please unlock)\b",
                          str(error), flags=re.IGNORECASE))


async def service_locked(client):
    """Use lockdownd's actual StartService gate, never the passcode-set flag.

    None means unavailable/unknown, not proof that the device is unlocked.
    No AMFI enable action is sent by this probe.
    """
    from pymobiledevice3.services.amfi import AmfiService

    try:
        async with asyncio.timeout(REQUEST_TIMEOUT):
            await client.get_service_connection_attributes(AmfiService.SERVICE_NAME)
        return False
    except Exception as error:
        return True if needs_unlock(error) else None


async def wait_for_unlock(client, deadline, progress, fields, *, locked):
    if locked:
        progress(False, "unlock_needed", final=False, **fields)
    status = await service_locked(client)
    if not locked and status is not True:
        return True
    if not locked:
        progress(False, "unlock_needed", final=False, **fields)
    while status is True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return False
        await asyncio.sleep(min(UNLOCK_POLL_SECONDS, remaining))
        status = await service_locked(client)
    # The gate has opened, or the transport has gone away. In the latter case
    # the next bounded attempt reconnects; it does not claim an unlock occurred.
    return time.monotonic() < deadline


def record_failure(error, client, diagnostics, state, attempt):
    from pymobiledevice3.exceptions import DeviceHasPasscodeSetError

    diagnostics.update(devmode_enable_error=safe_error(error, client),
                       devmode_passcode=int(isinstance(error, DeviceHasPasscodeSetError)))
    if state is not None:
        # Same bounded, owner-only Backend log and writer used by capture_service.
        # This survives main() suppressing stderr and third-party logging.
        from link_timeline import append_log
        append_log(Path(state).parent / "link-timeline.jsonl",
                   {"event": "devmode_enable_failed", "devmode_attempt": attempt, **diagnostics})


class RevealFailures:
    """Per setup run; independent of enable's diagnostics and bounded on disk."""
    def __init__(self):
        self.last_error = None
        self.answered = False

    def record_answer(self, state):
        if not self.answered and state is not None:
            from link_timeline import append_log
            append_log(Path(state).parent / "link-timeline.jsonl", {"event": "devmode_reveal_ok"})
        self.answered = True

    def record(self, error, client, state):
        message = safe_error(error, client)
        if message == self.last_error:
            return
        self.last_error = message
        if state is not None:
            from link_timeline import append_log
            append_log(Path(state).parent / "link-timeline.jsonl",
                       {"event": "devmode_reveal_failed", "devmode_reveal_error": message})


async def reveal(client, *, state=None, failures=None) -> bool:
    from pymobiledevice3.services.amfi import AmfiService

    failures = failures if failures is not None else RevealFailures()
    try:
        async with asyncio.timeout(REQUEST_TIMEOUT):
            await AmfiService(client).reveal_developer_mode_option_in_ui()
        failures.last_error = None
        return True
    except Exception as error:
        failures.record(error, client, state)
        return False


class RevealRepeater:
    """One bounded request in flight; tick never waits on AMFI or a reconnect.

    Own a separate client so the 1.5 s status loop can close its client safely.
    The owner must close this repeater before finishing or leaving setup.
    """
    def __init__(self, state):
        self.state = state
        self.failures = RevealFailures()
        self.next_at = 0.0
        self.task = None

    async def first(self, client):
        """Awaited before the guide says to look; the repeats start 3 s after it."""
        answered = await self._reveal(client)
        self.next_at = time.monotonic() + 3.0
        return answered

    async def _reveal(self, client):
        answered = await reveal(client, state=self.state, failures=self.failures)
        if answered:
            self.failures.record_answer(self.state)
        return answered

    def tick(self, reconnect):
        now = time.monotonic()
        if now < self.next_at or (self.task is not None and not self.task.done()):
            return
        self.next_at = now + 3.0
        self.task = asyncio.create_task(self._request(reconnect))

    async def _request(self, reconnect):
        client = None
        try:
            async with asyncio.timeout(REQUEST_TIMEOUT):
                client = await reconnect()
                async with client:
                    await self._reveal(client)
        except Exception as error:
            self.failures.record(error, client, self.state)

    async def close(self):
        if self.task is not None:
            self.task.cancel()
            try:
                await self.task
            except asyncio.CancelledError:
                pass
            self.task = None


async def enable(client, *, progress, diagnostics, state=None, reconnect=None,
                 model=None, ipados=None, deadline=None, revealer=None) -> str:
    """Return rebooting/manual/locked; at most three enable attempts in total."""
    from pymobiledevice3.exceptions import DeviceHasPasscodeSetError
    from pymobiledevice3.services.amfi import AmfiService

    if deadline is None:
        deadline = time.monotonic() + UNLOCK_TIMEOUT
    for attempt in range(ENABLE_ATTEMPTS):
        if attempt:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return "locked"
            await asyncio.sleep(min(RETRY_SECONDS[attempt - 1], remaining))
            if time.monotonic() >= deadline:
                return "locked"
        current = client
        async with AsyncExitStack() as stack:
            try:
                async with asyncio.timeout(REQUEST_TIMEOUT):
                    if attempt and reconnect is not None:
                        current = await stack.enter_async_context(await reconnect())
                    await AmfiService(current).enable_developer_mode(enable_post_restart=False)
                return "rebooting"
            except Exception as error:
                record_failure(error, current, diagnostics, state, attempt + 1)
                if isinstance(error, DeviceHasPasscodeSetError) or attempt == ENABLE_ATTEMPTS - 1:
                    if revealer is None:
                        await reveal(current, state=state)
                    else:
                        # Settings reads the row when it opens, so the guide must not say to
                        # look before iPadOS has answered. auto owns the asynchronous repeats
                        # after this; next_step awaits one reveal before its manual instruction.
                        await revealer.first(current)
                    return "manual"
                if not await wait_for_unlock(current, deadline, progress,
                                             {"model": model, "ipados": ipados, **diagnostics},
                                             locked=needs_unlock(error)):
                    return "locked"
    return "manual"  # Defensive only; the last failed attempt returns above.
