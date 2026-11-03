#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/ipad-attachment-sighting.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
swiftc "$project_dir/Sources/AttachmentSighting.swift" "$project_dir/Tests/AttachmentSightingPolicyTests.swift" -o "$test_dir/attachment-sighting-tests"
"$test_dir/attachment-sighting-tests"
