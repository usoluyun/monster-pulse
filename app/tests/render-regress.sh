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

# 规格固定 7 段：名称:额度:CPU:内存:stale:meters:extras
# 段数必须固定，否则 IFS=':' read 会因空段吞掉后面的字段（实测踩过）。
# meters 取值 both / no-cpu / no-mem / no-both，用于覆盖配置关掉指标后的图标外观。
# extras 可选，形如 pace=0.45,activity=0.8，用于覆盖动效分支；留空则不画动效，
# 这样既有基准图不会因为新增动效而全量失效。
CASES=(
  "normal-92:92:0.42:0.61:none:both:"
  "low-cpu-45:45:0.08:0.77:none:both:"
  "full-100:100:1.0:1.0:none:both:"
  "stale:88:0.42:0.61:stale:both:"
  "no-data:92:0:0:none:both:"
  "hide-cpu:92:0.42:0.61:none:no-cpu:"
  "hide-mem:92:0.42:0.61:none:no-mem:"
  "hide-both:92:0.42:0.61:none:no-both:"
  # 无额度数据：remaining 传 nil（渲染成横杠）。stale 与 no-quota-stale 两个
  # 用例断言「没有数字时不该标 OLD」——没有快照就谈不上旧数据。
  "no-quota:nil:0.42:0.61:none:both:"
  "no-quota-stale:nil:0.42:0.61:stale:both:"
  # 动效分支。extras 是第 7 段：pace=窗口已过比例，activity=亮点相位。
  "anim-pace:62:0.42:0.61:none:both:pace=0.45"
  "anim-activity:62:0.42:0.61:none:both:activity=0.8"
  "anim-both:62:0.42:0.61:none:both:pace=0.45,activity=0.8"
  # 亮点在已填充部分内移动：填充短时活动范围很小，用 cpu=0.1 覆盖这个边界
  "anim-lowcpu:62:0.10:0.61:none:both:activity=0.5"
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
  "details-normal-no-meters"
  "details-no-data-no-meters"
)

# 设置面板的用例。此前设置窗口没有渲染入口，新增控件是否被挤出可视区、
# 提示文案是否被截断都只能靠肉眼——实际就因此漏掉过一个严重的布局 bug：
# 「标签+滑杆」同行用负 gap 表达，而高度累加对负 gap 取 max(0,…)，导致每个
# 滑杆行多算一倍高度、间距被重复应用。现在纳入回归。
SETTINGS_CASES=(
  "settings-full"
  "settings-nometers"
  "settings-alerts-off"
  "settings-dns"
)

mkdir -p "$BASE"
if [ "${1:-}" = "--update" ]; then
  for spec in "${CASES[@]}"; do
    IFS=':' read -r name r c m st meters extras <<<"$spec"
    "$APP" --render-test "$BASE/$name.png" "$r" "$c" "$m" "$st" "$meters" "$extras" >/dev/null \
      && echo "  基线已更新 $name"
  done
  for state in "${DETAILS_CASES[@]}"; do
    "$APP" --details-render-test "$BASE/$state.png" "${state#details-}" >/dev/null \
      && echo "  基线已更新 $state"
  done
  for state in "${SETTINGS_CASES[@]}"; do
    "$APP" --settings-render-test "$BASE/$state.png" "${state#settings-}" >/dev/null \
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
  IFS=':' read -r name r c m st meters extras <<<"$spec"
  "$APP" --render-test "$WORK/$name.png" "$r" "$c" "$m" "$st" "$meters" "$extras" >/dev/null
  compare "$name" "$WORK/$name.png"
done

echo
echo "详情窗口视觉回归（容差 ${TOL}）"
for state in "${DETAILS_CASES[@]}"; do
  "$APP" --details-render-test "$WORK/$state.png" "${state#details-}" >/dev/null
  compare "$state" "$WORK/$state.png"
done

echo
echo "设置面板视觉回归（容差 ${TOL}）"
for state in "${SETTINGS_CASES[@]}"; do
  diag="$("$APP" --settings-render-test "$WORK/$state.png" "${state#settings-}" | grep '^layout:')"
  if [ -z "$diag" ]; then
    echo "  ERROR $state 未输出布局诊断"; fail=$((fail+1)); continue
  fi
  # 「不足(顶部被裁)」意味着窗口没长够高、最上面几项在可视区之外。
  # 这正是「看不到顶部设置」的成因：只改 content.frame 不会让窗口变高，
  # 而离屏渲染按 content.frame 渲染所以看不出来。必须在这里拦住。
  case "$diag" in
    *"不足"*|*"超出可视区"*)
      echo "  FAIL  $state 布局被裁：$diag"; fail=$((fail+1)); continue ;;
  esac
  compare "$state" "$WORK/$state.png"
done

echo
echo "结果：PASS $pass / FAIL $fail / SKIP $skip"
[ "$fail" -eq 0 ] || exit 1