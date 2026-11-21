#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/toss-device-adapter.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
"${TOSS_PYTHON:-python3}" -B "$project_dir/Tests/DeviceCaptureAdapterFixture.py" \
    "$project_dir/Sources/TossApp.swift" "$project_dir/Tests/DeviceCaptureAdapterFixture.swift.txt" "$test_dir/Fixture.swift"
xcrun swiftc "$project_dir/Sources/HotkeyCore.swift" "$project_dir/Sources/PairedDevice.swift" \
    "$project_dir/Sources/DeviceCopy.swift" "$project_dir/Sources/Language.swift" "$project_dir/Sources/Toast.swift" \
    "$project_dir/Sources/DeviceCapturePipeline.swift" "$test_dir/Fixture.swift" "$project_dir/Tests/DeviceCaptureAdapterTests.swift" -o "$test_dir/tests"
"$test_dir/tests"
