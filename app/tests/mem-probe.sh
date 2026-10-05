#!/bin/bash
# #20 定性实验：详情窗口关闭后内存涨至约 4 倍
#
# 历史现象（docs/codex-dock-verification.md §6，两轮复现）：
#   详情打开 → 稳定 30 MB；详情关闭 → 约 540s/420s 后稳定 133/135 MB
# 终值高度一致、非噪声、与 draw() 缓存优化无关。
# 两种未验证可能：① 窗口对象存活累积 ② footprint 求和口径把共享页算重。
#
# 本实验针对两种可能各取一个判别信号：
#   · 若 footprint 涨而 RSS 不涨 → 更可能是口径问题（假设②）
#   · 若两者同涨 → 更可能是真实分配（假设①或其他）
# 历史记录只测了 footprint，且只在详情打开时记过 RSS（113 MB），
# 「详情关闭时 RSS 是多少」这个关键数据恰好缺失。
#
# 用法: tests/mem-probe.sh [打开阶段分钟数] [关闭阶段分钟数]
set -uo pipefail
cd "$(dirname "$0")/.."
APP=".build/MonsterPulse.app/Contents/MacOS/MonsterPulse"
OPEN_MIN="${1:-4}"
CLOSED_MIN="${2:-10}"
OUT="${MEM_OUT:-/tmp/monsterpulse-mem.csv}"
SNAP="${MEM_SNAP:-/tmp/monsterpulse-mem-snap}"

cleanup() { pkill -9 -x MonsterPulse 2>/dev/null; }
trap cleanup EXIT

footprint_kb() {
  footprint -p "$1" 2>/dev/null | awk '/phys_footprint:/ {print $2 * 1024; exit}'
}

echo "内存定性实验：详情打开 ${OPEN_MIN} 分钟 → 关闭 ${CLOSED_MIN} 分钟，每 30s 采样"
echo

CODEX_BIN="${CODEX_BIN:-$(command -v codex)}" "$APP" >/tmp/monsterpulse-mem.log 2>&1 &
app_pid=$!
sleep 6
if ! kill -0 "$app_pid" 2>/dev/null; then
  echo "FAIL: 应用启动失败"; cat /tmp/monsterpulse-mem.log; exit 1
fi

mkdir -p "$SNAP"
printf 'state,elapsed_s,rss_kb,phys_footprint_kb,num_threads,num_fds' >"$OUT"

sample() {   # sample <state> <elapsed>
  local state="$1" elapsed="$2"
  local rss phys threads fds
  rss="$(ps -o rss= -p "$app_pid" | tr -d ' ')"
  phys="$(footprint_kb "$app_pid")"
  threads="$(ps -M "$app_pid" 2>/dev/null | wc -l | tr -d ' ')"
  fds="$(lsof -p "$app_pid" 2>/dev/null | awk 'NR>1 && $4 ~ /^[0-9]+[rwu]/ {n++} END{print n+0}')"
  printf '%s,%d,%s,%s,%s,%s\n' "$state" "$elapsed" "$rss" "${phys:-0}" "${threads:-0}" "$fds" >>"$OUT"
  printf '  [%s] t=%4ds  rss=%7s KB  footprint=%7s KB  threads=%-4s fds=%s\n' \
    "$state" "$elapsed" "$rss" "${phys:-0}" "${threads:-?}" "$fds"
}

# 阶段 A：详情窗口打开
elapsed=0
for _ in $(seq 0 $(( OPEN_MIN * 2 - 1 ))); do
  sample "open" "$elapsed"
  sleep 30; elapsed=$((elapsed + 30))
done
vmmap -summary "$app_pid" >"$SNAP/open.vmmap" 2>/dev/null

# 关闭详情窗口（应用保持常驻，这正是 #20 的场景）
osascript -e 'tell application "System Events" to tell process "MonsterPulse" to keystroke "w" using command down' >/dev/null 2>&1
sleep 2
echo "已关闭详情窗口，继续观察 ${CLOSED_MIN} 分钟"

# 阶段 B：详情关闭
for _ in $(seq 0 $(( CLOSED_MIN * 2 - 1 ))); do
  sample "closed" "$elapsed"
  sleep 30; elapsed=$((elapsed + 30))
done
vmmap -summary "$app_pid" >"$SNAP/closed.vmmap" 2>/dev/null

echo
echo "CSV: $OUT"
echo "vmmap 快照: $SNAP/open.vmmap  $SNAP/closed.vmmap"
