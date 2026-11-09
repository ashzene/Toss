#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/toss-transfer-cancel.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
test_app="$test_dir/Toss Transfer Preview.app"
mkdir -p "$test_app/Contents/MacOS"
cat > "$test_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.ashzene.toss.transfer-preview</string>
<key>CFBundleName</key><string>Toss Transfer Preview</string>
<key>CFBundleExecutable</key><string>TossTransferPreview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 \
    -framework AppKit -framework QuartzCore -framework CoreText -framework ImageIO -framework ScreenCaptureKit \
    Sources/Language.swift Sources/SettingsStyle.swift Sources/CaptureAnimation.swift Sources/AttachmentSighting.swift \
    Tests/TransferCancelUITests.swift -o "$test_app/Contents/MacOS/TossTransferPreview"
"$test_app/Contents/MacOS/TossTransferPreview" "$@"
