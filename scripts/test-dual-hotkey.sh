#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/ipad-dual-hotkey-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
swiftc "$project_dir/Sources/HotkeyCore.swift" "$project_dir/Tests/DualHotkeyCoreTests.swift" -o "$test_dir/dual-hotkey-tests"
"$test_dir/dual-hotkey-tests"
