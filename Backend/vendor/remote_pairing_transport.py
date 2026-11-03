"""Optional strict RemotePairing experiment; pymobiledevice3 == 11.31.0 only.

No action runs at import. Initial USB bootstrap is a separate explicit operation.
The wireless path (Wi-Fi or a wired Ethernet LAN of the Mac) never pairs, never
uses USB, never requests remote unlock, and requires a device signature under a
public key obtained over the already trusted USB link.
USB bootstrap and Wi-Fi screenshot capture were verified on iPad14,3 / 18.7.8;
other iPads on iPadOS 17+ are accepted but not yet device-verified,
including a capture after the user unplugged USB. This remains a diagnostic
component, not a native chat attachment tool. See the separate acceptance log.
"""
from __future__ import annotations

import asyncio
import base64
from contextlib import AsyncExitStack, asynccontextmanager, suppress
import hmac
import importlib.metadata
import ipaddress
import json
import os
from pathlib import Path
import plistlib
import socket
import contextlib
import ssl
import stat
import time

from ipad_probe import ProbeFailure, fingerprint
from wifi_transport import LAN_DEVICE, lan_interfaces


def configure(state: Path):
    if os.geteuid() == 0:
        raise ProbeFailure("root_execution_not_allowed")
    if importlib.metadata.version("pymobiledevice3") != "11.31.0":
        raise ProbeFailure("unexpected_library_version")
    os.umask(0o077)
    state = state.resolve()
    if not state.is_dir() or state.stat().st_mode & 0o077:
        raise ProbeFailure("private_existing_state_directory_required")
    pin = json.loads((state / "target.json").read_text())
    model = pin.get("model")
    if not isinstance(model, str) or not model.startswith("iPad") or not isinstance(pin.get("device_hash"), str):
        raise ProbeFailure("unexpected_device_pin")
    cache = state / "cache"
    cache.mkdir(mode=0o700, exist_ok=True)
    import pymobiledevice3.common as common
    common._HOMEFOLDER = cache
    os.environ.pop("USBMUXD_SOCKET_ADDRESS", None)
    os.environ.pop("PYMOBILEDEVICE3_USERSPACE_TCP_RELAY", None)
    return state, pin, cache


def supported_ipados(version) -> bool:
    """RemotePairing over Wi-Fi exists from iPadOS 17."""
    try:
        return int(str(version).split(".")[0]) >= 17
    except ValueError:
        return False


ENDPOINT_HINT = "endpoint-hint.json"


def load_endpoint_hint(state: Path, interfaces):
    """Last authenticated LAN endpoint, a dial hint only (never trust).

    Returns (host, port, interface). The device must still pass the full
    pair-verify signature check. A hint for an interface that is not currently
    eligible, a non-LAN address or an unsafe file is ignored.
    """
    path = state / ENDPOINT_HINT
    try:
        info = path.lstat()
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or info.st_mode & 0o077 or info.st_size > 512):
            return None
        raw = json.loads(path.read_text())
        host, port, interface = raw["ip"], raw["port"], raw["interface"]
        if (type(interface) is not str or interface not in interfaces
                or not LAN_DEVICE.fullmatch(interface)
                or type(port) is not int or not 1 <= port <= 65535):
            return None
        address = ipaddress.ip_address(str(host).split("%", 1)[0])
    except (OSError, ValueError, KeyError, TypeError):
        return None
    if address.is_loopback or address.is_unspecified or not (address.is_private or address.is_link_local):
        return None
    if address.version == 6 and address.is_link_local:
        return f"{address.compressed}%{interface}", port, interface
    return address.compressed, port, interface


def save_endpoint_hint(state: Path, host: str, port: int, interface: str):
    with suppress(OSError, ValueError, TypeError):
        data = json.dumps({"ip": str(host), "port": int(port), "interface": interface}).encode()
        temporary = state / (ENDPOINT_HINT + ".tmp")
        with suppress(FileNotFoundError):
            temporary.unlink()
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
        os.replace(temporary, state / ENDPOINT_HINT)


