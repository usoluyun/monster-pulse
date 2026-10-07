#!/bin/bash
# Dock 图标视觉回归：渲染若干状态，与基准图逐像素比对。
#
# 用法：
#   tests/render-regress.sh            # 渲染当前版本并与 tests/baseline/ 比对
#   tests/render-regress.sh --update   # 确认外观后更新全部基准
#   tests/render-regress.sh --update-dock # 仅更新 Dock 基准，保留窗口基准
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

# 规格固定 6 段：名称:额度:CPU:stale:meters:extras。
# activity 为历史参数；两个相位必须渲染成同一张静态图。
CASES=(
  # 新签名：<remaining> <cpu> <stale|none> <meters> <extras>
  # extras: gpu= / rail=<used>/<elapsed>（5h轨，elapsed 传 -1 画无刻度）/
  #         rail2=<used>/<elapsed>（周轨）/ activity=历史相位（忽略）/ nogpu / nogpumeter
  # meters: both / no-cpu / no-gpu / no-both
  #
  # rail 与 rail2 是额度轨（bullet graph）：填充=已用%，刻度=时间已过%。
  # 两条轨默认都给典型值——不给的话退化为「无额度数据」外观，与真实使用不符。
  "normal-92:92:0.42:none:both:gpu=0.12,rail=0.35/0.42,rail2=0.12/0.30,country=US,proxy=on,reset=10800"
  "low-cpu-45:45:0.08:none:both:gpu=0.12,rail=0.35/0.42,rail2=0.12/0.30,country=US,proxy=on,reset=10800"
  "full-100:100:1.0:stale:both:gpu=1.0,rail=1.0/1.0,rail2=1.0/1.0,country=US,proxy=on,reset=10800"
  "stale:88:0.42:stale:both:gpu=0.12,rail=0.35/0.42,rail2=0.12/0.30,country=US,proxy=on,reset=10800"
  "no-data:92:0:none:both:gpu=0.12,country=US,proxy=on,reset=10800"
  "hide-cpu:92:0.42:none:no-cpu:gpu=0.12,rail=0.35/0.42,rail2=0.12/0.30,country=US,proxy=on,reset=10800"
  "hide-gpu:92:0.42:none:no-gpu:gpu=0.5,rail=0.35/0.42,rail2=0.12/0.30,country=US,proxy=on,reset=10800"
  "hide-both:92:0.42:none:no-both:gpu=0.5,rail=0.35/0.42,rail2=0.12/0.30,country=US,proxy=on,reset=10800"
  # 无额度数据：remaining 传 nil（渲染成横杠）。stale 与 no-quota-stale 断言
  # 「没有数字时不该标 OLD」；无轨状态下背板也不画轨底槽（backdropRails 机制）。
  "no-quota:nil:0.42:none:both:gpu=0.12,country=US,proxy=on,reset=10800"
  "no-quota-stale:nil:0.42:stale:both:gpu=0.12,country=US,proxy=on,reset=10800"
  # 历史动效相位不再影响外观。
  "blink-on:62:0.42:none:both:gpu=0.55,rail=0.35/0.42,rail2=0.12/0.30,activity=0.2,country=US,proxy=on,reset=10800"
  "blink-off:62:0.42:none:both:gpu=0.55,rail=0.35/0.42,rail2=0.12/0.30,activity=0.7,country=US,proxy=on,reset=10800"
  # 低负载仍显示固定底槽。
  "idle-nodot:62:0.01:none:both:gpu=0.01,rail=0.35/0.42,rail2=0.12/0.30,activity=0.2,country=US,proxy=on,reset=10800"
  # 跑本地大模型：CPU 低、GPU 满。这是这套图标最该被一眼看出来的场景。
  "gpu-busy:62:0.10:none:both:gpu=0.98,rail=0.35/0.42,rail2=0.12/0.30,activity=0.2,country=US,proxy=on,reset=10800"
  # 烧得快：used(0.55) > elapsed(0.30)+0.05 → 5h 轨转琥珀色
  "burning:62:0.10:none:both:gpu=0.98,rail=0.55/0.30,activity=0.2,country=US,proxy=on,reset=10800"
  # 周轨单独变化：只给 rail 不给 rail2 → 只有 5h 轨有底槽
  "single-rail:62:0.42:none:both:gpu=0.12,rail=0.35/0.42,country=US,proxy=on,reset=10800"
  # 刻度缺失（无 resetsAt 时间信息）→ 填充照画、刻度不画
  "no-tick:62:0.42:none:both:gpu=0.12,rail=0.35/-1,rail2=0.12/-1,country=US,proxy=on,reset=10800"
  "gpu-unavailable:62:0:none:both:nogpu,rail=0.35/0.42,rail2=0.12/0.30,country=US,proxy=on,reset=10800"
  "cpu-full:62:1:none:both:gpu=0,rail=0.35/0.42,rail2=0.12/0.30,country=US,proxy=on,reset=10800"
  "gpu-full:62:0:none:both:gpu=1,rail=0.35/0.42,rail2=0.12/0.30,country=US,proxy=on,reset=10800"
  "zero-load:62:0:none:both:gpu=0,rail=0.35/0.42,rail2=0.12/0.30,country=US,proxy=on,reset=10800"
  "network-off:62:0.12:none:both:gpu=1,rail=0.38/0.45,rail2=0.26/0.32,country=CN,proxy=off,reset=1800"
  "network-unknown:62:0.12:none:both:gpu=1,rail=0.38/0.45,rail2=0.26/0.32,proxy=unknown"
  "quota-empty:0:0:none:both:gpu=0,country=US,proxy=on"
  "quota-full:100:0:none:both:gpu=0,country=US,proxy=on"

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
  "details-no-gpu"
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
  "settings-login-on"
  "settings-login-off"
)

mkdir -p "$BASE"
if [ "${1:-}" = "--update" ] || [ "${1:-}" = "--update-dock" ]; then
  for spec in "${CASES[@]}"; do
    IFS=':' read -r name r c st meters extras <<<"$spec"
    "$APP" --render-test "$BASE/$name.png" "$r" "$c" "$st" "$meters" "$extras" >/dev/null \
      && echo "  基线已更新 $name"
  done
  if [ "${1:-}" = "--update-dock" ]; then
    echo "Dock 基准图写入 $BASE"; exit 0
  fi
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
  IFS=':' read -r name r c st meters extras <<<"$spec"
  "$APP" --render-test "$WORK/$name.png" "$r" "$c" "$st" "$meters" "$extras" >/dev/null
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
  #
  # 「异常(应为 24pt)」是另一类：窗口够高，但顶部内边距没落到内容上，
  # 首行被顶到上沿、底部多出一块死白。只查「够不够高」发现不了。
  case "$diag" in
    *"不足"*|*"超出可视区"*|*"异常"*)
      echo "  FAIL  $state 布局异常：$diag"; fail=$((fail+1)); continue ;;
  esac
  compare "$state" "$WORK/$state.png"
done

echo
if python3 tests/dock-layout-check.py "$WORK"; then
  pass=$((pass+1))
else
  fail=$((fail+1))
fi
if python3 tests/window-render-check.py "$WORK"; then
  pass=$((pass+1))
else
  fail=$((fail+1))
fi
echo "结果：PASS $pass / FAIL $fail / SKIP $skip"
[ "$fail" -eq 0 ] || exit 1
