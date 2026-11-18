#!/bin/sh
# Pure metadata, persisted-state and cache policy tests; no real pairing directory.
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/paired-device-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
swiftc "$project_dir/Sources/PairedDevice.swift" "$project_dir/Tests/PairedDeviceTests.swift" \
    -o "$test_dir/paired-device-tests"
"$test_dir/paired-device-tests"
