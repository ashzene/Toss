"""Two independent pinned devices. Reading never migrates or chooses by availability."""
import json
import os
from pathlib import Path
import shutil
import stat
import uuid

from ipad_probe import ProbeFailure, device_class_from_pin, read_device_pin

CLASSES = ("iPad", "iPhone")
LEGACY_FILES = ("target.json", "strict-remote-pairing.plist", "endpoint-hint.json", "cache")


def private_directory(path, create=False):
    path = Path(path)
    if create:
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ProbeFailure("private_existing_state_directory_required")
    return path


def read_targets(root):
    path = Path(root) / "target.json"
    if not path.exists() and not path.is_symlink():
        return {}, False
    private_directory(root)
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ProbeFailure("pairing_state_not_private")
    try:
        value = json.loads(path.read_bytes())
        if not isinstance(value, dict):
            raise ValueError()
        if "schema_version" not in value:
            pin = read_device_pin(root)
            return {pin["device_class"]: pin}, True
        if type(value["schema_version"]) is not int or value["schema_version"] != 2:
            raise ValueError()
        targets = value["devices"]
        if not isinstance(targets, dict) or set(targets) - set(CLASSES):
            raise ValueError()
        for kind, pin in targets.items():
            if device_class_from_pin(pin) != kind or not isinstance(pin.get("device_hash"), str):
                raise ValueError()
        return targets, False
    except (ValueError, KeyError, TypeError):
        raise ProbeFailure("unexpected_device_pin") from None


def write_targets(root, targets):
    root = private_directory(root, create=True)
    temporary = root / (".targets-" + uuid.uuid4().hex)
    try:
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(json.dumps({"schema_version": 2, "devices": targets}, sort_keys=True).encode())
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, root / "target.json")
    finally:
        temporary.unlink(missing_ok=True)


def device_directory(root, kind):
    if kind not in CLASSES:
        raise ProbeFailure("unexpected_device_pin")
    return Path(root) / "devices" / kind


def resolve_state(root, kind=None):
    targets, legacy = read_targets(root)
    if kind is None:
        if len(targets) != 1:
            raise ProbeFailure("unexpected_device_pin")
        kind = next(iter(targets))
    if kind not in targets:
        raise ProbeFailure("unexpected_device_pin")
    state = Path(root) if legacy else device_directory(root, kind)
    if not legacy:
        private_directory(Path(root) / "devices")
    private_directory(state)
    if read_device_pin(state) != targets[kind]:
        raise ProbeFailure("unexpected_device_pin")
    return state


def cleanup_legacy(root):
    # Only after the v2 index was committed. Retryable after an interrupted cleanup.
    for name in LEGACY_FILES[1:]:
        old = root / name
        if old.is_dir() and not old.is_symlink():
            shutil.rmtree(old)
        else:
            old.unlink(missing_ok=True)


def migrate_legacy(root):
    """Copy first, atomically publish the index last; an interrupted copy is retryable."""
    root = private_directory(root, create=True)
    targets, legacy = read_targets(root)
    if not legacy:
        if (root / "target.json").exists() and (root / "strict-remote-pairing.plist").exists():
            # A v2 index means copying finished before the interruption.
            for kind in targets:
                resolve_state(root, kind)
            cleanup_legacy(root)
        return targets
    kind = next(iter(targets))
    if not (root / "strict-remote-pairing.plist").exists():
        # An interrupted old setup wrote a pin but no credentials: it is not an occupied slot.
        write_targets(root, {})
        return {}
    private_directory(root / "devices", create=True)
    state = private_directory(device_directory(root, kind), create=True)
    if any(p.is_symlink() for p in state.rglob("*")):
        raise ProbeFailure("pairing_state_not_private")
    # Never follow a credential/cache symlink out of the private state.
    for name in LEGACY_FILES:
        source = root / name
        if source.is_symlink() or (source.is_dir() and any(p.is_symlink() for p in source.rglob("*"))):
            raise ProbeFailure("pairing_state_not_private")
        if source.is_dir():
            shutil.copytree(source, state / name, dirs_exist_ok=True)
        elif source.exists():
            shutil.copy2(source, state / name)
    # The original target may have omitted device_class; keep its bytes intact.
    write_targets(root, targets)
    cleanup_legacy(root)
    return targets


def register_device(root, kind):
    targets, legacy = read_targets(root)
    if legacy:
        raise ProbeFailure("unexpected_device_pin")
    state = device_directory(root, kind)
    private_directory(Path(root) / "devices")
    private_directory(state)
    pin = read_device_pin(state)
    if pin["device_class"] != kind or not (state / "strict-remote-pairing.plist").is_file():
        raise ProbeFailure("unexpected_device_pin")
    write_targets(root, {**targets, kind: pin})


def forget_device(root, kind):
    if kind not in CLASSES:
        raise ProbeFailure("unexpected_device_pin")
    targets = migrate_legacy(root)
    targets.pop(kind, None)
    # Publish removal first: a crash must not resurrect an old pairing.
    write_targets(root, targets)
    state = device_directory(root, kind)
    if state.exists() or state.is_symlink():
        private_directory(Path(root) / "devices")
        private_directory(state)
        shutil.rmtree(state)
