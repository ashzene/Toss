#!/bin/sh
# Pure burst/address checks and private temporary files; no socket, nothing sent.
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/ipad-waker-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
swiftc "$project_dir/Sources/HotkeyCore.swift" "$project_dir/Sources/IPadWaker.swift" \
    "$project_dir/Tests/IPadWakerTests.swift" -o "$test_dir/ipad-waker-tests"
"$test_dir/ipad-waker-tests"
