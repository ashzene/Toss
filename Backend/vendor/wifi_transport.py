"""Host LAN interface lookup, extended from the tested local wifi_transport.py.

The older direct-lockdown and usbmux transport paths are not included.
"""
import ipaddress
import re
import socket
import subprocess
from ipad_probe import ProbeFailure

# Wi-Fi and wired Ethernet (built-in, Thunderbolt or USB adapters) are enN.
# utun, awdl, llw, bridge, anpi, ap and loopback interfaces never match.
LAN_DEVICE = re.compile(r"en[0-9]{1,3}")
WIFI_PORTS = ("Wi-Fi", "AirPort")


def hardware_ports(listing: str):
    """(port name, device) pairs from `networksetup -listallhardwareports`."""
    ports = []
    for block in listing.split("\n\n"):
        port = device = None
        for line in block.splitlines():
            if line.startswith("Hardware Port: "):
                port = line.split(": ", 1)[1].strip()
            elif line.startswith("Device: "):
                device = line.split(": ", 1)[1].strip()
        if port and device:
            ports.append((port, device))
    return ports


def has_lan_ipv4(addresses) -> bool:
    """A configured private, non-link-local IPv4 marks an active LAN port."""
    for address in addresses:
        if address.family != socket.AF_INET:
            continue
        try:
            ip = ipaddress.ip_address(address.address)
        except ValueError:
            continue
        if ip.is_private and not (ip.is_link_local or ip.is_loopback or ip.is_unspecified):
            return True
    return False


def select_lan_interfaces(ports, addresses, stats) -> tuple:
    """Wi-Fi first, then other active Ethernet-class ports, in system order.

    Wi-Fi stays eligible exactly as before, even while it rejoins a network.
    Another port must be up with a private IPv4 address: idle Thunderbolt
    bridge members, virtual adapters and an iPad's own USB network link
    (IPv6 link-local only, and never named as a LAN port here) are excluded.
    """
    wifi, wired = [], []
    for port, device in ports:
        if not LAN_DEVICE.fullmatch(device) or device in wifi or device in wired:
            continue
        if port.startswith(WIFI_PORTS):
            wifi.append(device)
        elif ("iPad" not in port and device in stats and stats[device].isup
                and has_lan_ipv4(addresses.get(device, ()))):
            wired.append(device)
    return tuple(wifi + wired)


def lan_interfaces() -> tuple:
    import psutil
    result = subprocess.run(
        ["/usr/sbin/networksetup", "-listallhardwareports"],
        capture_output=True, text=True, check=True, timeout=5,
    )
    interfaces = select_lan_interfaces(hardware_ports(result.stdout),
                                       psutil.net_if_addrs(), psutil.net_if_stats())
    if not interfaces:
        raise ProbeFailure("lan_interface_not_identified")
    return interfaces
