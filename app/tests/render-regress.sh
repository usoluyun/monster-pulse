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
APP=".build/MonsterPulse.app/Contents/MacOS/MonsterPulse"
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

# 详情窗口的用例。规格只有状态名，由应用内部决定该状态的数据，
# 且必须用固定基准时间渲染（--details-render-test 里已固化 Date，
# 不能用 Date()，否则 footer 的「更新 HH:mm:ss」每次都不同、逐像素必 FAIL）。
DETAILS_CASES=(
  "details-normal"
  "details-no-data"
  "details-stale"
  "details-error"
  "details-loading"
)

mkdir -p "$BASE"
if [ "${1:-}" = "--update" ]; then
  for spec in "${CASES[@]}"; do
    IFS=':' read -r name r c m extra <<<"$spec"
    args=(--render-test "$BASE/$name.png" "$r" "$c" "$m")
    [ -n "${extra:-}" ] && args+=("$extra")
    "$APP" "${args[@]}" >/dev/null && echo "  基线已更新 $name"
  done
  for state in "${DETAILS_CASES[@]}"; do
    "$APP" --details-render-test "$BASE/$state.png" "${state#details-}" >/dev/null \
      && echo "  基线已更新 $state"
  done
  echo; echo "基准图写入 $BASE"; exit 0
fi

pass=0; fail=0; skip=0

compare() {   # compare <名称> <渲染出的文件>
  local name="$1" file="$2"
  if [ ! -f "$file" ]; then
    echo "  ERROR $name 渲染失败"; fail=$((fail+1)); return
  fi
  if [ ! -f "$BASE/$name.png" ]; then
    echo "  SKIP  $name 无基准图，先跑 --update"; skip=$((skip+1)); return
  fi
  local out
  out="$(python3 "$PWD/tests/pixel-diff.py" "$BASE/$name.png" "$file" "$TOL" 2>&1)"
  if printf '%s' "$out" | grep -q "✓"; then
    pass=$((pass+1))
    printf '  PASS  %-16s %s\n' "$name" "$(printf '%s' "$out" | grep -o '差异像素 [0-9]* ([0-9.]*%)')"
  else
    fail=$((fail+1)); printf '  FAIL  %-16s\n' "$name"
    printf '%s\n' "$out" | sed 's/^/        /'
  fi
}

echo "Dock 图标视觉回归（容差 ${TOL}）"
for spec in "${CASES[@]}"; do
  IFS=':' read -r name r c m extra <<<"$spec"
  args=(--render-test "$WORK/$name.png" "$r" "$c" "$m")
  [ -n "${extra:-}" ] && args+=("$extra")
  "$APP" "${args[@]}" >/dev/null
  compare "$name" "$WORK/$name.png"
done

echo
echo "详情窗口视觉回归（容差 ${TOL}）"
for state in "${DETAILS_CASES[@]}"; do
  "$APP" --details-render-test "$WORK/$state.png" "${state#details-}" >/dev/null
  compare "$state" "$WORK/$state.png"
done

echo
echo "结果：PASS $pass / FAIL $fail / SKIP $skip"
[ "$fail" -eq 0 ] || exit 1