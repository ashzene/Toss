#!/bin/sh
# Synthetic logs in private temporary directories; never read real logs or launch Toss.
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/toss-log-export-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 \
    "$project_dir/Sources/LogExporter.swift" "$project_dir/Tests/LogExporterTests.swift" \
    -o "$test_dir/log-export-tests"
"$test_dir/log-export-tests"
