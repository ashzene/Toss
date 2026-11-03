"""Fake macOS DNS-SD callback tests; never starts a real browse or socket."""
import asyncio
import ctypes as C
import socket
import struct
import unittest
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "vendor"))
from unittest.mock import patch

from ipad_probe import ProbeFailure
import system_bonjour as b


class FakeLoop:
    def __init__(self):
        self.readers = {}

    def add_reader(self, fd, callback, *args):
        self.readers[fd] = (callback, args)

    def remove_reader(self, fd):
        self.readers.pop(fd, None)

    def call_soon(self, callback, *args):
        callback(*args)


class FakeLib:
    def __init__(self):
        self.refs, self.deallocated = {}, []

    def _start(self, ref, *args):
        number = len(self.refs) + 1
        ref._obj.value = number
        self.refs[number] = args
        return 0

    DNSServiceBrowse = DNSServiceResolve = DNSServiceGetAddrInfo = _start

    def DNSServiceRefSockFD(self, ref):
        return ref.value + 100

    def DNSServiceRefDeallocate(self, ref):
        self.deallocated.append(ref.value)

    def DNSServiceProcessResult(self, ref):
        return 0


def txt(**fields):
    pieces = []
    for key, value in fields.items():
        item = (key + "=" + value).encode()
        pieces.append(bytes([len(item)]) + item)
    return b"".join(pieces)


