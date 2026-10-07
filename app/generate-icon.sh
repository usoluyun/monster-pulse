#!/bin/bash
# 从原始矢量图生成 macOS 静态图标。仅修改图标时需要 rsvg-convert；常规构建直接拷贝 icns。
set -euo pipefail
cd "$(dirname "$0")"
command -v rsvg-convert >/dev/null || {
  printf '需要 rsvg-convert（librsvg）才能重新生成图标\n' >&2
  exit 1
}
ICONSET=".build/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  rsvg-convert -w "$size" -h "$size" Resources/AppIcon.svg \
    -o "$ICONSET/icon_${size}x${size}.png"
  retina=$((size * 2))
  rsvg-convert -w "$retina" -h "$retina" Resources/AppIcon.svg \
    -o "$ICONSET/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
printf 'Generated: %s/Resources/AppIcon.icns\n' "$PWD"
