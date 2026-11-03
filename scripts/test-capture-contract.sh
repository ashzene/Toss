#!/bin/sh
# Compile only the pure contract. Do not link or run TossApp or target UI code.
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/ipad-capture-contract.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
swiftc "$project_dir/Sources/CaptureContract.swift" \
    "$project_dir/Tests/CaptureContractTests.swift" -o "$test_dir/capture-contract-tests"
"$test_dir/capture-contract-tests"
