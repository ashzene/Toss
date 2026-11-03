#!/usr/bin/env python3
"""Build and sign the self-contained app (runtime included); never launch it.

The runtime folder is prepared once by scripts/prepare-runtime.sh: a relocatable
CPython 3.13 (python-build-standalone) plus the pinned packages from
Backend/requirements-tested.txt, precompiled.

Signing: with the stable identity from scripts/create-signing-identity.sh (found
automatically), macOS keeps the user's Accessibility / Input Monitoring grants
across updates. Without it the build is ad-hoc signed and every update needs
those grants again. --dmg also writes the distributable disk image.
"""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

VERSION, BUILD = "1.0.0", "39"
DEFAULT_IDENTITY = "Toss Local Signing"

project = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, default=project / "build/release")
parser.add_argument("--runtime", type=Path, default=project.parent / "runtime/python")
parser.add_argument("--identity", default=os.environ.get("TOSS_SIGN_IDENTITY"),
                    help="code-signing identity; default: the stable local one if present, else ad-hoc")
parser.add_argument("--dmg", action="store_true", help="also create the disk image next to the app")
parser.add_argument("--zip", action="store_true", help="also create Toss.app.zip next to the app")
args = parser.parse_args()
if args.identity is None:
    found = subprocess.run(["/usr/bin/security", "find-identity", "-p", "codesigning"],
                           capture_output=True, text=True).stdout
    args.identity = DEFAULT_IDENTITY if f'"{DEFAULT_IDENTITY}"' in found else "-"
if args.identity == "-":
    print("WARNING: ad-hoc signature. Users must grant Accessibility/Input Monitoring again after this "
          "update. Run scripts/create-signing-identity.sh once to keep grants across updates.")
runtime = args.runtime.resolve()
if not (runtime / "bin/python3").exists():
    raise SystemExit("runtime missing: run scripts/prepare-runtime.sh first")
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
# Keep build outputs out of Spotlight and Launchpad, so app search only finds the installed Toss
# (2026-10-29: searching showed a pile of build copies).
(out / ".metadata_never_index").touch()
app = out / "Toss.app"
if app.exists():
    shutil.rmtree(app)
macos = app / "Contents/MacOS"
resources = app / "Contents/Resources"
macos.mkdir(parents=True)
resources.mkdir()
subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", "-O",
    "-target", "arm64-apple-macosx14.0", "-framework", "AppKit", "-framework", "ApplicationServices",
    "-framework", "CryptoKit", "-framework", "ServiceManagement", "-framework", "QuartzCore", "-framework", "ScreenCaptureKit",
    *map(str, sorted((project / "Sources").glob("*.swift"))),
    "-o", str(macos / "Toss")], check=True)
info = {"CFBundleIdentifier": "io.github.ashzene.toss", "CFBundleName": "Toss",
    "CFBundleDisplayName": "Toss", "CFBundleExecutable": "Toss",
    "CFBundlePackageType": "APPL", "CFBundleShortVersionString": VERSION, "CFBundleVersion": BUILD,
    "LSUIElement": True, "LSMinimumSystemVersion": "14.0", "NSHighResolutionCapable": True,
    "LSArchitecturePriority": ["arm64"],
    "CFBundleDevelopmentRegion": "en", "CFBundleLocalizations": ["en"],
    "NSLocalNetworkUsageDescription": "Connect to your paired iPad and request a screenshot over your local network when you press a shortcut.",
    "NSBonjourServices": ["_remotepairing._tcp"]}
# App icon: Assets/Toss.icon (Icon Composer) compiles to Assets.car so macOS 26 draws the light,
# dark, clear and tinted variants itself; Toss.icns from Toss.iconset covers older systems.
# actool needs full Xcode 26 (Command Line Tools lack it); only actool gets DEVELOPER_DIR.
xcode = os.environ.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
with tempfile.TemporaryDirectory() as partial:
    partial = Path(partial) / "partial.plist"
    subprocess.run(["/usr/bin/xcrun", "actool", str(project / "Assets/Toss.icon"), "--compile", str(resources),
        "--app-icon", "Toss", "--enable-on-demand-resources", "NO", "--development-region", "en",
        "--target-device", "mac", "--platform", "macosx", "--minimum-deployment-target", "14.0",
        "--output-partial-info-plist", str(partial), "--errors", "--warnings"],
        check=True, env={**os.environ, "DEVELOPER_DIR": xcode})
    info.update(plistlib.loads(partial.read_bytes()))
subprocess.run(["/usr/bin/iconutil", "-c", "icns", str(project / "Assets/Toss.iconset"),
                "-o", str(resources / "Toss.icns")], check=True)
