#!/bin/zsh
set -eu
cd "${0:A:h:h}"
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/toss-animation-tests.XXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT
xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 -framework AppKit -framework QuartzCore -framework ImageIO -framework ScreenCaptureKit \
  -framework CoreText Sources/Language.swift Sources/SettingsStyle.swift Sources/CaptureAnimation.swift Sources/AttachmentSighting.swift Tests/CaptureAnimationTests.swift -o "$temporary_dir/animation-tests"
"$temporary_dir/animation-tests"
