#!/bin/zsh
# Rebuild ../runtime/python. Downloads python-build-standalone 3.13.15 (checksum
# verified against the release's SHA256SUMS) and installs the pinned packages.
# Reference recipe: the 0.6.0 build copied the already-verified local packages
# instead of running the pip step below.
set -euo pipefail
project=${0:A:h:h}
runtime="$project/../runtime"
tag=20260929
file="cpython-3.13.15+${tag}-aarch64-apple-darwin-install_only_stripped.tar.gz"
work=$(mktemp -d /tmp/toss-runtime.XXXXXX)
trap 'rm -rf "$work"' EXIT
base="https://github.com/astral-sh/python-build-standalone/releases/download/$tag"
curl -sSfL -o "$work/$file" "$base/${file//+/%2B}"
curl -sSfL -o "$work/SHA256SUMS" "$base/SHA256SUMS"
[[ "$(grep " $file\$" "$work/SHA256SUMS" | awk '{print $1}')" == "$(shasum -a 256 "$work/$file" | awk '{print $1}')" ]]
rm -rf "$runtime/python" && mkdir -p "$runtime"
tar -xzf "$work/$file" -C "$runtime"
"$runtime/python/bin/python3" -m pip install --no-cache-dir --only-binary=:all: -r "$project/Backend/requirements-tested.txt"
bash -c 'shopt -s nullglob; cd "$1"; L=lib/python3.13; rm -rf $L/test $L/idlelib $L/tkinter $L/turtledemo $L/ensurepip $L/lib2to3 lib/tcl* lib/tk* lib/itcl* share include bin/idle3* bin/pydoc3* bin/2to3* bin/pip* bin/*-config $L/config-3.13-darwin $L/site-packages/pip $L/site-packages/pip-*' _ "$runtime/python"
"$runtime/python/bin/python3" -I -m compileall -q -j 0 --invalidation-mode unchecked-hash "$runtime/python/lib" >/dev/null
"$runtime/python/bin/python3" -I -c 'import ssl,pymobiledevice3; assert hasattr(ssl.SSLContext,"set_psk_client_callback"); print("runtime ready")'
