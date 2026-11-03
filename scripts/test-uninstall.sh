#!/bin/sh
# No real home deletion, TCC, login service, Finder or app recycling.
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_python=${TOSS_PYTHON:?Set TOSS_PYTHON to the existing runtime}
test_dir=$(mktemp -d "${TMPDIR:-/private/tmp}/toss-uninstall.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
    "$project_dir/Sources/Language.swift" "$project_dir/Sources/UninstallController.swift" \
    "$project_dir/Sources/ConnectionStatus.swift" "$project_dir/Sources/CaptureWorker.swift" \
    "$project_dir/Sources/SetupWizard.swift" "$project_dir/Tests/UninstallTests.swift" \
    -o "$test_dir/uninstall-tests"
"$test_dir/uninstall-tests" "$project_dir" "$test_python"
