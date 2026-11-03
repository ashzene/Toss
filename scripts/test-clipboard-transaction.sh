#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/clipboard-transaction.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
swiftc "$project_dir/Sources/Language.swift" "$project_dir/Sources/TossError.swift" "$project_dir/Sources/HotkeyCore.swift" \
  "$project_dir/Sources/MacInput.swift" "$project_dir/Tests/ClipboardTransactionTests.swift" \
  -o "$test_dir/clipboard-tests"
"$test_dir/clipboard-tests"
