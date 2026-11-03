#!/bin/sh
# Offscreen native views only; optional first argument saves rendered PNGs.
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/toss-log-export-ui.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 \
    -framework AppKit -framework QuartzCore -framework CoreText -framework ImageIO -framework ScreenCaptureKit \
    Sources/Language.swift Sources/SettingsStyle.swift Sources/ConnectionStatus.swift Sources/Onboarding.swift \
    Sources/MenuBarStatus.swift Sources/CaptureAnimation.swift Sources/AttachmentSighting.swift Sources/LogExportNotice.swift \
    Tests/LogExportUITests.swift -o "$test_dir/log-export-ui-tests"
"$test_dir/log-export-ui-tests" "$@"
