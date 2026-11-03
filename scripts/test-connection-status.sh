#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/toss-connection-status.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
swiftc "$project_dir/Sources/Language.swift" "$project_dir/Sources/ConnectionStatus.swift" \
    "$project_dir/Tests/ConnectionStatusTests.swift" -o "$test_dir/connection-status-tests"
"$test_dir/connection-status-tests"
