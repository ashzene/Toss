#!/bin/sh
# Never run TossApp. Test a fake service plus real cross-process CFPreferences
# persistence in a private temporary plist (no writes to the user's preferences).
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# Keep the explicit CFPreferences application path in /tmp. The per-user
# DARWIN_USER_TEMP_DIR path is not usable by CFPreferences in a restricted runner.
test_dir=$(mktemp -d "/tmp/ipad-startup-controller.XXXXXX")
test_domain="io.github.ashzene.toss.startup-test.$(/usr/bin/uuidgen | tr '[:upper:]' '[:lower:]')"
cleanup() {
    rm -rf "$test_dir"
}
trap cleanup EXIT HUP INT TERM
test_bundle="$test_dir/StartupPreferenceFixture.app"
mkdir -p "$test_bundle/Contents/MacOS"
mkdir -m 700 "$test_dir/Preferences"
cat > "$test_bundle/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$test_domain</string>
<key>CFBundleExecutable</key><string>startup-controller-tests</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
EOF
xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 \
    -framework ServiceManagement \
    "$project_dir/Sources/Language.swift" "$project_dir/Sources/StartupController.swift" \
    "$project_dir/Tests/StartupControllerTests.swift" \
    -o "$test_bundle/Contents/MacOS/startup-controller-tests"
TOSS_TEST_PREFERENCES_DIRECTORY="$test_dir/Preferences" \
    "$test_bundle/Contents/MacOS/startup-controller-tests" --preference-domain "$test_domain"
