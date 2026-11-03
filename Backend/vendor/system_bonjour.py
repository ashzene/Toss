"""Bounded macOS DNS-SD discovery, using the system mDNSResponder client API.

No subprocesses, persistent cache, arbitrary DNS names, subnet scanning, or device
sessions. Results are discovery hints; the transport MUST still authenticate its
peer. No discovery starts on import. Addresses/TXT records are never printed.
"""
from __future__ import annotations

import asyncio
from contextlib import suppress
import ctypes as C
from dataclasses import dataclass, field
import ipaddress
import socket
import sys
import time
from typing import Callable, Sequence

from ipad_probe import ProbeFailure

ADD = 0x2
MORE_COMING = 0x1
FORCE_MULTICAST = 0x400
IPV4_AND_IPV6 = 0x3

# ABI declarations come from the installed macOS SDK usr/include/dns_sd.h:
# DNSServiceBrowseReply, DNSServiceResolveReply, DNSServiceGetAddrInfoReply.
BrowseReply = C.CFUNCTYPE(None, C.c_void_p, C.c_uint32, C.c_uint32, C.c_int32,
                          C.c_char_p, C.c_char_p, C.c_char_p, C.c_void_p)
ResolveReply = C.CFUNCTYPE(None, C.c_void_p, C.c_uint32, C.c_uint32, C.c_int32,
                           C.c_char_p, C.c_char_p, C.c_uint16, C.c_uint16,
                           C.c_void_p, C.c_void_p)
AddrReply = C.CFUNCTYPE(None, C.c_void_p, C.c_uint32, C.c_uint32, C.c_int32,
                        C.c_char_p, C.c_void_p, C.c_uint32, C.c_void_p)


def parse_txt(data: bytes) -> dict[str, str]:
    """Decode bounded RFC 6763 TXT data; ambiguous duplicate keys are rejected."""
    if len(data) > 4096:
        raise ProbeFailure("dns_sd_txt_too_large")
    result, seen = {}, set()
    offset = 0
    while offset < len(data):
        size = data[offset]
        offset += 1
        if offset + size > len(data):
            raise ProbeFailure("dns_sd_txt_truncated")
        item = data[offset:offset + size]
        offset += size
        if not item:
            continue
        key_bytes, separator, value_bytes = item.partition(b"=")
        key = key_bytes.decode("ascii")
        if not key or any(ord(c) < 0x20 or ord(c) > 0x7e for c in key):
            raise ProbeFailure("dns_sd_txt_invalid_key")
        if key.lower() in seen:
            raise ProbeFailure("dns_sd_txt_duplicate_key")
        seen.add(key.lower())
        result[key] = value_bytes.decode("utf-8") if separator else ""
    return result


def parse_sockaddr(data: bytes) -> str:
    """Decode Darwin sockaddr_in/sockaddr_in6, with sa_len and family checks."""
    if len(data) < 2 or data[0] > len(data):
        raise ProbeFailure("dns_sd_sockaddr_truncated")
    length, family = data[:2]
    if family == socket.AF_INET and length >= 16:
        return socket.inet_ntop(socket.AF_INET, data[4:8])
    if family == socket.AF_INET6 and length >= 28:
        return socket.inet_ntop(socket.AF_INET6, data[8:24])
    raise ProbeFailure("dns_sd_sockaddr_family_unsupported")


def _library():
    if sys.platform != "darwin":
        raise ProbeFailure("system_dns_sd_requires_macos")
    # macOS 26 exports these APIs from libSystem; a separate libdns_sd.dylib
    # is not present in this machine's filesystem or dyld shared cache.
    lib = C.CDLL("/usr/lib/libSystem.B.dylib")
    lib.DNSServiceBrowse.argtypes = [C.POINTER(C.c_void_p), C.c_uint32, C.c_uint32,
                                   C.c_char_p, C.c_char_p, BrowseReply, C.c_void_p]
    lib.DNSServiceResolve.argtypes = [C.POINTER(C.c_void_p), C.c_uint32, C.c_uint32,
                                    C.c_char_p, C.c_char_p, C.c_char_p, ResolveReply, C.c_void_p]
    lib.DNSServiceGetAddrInfo.argtypes = [C.POINTER(C.c_void_p), C.c_uint32, C.c_uint32,
                                        C.c_uint32, C.c_char_p, AddrReply, C.c_void_p]
    lib.DNSServiceRefSockFD.argtypes = [C.c_void_p]
    lib.DNSServiceProcessResult.argtypes = [C.c_void_p]
    lib.DNSServiceRefDeallocate.argtypes = [C.c_void_p]
    for name in ("DNSServiceBrowse", "DNSServiceResolve", "DNSServiceGetAddrInfo",
                 "DNSServiceRefSockFD", "DNSServiceProcessResult"):
        getattr(lib, name).restype = C.c_int32
    lib.DNSServiceRefDeallocate.restype = None
    return lib


