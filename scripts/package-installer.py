#!/usr/bin/env python3
"""Build a signed native drag-to-install window; never install or open it."""
import argparse
import plistlib
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--payload', type=Path, default=root / 'build/release/Toss.app')
parser.add_argument('--output', type=Path, default=root / 'build/release')
parser.add_argument('--identity', default='Toss Local Signing')
parser.add_argument('--qa', action='store_true', help='compile an isolated destination for installer tests')
parser.add_argument('--no-dmg', action='store_true')
args = parser.parse_args()
app = args.payload.resolve()
out = args.output.resolve(); out.mkdir(parents=True, exist_ok=True)
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
signature = subprocess.run(['codesign', '-dv', '--verbose=4', str(app)], capture_output=True, text=True, check=True)
digest = re.search(r'^CDHash=(\w+)$', signature.stderr, re.MULTILINE).group(1)
installer = out / 'Toss Installer.app'
if installer.exists(): shutil.rmtree(installer)
contents = installer / 'Contents'; (contents / 'MacOS').mkdir(parents=True)
resources = contents / 'Resources'; resources.mkdir()
subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-O',
    '-target', 'arm64-apple-macosx14.0', *(['-D', 'INSTALLER_QA'] if args.qa else []),
    *map(str, sorted((root / 'Installer').glob('*.swift'))), '-o', str(contents / 'MacOS/Installer')], check=True)
metadata = {'CFBundleIdentifier': 'io.github.ashzene.toss.installer' + ('.qa' if args.qa else ''),
    'CFBundleExecutable': 'Installer', 'CFBundleName': 'Toss Installer', 'CFBundleDisplayName': 'Toss Installer',
    'CFBundlePackageType': 'APPL', 'CFBundleIconFile': 'Toss.icns',
    'CFBundleShortVersionString': info['CFBundleShortVersionString'], 'CFBundleVersion': info['CFBundleVersion'],
    'LSMinimumSystemVersion': '14.0', 'LSUIElement': True, 'NSHighResolutionCapable': True,
    'TossPayloadIdentifier': info['CFBundleIdentifier'], 'TossPayloadHash': digest}
(contents / 'Info.plist').write_bytes(plistlib.dumps(metadata))
subprocess.run(['ditto', str(app), str(resources / 'Toss.app')], check=True)
shutil.copyfile(app / 'Contents/Resources/Toss.icns', resources / 'Toss.icns')
shutil.copyfile(root / 'User Guide.txt', resources / 'User Guide.txt')
for name, target in [('background.tiff', 'background.tiff'), ('guide.icns', 'Guide.icns')]:
    shutil.copyfile(root / 'Assets/DmgWindow' / name, resources / target)
subprocess.run(['codesign', '--force', '--sign', args.identity, str(installer)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(installer)], check=True)
if not args.no_dmg:
    dmg = out / f"Toss {info['CFBundleShortVersionString']} Nightly for iPad.dmg"
    with tempfile.TemporaryDirectory(prefix='toss-native-install-', dir='/private/tmp') as scratch:
        stage = Path(scratch) / 'stage'; stage.mkdir()
        subprocess.run(['ditto', str(installer), str(stage / installer.name)], check=True)
        image = Path(scratch) / 'Toss.dmg'
        subprocess.run(['hdiutil', 'create', '-quiet', '-volname', 'Toss ' + info['CFBundleShortVersionString'],
            '-srcfolder', str(stage), '-format', 'ULMO', str(image)], check=True)
        subprocess.run(['hdiutil', 'verify', str(image)], check=True)
        shutil.copyfile(image, dmg)
    print('Packaged:', dmg)
print('Built, not opened:', installer)
