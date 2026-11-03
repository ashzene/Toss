#!/bin/sh
# Pure onboarding rules and copy; no window, device or setup process.
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/toss-onboarding.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 -parse-as-library \
    "$project_dir/Sources/Language.swift" "$project_dir/Sources/SettingsStyle.swift" "$project_dir/Sources/Onboarding.swift" \
    "$project_dir/Tests/OnboardingTests.swift" -o "$test_dir/onboarding-tests"
"$test_dir/onboarding-tests" "$project_dir/Sources/TossApp.swift"
