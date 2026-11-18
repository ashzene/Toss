"""Minimal pure helpers extracted from the local, tested ipad_probe.py.

There are no setup commands, imports of device services, or actions at import.
"""
import hashlib
import json
from pathlib import Path


class ProbeFailure(Exception):
    pass


def fingerprint(identifier: str) -> str:
    return hashlib.sha256(identifier.replace("-", "").encode()).hexdigest()


def device_class_from_model(model):
    """ProductType, never screen dimensions, determines the supported class."""
    if isinstance(model, str):
        for device_class in ("iPad", "iPhone"):
            if model.startswith(device_class):
                return device_class
    return None


def device_class_from_pin(pin):
    if not isinstance(pin, dict):
        raise ProbeFailure("unexpected_device_pin")
    inferred = device_class_from_model(pin.get("model"))
    # Only an absent field is legacy. An explicit null/unknown/mismatch fails.
    if inferred is None or pin.get("device_class", inferred) != inferred:
        raise ProbeFailure("unexpected_device_pin")
    return inferred


def read_device_pin(state):
    """Validate old/new target.json without changing the on-disk record."""
    try:
        pin = json.loads((Path(state) / "target.json").read_text())
    except (OSError, ValueError):
        raise ProbeFailure("unexpected_device_pin") from None
    device_class = device_class_from_pin(pin)
    if not isinstance(pin.get("device_hash"), str):
        raise ProbeFailure("unexpected_device_pin")
    return {**pin, "device_class": device_class}
