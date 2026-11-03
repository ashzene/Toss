"""In-memory cryptographic protocol tests only. Never connects to any device."""
import asyncio
import json
import unittest
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "vendor"))
from unittest.mock import patch

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

from ipad_probe import ProbeFailure
from remote_pairing_transport import (protocol_classes, require_lan_writer, untried_lan_addresses,
                                      _TransportRelayGuard)
import wifi_transport
import socket
from types import SimpleNamespace
from pymobiledevice3.remote import tunnel_service as ts
import base64
import tempfile
from pymobiledevice3.bonjour import Address, ServiceInstance
from pymobiledevice3.remote.siphash import compute_auth_tag
import pymobiledevice3.remote.remote_service_discovery  # noqa: F401 (preload outside the event loop)
import pymobiledevice3.remote.userspace_tunnel  # noqa: F401
import remote_pairing_transport as rp
import system_bonjour

USB, Wifi = protocol_classes()
T, TLV = ts.PairingDataComponentType, ts.PairingDataComponentTLVBuf


class SimulatedWifi(Wifi):
    """Answer M1/M3 from an in-memory peer; no socket or mDNS calls."""
    def __init__(self, fault=None):
        super().__init__("synthetic-device", "invalid.local", 1)
        self.fault = fault
        self.host_key = Ed25519PrivateKey.generate()
        self.peer_key = Ed25519PrivateKey.generate()
        self.peer_ephemeral_key = X25519PrivateKey.generate()
        self.record = {
            "host_identifier": "test-host",
            "private_key": self.host_key.private_bytes_raw(),
            "peer_public_key": self.peer_key.public_key().public_bytes_raw(),
            "peer_identifier": b"synthetic-peer",
        }
        self.sent_host_identity = False

    @property
    def pair_record(self):
        return self.record

    async def _send_receive_pairing_data(self, packet):
        fields = self.decode_tlv(TLV.parse(packet["data"]))
        if fields[T.STATE] == b"\x01":
            self.host_ephemeral = fields[T.PUBLIC_KEY]
            self.peer_ephemeral = self.peer_ephemeral_key.public_key().public_bytes_raw()
            secret = self.peer_ephemeral_key.exchange(X25519PublicKey.from_public_bytes(self.host_ephemeral))
            key = HKDF(algorithm=hashes.SHA512(), length=32,
                       salt=b"Pair-Verify-Encrypt-Salt", info=b"Pair-Verify-Encrypt-Info").derive(secret)
            self.cip = ChaCha20Poly1305(key)
            identifier = b"wrong-peer" if self.fault == "identifier" else self.record["peer_identifier"]
            signature_input = self.peer_ephemeral + identifier + self.host_ephemeral
            if self.fault == "replay":
                signature_input = self.peer_ephemeral + identifier + b"\x00" * 32
            signing_key = Ed25519PrivateKey.generate() if self.fault == "signature" else self.peer_key
            payload = TLV.build([
                {"type": T.IDENTIFIER, "data": identifier},
                {"type": T.SIGNATURE, "data": signing_key.sign(signature_input)},
            ])
            encrypted = self.cip.encrypt(b"\x00\x00\x00\x00PV-Msg02", payload, b"")
            if self.fault == "ciphertext":
                encrypted = bytes([encrypted[0] ^ 1]) + encrypted[1:]
            return TLV.build([
                {"type": T.STATE, "data": b"\x02"},
                {"type": T.PUBLIC_KEY, "data": self.peer_ephemeral},
                {"type": T.ENCRYPTED_DATA, "data": encrypted},
            ])
        self.sent_host_identity = True
        host_payload = self.decode_tlv(TLV.parse(self.cip.decrypt(
            b"\x00\x00\x00\x00PV-Msg03", fields[T.ENCRYPTED_DATA], b"")))
        self.host_key.public_key().verify(host_payload[T.SIGNATURE],
            self.host_ephemeral + host_payload[T.IDENTIFIER] + self.peer_ephemeral)
        return TLV.build([{"type": T.STATE, "data": b"\x04" if self.fault != "m4" else b"\x05"}])


