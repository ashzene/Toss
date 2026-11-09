#!/bin/sh
# Every language file has every string the app shows, with the same placeholders and line count.
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PYTHONDONTWRITEBYTECODE=1 "${TOSS_PYTHON:-python3}" "$project_dir/scripts/check-localization.py" "$project_dir"
