"""Small, private history of successful screenshot RPC durations, shared by workers.

The atomic JSON is deliberately independent of capture-history.jsonl. A malformed,
oversized, non-private or missing file means no samples, never a capture failure.
"""
from __future__ import annotations

import contextlib
from dataclasses import dataclass
import fcntl
import json
import math
import os
from pathlib import Path
import stat
import tempfile
import time

MAX_BYTES = 128 * 1024
MAX_SAMPLES = 200
WINDOW = 100
MAX_TRANSFER_BUDGET = 30.0


@dataclass(frozen=True)
class Threshold:
    seconds: float
    count: int
    maximum: float


# Floors (Claude review 2026-10-28): the picture size varies, the connection does not. A 16-bit 11 MB
# frame takes ~0.8 s over USB (814 ms seen) while 8-bit frames take ~0.15 s; over the owner's usual Wi-Fi
# (median ~10 MB/s, ~0.5 s before the first byte) it would take ~2.1 s, never yet observed. So a
# history of small frames must not fail big ones. A silence-based T is the planned replacement.
USB_FLOOR = 2.5
WIFI_FLOOR = 2.5


def threshold(samples, transport):
    recent = samples[-WINDOW:]
    count = len(recent)
    maximum = max((row["seconds"] for row in recent), default=0.0)
    seconds = 4.5 if count < 10 else min(4.5, max(
        USB_FLOOR if transport == "usb" else WIFI_FLOOR, maximum + max(0.25, maximum * 0.2)))
    return Threshold(seconds, count, maximum)


class SuccessTimingStore:
    def __init__(self, path):
        self.path = Path(path)

    @staticmethod
    def _private_regular(info):
        return (stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid()
                and stat.S_IMODE(info.st_mode) == 0o600)

    def load(self):
        empty = {"usb": [], "wifi": []}
        try:
            fd = os.open(self.path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(fd, "rb") as handle:
                info = os.fstat(handle.fileno())
                if not self._private_regular(info) or info.st_size > MAX_BYTES:
                    return empty
                value = json.loads(handle.read(MAX_BYTES + 1))
            if (not isinstance(value, dict) or type(value.get("schema_version")) is not int
                    or value["schema_version"] != 1
                    or set(value) != {"schema_version", "usb", "wifi"}):
                return empty
            for lane in ("usb", "wifi"):
                rows = value[lane]
                if not isinstance(rows, list) or len(rows) > MAX_SAMPLES:
                    return empty
                for row in rows:
                    if not isinstance(row, dict) or set(row) != {"seconds", "timestamp"}:
                        return empty
                    if any(type(row[key]) not in (float, int) or not math.isfinite(row[key])
                           for key in ("seconds", "timestamp")):
                        return empty
                    if not 0 <= row["seconds"] <= MAX_TRANSFER_BUDGET or row["timestamp"] <= 0:
                        return empty
            return {lane: sorted(value[lane], key=lambda row: row["timestamp"]) for lane in ("usb", "wifi")}
        except (OSError, ValueError, TypeError, RecursionError):
            return empty

    def threshold(self, transport):
        return threshold(self.load()[transport], transport)

    def record(self, transport, seconds, timestamp=None):
        """Best-effort durable write; no unbounded lock wait on the capture path."""
        timestamp = time.time() if timestamp is None else timestamp
        if (transport not in ("usb", "wifi") or type(seconds) not in (float, int)
                or not math.isfinite(seconds) or not 0 <= seconds <= MAX_TRANSFER_BUDGET
                or type(timestamp) not in (float, int) or not math.isfinite(timestamp) or timestamp <= 0):
            return False
        lock_fd = None
        staging = None
        try:
            parent = self.path.parent.lstat()
            if (not stat.S_ISDIR(parent.st_mode) or parent.st_uid != os.geteuid()
                    or stat.S_IMODE(parent.st_mode) & 0o077):
                return False
            lock_fd = os.open(str(self.path) + ".lock",
                             os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
            if not self._private_regular(os.fstat(lock_fd)):
                return False
            until = time.monotonic() + 0.1
            while True:
                try:
                    fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= until:
                        return False
                    time.sleep(0.002)
            value = self.load()
            value[transport] = sorted(value[transport] + [{"seconds": float(seconds),
                "timestamp": float(timestamp)}], key=lambda row: row["timestamp"])[-MAX_SAMPLES:]
            payload = json.dumps({"schema_version": 1, **value}, allow_nan=False,
                                 separators=(",", ":")).encode()
            fd, staging = tempfile.mkstemp(prefix=".screenshot-success-times-", dir=self.path.parent)
            with os.fdopen(fd, "wb") as handle:
                os.fchmod(handle.fileno(), 0o600)
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(staging, self.path)
            staging = None
            directory_fd = os.open(self.path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
            return True
        except (OSError, ValueError):
            return False
        finally:
            if staging is not None:
                with contextlib.suppress(OSError):
                    os.unlink(staging)
            if lock_fd is not None:
                os.close(lock_fd)


class TransferBudget:
    """A fixed press origin, extended only by observed incoming data; never by ETA."""
    def __init__(self, started, normal=4.5, hard=MAX_TRANSFER_BUDGET, stall=1.2):
        self.normal_end = started + normal
        self.hard_end = started + hard
        self.stall = stall
        self.received = 0
        self.last_byte = None

    def observe(self, now, received, idle_ms=0):
        if received > self.received:
            self.received = received
            self.last_byte = now - max(0, idle_ms) / 1000

    @property
    def deadline(self):
        flowing_end = self.last_byte + self.stall if self.last_byte is not None else self.normal_end
        return min(self.hard_end, max(self.normal_end, flowing_end))
