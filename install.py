#!/usr/bin/env python3
"""Install the self-contained Toss app without launching it or importing data."""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import uuid


def install(folder, *, check_only=False):
    app_source = folder / "Toss.app"
    executable = Path("Contents/MacOS/Toss")
    runtime = Path("Contents/Resources/Runtime/python/bin/python3")
    if not (app_source / executable).is_file() or not (app_source / runtime).is_file():
        raise RuntimeError("The install source is incomplete. Keep Toss.app and its bundled runtime.")
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app_source)], check=True)
    if check_only:
        print("Install source checked. Nothing installed, no pairing data read, no app started.")
        return

    apps = Path.home() / "Applications"
    apps.mkdir(exist_ok=True)
    destination = apps / "Toss.app"
    if destination.exists():
        current = destination / executable
        if not current.is_file() or hashlib.sha256(current.read_bytes()).digest() != hashlib.sha256((app_source / executable).read_bytes()).digest():
            raise RuntimeError("A different version is installed. Quit Toss and move the existing app to the Trash, then run the installer again.")
    else:
        temporary = apps / (".toss-install-" + uuid.uuid4().hex + ".app")
        try:
            subprocess.run(["/usr/bin/ditto", str(app_source), str(temporary)], check=True)
            temporary.rename(destination)
        finally:
            if temporary.exists():
                shutil.rmtree(temporary)
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(destination)], check=True)
    print("Installed. Open ~/Applications/Toss.app yourself and grant the permissions.")
    print("No pairing data was imported, nothing was started and no login item was registered. The runtime is inside the app.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if os.geteuid() == 0:
        raise RuntimeError("Run this as the logged-in user, not with sudo.")
    os.umask(0o077)
    install(Path(__file__).resolve().parent, check_only=args.check)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        if isinstance(error, RuntimeError):
            print("Install did not finish: " + str(error), file=sys.stderr)
        else:
            print("Install did not finish: a local file or signature check failed. Nothing was started.", file=sys.stderr)
        sys.exit(1)
