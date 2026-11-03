#!/bin/sh
# History line encoding and the 250/200-line trim; private temporary files only.
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/capture-history-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
swiftc "$project_dir/Sources/Language.swift" "$project_dir/Sources/ConnectionStatus.swift" "$project_dir/Sources/CaptureHistory.swift" \
    "$project_dir/Tests/CaptureHistoryTests.swift" -o "$test_dir/capture-history-tests"
"$test_dir/capture-history-tests"
