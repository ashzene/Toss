#!/bin/sh
# Synthetic tests only: no iPad, network capture, UI, clipboard, or key posting.
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_python=${TOSS_PYTHON:-"$project_dir/.venv/bin/python"}
if [ ! -x "$test_python" ]; then
    printf '%s\n' 'Python environment not found. Set TOSS_PYTHON to a Python 3.13 environment with Backend/requirements-tested.txt installed.' >&2
    exit 1
fi
env -u PYTHONPATH -u PYTHONHOME PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1 \
    "$test_python" -c 'import ssl,sys,importlib.metadata; assert sys.version_info[:2] == (3,13), "Python 3.13 required"; assert hasattr(ssl.SSLContext,"set_psk_client_callback"), "OpenSSL PSK callback support required"; assert importlib.metadata.version("pymobiledevice3") == "11.31.0", "pymobiledevice3 11.31.0 required"'
env -u PYTHONPATH -u PYTHONHOME PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1 \
    "$test_python" -m unittest discover -s "$project_dir/Backend/tests" -v

# Installation uses a fake app/home and injected copy/signature commands only.
env -u PYTHONPATH -u PYTHONHOME PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1 \
    "$test_python" "$project_dir/Tests/test_install_synthetic.py"
