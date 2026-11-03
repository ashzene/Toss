"""Passive per-transfer timeline of the Wi-Fi link (2026-10-25, measurement only).

Records when tunnel packets arrive from the iPad while one screenshot RPC is in flight, and
samples the outer TLS/TCP socket's kernel counters (macOS TCP_CONNECTION_INFO) every 50 ms.
Nothing is sent, delayed or changed: the hook timestamps packets on their way into the
userspace stack and passes them through untouched. It separates the steady part of a
transfer (first byte, throughput) from stalls (gaps >= 200 ms with no data), and keeps what
the outer socket looked like during the longest stall (send-buffer bytes, including in-flight,
retransmissions, out-of-order bytes from the iPad). Metadata only: no payload is kept.
"""
from __future__ import annotations

import asyncio
import contextlib
import json
import importlib.metadata
import os
import socket
import struct
import time
import weakref

STALL = 0.2               # a gap with no inbound data this long counts as a stall
DATA_MIN = 200            # smaller inbound packets are ACKs/keepalives, not screenshot data
SAMPLE = 0.05             # outer socket counters sampled this often during a transfer
BIN = 0.05                # throughput curve resolution in the detailed log
TCP_CONNECTION_INFO = 0x106
LOG_LINES = 300

_current = None           # the one tunnel this worker process owns
expected_bytes = 420 * 1024   # size of the next frame: the last complete transfer (inbound bytes)
RATE_WINDOW = 0.6             # judge a stretch of data only after it has lasted this long
FLOWING = 0.25                # ...and only while data arrived this recently


def projected_finish(first, now, got, expected):
    """When the transfer would end at its current rate (monotonic), or None if unknown."""
    if first is None or now <= first or got <= 0:
        return None
    if got >= expected:
        return now
    return now + (expected - got) / (got / (now - first))
last_summary = None       # the latest finished transfer's summary (one RPC at a time)


def socket_info(sock):
    """Outer socket counters, or None if the kernel call is unavailable."""
    if sock is None:
        return None
    try:
        raw = sock.getsockopt(socket.IPPROTO_TCP, TCP_CONNECTION_INFO, 112)
        state = struct.unpack_from("<4B12I", raw, 0)
        counters = struct.unpack_from("<7Q", raw, 56)
    except (OSError, struct.error, ValueError):
        return None
    # tcpi_snd_sbbytes includes in-flight data; historical key "unsent" is not an ACK counter.
    return {"rto": state[6], "unsent": state[11], "rtt": state[13], "rttvar": state[15],
            "tx_packets": counters[0], "rx_bytes": counters[4], "rx_ooo_bytes": counters[5],
            "tx_retx_packets": counters[6]}


# The read wrapper is installed before DVT starts its idle reader. It remains a
# pass-through unless an active screenshot registers that exact StreamReader.
# No fragment payload, device identifier, endpoint or pairing data is retained.
_rpc_recordings = weakref.WeakKeyDictionary()
_rpc_hook_installed = False
MAX_RPC_FRAGMENTS = 4096


def install_rpc_hook():
    """Best-effort instrumentation for the pinned 11.31.0 fragment reader API."""
    global _rpc_hook_installed
    if _rpc_hook_installed:
        return True
    try:
        if importlib.metadata.version("pymobiledevice3") != "11.31.0":
            return False
        from pymobiledevice3.dtx.fragment import DTXFragment
        original = DTXFragment.read

        async def read(stream):
            started = time.monotonic()
            fragment = await original(stream)
            recording = _rpc_recordings.get(stream)
            if recording is not None:
                with contextlib.suppress(Exception):
                    recording.fragment(fragment, started, time.monotonic())
            return fragment
        DTXFragment.read = staticmethod(read)
        _rpc_hook_installed = True
        return True
    except (ImportError, AttributeError, importlib.metadata.PackageNotFoundError):
        return False


