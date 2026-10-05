#!/bin/bash
# Codex Dock 性能验收：与活动监视器对比
#
# 严格按 docs/codex-dock-feasibility.md §性能验收方法：
#   · Release(-O) 构建（build.sh 已是 -O）
#   · 两者**分开单独运行**，绝不同时跑（否则监控工具本身影响被测对象）
#   · 记录应用与子进程合计的累计 CPU 时间、平均 CPU、物理 footprint、峰值内存
#
# 唤醒次数需要 powermetrics（sudo），本脚本不采集，结论里单独标注为未覆盖。
#
# 用法：
#   example/codex-dock/tests/run-perf-test.sh
#   PERF_ROUNDS=3 PERF_CYCLE_MINUTES=15 example/codex-dock/tests/run-perf-test.sh
set -uo pipefail

cd "$(dirname "$0")/.."
MEASURE="$PWD/tests/measure.py"
APP="$PWD/.build/CodexDock.app/Contents/MacOS/CodexDock"
OUT="${PERF_OUT:-/tmp/codexdock-perf}"
ROUNDS="${PERF_ROUNDS:-1}"
CYCLE_MINUTES="${PERF_CYCLE_MINUTES:-15}"
INTERVAL="${PERF_INTERVAL:-60}"

mkdir -p "$OUT"

cleanup() {
  pkill -9 -x CodexDock 2>/dev/null
  osascript -e 'tell application "Activity Monitor" to quit' 2>/dev/null
  sleep 1
}
trap cleanup EXIT

close_window() {
  osascript -e 'tell application "System Events" to tell process "CodexDock"
    if exists window 1 then perform action "AXClose" of window 1
  end tell' 2>/dev/null || true
  sleep 2
}

echo "性能验收：${ROUNDS} 轮 × ${CYCLE_MINUTES} 分钟，对比活动监视器"
echo "两者严格分开单独运行；唤醒次数需 powermetrics(sudo)，本次未采集。"
echo "输出：$OUT"
echo

run_dock() { # 标签  是否关闭详情窗
  local label="$1" close="$2"
  cleanup
  CODEX_BIN="${CODEX_BIN:-$(command -v codex)}" "$APP" >/dev/null 2>&1 &
  local pid=$!
  sleep 6   # 等首帧绘制与首次额度查询完成
  [ "$close" = "yes" ] && close_window
  echo "  → CodexDock pid=$pid 详情$( [ "$close" = yes ] && echo 关闭 || echo 打开 )"
  python3 "$MEASURE" --pid "$pid" "$label" "$(( CYCLE_MINUTES * 60 ))" "$INTERVAL" \
    >"$OUT/$label.csv"
  pkill -9 -x CodexDock 2>/dev/null
}

run_activity_monitor() { # 标签
  local label="$1"
  cleanup
  open -a "Activity Monitor"
  sleep 10
  local pid; pid="$(pgrep -x 'Activity Monitor' | head -1)"
  if [ -z "$pid" ]; then
    echo "  → 活动监视器启动失败，跳过本轮"; return
  fi
  echo "  → Activity Monitor pid=$pid 窗口打开"
  python3 "$MEASURE" --pid "$pid" "$label" "$(( CYCLE_MINUTES * 60 ))" "$INTERVAL" \
    >"$OUT/$label.csv"
  osascript -e 'tell application "Activity Monitor" to quit' 2>/dev/null
}

for round in $(seq 1 "$ROUNDS"); do
  echo "[$round/$ROUNDS] CodexDock · 详情关闭（基线场景）· ${CYCLE_MINUTES} 分钟"
  run_dock "dock-r$round-baseline" yes

  echo "[$round/$ROUNDS] CodexDock · 详情打开 · ${CYCLE_MINUTES} 分钟"
  run_dock "dock-r$round-detail" no

  echo "[$round/$ROUNDS] Activity Monitor · 窗口打开 · ${CYCLE_MINUTES} 分钟"
  run_activity_monitor "am-r$round-baseline"

  echo
done

echo "采样完成，汇总："
python3 "$PWD/tests/perf-summary.py" "$OUT"