class ParserTests(unittest.TestCase):
    def test_txt_and_duplicate_rejection(self):
        self.assertEqual(b.parse_txt(txt(identifier="test", authTag="abcd")),
                         {"identifier": "test", "authTag": "abcd"})
        with self.assertRaises(ProbeFailure):
            b.parse_txt(txt(authTag="one", AUTHTAG="two"))
        with self.assertRaises(ProbeFailure):
            b.parse_txt(b"\x04ab")

    def test_darwin_ipv4_ipv6_layout(self):
        ipv4 = bytes([16, socket.AF_INET]) + b"\0\0" + socket.inet_pton(socket.AF_INET, "192.168.1.2") + b"\0" * 8
        ipv6 = bytes([28, socket.AF_INET6]) + b"\0" * 6 + socket.inet_pton(socket.AF_INET6, "fe80::1234") + b"\0" * 4
        self.assertEqual(b.parse_sockaddr(ipv4), "192.168.1.2")
        self.assertEqual(b.parse_sockaddr(ipv6), "fe80::1234")
        with self.assertRaises(ProbeFailure):
            b.parse_sockaddr(ipv6[:12])

    def test_scoped_callbacks_port_and_cleanup(self):
        loop, lib, diagnostics = FakeLoop(), FakeLib(), {}
        browser = b._Browser(loop, lib, "_remotepairing._tcp", {6: "en0"}, None, diagnostics)
        browser.start()
        browser._on_browse(None, b.ADD, 8, 0, b"wrong-interface", b"_remotepairing._tcp.", b"local.", None)
        self.assertEqual(len(browser.records), 0)
        browser._on_browse(None, b.ADD, 6, 0, b"test", b"_remotepairing._tcp.", b"local.", None)
        record = next(iter(browser.records.values()))
        raw_txt = txt(identifier="test", authTag="abcd")
        text_buffer = C.create_string_buffer(raw_txt)
        browser._on_resolve(record, None, 0, 6, 0,
                            b"test._remotepairing._tcp.local.", b"test.local.",
                            socket.htons(55001), len(raw_txt), C.cast(text_buffer, C.c_void_p), None)
        self.assertEqual(record.port, 55001)
        self.assertEqual(lib.refs[3][:4], (b.FORCE_MULTICAST, 6, b.IPV4_AND_IPV6, b"test.local."))
        raw_address = bytes([16, socket.AF_INET]) + b"\0\0" + socket.inet_pton(socket.AF_INET, "192.168.1.2") + b"\0" * 8
        addr_buffer = C.create_string_buffer(raw_address)
        browser._on_address(record, None, b.ADD, 8, 0, b"test.local.", C.cast(addr_buffer, C.c_void_p), 120, None)
        self.assertEqual(record.addresses, set())
        browser._on_address(record, None, b.ADD, 6, 0, b"test.local.", C.cast(addr_buffer, C.c_void_p), 120, None)
        answers = browser.results()
        self.assertEqual(len(answers), 1)
        self.assertEqual(answers[0].port, 55001)
        self.assertEqual(answers[0].addresses[0].iface, "en0")
        browser._on_browse(None, 0, 6, 0, b"test", b"_remotepairing._tcp.", b"local.", None)
        self.assertEqual(browser.results(), [])
        browser.close()
        self.assertEqual(set(lib.deallocated), {1, 2, 3})
        self.assertEqual(loop.readers, {})
        self.assertEqual(diagnostics["open_dns_sd_handles_after_close"], 0)

    def test_property_filter_prevents_address_lookup(self):
        loop, lib = FakeLoop(), FakeLib()
        browser = b._Browser(loop, lib, "_remotepairing._tcp", {6: "en0"},
                             lambda properties: False, {})
        browser.start()
        browser._on_browse(None, b.ADD, 6, 0, b"test", b"_remotepairing._tcp.", b"local.", None)
        record = next(iter(browser.records.values()))
        browser._on_resolve(record, None, 0, 6, 0,
                            b"test._remotepairing._tcp.local.", b"test.local.",
                            socket.htons(55001), 0, None, None)
        self.assertIsNone(record.address_op)
        browser.close()

    def test_fast_settle_requires_both_lan_families_and_completed_batch(self):
        loop, lib = FakeLoop(), FakeLib()
        browser = b._Browser(loop, lib, "_remotepairing._tcp", {6: "en0"}, lambda _: True, {})
        record = b._Record(b"test", b"_remotepairing._tcp.", b"local.", 6,
                           host="test.local.", port=55001)
        browser.records["synthetic"] = record
        def callback(address, flags=b.ADD, ttl=120):
            parsed = b.ipaddress.ip_address(address)
            raw = ((bytes([16, socket.AF_INET]) + b"\0\0" + parsed.packed + b"\0" * 8)
                   if parsed.version == 4 else
                   (bytes([28, socket.AF_INET6]) + b"\0" * 6 + parsed.packed + b"\0" * 4))
            buffer = C.create_string_buffer(raw)
            browser._on_address(record, None, flags, 6, 0, b"test.local.",
                                C.cast(buffer, C.c_void_p), ttl, None)
        callback("192.168.1.2")
        self.assertIsNone(browser.dual_stack_batch_complete_at())
        callback("fe80::1234", flags=b.ADD | b.MORE_COMING)
        self.assertIsNone(browser.dual_stack_batch_complete_at())
        callback("fe80::1234")
        self.assertIsInstance(browser.dual_stack_batch_complete_at(), float)
        callback("fe80::1234", flags=0, ttl=0)
        self.assertIsNone(browser.dual_stack_batch_complete_at())
        callback("2001:4860:4860::8888")  # Public IPv6 does not qualify.
        self.assertIsNone(browser.dual_stack_batch_complete_at())
        record.active = False
        self.assertIsNone(browser.dual_stack_batch_complete_at())
        browser.close()

    def test_addresses_from_separate_services_do_not_shorten_settle(self):
        browser = b._Browser(FakeLoop(), FakeLib(), "_remotepairing._tcp", {6: "en0"},
                             lambda _: True, {})
        browser.records = {
            "v4": b._Record(b"v4", b"_remotepairing._tcp.", b"local.", 6,
                            port=55001, addresses={"192.168.1.2"}, address_batch_complete_at=1.0),
            "v6": b._Record(b"v6", b"_remotepairing._tcp.", b"local.", 6,
                            port=55002, addresses={"fe80::1234"}, address_batch_complete_at=1.0),
        }
        self.assertIsNone(browser.dual_stack_batch_complete_at())
        browser.close()


    def test_each_lan_interface_browsed_and_wifi_results_first(self):
        loop, lib, diagnostics = FakeLoop(), FakeLib(), {}
        browser = b._Browser(loop, lib, "_remotepairing._tcp", {6: "en0", 9: "en5"},
                             None, diagnostics)
        browser.start()
        self.assertEqual([args[1] for args in lib.refs.values()], [6, 9])
        self.assertEqual(diagnostics["host_interfaces"], ["en0", "en5"])
        browser._on_browse(None, b.ADD, 8, 0, b"tunnel", b"_remotepairing._tcp.", b"local.", None)
        browser._on_browse(None, b.ADD, 9, 0, b"test", b"_remotepairing._tcp.", b"local.", None)
        browser._on_browse(None, b.ADD, 6, 0, b"test", b"_remotepairing._tcp.", b"local.", None)
        self.assertEqual(len(browser.records), 2)
        wired, wifi = browser.records.values()
        raw_address = bytes([16, socket.AF_INET]) + b"\0\0" + socket.inet_pton(socket.AF_INET, "192.168.1.2") + b"\0" * 8
        addr_buffer = C.create_string_buffer(raw_address)
        for record, index in ((wired, 9), (wifi, 6)):
            browser._on_resolve(record, None, 0, 6 if index == 9 else 9, 0,
                                b"test._remotepairing._tcp.local.", b"test.local.",
                                socket.htons(55001), 0, None, None)
            self.assertEqual(record.port, 0)  # Resolve answer from another interface.
            browser._on_resolve(record, None, 0, index, 0,
                                b"test._remotepairing._tcp.local.", b"test.local.",
                                socket.htons(55001), 0, None, None)
            browser._on_address(record, None, b.ADD, 6 if index == 9 else 9, 0, b"test.local.",
                                C.cast(addr_buffer, C.c_void_p), 120, None)
            self.assertEqual(record.addresses, set())  # Address from another interface.
            browser._on_address(record, None, b.ADD, index, 0, b"test.local.",
                                C.cast(addr_buffer, C.c_void_p), 120, None)
        answers = browser.results()
        self.assertEqual([answer.addresses[0].iface for answer in answers], ["en0", "en5"])
        browser.close()
        self.assertEqual(loop.readers, {})

    def test_browse_starts_if_any_lan_interface_starts(self):
        class OneFailingLib(FakeLib):
            def DNSServiceBrowse(self, ref, flags, index, *args):
                return -65540 if index == 6 else self._start(ref, flags, index, *args)
        diagnostics = {}
        browser = b._Browser(FakeLoop(), OneFailingLib(), "_remotepairing._tcp",
                             {6: "en0", 9: "en5"}, None, diagnostics)
        browser.start()
        self.assertEqual(len(browser.operations), 1)
        self.assertEqual(diagnostics["operation_errors"], 1)
        browser.close()
        browser = b._Browser(FakeLoop(), OneFailingLib(), "_remotepairing._tcp",
                             {6: "en0"}, None, {})
        with self.assertRaises(ProbeFailure):
            browser.start()