(app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
ignore = shutil.ignore_patterns("__pycache__", "*.pyc", ".DS_Store", "tests")
shutil.copytree(project / "Backend", resources / "Backend", ignore=ignore)
# ditto keeps the runtime's symlinks and precompiled bytecode intact.
subprocess.run(["/usr/bin/ditto", str(runtime), str(resources / "Runtime/python")], check=True)
# Console-script wrappers (pymobiledevice3, ipython, uvicorn, ...) carry this Mac's absolute
# interpreter path in their first lines and are never used: Toss runs python3 directly. Ship
# only the interpreter itself, so the bundle holds no local paths and no dead launchers.
runtime_bin = resources / "Runtime/python/bin"
for entry in runtime_bin.iterdir():
    if entry.name in ("python", "python3", "python3.13"):
        continue
    if entry.is_symlink() or entry.is_file():
        entry.unlink()
# The runtime's bytecode was compiled in place, so every .pyc records this Mac's absolute source path.
# Recompile exactly the existing .pyc files with the bundled interpreter, recording a neutral
# "Runtime/python/..." path and unchecked-hash validation (independent of file dates).
recompile = '''
import importlib.util, pathlib, py_compile, sys
root = pathlib.Path(sys.argv[1])
for pyc in root.joinpath("lib").rglob("*.pyc"):
    try:
        source = pathlib.Path(importlib.util.source_from_cache(str(pyc)))
    except ValueError:
        continue
    if source.exists():
        py_compile.compile(str(source), cfile=str(pyc), dfile="Runtime/python/" + str(source.relative_to(root)),
                           doraise=True, invalidation_mode=py_compile.PycInvalidationMode.UNCHECKED_HASH)
'''
subprocess.run([str(runtime_bin / "python3"), "-I", "-c", recompile, str(resources / "Runtime/python")],
               check=True, env={"PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1"})
shutil.copyfile(project / "User Guide.txt", resources / "User Guide.txt")
# Toss's own upload cues (2026-10-24). Both are required: the shipped app
# carries no Codex sound and has no fallback.
for cue in ("Toss-Success.aiff", "Toss-Failure.aiff"):
    if not (project / "Assets/Sounds" / cue).exists():
        sys.exit(f"missing Assets/Sounds/{cue}")
    shutil.copyfile(project / "Assets/Sounds" / cue, resources / cue)
# Settings window type: Source Serif 4 + Hanken Grotesk (SIL OFL, licences alongside).
shutil.copytree(project / "Assets/Fonts", resources / "Fonts")
# Nothing from the build Mac may ship: refuse a bundle whose text files carry this Mac's home path
# (2026-10-29: runtime launchers did, until they were dropped above).
home = str(Path.home()).encode()
for path in app.rglob("*"):
    if path.is_file() and not path.is_symlink() and path.stat().st_size < 4 * 1024 * 1024:
        if home in path.read_bytes():
            sys.exit(f"build Mac's home path found in the bundle: {path.relative_to(app)}")
subprocess.run(["/usr/bin/codesign", "--force", "--sign", args.identity, "--identifier", "io.github.ashzene.toss",
                str(app)], check=True)
subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
requirement = subprocess.run(["/usr/bin/codesign", "-d", "-r-", str(app)], capture_output=True, text=True)
print(next((line for line in (requirement.stdout + requirement.stderr).splitlines() if "designated" in line), "designated requirement unavailable"))
print("Built and signature-verified. App was NOT launched: " + str(app))
subprocess.run(["/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                "-u", str(app)], check=False, stderr=subprocess.DEVNULL)

if args.dmg:
    # The app installs itself into Applications on first open; no script needed.
    dmg = out / f"Toss {VERSION}.dmg"
    with tempfile.TemporaryDirectory() as staging:
        staging = Path(staging)
        subprocess.run(["/usr/bin/ditto", str(app), str(staging / app.name)], check=True)
        (staging / "Applications").symlink_to("/Applications")
        for name in ("User Guide.txt",):
            shutil.copy2(project / name, staging / name)
        if dmg.exists():
            dmg.unlink()
        subprocess.run(["/usr/bin/hdiutil", "create", "-quiet", "-volname", f"Toss {VERSION}",
                        "-srcfolder", str(staging), "-format", "UDZO", "-fs", "HFS+", str(dmg)], check=True)
    digest = subprocess.run(["/usr/bin/shasum", "-a", "256", str(dmg)], capture_output=True, text=True, check=True)
    print("Disk image: " + str(dmg) + "\n" + digest.stdout.strip())

if args.zip:
    # --sequesterRsrc keeps extended attributes in __MACOSX/ instead of beside the files: without it
    # Finder's Archive Utility and unzip write ._ files next to the bundle's symlinks and the
    # extracted app fails its signature check (2026-10-29).
    archive = out / "Toss.app.zip"
    if archive.exists():
        archive.unlink()
    subprocess.run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive)], check=True)
    digest = subprocess.run(["/usr/bin/shasum", "-a", "256", str(archive)], capture_output=True, text=True, check=True)
    print("Zip: " + str(archive) + "\n" + digest.stdout.strip())