class ProtocolTests(unittest.IsolatedAsyncioTestCase):
    async def test_valid_mutual_pair_verify(self):
        peer = SimulatedWifi()
        with patch("asyncio.open_connection", side_effect=AssertionError("network forbidden")):
            self.assertTrue(await peer._validate_pairing())
        self.assertTrue(peer.peer_signature_verified)
        self.assertTrue(peer.sent_host_identity)

    async def test_bad_peer_proof_fails_before_host_identity(self):
        for fault in ("signature", "identifier", "replay", "ciphertext"):
            with self.subTest(fault=fault):
                peer = SimulatedWifi(fault)
                with self.assertRaises(ProbeFailure):
                    await peer._validate_pairing()
                self.assertFalse(peer.sent_host_identity)

    async def test_bad_m4_fails(self):
        with self.assertRaises(ProbeFailure):
            await SimulatedWifi("m4")._validate_pairing()

    async def test_remote_unlock_sends_nothing(self):
        peer = SimulatedWifi()
        async def forbidden(*args, **kwargs):
            raise AssertionError("remote unlock operation must not be sent")
        peer._send_receive_encrypted_request = forbidden
        await peer._create_remote_unlock()
        self.assertEqual(peer.remote_unlock_host_key, "")

    async def test_wifi_autopair_refused_before_connect(self):
        with patch("asyncio.open_connection", side_effect=AssertionError("network forbidden")):
            with self.assertRaises(ProbeFailure):
                await SimulatedWifi().connect(autopair=True)


class CandidateTests(unittest.TestCase):
    def address(self, value, interface="en0"):
        return SimpleNamespace(ip=value, iface=interface)

    def test_duplicate_endpoint_skipped_across_matching_adverts(self):
        attempted = set()
        address = self.address("192.168.1.2")
        self.assertEqual(list(untried_lan_addresses([address, address], ("en0",), 55001, attempted)), [address])
        self.assertEqual(list(untried_lan_addresses([address], ("en0",), 55001, attempted)), [])
        self.assertEqual(list(untried_lan_addresses([address], ("en0",), 55002, attempted)), [address])

    def test_ipv6_equivalent_forms_deduplicated(self):
        attempted = set()
        first, second = self.address("fe80::1234"), self.address("fe80:0:0:0:0:0:0:1234")
        self.assertEqual(list(untried_lan_addresses([first, second], ("en0",), 55001, attempted)), [first])

    def test_order_and_lan_interface_filter_unchanged(self):
        v6, v4 = self.address("fe80::1234"), self.address("192.168.1.2")
        filtered = [self.address("192.168.1.3", "en7"), self.address("127.0.0.1"),
                    self.address("0.0.0.0"), self.address("8.8.8.8")]
        self.assertEqual(list(untried_lan_addresses([v6, *filtered, v4], ("en0",), 55001, set())), [v4, v6])

    def test_any_eligible_lan_interface_accepted_and_kept_distinct(self):
        attempted = set()
        wifi, wired = self.address("192.168.1.2"), self.address("192.168.1.2", "en5")
        tunnel = self.address("192.168.1.2", "utun3")
        self.assertEqual(list(untried_lan_addresses([wifi, wired, tunnel], ("en0", "en5"), 55001,
                                                    attempted)), [wifi, wired])
        self.assertEqual(attempted, {("192.168.1.2", 55001, "en0"), ("192.168.1.2", 55001, "en5")})


class Writer:
    def __init__(self, local, remote):
        self.info = {"sockname": local, "peername": remote}

    def get_extra_info(self, name, default=None):
        return self.info.get(name, default)


def if_addrs(**interfaces):
    return {name: [SimpleNamespace(family=socket.AF_INET6 if ":" in ip else socket.AF_INET, address=ip)
                   for ip in addresses] for name, addresses in interfaces.items()}


