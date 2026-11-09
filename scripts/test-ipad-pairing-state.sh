#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/toss-pairing-state.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
xcrun swiftc "$project_dir/Sources/IPadPairingState.swift" "$project_dir/Tests/IPadPairingStateTests.swift" -o "$test_dir/tests"
"$test_dir/tests"
