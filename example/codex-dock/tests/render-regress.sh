#!/bin/bash
# Dock 图标视觉回归：渲染若干状态，与基准图逐像素比对。
#
# 用法：
#   tests/render-regress.sh            # 渲染当前版本并与 tests/baseline/ 比对
#   tests/render-regress.sh --update   # 用当前构建重新生成基准（源码有改动后应先跑这个）
#
# 容差默认 24，不是 1。原因是实测发现：CoreText 文字抗锯齿依赖编译产物，
# 同一二进制两次渲染完全一致，但重新编译后文字像素最大差约 22/255。所以容差必须
# 吸收编译抖动，否则任何源码改动都会让本脚本报 FAIL。
#
# 这样做的代价要清楚：本回归捕获的是布局/结构错误（元素缺失、位置错乱、颜色错误），
# 不是逐像素一致。要验证"某次视觉改动没改变外观"，需让改动前后用同一种方式构建
# 再互相比对——那是 pixel-diff.py 的直接用法，不是本脚本。
set -uo pipefail

cd "$(dirname "$0")/.."
APP=".build/CodexDock.app/Contents/MacOS/CodexDock"
BASE="tests/baseline"
TOL="${TOL:-24}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CASES=(
  "normal-92:92:0.42:0.61"
  "low-cpu-45:45:0.08:0.77"
  "full-100:100:1.0:1.0"
  "stale:88:0.42:0.61:stale"
  "no-data:92:0:0"
)

mkdir -p "$BASE"
if [ "${1:-}" = "--update" ]; then
  for spec in "${CASES[@]}"; do
    IFS=':' read -r name r c m extra <<<"$spec"
    args=(--render-test "$BASE/$name.png" "$r" "$c" "$m")
    [ -n "${extra:-}" ] && args+=("$extra")
    "$APP" "${args[@]}" >/dev/null && echo "  基线已更新 $name"
  done
  echo; echo "基准图写入 $BASE"; exit 0
fi

echo "Dock 图标视觉回归（容差 ${TOL}）"
pass=0; fail=0; skip=0
for spec in "${CASES[@]}"; do
  IFS=':' read -r name r c m extra <<<"$spec"
  args=(--render-test "$WORK/$name.png" "$r" "$c" "$m")
  [ -n "${extra:-}" ] && args+=("$extra")
  if ! "$APP" "${args[@]}" >/dev/null; then
    echo "  ERROR $name 渲染失败"; fail=$((fail+1)); continue
  fi
  if [ ! -f "$BASE/$name.png" ]; then
    echo "  SKIP  $name 无基准图，先跑 --update"; skip=$((skip+1)); continue
  fi
  out="$(python3 "$PWD/tests/pixel-diff.py" "$BASE/$name.png" "$WORK/$name.png" "$TOL" 2>&1)"
  if printf '%s' "$out" | grep -q "✓"; then
    pass=$((pass+1)); printf '  PASS  %-12s %s\n' "$name" "$(printf '%s' "$out" | grep -o '差异像素 [0-9]* ([0-9.]*%)')"
  else
    fail=$((fail+1)); printf '  FAIL  %-12s\n' "$name"
    printf '%s\n' "$out" | sed 's/^/        /'
  fi
done

echo
echo "结果：PASS $pass / FAIL $fail / SKIP $skip"
[ "$fail" -eq 0 ] || exit 1