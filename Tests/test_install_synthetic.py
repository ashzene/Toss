"""Exercise Toss installation using a fake home, fake app and injected commands."""
import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
from unittest.mock import patch


def main():
    spec = importlib.util.spec_from_file_location("synthetic_installer", Path(__file__).resolve().parents[1] / "install.py")
    installer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(installer)
    with tempfile.TemporaryDirectory(prefix="toss-install-test-") as temporary:
        root = Path(temporary)
        folder = root / "delivery"
        app = folder / "Toss.app"
        executable = Path("Contents/MacOS/Toss")
        runtime = Path("Contents/Resources/Runtime/python/bin/python3")
        for relative in (executable, runtime):
            target = app / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(b"SYNTHETIC TEST ONLY")
        fake_home = root / "user"
        fake_home.mkdir()
        untouched = fake_home / "Library/Application Support/Toss/DeviceState/target.json"
        untouched.parent.mkdir(parents=True)
        untouched.write_bytes(b"DO NOT IMPORT OR REPLACE")
        calls = []

        def command(args, **kwargs):
            calls.append(args)
            assert kwargs == {"check": True}
            if args[0] == "/usr/bin/ditto":
                shutil.copytree(args[1], args[2])
            else:
                assert args[:4] == ["/usr/bin/codesign", "--verify", "--deep", "--strict"]
            return subprocess.CompletedProcess(args, 0)

        with patch.object(Path, "home", return_value=fake_home), patch.object(installer.subprocess, "run", side_effect=command):
            installer.install(folder, check_only=True)
            assert not (fake_home / "Applications").exists()
            installer.install(folder)
            installer.install(folder)
            destination = fake_home / "Applications/Toss.app"
            assert (destination / executable).read_bytes() == (app / executable).read_bytes()
            assert (destination / runtime).read_bytes() == (app / runtime).read_bytes()
            assert sum(call[0] == "/usr/bin/ditto" for call in calls) == 1
            (app / executable).write_bytes(b"DIFFERENT BUILD")
            try:
                installer.install(folder)
            except RuntimeError:
                pass
            else:
                raise AssertionError("A different installed build must be preserved")
            assert (destination / executable).read_bytes() == b"SYNTHETIC TEST ONLY"
            assert untouched.read_bytes() == b"DO NOT IMPORT OR REPLACE"
            assert not (untouched.parents[1] / "config.json").exists()
            assert sorted(p.name for p in (fake_home / "Applications").iterdir()) == ["Toss.app"]
    print("Synthetic installer passed: check-only, bundled runtime, repeat install, different-build refusal, pairing preserved; injected commands only.")


if __name__ == "__main__":
    main()
