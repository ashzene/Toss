#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/toss-device-pipeline.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
xcrun swiftc "$project_dir/Sources/HotkeyCore.swift" "$project_dir/Sources/PairedDevice.swift" \
    "$project_dir/Sources/DeviceCapturePipeline.swift" "$project_dir/Tests/DeviceCapturePipelineTests.swift" -o "$test_dir/tests"
"$test_dir/tests"
