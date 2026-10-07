#!/bin/bash
# 安装已构建的应用，并通知系统更新图标登记。先退出正在运行的 Monster Pulse。
set -euo pipefail
cd "$(dirname "$0")"
APP=".build/MonsterPulse.app"
DEST="${1:-/Applications/MonsterPulse.app}"
test -f "$APP/Contents/MacOS/MonsterPulse"
test -f "$APP/Contents/Resources/AppIcon.icns"
ditto "$APP" "$DEST"
# ditto 会保留旧目录日期；仅替换 Contents 不足以通知各处的图标缓存。
touch "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
printf 'Installed: %s\n' "$DEST"
