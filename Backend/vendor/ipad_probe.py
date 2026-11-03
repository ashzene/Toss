"""Minimal pure helpers extracted from the local, tested ipad_probe.py.

There are no setup commands, imports of device services, or actions at import.
"""
import hashlib


class ProbeFailure(Exception):
    pass


def fingerprint(identifier: str) -> str:
    return hashlib.sha256(identifier.replace("-", "").encode()).hexdigest()