class LanRouteTests(unittest.TestCase):
    def check(self, local, remote, interfaces, **addresses):
        with patch("psutil.net_if_addrs", return_value=if_addrs(**addresses)):
            return require_lan_writer(Writer((local, 1), (remote, 2)), interfaces)

    def test_returns_interface_socket_actually_used(self):
        lan = {"en0": ["192.168.1.10"], "en5": ["192.168.1.11"], "utun3": ["10.8.0.2"]}
        self.assertEqual(self.check("192.168.1.11", "192.168.1.20", ("en0", "en5"), **lan), "en5")
        self.assertEqual(self.check("192.168.1.10", "192.168.1.20", ("en0", "en5"), **lan), "en0")
        self.assertEqual(self.check("fe80::5%en5", "fe80::1%en5", ("en0", "en5"),
                                    en0=["fe80::4%en0"], en5=["fe80::5%en5"]), "en5")

    def test_route_outside_eligible_lan_interfaces_rejected(self):
        cases = (
            ("10.8.0.2", "10.0.0.20", {"en0": ["192.168.1.10"], "utun3": ["10.8.0.2"]}),
            ("192.168.1.11", "192.168.1.20", {"en0": ["192.168.1.10"], "en7": ["192.168.1.11"]}),
            ("192.168.1.10", "192.168.1.20", {"en0": ["192.168.1.10"], "bridge0": ["192.168.1.10"]}),
            ("192.168.1.99", "192.168.1.20", {"en0": ["192.168.1.10"]}),
        )
        for local, remote, addresses in cases:
            with self.subTest(local=local, addresses=sorted(addresses)), self.assertRaises(ProbeFailure) as raised:
                self.check(local, remote, ("en0", "en5"), **addresses)
            self.assertEqual(str(raised.exception), "tcp_route_not_uniquely_lan")

    def test_public_or_loopback_peer_rejected(self):
        for remote in ("8.8.8.8", "127.0.0.1", "2001:4860:4860::8888"):
            with self.subTest(remote=remote), self.assertRaises(ProbeFailure) as raised:
                self.check("192.168.1.10", remote, ("en0",), en0=["192.168.1.10"])
            self.assertEqual(str(raised.exception), "peer_not_lan_address")


class ConnectRouteTests(unittest.IsolatedAsyncioTestCase):
    async def test_verified_connection_records_interface_used(self):
        peer = SimulatedWifi()
        peer.interfaces = ("en0", "en5")
        writer = Writer(("192.168.1.11", 50000), ("192.168.1.20", 49152))
        async def opened(*args, **kwargs):
            return object(), writer
        async def no_handshake():
            pass
        peer._attempt_pair_verify = no_handshake
        with patch("asyncio.open_connection", side_effect=opened), \
             patch("psutil.net_if_addrs", return_value=if_addrs(en0=["192.168.1.10"], en5=["192.168.1.11"])):
            await peer.connect(autopair=False)
        self.assertEqual(peer.interface, "en5")
        self.assertTrue(peer.peer_signature_verified)

    async def test_signature_still_required_on_ethernet(self):
        peer = SimulatedWifi("signature")
        peer.interfaces = ("en5",)
        writer = Writer(("192.168.1.11", 50000), ("192.168.1.20", 49152))
        async def opened(*args, **kwargs):
            return object(), writer
        async def no_handshake():
            pass
        peer._attempt_pair_verify = no_handshake
        with patch("asyncio.open_connection", side_effect=opened), \
             patch("psutil.net_if_addrs", return_value=if_addrs(en5=["192.168.1.11"])):
            with self.assertRaises(ProbeFailure) as raised:
                await peer.connect(autopair=False)
        self.assertEqual(str(raised.exception), "remote_peer_signature_not_verified")
        self.assertFalse(peer.peer_signature_verified)
        self.assertIsNone(peer._writer)


NETWORKSETUP = """
Hardware Port: Ethernet
Device: en5
Ethernet Address: 00:00:00:00:00:05

Hardware Port: Thunderbolt Bridge
Device: bridge0
Ethernet Address: 00:00:00:00:00:10

Hardware Port: Wi-Fi
Device: en0
Ethernet Address: 00:00:00:00:00:00

Hardware Port: Thunderbolt 1
Device: en1
Ethernet Address: 00:00:00:00:00:01

Hardware Port: USB 10/100/1000 LAN
Device: en8
Ethernet Address: 00:00:00:00:00:08

Hardware Port: iPad USB
Device: en9
Ethernet Address: 00:00:00:00:00:09

Hardware Port: Ethernet Adapter (en3)
Device: en3
Ethernet Address: 00:00:00:00:00:03

VLAN Configurations
===================
"""