class RPCRecording:
    """Completed DTX reply fragment timings, distinct from tunnel packet progress.

    The screenshot channel has one in-flight RPC. An uncertain RPC always retires
    that session, so no former screenshot response can enter a later recording.
    """
    def __init__(self, screenshot, started):
        self.started = started
        self.fragments = []
        self.reader = None
        self.channel = None
        self.dtx = None
        self.dropped = 0
        with contextlib.suppress(AttributeError, TypeError, RuntimeError):
            reader = screenshot.dtx._reader
            channel = screenshot.service._channel.code
            if _rpc_hook_installed and isinstance(channel, int):
                self.reader, self.channel = reader, channel
                self.dtx = screenshot.dtx
                _rpc_recordings[reader] = self

    def fragment(self, fragment, read_started, ended):
        if fragment.channel_code != self.channel or fragment.conversation_index != 1:
            return
        if fragment.identifier not in getattr(self.dtx, "_pending_replies", {}):
            return  # Uncorrelated/duplicate replies are not the active RPC.
        if len(self.fragments) >= MAX_RPC_FRAGMENTS:
            self.dropped += 1
            return
        self.fragments.append({"index": fragment.index, "count": fragment.count,
            "bytes": len(fragment.payload), "declared_bytes": fragment.data_size,
            "at_ms": round(max(0, ended - self.started) * 1000, 3),
            "read_ms": round(max(0, ended - max(read_started, self.started)) * 1000, 3)})

    def progress(self, now):
        if not self.fragments:
            return None
        first = self.fragments[0]
        expected = first["declared_bytes"] if first["index"] == 0 else 0
        return {"rpc_received_bytes": sum(f["bytes"] for f in self.fragments),
                "expected_bytes": expected}

    def finish(self):
        if self.reader is not None and _rpc_recordings.get(self.reader) is self:
            del _rpc_recordings[self.reader]
        return {"rpc_fragments_available": self.reader is not None,
                "rpc_fragments": self.fragments, "rpc_fragments_dropped": self.dropped}


class Link:
    """Timestamps one tunnel's inbound packets while a transfer is being recorded."""

    def __init__(self, tun, sock, *, allow_size_prediction=True):
        self.sock = sock
        self.allow_size_prediction = allow_size_prediction
        self.packets = None
        original = tun.write

        def write(data):
            if self.packets is not None:
                self.packets.append((time.monotonic(), len(data)))
            return original(data)
        tun.write = write


def attach(tunnel, sock):
    """Called once the tunnel is up (vendor/remote_pairing_transport.py)."""
    global _current
    with contextlib.suppress(Exception):
        _current = Link(tunnel.tun, sock)


class Recording:
    def __init__(self):
        self.link = _current
        self.started = time.monotonic()
        self.samples = []
        self.sampler = None
        if self.link is not None:
            self.link.packets = []
            self.samples.append((self.started, socket_info(self.link.sock)))
            self.sampler = asyncio.ensure_future(self._sample())

    async def _sample(self):
        with contextlib.suppress(asyncio.CancelledError):
            while True:
                await asyncio.sleep(SAMPLE)
                self.samples.append((time.monotonic(), socket_info(self.link.sock)))

    def progress(self, now, first_byte_limit, stall_limit, deadline=None):
        """Advisory only: packet silence is not proof that TCP disconnected."""
        data = [(t, n) for t, n in (self.link.packets or []) if n >= DATA_MIN] if self.link else []
        return {"elapsed_ms": max(0, (now - self.started) * 1000),
                "received_bytes": sum(n for _, n in data),
                "idle_ms": max(0, (now - (data[-1][0] if data else self.started)) * 1000),
                "reason": self.verdict(now, first_byte_limit, stall_limit, deadline) or "progress",
                "source": "tunnel" if self.link is not None else "unknown"}

    def verdict(self, now, first_byte_limit, stall_limit, deadline=None):
        """Advisory progress rules: None while the transfer can still make it.
        No first byte in time, a stall, or (17:47, after 10 slow-but-moving transfers were cut at a
        fixed 2 s) a transfer whose current rate cannot finish it by `deadline` (too_slow)."""
        if self.link is None or self.link.packets is None:
            return None
        first = last = flow_start = None
        got = flow_got = 0
        for t, n in self.link.packets:
            if n < DATA_MIN:
                continue
            if last is None or t - last > FLOWING:
                flow_start, flow_got = t, 0          # a new uninterrupted stretch of data
            first = t if first is None else first
            last = t
            got += n
            flow_got += n
        if last is None:
            return "first_byte_timeout" if now - self.started >= first_byte_limit else None
        if now - last >= stall_limit:
            return "stall_timeout"
        # The rate of the current uninterrupted stretch only, once it has lasted RATE_WINDOW; pauses
        # are the stall rule's job (17:15: a 1.1 s pause, then done at 1.5 s, must not count as slow).
        if now - last > FLOWING or now - flow_start < RATE_WINDOW:
            return None
        rate = flow_got / (now - flow_start)
        self.projected = now + max(0, expected_bytes - got) / rate if rate > 0 else None
        # The previous screenshot's size is only a guess. USB has no calibrated
        # size/rate model: a large previous frame must not abort a small current
        # frame that is still making progress. Keep the estimate for diagnostics;
        # first-byte/stall checks and the caller's real deadline remain active.
        if (getattr(self.link, "allow_size_prediction", True)
                and deadline is not None and self.projected is not None and self.projected > deadline):
            return "too_slow"
        return None

    def finish(self, outcome):
        """Stops recording; returns (summary for timings_ms, detailed line) or (None, None)."""
        if self.link is None:
            return None, None
        ended = time.monotonic()
        packets, self.link.packets = self.link.packets or [], None
        if self.sampler is not None:
            self.sampler.cancel()
        self.samples.append((ended, socket_info(self.link.sock)))
        global last_summary, expected_bytes
        summary, detail = summarize(self.started, ended, packets, self.samples, outcome)
        if outcome == "ok" and summary["link_rx_kb"] > 20:
            expected_bytes = summary["link_rx_kb"] * 1024
        if getattr(self, "projected", None) is not None and outcome != "ok":
            summary["link_projected_finish"] = (self.projected - self.started) * 1000
            detail["projected_finish_ms"] = round(summary["link_projected_finish"])
        last_summary = summary
        return summary, detail


