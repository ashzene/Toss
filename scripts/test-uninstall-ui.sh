#!/bin/sh
# Real settings/sheet layout, compiled without the app entry. Optional PNG output.
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
test_dir=$(mktemp -d "${TMPDIR:-/private/tmp}/toss-uninstall-ui.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
xcrun swiftc -swift-version 5 -parse-as-library -D TOSS_RENDER -target arm64-apple-macosx14.0 \
    -framework AppKit -framework ApplicationServices -framework CryptoKit -framework ServiceManagement \
    -framework QuartzCore -framework ImageIO -framework ScreenCaptureKit -framework CoreText \
    Sources/*.swift Tests/UninstallUITests.swift -o "$test_dir/uninstall-ui-tests"
"$test_dir/uninstall-ui-tests" "$@"
