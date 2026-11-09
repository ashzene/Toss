#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/toss-entry.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
xcrun swiftc -parse-as-library -swift-version 5 -D TOSS_RENDER "$project_dir"/Sources/*.swift "$project_dir/Tests/EntryRoutingTests.swift" -o "$test_dir/entry-tests"
"$test_dir/entry-tests"
