#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/toss-two-delivery.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
"${TOSS_PYTHON:-python3}" -B "$project_dir/Tests/TwoDeviceDeliveryFixture.py" \
    "$project_dir/Sources/TossApp.swift" "$test_dir/Fixture.swift"
xcrun swiftc "$project_dir/Sources/HotkeyCore.swift" "$project_dir/Sources/PairedDevice.swift" \
    "$test_dir/Fixture.swift" "$project_dir/Tests/TwoDeviceDeliveryTests.swift" -o "$test_dir/tests"
"$test_dir/tests"
