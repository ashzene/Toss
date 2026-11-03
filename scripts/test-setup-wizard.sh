#!/bin/sh
# Streaming setup progress with a synthetic /bin/sh script; never the real backend.
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/ipad-setup-wizard.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
    "$project_dir/Sources/Language.swift" "$project_dir/Sources/SetupWizard.swift" "$project_dir/Tests/SetupWizardTests.swift" -o "$test_dir/setup-wizard-tests"
"$test_dir/setup-wizard-tests"
