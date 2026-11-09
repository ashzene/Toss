#!/bin/sh
# Pure insertion policy + injected daemon/registry. Never opens real USB or launches Toss.
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/private/tmp}/toss-usb-setup.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
    "$project_dir/Sources/USBSetupObserver.swift" "$project_dir/Tests/USBSetupObserverTests.swift" \
    -o "$test_dir/usb-setup-tests"
"$test_dir/usb-setup-tests" "$project_dir/Sources/TossApp.swift"