def load_record(state: Path, pin: dict):
    path = state / "strict-remote-pairing.plist"
    if not path.exists():
        return None
    if path.is_symlink() or path.stat().st_mode & 0o077:
        raise ProbeFailure("remote_pairing_record_not_private")
    record = plistlib.loads(path.read_bytes())
    if (record.get("strict_schema") != 1
            or record.get("device_hash") != pin["device_hash"]
            or fingerprint(record.get("pinned_udid", "")) != pin["device_hash"]
            or record.get("remote_unlock_host_key") != ""):
        raise ProbeFailure("strict_remote_pairing_record_mismatch")
    for key, size in (("private_key", 32), ("public_key", 32),
                      ("peer_public_key", 32), ("peer_alt_irk", 16)):
        if not isinstance(record.get(key), bytes) or len(record[key]) != size:
            raise ProbeFailure("strict_remote_pairing_record_incomplete")
    if not isinstance(record.get("peer_identifier"), bytes) or not record["peer_identifier"]:
        raise ProbeFailure("strict_remote_pairing_record_incomplete")
    if not isinstance(record.get("host_identifier"), str) or not record["host_identifier"]:
        raise ProbeFailure("strict_remote_pairing_record_incomplete")
    return record


def require_lan_writer(writer, interfaces) -> str:
    """Return the interface the real socket went out on, which must be one of
    the eligible LAN interfaces and the unique owner of the local address."""
    import psutil
    local = writer.get_extra_info("sockname")
    remote = writer.get_extra_info("peername")
    if not local or not remote:
        raise ProbeFailure("tcp_route_unavailable")
    local_ip = ipaddress.ip_address(str(local[0]).split("%", 1)[0])
    peer_ip = ipaddress.ip_address(str(remote[0]).split("%", 1)[0])
    if peer_ip.is_loopback or not (peer_ip.is_private or peer_ip.is_link_local):
        raise ProbeFailure("peer_not_lan_address")
    names = set()
    for name, addresses in psutil.net_if_addrs().items():
        for address in addresses:
            if address.family not in (socket.AF_INET, socket.AF_INET6):
                continue
            with suppress(ValueError):
                if ipaddress.ip_address(address.address.split("%", 1)[0]) == local_ip:
                    names.add(name)
    if len(names) != 1 or not names <= set(interfaces):
        raise ProbeFailure("tcp_route_not_uniquely_lan")
    return names.pop()