@dataclass
class _Record:
    service_name: bytes
    regtype: bytes
    domain: bytes
    interface_index: int
    active: bool = True
    fullname: str = ""
    host: str = ""
    port: int = 0
    properties: dict[str, str] = field(default_factory=dict)
    addresses: set[str] = field(default_factory=set)
    resolve_op: int | None = None
    address_op: int | None = None
    address_batch_complete_at: float | None = None


class _Browser:
    def __init__(self, loop, lib, service_type, interfaces, accept_properties, diagnostics):
        """interfaces maps interface index to name, in preference order."""
        self.loop, self.lib = loop, lib
        self.service_type, self.interfaces = service_type, dict(interfaces)
        self.accept_properties = accept_properties
        self.evidence = diagnostics
        self.records = {}
        self.operations = {}
        self.closed = False
        self.first_accepted_at = None
        self.changed = asyncio.Event()
        self.evidence.update(discovery_backend="macos_dns_sd",
                             host_interfaces=list(self.interfaces.values()),
                             browse_add_events=0, resolved_services=0, address_events=0,
                             callback_errors=0, operation_errors=0)

    def error(self, stage, code=None, error=None):
        self.evidence["operation_errors" if code is not None else "callback_errors"] += 1
        self.evidence["last_discovery_error"] = {"stage": stage}
        if code is not None:
            self.evidence["last_discovery_error"]["code"] = int(code)
        if error is not None:
            self.evidence["last_discovery_error"]["error_class"] = type(error).__name__

    def _start(self, function, args, callback):
        if self.closed:
            return None
        if len(self.operations) >= 80:
            raise ProbeFailure("dns_sd_operation_limit")
        reference = C.c_void_p()
        code = function(C.byref(reference), *args, callback, None)
        if code:
            self.error("start", code=code)
            return None
        descriptor = self.lib.DNSServiceRefSockFD(reference)
        if descriptor < 0:
            self.lib.DNSServiceRefDeallocate(reference)
            raise ProbeFailure("dns_sd_descriptor_unavailable")
        # Retain callback strongly until its C operation is deallocated.
        key = int(reference.value)
        self.operations[key] = (reference, descriptor, callback)
        try:
            self.loop.add_reader(descriptor, self._process, key)
        except BaseException:
            self._close_operation(key)
            raise
        return key

    def _process(self, key):
        operation = self.operations.get(key)
        if operation is None or self.closed:
            return
        code = self.lib.DNSServiceProcessResult(operation[0])
        if code:
            self.error("process", code=code)
            self._close_operation(key)

    def _close_operation(self, key):
        operation = self.operations.pop(key, None)
        if operation is not None:
            self.loop.remove_reader(operation[1])
            self.lib.DNSServiceRefDeallocate(operation[0])

    def close(self):
        self.closed = True
        for key in list(self.operations):
            self._close_operation(key)
        self.evidence["open_dns_sd_handles_after_close"] = len(self.operations)

    def start(self):
        # One browse per eligible interface; never kDNSServiceInterfaceIndexAny,
        # which would include tunnel, AWDL and peer-to-peer interfaces.
        started = 0
        for index in self.interfaces:
            callback = BrowseReply(self._on_browse)
            if self._start(self.lib.DNSServiceBrowse,
                           (0, index, self.service_type.encode(), b"local."), callback) is not None:
                started += 1
        if not started:
            raise ProbeFailure("system_dns_sd_browse_start_failed")

    def _on_browse(self, reference, flags, index, code, name, regtype, domain, context):
        try:
            if code:
                self.error("browse", code=code)
                return
            if self.closed or index not in self.interfaces:
                return
            if not name or regtype.rstrip(b".") != self.service_type.encode() or domain != b"local.":
                return
            key = (bytes(name), bytes(regtype), bytes(domain), index)
            if not flags & ADD:
                record = self.records.get(key)
                if record is not None:
                    record.active = False
                    # Deallocate outside the current C callback.
                    for operation in (record.resolve_op, record.address_op):
                        if operation is not None:
                            self.loop.call_soon(self._close_operation, operation)
                self.changed.set()
                return
            if key in self.records and self.records[key].active:
                return
            if len(self.records) >= 32:
                raise ProbeFailure("dns_sd_service_limit")
            self.evidence["browse_add_events"] += 1
            record = _Record(*key)
            self.records[key] = record
            callback = ResolveReply(lambda *args: self._on_resolve(record, *args))
            record.resolve_op = self._start(self.lib.DNSServiceResolve,
                (0, index, name, regtype, domain), callback)
        except Exception as error:
            self.error("browse_callback", error=error)

    def _on_resolve(self, record, reference, flags, index, code, fullname, host,
                    port, txt_length, txt_pointer, context):
        try:
            if code:
                self.error("resolve", code=code)
                return
            if self.closed or not record.active or index != record.interface_index:
                return
            if not fullname or not host or not host.lower().endswith(b".local."):
                return
            properties = parse_txt(C.string_at(txt_pointer, txt_length) if txt_length else b"")
            if self.accept_properties is not None and not self.accept_properties(properties):
                return
            new_port = socket.ntohs(port)
            if not 1 <= new_port <= 65535:
                return
            host_string = host.decode("utf-8")
            if record.host == host_string and record.port == new_port and record.properties == properties:
                return
            record.fullname = fullname.decode("utf-8")
            record.host, record.port, record.properties = host_string, new_port, properties
            record.addresses.clear()
            record.address_batch_complete_at = None
            if record.address_op is not None:
                self.loop.call_soon(self._close_operation, record.address_op)
            self.evidence["resolved_services"] += 1
            callback = AddrReply(lambda *args: self._on_address(record, *args))
            record.address_op = self._start(self.lib.DNSServiceGetAddrInfo,
                (FORCE_MULTICAST, index, IPV4_AND_IPV6, host), callback)
        except Exception as error:
            self.error("resolve_callback", error=error)

    def _on_address(self, record, reference, flags, index, code, hostname,
                    address_pointer, ttl, context):
        try:
            if code:
                self.error("address", code=code)
                return
            if (self.closed or not record.active or index != record.interface_index
                    or not address_pointer or not hostname
                    or hostname.decode("utf-8").lower() != record.host.lower()):
                return
            prefix = C.string_at(address_pointer, 2)
            if prefix[0] not in (16, 28):
                raise ProbeFailure("dns_sd_sockaddr_size_unsupported")
            ip = parse_sockaddr(C.string_at(address_pointer, prefix[0]))
            parsed = ipaddress.ip_address(ip)
            if parsed.is_loopback or parsed.is_unspecified or parsed.is_multicast:
                return
            self.evidence["address_events"] += 1
            if flags & ADD and ttl:
                record.addresses.add(ip)
                if self.first_accepted_at is None:
                    self.first_accepted_at = time.monotonic()
            else:
                record.addresses.discard(ip)
            # MoreComing means DNS-SD already has another callback queued in
            # this batch. Do not shorten collection while such a batch is open.
            record.address_batch_complete_at = None if flags & MORE_COMING else time.monotonic()
            self.changed.set()
        except Exception as error:
            self.error("address_callback", error=error)

    def results(self):
        from pymobiledevice3.bonjour import Address, ServiceInstance
        result = []
        preference = list(self.interfaces)
        # Stable sort: services on a more preferred interface (Wi-Fi) first.
        for record in sorted(self.records.values(),
                             key=lambda record: preference.index(record.interface_index)):
            if not record.active or not record.addresses or not record.port:
                continue
            interface = self.interfaces[record.interface_index]
            result.append(ServiceInstance(instance=record.fullname, host=record.host.rstrip("."),
                port=record.port, properties=dict(record.properties),
                addresses=[Address(ip=ip, iface=interface) for ip in sorted(record.addresses)]))
        return result

    def dual_stack_batch_complete_at(self):
        """Earliest completed batch with usable addresses from BOTH families.

        Single-family replies keep the original settle window so a late second
        family remains available as fallback. TXT filtering and full transport
        authentication are unchanged. Public/non-LAN addresses cannot shorten
        discovery even though they may appear in a system DNS-SD answer.
        """
        completed = []
        for record in self.records.values():
            if (not record.active or not record.port
                    or record.address_batch_complete_at is None):
                continue
            families = {ipaddress.ip_address(address).version for address in record.addresses
                        if ipaddress.ip_address(address).is_private}
            if families == {4, 6}:
                completed.append(record.address_batch_complete_at)
        return min(completed) if completed else None


