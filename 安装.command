#!/bin/zsh
# Compatibility entry point: the app owns installation of all bundled features.
set -euo pipefail
TASK_APP="${0:A:h}/Toss.app"
[[ -d "$TASK_APP" ]] || TASK_APP="${0:A:h}/../Release/Toss.app"
if [[ ! -d "$TASK_APP" ]]; then
  print 'Toss.app was not found. Open the Toss disk image, then open Toss.'
  exit 1
fi
print 'Opening Toss. Its menu bar feature is included in the same app installation.'
/usr/bin/open "$TASK_APP"