class LanInterfaceSelectionTests(unittest.TestCase):
    def select(self, addresses, down=()):
        names = ("en0", "en1", "en3", "en5", "en8", "en9", "bridge0")
        stats = {name: SimpleNamespace(isup=name not in down) for name in names}
        return wifi_transport.select_lan_interfaces(wifi_transport.hardware_ports(NETWORKSETUP),
                                                    if_addrs(**addresses), stats)

    def test_wifi_first_then_active_wired_ports(self):
        addresses = {"en0": ["192.168.1.10"], "en5": ["192.168.1.11", "fe80::5%en5"],
                     "en8": ["10.0.0.4"], "en1": ["fe80::1%en1"], "en3": ["169.254.3.3"],
                     "en9": ["172.20.10.2"], "bridge0": ["192.168.2.1"]}
        self.assertEqual(self.select(addresses), ("en0", "en5", "en8"))
        self.assertEqual(self.select(addresses, down={"en5"}), ("en0", "en8"))

    def test_ethernet_only_mac_and_wifi_without_address(self):
        self.assertEqual(self.select({"en5": ["192.168.1.11"]}), ("en0", "en5"))
        self.assertEqual(self.select({"en5": ["8.8.4.4"]}), ("en0",))
        listing = NETWORKSETUP.replace("Hardware Port: Wi-Fi", "Hardware Port: Unused")
        stats = {"en0": SimpleNamespace(isup=True), "en5": SimpleNamespace(isup=True)}
        self.assertEqual(wifi_transport.select_lan_interfaces(
            wifi_transport.hardware_ports(listing), if_addrs(en5=["192.168.1.11"]), stats), ("en5",))

    def test_no_eligible_interface_fails_closed(self):
        class Result:
            stdout = "Hardware Port: Thunderbolt Bridge\nDevice: bridge0\n"
        with patch.object(wifi_transport.subprocess, "run", return_value=Result()), \
             patch("psutil.net_if_addrs", return_value=if_addrs(bridge0=["192.168.2.1"])), \
             patch("psutil.net_if_stats", return_value={"bridge0": SimpleNamespace(isup=True)}):
            with self.assertRaises(ProbeFailure) as raised:
                wifi_transport.lan_interfaces()
        self.assertEqual(str(raised.exception), "lan_interface_not_identified")


class LanDiscoveryFlowTests(unittest.IsolatedAsyncioTestCase):
    """open_remote_wifi_rsd(status_only) with every device/network edge simulated."""
    async def run_flow(self, routes, hint=None, discovered=()):
        irk = b"\x01" * 16
        record = {"peer_alt_irk": irk, "pinned_udid": "synthetic-device"}
        dialed, browsed = [], []

        class Service:
            def __init__(self, udid, host, port):
                self.host, self.port, self.interface = host, port, None
            async def connect(self, autopair=False):
                dialed.append(self.host)
                if self.host not in routes:
                    raise ProbeFailure("tcp_route_not_uniquely_lan")
                self.interface = routes[self.host]
                assert self.interface in self.interfaces
            async def close(self):
                pass

        async def browse(**kwargs):
            browsed.append(kwargs["interfaces"])
            tag = base64.b64encode(compute_auth_tag(irk, "peer")).decode()
            return [ServiceInstance(instance="x", host="ipad.local", port=49152,
                                    properties={"identifier": "peer", "authTag": tag},
                                    addresses=[Address(ip, interface) for ip, interface in discovered])]

        with tempfile.TemporaryDirectory() as temp:
            state = Path(temp)
            if hint is not None:
                rp.save_endpoint_hint(state, *hint)
            with patch.object(rp, "configure", return_value=(state, {}, state)), \
                 patch.object(rp, "load_record", return_value=record), \
                 patch.object(rp, "protocol_classes", return_value=(None, Service)), \
                 patch.object(rp, "lan_interfaces", return_value=("en0", "en5")), \
                 patch.object(system_bonjour, "browse_remotepairing", browse):
                evidence = {}
                async with rp.open_remote_wifi_rsd(state, status_only=True, diagnostics=evidence) as (service, _):
                    pass
            saved = json.loads((state / rp.ENDPOINT_HINT).read_text())
        return service, evidence, saved, dialed, browsed

    async def test_ethernet_only_discovery_saves_interface_used(self):
        service, evidence, saved, dialed, browsed = await self.run_flow(
            {"192.168.1.20": "en5"}, discovered=[("192.168.1.20", "en5"), ("8.8.8.8", "en5")])
        self.assertEqual(browsed, [("en0", "en5")])
        self.assertEqual(dialed, ["192.168.1.20"])
        self.assertEqual(saved, {"ip": "192.168.1.20", "port": 49152, "interface": "en5"})
        self.assertEqual((evidence["host_interface"], evidence["host_interfaces"]), ("en5", ["en0", "en5"]))
        self.assertTrue(evidence["lan_socket_route_verified"])
        self.assertNotIn("192.168", json.dumps(evidence))

    async def test_hint_reused_and_interface_updated_when_route_moves(self):
        service, evidence, saved, dialed, browsed = await self.run_flow(
            {"192.168.1.20": "en5"}, hint=("192.168.1.20", 49152, "en0"))
        self.assertEqual((evidence["endpoint_hint"], browsed, dialed), ("used", [], ["192.168.1.20"]))
        self.assertEqual(saved["interface"], "en5")

    async def test_failed_hint_falls_back_to_lan_discovery(self):
        service, evidence, saved, dialed, browsed = await self.run_flow(
            {"10.0.0.7": "en0"}, hint=("10.0.0.9", 49152, "en5"), discovered=[("10.0.0.7", "en0")])
        self.assertEqual(dialed, ["10.0.0.9", "10.0.0.7"])
        self.assertEqual(saved, {"ip": "10.0.0.7", "port": 49152, "interface": "en0"})


class TransportWatcherTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.transport_ended = asyncio.Event()
        self.relay_closed = asyncio.Event()
        self.waits = self.closes = 0
        owner = self
        class Client:
            async def wait_closed(self):
                owner.waits += 1
                await owner.transport_ended.wait()
        async def close_relay():
            self.closes += 1
            self.relay_closed.set()
        self.guard = _TransportRelayGuard(Client(), close_relay)

    async def asyncTearDown(self):
        await self.guard.close()

    async def test_idle_watcher_only_waits_then_normal_close_is_once(self):
        self.guard.start()
        self.guard.start()
        await asyncio.sleep(0)
        self.assertEqual((self.waits, self.closes), (1, 0))
        self.assertFalse(self.guard.disconnected)
        await self.guard.close()
        await self.guard.close()
        self.assertEqual(self.closes, 1)
        self.assertTrue(self.guard.watcher.done())
        self.assertFalse(self.guard.disconnected)

    async def test_transport_death_closes_relay_and_wakes_blocked_service_read(self):
        async def blocked_read():
            await self.relay_closed.wait()
            raise ConnectionError("synthetic closed relay")
        read = asyncio.create_task(blocked_read())
        self.guard.start()
        self.transport_ended.set()
        with self.assertRaises(ConnectionError):
            await asyncio.wait_for(read, 0.2)
        self.assertTrue(self.guard.disconnected)
        await self.guard.close()
        self.assertEqual(self.closes, 1)

    async def test_unknown_transport_exception_is_also_fail_closed(self):
        async def broken():
            self.waits += 1
            raise RuntimeError("SECRET_HOST")
        self.guard.client.wait_closed = broken
        self.guard.start()
        await asyncio.wait_for(self.relay_closed.wait(), 0.2)
        self.assertTrue(self.guard.disconnected)
        self.assertEqual(self.closes, 1)

    async def test_teardown_and_disconnect_share_single_relay_close(self):
        entered, release = asyncio.Event(), asyncio.Event()
        async def slow_close():
            self.closes += 1
            entered.set()
            await release.wait()
            self.relay_closed.set()
        self.guard.close_relay = slow_close
        self.guard.start()
        self.transport_ended.set()
        await entered.wait()
        close = asyncio.create_task(self.guard.close())
        await asyncio.sleep(0)
        release.set()
        await asyncio.wait_for(close, 0.2)
        self.assertEqual(self.closes, 1)
        self.assertTrue(self.relay_closed.is_set())

    async def test_cancelled_teardown_does_not_cancel_relay_cleanup(self):
        entered, release = asyncio.Event(), asyncio.Event()
        async def slow_close():
            self.closes += 1
            entered.set()
            await release.wait()
            self.relay_closed.set()
        self.guard.close_relay = slow_close
        self.guard.start()
        closing = asyncio.create_task(self.guard.close())
        await entered.wait()
        closing.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await closing
        self.assertFalse(self.guard.close_task.cancelled())
        release.set()
        await asyncio.wait_for(self.guard.close(), 0.2)
        self.assertEqual(self.closes, 1)
        self.assertTrue(self.relay_closed.is_set())


if __name__ == "__main__":
    unittest.main()