async def browse_service(service_type: str, timeout: float = 6.0,
                         interfaces: str | Sequence[str] | None = None,
                         diagnostics: dict | None = None,
                         accept_properties: Callable[[dict[str, str]], bool] | None = None,
                         settle_seconds: float = 0.35, dual_stack_settle_seconds: float = 0.05):
    """Return pmd ServiceInstances on host LAN interfaces, with deterministic cleanup.

    Each returned Address names the interface its record was discovered on;
    services are ordered by the given interface preference (default: Wi-Fi
    first, then active Ethernet). An interface that vanished since it was
    listed is skipped; with none left, discovery fails closed.

    If accept_properties is provided, only matching TXT records are resolved to
    addresses and discovery may finish settle_seconds after a matching address
    arrives. Once a matching service has BOTH usable address families and the
    system's current callback batch is complete, the shorter dual-stack settle
    applies. Single-family discovery retains the full settle window. Otherwise
    the full timeout window is collected. This callback is a
    discovery filter, not a replacement for the transport's peer authentication.
    """
    if service_type not in {"_remotepairing._tcp", "_apple-mobdev2._tcp"}:
        raise ProbeFailure("dns_sd_service_type_not_allowed")
    if (not 0 < timeout <= 30 or not 0.05 <= settle_seconds <= timeout
            or not 0.01 <= dual_stack_settle_seconds <= settle_seconds):
        raise ProbeFailure("dns_sd_invalid_deadline")
    if interfaces is None:
        from wifi_transport import lan_interfaces
        interfaces = lan_interfaces()
    elif isinstance(interfaces, str):
        interfaces = (interfaces,)
    if not 0 < len(interfaces) <= 8 or len(set(interfaces)) != len(interfaces):
        raise ProbeFailure("dns_sd_invalid_interfaces")
    indexes = {}
    for interface in interfaces:
        with suppress(OSError):
            indexes.setdefault(socket.if_nametoindex(interface), interface)
    if not indexes:
        raise ProbeFailure("lan_interface_not_identified")
    evidence = diagnostics if diagnostics is not None else {}
    browser = _Browser(asyncio.get_running_loop(), _library(), service_type,
                       indexes, accept_properties, evidence)
    end = time.monotonic() + timeout
    try:
        browser.start()
        while True:
            deadline = end
            if accept_properties is not None and browser.first_accepted_at is not None:
                deadline = min(deadline, browser.first_accepted_at + settle_seconds)
                dual_stack_at = browser.dual_stack_batch_complete_at()
                if dual_stack_at is not None:
                    deadline = min(deadline, dual_stack_at + dual_stack_settle_seconds)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            browser.changed.clear()
            try:
                await asyncio.wait_for(browser.changed.wait(), timeout=remaining)
            except asyncio.TimeoutError:
                break
        answers = browser.results()
        evidence["returned_services"] = len(answers)
        return answers
    finally:
        browser.close()


async def browse_remotepairing(timeout: float = 6.0, **kwargs):
    return await browse_service("_remotepairing._tcp", timeout=timeout, **kwargs)


async def browse_mobdev2(timeout: float = 6.0, **kwargs):
    return await browse_service("_apple-mobdev2._tcp", timeout=timeout, **kwargs)
