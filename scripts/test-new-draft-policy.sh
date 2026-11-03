#!/bin/zsh
set -eu
cd "${0:A:h:h}"
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/toss-new-draft-tests.XXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT
swiftc Sources/Language.swift Sources/StrictTarget.swift Sources/ClaudeTarget.swift Sources/ChatTarget.swift Sources/TargetActivator.swift Tests/NewDraftPolicyTests.swift -o "$temporary_dir/new-draft-tests"
"$temporary_dir/new-draft-tests"
