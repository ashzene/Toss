#!/bin/sh
# Anonymous-pipe JSONL tests using a fake Python worker, never the real backend.
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_python=${TOSS_PYTHON:-"$project_dir/.venv/bin/python"}
if [ ! -x "$test_python" ]; then
    printf '%s\n' 'Set TOSS_PYTHON to an existing Python 3.13 interpreter.' >&2
    exit 1
fi
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/ipad-capture-worker.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
swiftc "$project_dir/Sources/Language.swift" "$project_dir/Sources/ConnectionStatus.swift" "$project_dir/Sources/CaptureWorker.swift" \
    "$project_dir/Tests/CaptureWorkerTests.swift" -o "$test_dir/capture-worker-tests"
"$test_dir/capture-worker-tests" "$test_python" "$project_dir/Tests/fixtures/fake_capture_worker.py"
