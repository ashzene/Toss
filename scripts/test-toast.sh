#!/bin/zsh
# Pure policy/timing/preferences tests. Never construct a window or start Toss.
set -eu
cd "${0:A:h:h}"
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/toss-toast-tests.XXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT
# ChatTarget's TargetKind shares a file with its two target adapters.
xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 \
  -framework AppKit -framework ApplicationServices -framework QuartzCore -framework CoreText \
  Sources/Language.swift Sources/StrictTarget.swift Sources/ClaudeTarget.swift Sources/ChatTarget.swift Sources/TargetActivator.swift \
  Sources/SettingsStyle.swift Sources/Toast.swift Tests/ToastTests.swift -o "$temporary_dir/toast-tests"
"$temporary_dir/toast-tests"
