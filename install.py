#!/usr/bin/env python3
"""Install the self-contained Toss app without launching it or importing data."""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import uuid


def install(folder, *, check_only=False):
    app_source = folder / "Toss.app"
    executable = Path("Contents/MacOS/Toss")
    runtime = Path("Contents/Resources/Runtime/python/bin/python3")
    if not (app_source / executable).is_file() or not (app_source / runtime).is_file():
        raise RuntimeError("安装源不完整；请保留 Toss.app 及其内置运行环境")
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app_source)], check=True)
    if check_only:
        print("安装源检查通过；未安装、未读取配对内容、未启动任何应用。")
        return

    apps = Path.home() / "Applications"
    apps.mkdir(exist_ok=True)
    destination = apps / "Toss.app"
    if destination.exists():
        current = destination / executable
        if not current.is_file() or hashlib.sha256(current.read_bytes()).digest() != hashlib.sha256((app_source / executable).read_bytes()).digest():
            raise RuntimeError("已有不同版本。请先退出 Toss 并将已有 App 移到废纸篓，再运行安装")
    else:
        temporary = apps / (".toss-install-" + uuid.uuid4().hex + ".app")
        try:
            subprocess.run(["/usr/bin/ditto", str(app_source), str(temporary)], check=True)
            temporary.rename(destination)
        finally:
            if temporary.exists():
                shutil.rmtree(temporary)
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(destination)], check=True)
    print("安装完成。请自己打开 ~/Applications/Toss.app 并授权。")
    print("未导入配对数据、未自动启动、未注册登录项；运行环境包含在 App 内。")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if os.geteuid() == 0:
        raise RuntimeError("请用当前登录用户运行，不要 sudo")
    os.umask(0o077)
    install(Path(__file__).resolve().parent, check_only=args.check)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        if isinstance(error, RuntimeError):
            print("安装未完成：" + str(error), file=sys.stderr)
        else:
            print("安装未完成：本地文件或签名检查失败；未启动工具。", file=sys.stderr)
        sys.exit(1)
