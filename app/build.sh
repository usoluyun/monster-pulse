#!/bin/bash
# Codex Dock 构建与打包
#
# 用法：
#   build.sh                    构建 .app（默认，行为与原来一致）
#   build.sh --standalone       只产出单个可执行文件，不做 .app bundle
#   build.sh --dmg              构建 .app 并打成 .dmg（可拷贝给本机使用）
#   build.sh --sign             给 .app 做 ad-hoc 签名（Gatekeeper 放行本机）
#   build.sh --universal        额外构建 arm64 + x86_64 通用二进制
#
# 产物在 .build/ 下。.build 已在 .gitignore 中。
#
# 分发边界（重要）：
#   · 单文件：能正常显示 Dock 图标（代码里 setActivationPolicy(.regular) 强制激活），
#     但没有 Info.plist，因此没有 CFBundleIdentifier、不能用 `open -b`/`open -a`
#     按 bundle id 启动，将来也没法挂资源文件。适合自用或塞进 dotfiles。
#   · .dmg：未签名时拷到**别的机器**会被 Gatekeeper 拦（quarantine），
#     需对方右键打开或 `xattr -d com.apple.quarantine`。
#   · 要让别的机器无需任何操作就能运行，必须走 Developer ID 签名 + 公证，
#     需要付费 Apple 开发者账号，见 README §分发。
set -euo pipefail
# 先把自身绝对路径算出来：下面会 cd 到脚本目录，之后相对路径就失效了
#（-h 分支要回读本文件头部输出用法）
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$SELF")"

ARCH="$(uname -m)"
APP_NAME="MonsterPulse"
APP=".build/${APP_NAME}.app"
BIN="${APP}/Contents/MacOS/${APP_NAME}"
MODE=app
DMG=0
SIGN=0
UNIVERSAL=0

for arg in "$@"; do
  case "$arg" in
    --standalone) MODE=standalone ;;
    --dmg)        DMG=1 ;;
    --sign)       SIGN=1 ;;
    --universal)  UNIVERSAL=1 ;;
    -h|--help)    sed -n '2,24p' "$SELF" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf '未知参数: %s（-h 看用法）\n' "$arg" >&2; exit 64 ;;
  esac
done

mkdir -p .build/module-cache

# swiftc 一次只能出一个 target；通用二进制靠两次编译后 lipo 合并。
# 注意：x86_64 目标在本机需要对应 SDK，Apple Silicon 上交叉编译 x86_64 是可行的。
build_for() {
  local target="$1" out="$2"
  swiftc -O -swift-version 5 -target "$target-apple-macosx13.0" \
    -module-cache-path .build/module-cache -framework AppKit \
    Sources/*.swift -o "$out"
}

if [ "$MODE" = "standalone" ]; then
  out=".build/${APP_NAME}"
  if [ "$UNIVERSAL" = "1" ]; then
    build_for "$ARCH" ".build/.sa-arm64"
    build_for "x86_64" ".build/.sa-x86_64" 2>/dev/null || {
      printf 'x86_64 交叉编译失败（本机可能缺少对应 SDK），仅产出 arm64\n' >&2
      cp .build/.sa-arm64 "$out"; rm -f .build/.sa-arm64; exit 0; }
    lipo -create .build/.sa-arm64 .build/.sa-x86_64 -output "$out"
    rm -f .build/.sa-arm64 .build/.sa-x86_64
  else
    build_for "$ARCH" "$out"
  fi
  chmod +x "$out"
  printf '%s\n' "Built (standalone): $PWD/$out"
  printf '%s\n' "运行: $out    自检: $out --self-test    额度探针: $out --probe"
  exit 0
fi

rm -rf "$APP"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
build_for "$ARCH" "$BIN"
cp Info.plist "${APP}/Contents/Info.plist"
cp Resources/AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"
cp Resources/LICENSE.txt "${APP}/Contents/Resources/LICENSE.txt"
printf '%s\n' "Built: $PWD/${APP}"

if [ "$SIGN" = "1" ]; then
  # ad-hoc 签名：不需要证书，但也不构成「已公证」，只解决本机 Gatekeeper 记缓存的问题
  codesign --force --sign - "$APP" && printf '%s\n' "Signed (ad-hoc): $APP"
fi

if [ "$DMG" = "1" ]; then
  STAGE="$(mktemp -d)"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  OUT=".build/${APP_NAME}.dmg"
  rm -f "$OUT"
  # 仍用 hdiutil：diskutil image create 的子命令语法与此不兼容，
  # 且 hdiutil 兼容面更广。那条 deprecation 警告是形式性的，不影响产物。
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" \
    -ov -format UDZO "$OUT" >/dev/null
  rm -rf "$STAGE"
  printf '%s\n' "Built: $PWD/${OUT}"
  printf '%s\n' "拷到其他机器后需右键打开，或执行: xattr -d com.apple.quarantine <dmg>"
fi
