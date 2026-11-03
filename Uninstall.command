#!/bin/zsh
set -euo pipefail
if /usr/bin/pgrep -x Toss >/dev/null; then
  print 'Quit Toss from its menu before uninstalling.'
  exit 1
fi
TASK_APP="/Applications/Toss.app"
[[ -d "$TASK_APP" ]] || TASK_APP="$HOME/Applications/Toss.app"
TASK_SUPPORT="$HOME/Library/Application Support/Toss"
TASK_CACHE="$HOME/Library/Caches/Toss"
TASK_EXEC="$TASK_APP/Contents/MacOS/Toss"
if [[ ! -x "$TASK_EXEC" ]]; then
  print 'Toss was not found. Restore the app to unregister its login item, then try again. No files were removed.'
  exit 1
fi
# Version 0.4+ handles this before any UI, auto-resume, keys or device work.
TASK_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$TASK_APP/Contents/Info.plist")
if [[ "$TASK_VERSION" != <-> ]] || (( TASK_VERSION < 10 )); then
  print 'This older build needs its matching uninstaller. No files were removed.'
  exit 1
fi
"$TASK_EXEC" --unregister-login-item
/bin/rm -rf -- "$TASK_APP" "$TASK_SUPPORT" "$TASK_CACHE"
# Accessibility stays granted (2026-10-29): a reinstall then works at once instead of
# asking again. The entry can be removed by hand in System Settings → Privacy & Security.
print 'Login item unregistered. Toss, its runtime, local pairing files, and screenshot cache have been removed.'
print 'Trust and Developer Mode on your iPad are unchanged. You can change them in iPad Settings.'
print 'The Accessibility permission was kept so a reinstall works at once. You can remove it in System Settings → Privacy & Security → Accessibility.'
print 'Press Return to close this window.'
read -r