def protocol_classes():
    """Load pinned library classes only after caller configures its private cache."""
    from cryptography.exceptions import InvalidSignature, InvalidTag
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PublicKey
    from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
    from cryptography.hazmat.primitives.kdf.hkdf import HKDF
    from pymobiledevice3.remote import tunnel_service as ts
    from pymobiledevice3.service_connection import close_stream_writer
    T = ts.PairingDataComponentType
    TLV = ts.PairingDataComponentTLVBuf

    def bytes_field(fields, key, length=None):
        value = fields.get(key)
        if not isinstance(value, bytes) or not value or (length is not None and len(value) != length):
            raise ProbeFailure("remote_pairing_required_field_invalid")
        return value

    class StrictPeerMixin:
        state: Path
        pin: dict
        peer_signature_verified = False

        @property
        def pair_record_path(self):
            return self.state / "strict-remote-pairing.plist"

        @property
        def pair_record(self):
            return load_record(self.state, self.pin)

        async def _validate_pairing(self):
            record = self.pair_record
            if record is None:
                raise ProbeFailure("strict_remote_pairing_record_required")
            self.identifier = record["host_identifier"]
            local_ephemeral = self.x25519_private_key.public_key().public_bytes_raw()
            response = await self._send_receive_pairing_data({
                "data": TLV.build([
                    {"type": T.STATE, "data": b"\x01"},
                    {"type": T.PUBLIC_KEY, "data": local_ephemeral},
                ]),
                "kind": "verifyManualPairing", "startNewSession": True,
            })
            fields = self.decode_tlv(TLV.parse(response))
            if T.ERROR in fields:
                raise ProbeFailure("remote_pair_verify_rejected")
            if fields.get(T.STATE) != b"\x02":
                raise ProbeFailure("remote_pair_verify_unexpected_state")
            peer_ephemeral = bytes_field(fields, T.PUBLIC_KEY, 32)
            self.encryption_key = self.x25519_private_key.exchange(
                X25519PublicKey.from_public_bytes(peer_ephemeral))
            verify_key = HKDF(algorithm=hashes.SHA512(), length=32,
                              salt=b"Pair-Verify-Encrypt-Salt",
                              info=b"Pair-Verify-Encrypt-Info").derive(self.encryption_key)
            cip = ChaCha20Poly1305(verify_key)
            try:
                plaintext = cip.decrypt(b"\x00\x00\x00\x00PV-Msg02",
                                        bytes_field(fields, T.ENCRYPTED_DATA), b"")
                peer = self.decode_tlv(TLV.parse(plaintext))
                peer_identifier = bytes_field(peer, T.IDENTIFIER)
                if not hmac.compare_digest(peer_identifier, record["peer_identifier"]):
                    raise ProbeFailure("remote_peer_identifier_mismatch")
                # HAP Pair-Verify M2 binds both ephemeral keys to the installed
                # device's long-term Ed25519 identity. There is no unverified fallback.
                Ed25519PublicKey.from_public_bytes(record["peer_public_key"]).verify(
                    bytes_field(peer, T.SIGNATURE, 64),
                    peer_ephemeral + peer_identifier + local_ephemeral)
            except (InvalidSignature, InvalidTag):
                raise ProbeFailure("remote_peer_signature_not_verified") from None
            self.peer_signature_verified = True
            signature = Ed25519PrivateKey.from_private_bytes(record["private_key"]).sign(
                local_ephemeral + self.identifier.encode() + peer_ephemeral)
            encrypted = cip.encrypt(b"\x00\x00\x00\x00PV-Msg03", TLV.build([
                {"type": T.IDENTIFIER, "data": self.identifier.encode()},
                {"type": T.SIGNATURE, "data": signature},
            ]), b"")
            # TLV8 fields longer than 255 bytes require chunks; this M3 is below
            # that bound for this library's UUID host identifier.
            if len(encrypted) > 255:
                raise ProbeFailure("remote_pair_verify_m3_exceeds_tlv_limit")
            response = await self._send_receive_pairing_data({
                "data": TLV.build([
                    {"type": T.STATE, "data": b"\x03"},
                    {"type": T.ENCRYPTED_DATA, "data": encrypted},
                ]),
                "kind": "verifyManualPairing", "startNewSession": False,
            })
            fields = self.decode_tlv(TLV.parse(response))
            if T.ERROR in fields or fields.get(T.STATE) != b"\x04":
                raise ProbeFailure("remote_pair_verify_m4_rejected")
            return True

        async def _create_remote_unlock(self):
            # Do not send createRemoteUnlockKey. The user unlocks the iPad.
            self.remote_unlock_host_key = ""

    class StrictUsbBootstrap(StrictPeerMixin, ts.RemotePairingLockdownService):
        async def _validate_pairing(self):
            if self.pair_record is None:
                # Upstream's initial verify exchange uses its zero placeholder
                # private key to obtain a clean rejection before pair-setup.
                # This path exists ONLY on the already trusted pinned USB link.
                accepted = await ts.RemotePairingProtocol._validate_pairing(self)
                if accepted:
                    raise ProbeFailure("unregistered_remote_pairing_unexpectedly_accepted")
                return False
            return await StrictPeerMixin._validate_pairing(self)

        async def _request_pair_consent(self):
            await self._send_pairing_data({
                "data": TLV.build([
                    {"type": T.METHOD, "data": b"\x00"},
                    {"type": T.STATE, "data": b"\x01"},
                ]),
                "kind": "setupManualPairing", "sendingHost": "iPad Screenshot Helper",
                "startNewSession": True,
            })
            response = (await self._receive_plain_response())["event"]["_0"]
            if "awaitingUserConsent" in response:
                raise ProbeFailure("usb_remote_pairing_requested_physical_consent")
            if "pairingRejectedWithError" in response:
                raise ProbeFailure("usb_remote_pairing_rejected")
            if "pairingData" not in response:
                raise ProbeFailure("usb_remote_pairing_unexpected_response")
            fields = self.decode_tlv(TLV.parse(
                self._decode_bytes_if_needed(response["pairingData"]["_0"]["data"])))
            if T.ERROR in fields or fields.get(T.STATE) != b"\x02":
                raise ProbeFailure("usb_remote_pairing_setup_rejected")
            return ts.PairConsentResult(public_key=bytes_field(fields, T.PUBLIC_KEY),
                                        salt=bytes_field(fields, T.SALT), pin=None)

        async def _save_pair_record_on_peer(self):
            result = await super()._save_pair_record_on_peer()
            fields = self.decode_tlv(result)
            self.installed_peer_key = bytes_field(fields, T.PUBLIC_KEY, 32)
            self.installed_peer_identifier = bytes_field(fields, T.IDENTIFIER)
            accessory_x = HKDF(algorithm=hashes.SHA512(), length=32,
                               salt=b"Pair-Setup-Accessory-Sign-Salt",
                               info=b"Pair-Setup-Accessory-Sign-Info").derive(self.encryption_key)
            try:
                Ed25519PublicKey.from_public_bytes(self.installed_peer_key).verify(
                    bytes_field(fields, T.SIGNATURE, 64),
                    accessory_x + self.installed_peer_identifier + self.installed_peer_key)
            except InvalidSignature:
                raise ProbeFailure("usb_remote_pairing_m6_signature_invalid") from None
            if not isinstance(self.peer_alt_irk, bytes) or len(self.peer_alt_irk) != 16:
                raise ProbeFailure("usb_remote_pairing_missing_alt_irk")
            return result

        def save_pair_record(self):
            record = {
                "strict_schema": 1, "device_hash": self.pin["device_hash"],
                "pinned_udid": self.remote_identifier,
                "host_identifier": self.identifier,
                "public_key": self.ed25519_private_key.public_key().public_bytes_raw(),
                "private_key": self.ed25519_private_key.private_bytes_raw(),
                "peer_public_key": self.installed_peer_key,
                "peer_identifier": self.installed_peer_identifier,
                "peer_alt_irk": self.peer_alt_irk,
                "remote_unlock_host_key": "",
            }
            # Never overwrite an existing record. Exclusive creation + private
            # mode; a failed partial write is retained for explicit inspection.
            descriptor = os.open(self.pair_record_path,
                                 os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(plistlib.dumps(record))
                handle.flush()
                os.fsync(handle.fileno())

    class StrictWifiService(StrictPeerMixin, ts.RemotePairingTunnelService):
        interfaces: tuple  # eligible host LAN interfaces for this attempt
        interface = None  # the one the verified control connection used
        connect_timeout = 3.0

        async def close(self):
            writer = self._writer
            self._reader = self._writer = None
            if writer is not None:
                await close_stream_writer(writer)

        async def connect(self, autopair=False):
            if autopair:
                raise ProbeFailure("wifi_automatic_pairing_forbidden")
            self._reader, self._writer = await asyncio.wait_for(
                asyncio.open_connection(self.hostname, self.port), timeout=self.connect_timeout)
            try:
                self.interface = require_lan_writer(self._writer, self.interfaces)
                await self._attempt_pair_verify()
                if not await self._validate_pairing() or not self.peer_signature_verified:
                    raise ProbeFailure("remote_peer_signature_not_verified")
                self._init_client_server_main_encryption_keys()
            except BaseException:
                await close_stream_writer(self._writer)
                self._reader = self._writer = None
                raise

        @asynccontextmanager
        async def start_tcp_tunnel(self):
            if not self.peer_signature_verified:
                raise ProbeFailure("remote_peer_signature_not_verified")
            parameters = await self.create_tcp_listener()
            port = parameters.get("port")
            if type(port) is not int or not 1 <= port <= 65535:
                raise ProbeFailure("invalid_authenticated_tunnel_port")
            if not hasattr(ssl.SSLContext, "set_psk_client_callback"):
                raise ProbeFailure("python_313_openssl_psk_required")
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            context.minimum_version = context.maximum_version = ssl.TLSVersion.TLSv1_2
            context.check_hostname = False
            # This transport authenticates with the verified pair exchange's
            # ephemeral PSK, not an X.509 certificate. No unauthenticated suite.
            context.verify_mode = ssl.CERT_NONE
            self._set_psk_ciphers(context)
            context.set_psk_client_callback(lambda hint: (None, self.encryption_key))
            reader, writer = await asyncio.wait_for(asyncio.open_connection(
                self.hostname, port, ssl=context, server_hostname=""), timeout=5)
            tunnel = None
            try:
                # The tunnel must leave on the same interface as the verified
                # control connection.
                require_lan_writer(writer, (self.interface,))
                cipher = writer.get_extra_info("ssl_object").cipher()[0]
                if "PSK" not in cipher:
                    raise ProbeFailure("tunnel_psk_cipher_not_confirmed")
                ts.OSUTIL.set_keepalive(writer.get_extra_info("socket"))
                tunnel = ts.RemotePairingTcpTunnel(reader, writer)
                handshake = await tunnel.request_tunnel_establish()
                await tunnel.start_tunnel(handshake["clientParameters"]["address"],
                                          handshake["clientParameters"]["mtu"],
                                          interface_name="ipad-remote-userspace")
                # Measurement only: timestamps inbound tunnel packets during a screenshot.
                with contextlib.suppress(Exception):
                    import link_timeline
                    link_timeline.attach(tunnel, writer.get_extra_info("socket"))
                yield ts.TunnelResult(tunnel.tun.name, handshake["serverAddress"],
                                     handshake["serverRSDPort"], ts.TunnelProtocol.TCP,
                                     tunnel, self.auxiliary_metadata)
            finally:
                if tunnel is not None:
                    with suppress(Exception):
                        await asyncio.wait_for(tunnel.stop_tunnel(), timeout=3)
                await close_stream_writer(writer)

    return StrictUsbBootstrap, StrictWifiService


async def bootstrap_usb(state: Path, apply_device_change=False, diagnostics=None):
    """Explicit initial setup; adds one RemotePairing record to the paired iPad."""
    if not apply_device_change:
        raise ProbeFailure("mutation_flag_required")
    state, pin, cache = configure(state)
    from pymobiledevice3 import usbmux
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.exceptions import RemotePairingCompletedError
    StrictUsb, _ = protocol_classes()
    evidence = diagnostics if diagnostics is not None else {}
    evidence.update(stage="resolve_pinned_usb", device_setting_changes=False,
                    remote_unlock_key_created=False, remote_pairing_record_added=False)
    devices = await usbmux.list_devices(usbmux_address="/var/run/usbmuxd")
    targets = [d for d in devices if d.is_usb and fingerprint(d.serial) == pin["device_hash"]]
    if len(targets) != 1:
        raise ProbeFailure("exact_pinned_usb_device_required")
    client = await create_using_usbmux(serial=targets[0].serial, connection_type="USB", autopair=False,
                                     pairing_records_cache_folder=cache, usbmux_address="/var/run/usbmuxd")
    async with client:
        if (not client.paired or fingerprint(client.udid) != pin["device_hash"]
                or client.product_type != pin["model"] or not supported_ipados(client.product_version)):
            raise ProbeFailure("trusted_expected_usb_device_required")
        existing = load_record(state, pin) is not None
        evidence.update(stage="usb_remote_pairing_existing_verify" if existing else "usb_remote_pairing_initial_setup",
                        device_model=client.product_type, device_os=client.product_version)

        async def create_service():
            service = await StrictUsb.create(client)
            service.state, service.pin = state, pin
            return service

        service = await create_service()
        try:
            try:
                await service.connect(autopair=not existing)
            except RemotePairingCompletedError:
                evidence["remote_pairing_record_added"] = True
                await service.close()
                evidence["stage"] = "usb_remote_pairing_new_record_verify"
                service = await create_service()
                await service.connect(autopair=False)
            if not service.peer_signature_verified:
                raise ProbeFailure("usb_record_device_signature_not_verified")
            if load_record(state, pin) is None:
                raise ProbeFailure("remote_pairing_record_not_saved")
            evidence.update(stage="usb_remote_pairing_ready", ok=True,
                            peer_signature_verified=True, existing_record_reused=existing,
                            wifi_capture_verified=False)
            return evidence
        finally:
            await service.close()


def untried_lan_addresses(addresses, interfaces, port, attempted_endpoints):
    """Keep the original IPv4-first order, but never redial one endpoint twice.

    Multiple matching mDNS service records may advertise the same address/port.
    They are only discovery hints for the same pinned device, not independent
    reasons to repeat a failed TCP/authentication attempt. Different ports and
    genuinely different addresses remain eligible; no remembered endpoint cache
    is persisted and the normal route/peer proof is still required per attempt.
    """
    eligible = [address for address in addresses if address.iface in interfaces
                and ipaddress.ip_address(address.ip).is_private
                and not ipaddress.ip_address(address.ip).is_loopback
                and not ipaddress.ip_address(address.ip).is_unspecified]
    eligible.sort(key=lambda address: (ipaddress.ip_address(address.ip).version != 4,
                                       not ipaddress.ip_address(address.ip).is_link_local))
    for address in eligible:
        endpoint = (ipaddress.ip_address(address.ip).compressed, port, address.iface)
        if endpoint in attempted_endpoints:
            continue
        attempted_endpoints.add(endpoint)
        yield address


class _TransportRelayGuard:
    """Wake inner service reads when the authenticated outer transport dies.

    Mirrors upstream UserspaceTunnelContext._watch_transport_closed without its
    USB discovery/bootstrap path. This watcher sends no packets and reconnects
    nothing. Closing the relay is shared by disconnect and normal teardown.
    """
    def __init__(self, client, close_relay, cleanup_timeout=0.5):
        self.client = client
        self.close_relay = close_relay
        self.cleanup_timeout = cleanup_timeout
        self.watcher = None
        self.close_task = None
        self.closing = False
        self.disconnected = False

    def start(self):
        if self.watcher is None:
            self.watcher = asyncio.create_task(self._watch())

    async def _close_relay_once(self):
        if self.close_task is None:
            self.close_task = asyncio.create_task(self.close_relay())
        # Cancelling a waiter must not abandon relay teardown halfway through.
        await asyncio.shield(self.close_task)

    async def _watch(self):
        try:
            await self.client.wait_closed()
        except asyncio.CancelledError:
            return
        except Exception:
            pass  # Any unknown transport ending is a disconnect, never a retry.
        if self.closing:
            return
        self.disconnected = True
        # A failed close is retained on close_task and re-raised by normal
        # teardown; never log peer details from a fire-and-forget watcher.
        with suppress(Exception):
            await self._close_relay_once()

    async def close(self):
        self.closing = True
        watcher = self.watcher
        if watcher is not None and watcher is not asyncio.current_task():
            if not watcher.done():
                watcher.cancel()
            done, _ = await asyncio.wait({watcher}, timeout=self.cleanup_timeout)
            if not done:
                raise ProbeFailure("transport_cleanup_failed")
            with suppress(asyncio.CancelledError, Exception):
                watcher.result()
        await self._close_relay_once()


@asynccontextmanager
async def open_remote_wifi_rsd(state: Path, browse_seconds=12.0, status_only=False,
                               diagnostics=None, discovery_file: Path | None = None):
    """Only known RemotePairing advertisements; host LAN routes; no usbmux calls.

    Discovery runs on every eligible LAN interface (Wi-Fi first, then active
    Ethernet). The interface the authenticated socket actually used is the
    one recorded and the one the tunnel must use.
    """
    state, pin, _ = configure(state)
    record = load_record(state, pin)
    if record is None:
        raise ProbeFailure("initial_usb_remote_pairing_required")
    _, StrictWifi = protocol_classes()
    from pymobiledevice3.bonjour import Address, ServiceInstance
    from system_bonjour import browse_remotepairing
    from pymobiledevice3.remote.siphash import compute_auth_tag
    from pymobiledevice3.remote import tunnel_service as ts, userspace_tunnel as us
    from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService
    evidence = diagnostics if diagnostics is not None else {}
    started = time.monotonic()

    def mark(stage, **safe_fields):
        evidence["stage"] = stage
        evidence.setdefault("stages", []).append({"stage": stage,
            "elapsed_ms": round((time.monotonic() - started) * 1000), **safe_fields})

    interfaces = lan_interfaces()
    evidence.update(host_interfaces=list(interfaces), requested_transport="strict_remote_pairing_lan",
                    usb_transport_used=False, autopair=False, remote_unlock_used=False,
                    physical_attachment_state="not_queried_by_capture_process",
                    matching_adverts=0, addresses_tried=0)
    def matches_properties(properties):
        identifier = properties.get("identifier")
        tag = properties.get("authTag")
        if not isinstance(identifier, str) or not isinstance(tag, str):
            return False
        try:
            supplied = base64.b64decode(tag, validate=True)
        except (ValueError, TypeError):
            return False
        return hmac.compare_digest(compute_auth_tag(record["peer_alt_irk"], identifier), supplied)

    service = None
    connected = None
    hint = load_endpoint_hint(state, interfaces) if discovery_file is None else None
    if hint is not None:
        # The iPad usually keeps its address and RemotePairing port until it
        # restarts or changes network: dial it directly and skip DNS-SD. The
        # same pair-verify device signature is required; any failure falls
        # back to normal discovery within this same attempt.
        evidence["endpoint_hint"] = "tried"
        candidate = StrictWifi(record["pinned_udid"], hint[0], hint[1])
        candidate.state, candidate.pin, candidate.interfaces = state, pin, interfaces
        candidate.connect_timeout = 1.0
        try:
            mark("endpoint_hint_verify")
            async with asyncio.timeout(4):
                await candidate.connect(autopair=False)
            service, connected = candidate, (hint[0], hint[1], candidate.interface)
            evidence["endpoint_hint"] = "used"
        except BaseException as error:
            await candidate.close()
            if not isinstance(error, Exception):
                raise
            mark("endpoint_hint_failed", error_class=type(error).__name__)
    if service is None:
        mark("remote_bonjour_discovery")
    if service is not None:
        answers = []
    elif discovery_file is not None:
        # System DNS-SD observations are discovery hints only. Both the
        # advertisement authTag and the cryptographic device proof below
        # remain mandatory, even for a locally edited/stale hint file.
        raw = json.loads(discovery_file.read_text())
        if not isinstance(raw, list) or len(raw) > 8:
            raise ProbeFailure("invalid_system_discovery_records")
        answers = [ServiceInstance(instance=a["instance"], host=a.get("host"),
                   port=a["port"], properties=a["properties"],
                   addresses=[Address(x["ip"], x["interface"]) for x in a["addresses"]])
                   for a in raw]
        evidence["discovery"] = "system_dns_sd_observation_file"
    else:
        answers = await browse_remotepairing(timeout=browse_seconds, interfaces=interfaces,
                    diagnostics=evidence.setdefault("discovery", {}),
                    accept_properties=matches_properties)
    attempted_endpoints = set()
    for answer in answers:
        identifier = answer.properties.get("identifier")
        tag = answer.properties.get("authTag")
        if not isinstance(identifier, str) or not tag:
            continue
        try:
            supplied_tag = base64.b64decode(tag, validate=True)
        except (ValueError, TypeError):
            continue
        if not hmac.compare_digest(compute_auth_tag(record["peer_alt_irk"], identifier), supplied_tag):
            continue
        evidence["matching_adverts"] += 1
        addresses = list(untried_lan_addresses(answer.addresses, interfaces, answer.port,
                                              attempted_endpoints))
        mark("matching_remote_advert", lan_address_count=len(addresses))
        for address in addresses:
            if evidence["addresses_tried"] >= 6:
                raise ProbeFailure("matching_address_attempt_limit")
            evidence["addresses_tried"] += 1
            candidate = StrictWifi(record["pinned_udid"], address.full_ip, answer.port)
            candidate.state, candidate.pin, candidate.interfaces = state, pin, interfaces
            try:
                mark("remote_pair_verify", address_kind="ipv4" if ":" not in address.ip else "ipv6")
                async with asyncio.timeout(8):
                    await candidate.connect(autopair=False)
                service, connected = candidate, (address.full_ip, answer.port, candidate.interface)
                break
            except BaseException as error:
                await candidate.close()
                if not isinstance(error, Exception):
                    raise
                # Never expose response bodies, endpoints, keys or identifiers.
                mark("remote_address_failed", error_class=type(error).__name__,
                     reason=str(error) if isinstance(error, ProbeFailure) else "protocol_or_transport_error")
        if service is not None:
            break
    if service is None:
        raise ProbeFailure("no_authenticated_remote_wifi_connection")
    if connected != hint:
        save_endpoint_hint(state, *connected)
    async with AsyncExitStack() as stack:
        stack.push_async_callback(service.close)
        evidence.update(peer_signature_verified=True, lan_socket_route_verified=True,
                        host_interface=service.interface)
        if status_only:
            mark("remote_wifi_control_ready")
            yield service, evidence
            return
        if us._active_tunnel is not None or ts.USE_USERSPACE_TUNNEL:
            raise ProbeFailure("another_userspace_tunnel_active_in_process")
        ts.USE_USERSPACE_TUNNEL = True
        stack.callback(setattr, ts, "USE_USERSPACE_TUNNEL", False)
        mark("authenticated_remote_tcp_tunnel")
        result = await stack.enter_async_context(service.start_tcp_tunnel())
        if not isinstance(result.client.tun, us.UserspaceTun):
            raise ProbeFailure("unexpected_non_userspace_tunnel")
        result.client.tun.set_peer(result.address)
        relay_stack = AsyncExitStack()
        guard = _TransportRelayGuard(result.client, relay_stack.aclose)
        stack.push_async_callback(guard.close)
        dial = await relay_stack.enter_async_context(us.UserspaceDialPlane(result.client.tun, result.address))
        if not dial._socket_dir or Path(dial._socket_dir).stat().st_mode & 0o077:
            raise ProbeFailure("private_unix_relay_unavailable")
        rsd = RemoteServiceDiscoveryService((result.address, result.port), open_connection=dial.dial,
                                          auxiliary_metadata=result.auxiliary_metadata)
        stack.push_async_callback(rsd.close)
        # Start before RSD handshake as a disconnected tunnel must also unblock
        # that handshake, not just subsequent DVT reads.
        guard.start()
        mark("remote_wifi_rsd_handshake")
        await rsd.connect()
        if guard.disconnected:
            raise ProbeFailure("remote_tunnel_disconnected")
        if fingerprint(rsd.udid) != pin["device_hash"]:
            raise ProbeFailure("rsd_device_identity_mismatch")
        evidence.update(root_used=False, lan_listener=False, relay="private_unix_socket")
        mark("remote_wifi_rsd_ready")
        yield rsd, evidence
