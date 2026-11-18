#!/bin/sh
# Pure copy and actual priority/progress methods; never construct TossDelegate.
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/device-copy-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
"${TOSS_PYTHON:-python3}" -B "$project_dir/Tests/DeviceCopyPriorityFixture.py" \
    "${DEVICE_COPY_TOSS_SOURCE:-$project_dir/Sources/TossApp.swift}" "$test_dir/DeviceCopyPriorityFixture.swift"
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
    "$project_dir/Sources/PairedDevice.swift" "$project_dir/Sources/DeviceCopy.swift" \
    "$project_dir/Sources/Language.swift" "$project_dir/Sources/SetupWizard.swift" "$project_dir/Sources/TossError.swift" \
    "$test_dir/DeviceCopyPriorityFixture.swift" "$project_dir/Tests/DeviceCopyTests.swift" \
    -o "$test_dir/device-copy-tests"
"$test_dir/device-copy-tests"
