#!/bin/zsh
set -euo pipefail
if /usr/bin/pgrep -x Toss >/dev/null; then
  print '请先从菜单退出 Toss，再卸载。'
  exit 1
fi
TASK_APP="/Applications/Toss.app"
[[ -d "$TASK_APP" ]] || TASK_APP="$HOME/Applications/Toss.app"
TASK_SUPPORT="$HOME/Library/Application Support/Toss"
TASK_CACHE="$HOME/Library/Caches/Toss"
TASK_EXEC="$TASK_APP/Contents/MacOS/Toss"
if [[ ! -x "$TASK_EXEC" ]]; then
  print '未找到可注销登录项的工具。请恢复 App 后重试；当前未删除任何文件。'
  exit 1
fi
# Version 0.4+ handles this before any UI, auto-resume, keys or device work.
TASK_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$TASK_APP/Contents/Info.plist")
if [[ "$TASK_VERSION" != <-> ]] || (( TASK_VERSION < 10 )); then
  print '旧版工具不支持此注销入口，请使用与旧版对应的卸载脚本。未删除文件。'
  exit 1
fi
"$TASK_EXEC" --unregister-login-item
/bin/rm -rf -- "$TASK_APP" "$TASK_SUPPORT" "$TASK_CACHE"
# Accessibility stays granted (Ashley 2026-10-29): a reinstall then works at once instead of
# asking again. The entry can be removed by hand in System Settings → Privacy & Security.
print '已确认注销登录项，并移除本工具（含内置运行环境）、本机配对文件及截图缓存。'
print 'iPad 上“信任此电脑”和开发者模式保持不变，可在 iPad 设置中自行关闭。'
print '辅助功能授权已保留，重新安装后可直接使用；如需删除，在 系统设置 → 隐私与安全性 → 辅助功能 里移除。'
print '按回车关闭此窗口。'
read -r