def summarize(started, ended, packets, samples, outcome):
    data = [(t, n) for t, n in packets if n >= DATA_MIN]
    first = data[0][0] if data else None
    last = data[-1][0] if data else None
    stalls = []
    previous = first
    for t, _ in data[1:]:
        if t - previous >= STALL:
            stalls.append((previous, t))
        previous = t
    if last is not None and ended - last >= STALL and outcome != "ok":
        stalls.append((last, ended))   # still stalled when the attempt ended
    if first is None and ended - started >= STALL:
        stalls.append((started, ended))
    longest = max(stalls, key=lambda s: s[1] - s[0], default=None)

    def during(window):
        inside = [info for t, info in samples if info and window[0] <= t <= window[1]]
        return inside[len(inside) // 2] if inside else None

    infos = [info for _, info in samples if info]
    begin, end = (infos[0], infos[-1]) if infos else (None, None)
    rx = sum(n for _, n in data)
    summary = {
        "link_first_byte": (first - started) * 1000 if first else (ended - started) * 1000,
        "link_rx_kb": rx / 1024,
        "link_stalls": float(len(stalls)),
        "link_stall_max": (longest[1] - longest[0]) * 1000 if longest else 0.0,
        "link_stall_total": sum(b - a for a, b in stalls) * 1000,
    }
    if begin and end:
        summary["link_rx_ooo_kb"] = (end["rx_ooo_bytes"] - begin["rx_ooo_bytes"]) / 1024
        summary["link_tx_retx"] = float(end["tx_retx_packets"] - begin["tx_retx_packets"])
        summary["link_rtt"] = float(max(i["rtt"] for i in infos))
    stalled = during(longest) if longest else None
    if stalled:
        summary["link_stall_unsent"] = float(stalled["unsent"])
        summary["link_stall_rto"] = float(stalled["rto"])
    curve = {}
    for t, n in data:
        slot = int((t - started) / BIN)
        curve[slot] = curve.get(slot, 0) + n
    detail = {"outcome": outcome, "duration_ms": round((ended - started) * 1000, 1),
              **{k: round(v, 1) for k, v in summary.items()},
              "stalls_ms": [[round((a - started) * 1000), round((b - a) * 1000)] for a, b in stalls],
              "curve_kb_per_50ms": [round(curve.get(i, 0) / 1024, 1)
                                    for i in range(int((ended - started) / BIN) + 1)],
              "socket_at_stall": stalled, "socket_begin": begin, "socket_end": end}
    return summary, detail


def append_log(path, line):
    """Keeps the last LOG_LINES transfers in an owner-only JSONL file next to the state dir."""
    with contextlib.suppress(Exception):
        line = {"time": time.strftime("%Y-%m-%dT%H:%M:%S%z"), **line}
        lines = []
        with contextlib.suppress(FileNotFoundError):
            with open(path, encoding="utf-8") as existing:
                lines = existing.read().splitlines()[-(LOG_LINES - 1):]
        lines.append(json.dumps(line, separators=(",", ":")))
        temporary = f"{path}.tmp"
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as out:
            out.write("\n".join(lines) + "\n")
        os.replace(temporary, path)
