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
#   app/tests/run-perf-test.sh
#   PERF_ROUNDS=3 PERF_CYCLE_MINUTES=15 app/tests/run-perf-test.sh
set -uo pipefail

cd "$(dirname "$0")/.."
MEASURE="$PWD/tests/measure.py"
APP="$PWD/.build/MonsterPulse.app/Contents/MacOS/MonsterPulse"
OUT="${PERF_OUT:-/tmp/monsterpulse-perf}"
ROUNDS="${PERF_ROUNDS:-1}"
CYCLE_MINUTES="${PERF_CYCLE_MINUTES:-15}"
INTERVAL="${PERF_INTERVAL:-60}"

mkdir -p "$OUT"

load_pids=""
cleanup() {
  stop_load
  pkill -9 -x MonsterPulse 2>/dev/null
  osascript -e 'tell application "Activity Monitor" to quit' 2>/dev/null
  sleep 1
}
trap cleanup EXIT

# 受控背景负载。目的：让 MonsterPulse 的 CPU 动效定时器确实在运行——
# 忙碌度 ≤0.02 时定时器根本不创建，不施加负载就测不到动效的真实开销
# （含 dockTile 上传与 WindowServer 合成，进程内基准测不到这部分）。
# 关键是**双方同等负载**：活动监视器也跑在同样的负载下，对照才公平。
start_load() {
  stop_load
  [ "${PERF_LOAD:-1}" = "1" ] || return
  # 占住 1 个核，避免压满全机影响对比
  yes >/dev/null & load_pids="$load_pids $!"
}

stop_load() {
  local pid
  for pid in $load_pids; do kill "$pid" 2>/dev/null; done
  load_pids=""
}

close_window() {
  osascript -e 'tell application "System Events" to tell process "MonsterPulse"
    if exists window 1 then perform action "AXClose" of window 1
  end tell' 2>/dev/null || true
  sleep 2
}

echo "性能验收：${ROUNDS} 轮 × ${CYCLE_MINUTES} 分钟，对比活动监视器"
echo "两者严格分开单独运行，且各自跑在同样的 1 核受控负载下（让动效真正运行）。"
echo "唤醒次数需 powermetrics(sudo)，本次未采集。"
echo "输出：$OUT"
echo

run_dock() { # 标签  是否关闭详情窗
  local label="$1" close="$2"
  cleanup
  # 应用日志落盘：事后要核对动效定时器在测量期间确实在运行
  CODEX_BIN="${CODEX_BIN:-$(command -v codex)}" "$APP" >"$OUT/$label.app.log" 2>&1 &
  local pid=$!
  sleep 6   # 等首帧绘制与首次额度查询完成
  [ "$close" = "yes" ] && close_window
  echo "  → MonsterPulse pid=$pid 详情$( [ "$close" = yes ] && echo 关闭 || echo 打开 )"
  start_load
  python3 "$MEASURE" --pid "$pid" "$label" "$(( CYCLE_MINUTES * 60 ))" "$INTERVAL" \
    >"$OUT/$label.csv"
  stop_load
  pkill -9 -x MonsterPulse 2>/dev/null
}

run_activity_monitor() { # 标签
  local label="$1"
  cleanup
  open -a "Activity Monitor"
  sleep 10
  # 收集**全部**相关进程，不只 head -1。历史记录里「只测到主进程」导致低估
  # 对比方、使对比偏向 MonsterPulse 有利。XPC service 由 launchd 拉起
  # （父进程不是 AM 本身），descendants() 抓不到，所以这里按进程名全量匹配。
  # 2026-10-06 实测：macOS 27.0.1 上活动监视器已是单进程、无 helper，此时
  # 列表长度为 1；但不能假设其他系统版本也如此，故按列表全量计量。
  local pids; pids="$(pgrep -x 'Activity Monitor' | paste -sd, -)"
  if [ -z "$pids" ]; then
    echo "  → 活动监视器启动失败，跳过本轮"; return
  fi
  # 用 awk 而非 wc -l：printf 不带尾换行时 wc -l 会少算最后一个
  local n; n="$(printf '%s,' "$pids" | awk -F, '{print NF-1}')"
  echo "  → Activity Monitor pids=$pids （${n} 个进程）"
  [ "$n" -gt 1 ] && echo "    注意：检测到多进程，已全部纳入计量"
  start_load
  python3 "$MEASURE" --pid "$pids" "$label" "$(( CYCLE_MINUTES * 60 ))" "$INTERVAL" \
    >"$OUT/$label.csv"
  stop_load
  osascript -e 'tell application "Activity Monitor" to quit' 2>/dev/null
}

for round in $(seq 1 "$ROUNDS"); do
  echo "[$round/$ROUNDS] MonsterPulse · 详情关闭（基线场景）· ${CYCLE_MINUTES} 分钟"
  run_dock "dock-r$round-baseline" yes

  echo "[$round/$ROUNDS] MonsterPulse · 详情打开 · ${CYCLE_MINUTES} 分钟"
  run_dock "dock-r$round-detail" no

  echo "[$round/$ROUNDS] Activity Monitor · 窗口打开 · ${CYCLE_MINUTES} 分钟"
  run_activity_monitor "am-r$round-baseline"

  # 分栏版不再创建闪点动画定时器；历史动画版的性能结果不能代替本版实测。
  echo "  → 本轮为静态分栏布局（仅采样/额度变化时重绘）"
done

echo "采样完成，汇总："
python3 "$PWD/tests/perf-summary.py" "$OUT"
