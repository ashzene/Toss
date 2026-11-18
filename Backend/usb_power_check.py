#!/usr/bin/env python3
"""Ask a paired device over Wi-Fi whether it still has external power. No screenshot, no USB calls.

Toss runs this once after USB data drops. Still powered means the cable is in but its data
stopped, which Toss cannot fix by itself. Stdout is one JSON object: {"external_connected": bool|null}.
"""
from __future__ import annotations

import argparse
import asyncio
import inspect
import json
import os
from pathlib import Path
import sys
import threading

sys.path.insert(0, str(Path(__file__).resolve().parent / "vendor"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

TIMEOUT_SECONDS = 15


def external_connected(battery) -> bool | None:
    value = battery.get("ExternalConnected") if isinstance(battery, dict) else None
    return value if isinstance(value, bool) else None


async def read_power(state: Path) -> bool | None:
    from remote_pairing_transport import open_remote_wifi_rsd
    async with open_remote_wifi_rsd(state, browse_seconds=6.0) as (provider, _):
        battery = provider.get_value(domain="com.apple.mobile.battery")
        return external_connected(await battery if inspect.isawaitable(battery) else battery)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--device-class", choices=("iPad", "iPhone"), required=True)
    args = parser.parse_args(argv)
    # Nothing may keep this one-shot helper alive after the app quits, even a call that ignores cancellation.
    watchdog = threading.Timer(TIMEOUT_SECONDS + 3, os._exit, args=(0,))
    watchdog.daemon = True
    watchdog.start()
    try:
        from paired_devices import resolve_state

        async def bounded():
            async with asyncio.timeout(TIMEOUT_SECONDS):
                return await read_power(resolve_state(args.state_dir, args.device_class))
        connected = asyncio.run(bounded())
    except Exception:
        connected = None  # Wi-Fi unreachable or locked: say nothing rather than guess.
    print(json.dumps({"external_connected": connected}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
