#!/bin/sh
# Static type checking only; no executable, app bundle, signing or launch.
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
xcrun swiftc -typecheck -parse-as-library -swift-version 5 -target arm64-apple-macosx14.0 \
  -framework AppKit -framework ApplicationServices -framework QuartzCore \
  -framework ImageIO -framework ScreenCaptureKit -framework CoreText \
  Sources/*.swift
printf '%s\n' 'Upload integration: all Swift sources typechecked (no executable or app produced).'