class CancellationTest(unittest.IsolatedAsyncioTestCase):
    async def test_cancel_closes_native_handles(self):
        events = []
        class SimulatedBrowser:
            first_accepted_at = None
            def __init__(self, *args):
                self.changed = asyncio.Event()
            def start(self):
                events.append("start")
            def close(self):
                events.append("close")
        with patch.object(b, "_library", return_value=object()), \
             patch.object(b, "_Browser", SimulatedBrowser), \
             patch.object(b.socket, "if_nametoindex", return_value=6):
            operation = asyncio.create_task(b.browse_remotepairing(interfaces="en0"))
            await asyncio.sleep(0)
            operation.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await operation
        self.assertEqual(events, ["start", "close"])

    async def test_dual_stack_wait_reduced_but_single_family_wait_unchanged(self):
        async def planned_wait(dual_stack, filtered):
            waits, events = [], []
            class SimulatedBrowser:
                def __init__(self, *args):
                    self.changed = asyncio.Event()
                    self.first_accepted_at = None
                def start(self):
                    self.first_accepted_at = b.time.monotonic()
                def dual_stack_batch_complete_at(self):
                    return self.first_accepted_at if dual_stack else None
                def results(self):
                    return []
                def close(self):
                    events.append("closed")
            async def no_real_wait(awaitable, timeout):
                awaitable.close()
                waits.append(timeout)
                raise asyncio.TimeoutError
            with patch.object(b, "_library", return_value=object()), \
                 patch.object(b, "_Browser", SimulatedBrowser), \
                 patch.object(b.socket, "if_nametoindex", return_value=6), \
                 patch.object(b.asyncio, "wait_for", no_real_wait):
                await b.browse_remotepairing(interfaces="en0", timeout=1.0,
                                           accept_properties=(lambda _: True) if filtered else None)
            self.assertEqual(events, ["closed"])
            self.assertEqual(len(waits), 1)
            return waits[0]
        fast = await planned_wait(dual_stack=True, filtered=True)
        ordinary = await planned_wait(dual_stack=False, filtered=True)
        unfiltered = await planned_wait(dual_stack=True, filtered=False)
        self.assertGreater(fast, 0.025)
        self.assertLessEqual(fast, 0.05)
        self.assertGreater(ordinary, 0.325)
        self.assertLessEqual(ordinary, 0.35)
        self.assertGreater(unfiltered, 0.975)
        self.assertLessEqual(unfiltered, 1.0)

    async def test_invalid_fast_settle_deadline_rejected_before_discovery(self):
        for value in (0.0, 0.5, float("inf"), float("nan")):
            with self.subTest(value=value), \
                 patch.object(b, "_library", side_effect=AssertionError("must not browse")):
                with self.assertRaises(ProbeFailure):
                    await b.browse_remotepairing(interfaces="en0", dual_stack_settle_seconds=value)


    async def test_interface_list_validated_and_vanished_interfaces_skipped(self):
        for value in ((), ("en0", "en0"), tuple(f"en{n}" for n in range(9))):
            with self.subTest(value=value), \
                 patch.object(b, "_library", side_effect=AssertionError("must not browse")):
                with self.assertRaises(ProbeFailure) as raised:
                    await b.browse_remotepairing(interfaces=value)
                self.assertEqual(str(raised.exception), "dns_sd_invalid_interfaces")
        seen = []
        class SimulatedBrowser:
            first_accepted_at = None
            def __init__(self, loop, lib, service_type, interfaces, *args):
                seen.append(interfaces)
                self.changed = asyncio.Event()
            def start(self):
                pass
            def results(self):
                return []
            def close(self):
                pass
        def index(name):
            if name == "en0":
                raise OSError("no such interface")
            return 9
        with patch.object(b, "_library", return_value=object()), \
             patch.object(b, "_Browser", SimulatedBrowser), \
             patch.object(b.socket, "if_nametoindex", side_effect=index):
            await b.browse_remotepairing(interfaces=("en0", "en5"), timeout=0.1, settle_seconds=0.05,
                                         dual_stack_settle_seconds=0.01)
            self.assertEqual(seen, [{9: "en5"}])
            with self.assertRaises(ProbeFailure) as raised:
                await b.browse_remotepairing(interfaces=("en0",))
            self.assertEqual(str(raised.exception), "lan_interface_not_identified")

if __name__ == "__main__":
    unittest.main()
