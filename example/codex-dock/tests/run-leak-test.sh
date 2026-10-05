#!/bin/bash
# Codex Dock 长时间泄漏测试
#
# 持续运行并周期采样，判断资源是否随时间累积。关注两类定时器：
#   · 5s  系统指标采样（每次 host_statistics + 可能触发 Dock 图标重绘）
#   · 120s 额度轮询（每次拉起一个辅助 codex 进程，跑完回收）
#
# 判据：RSS / 物理内存 footprint / 文件句柄 / 辅助子进程数在预热后应趋于平稳，
#      不呈单调上升。绝对值受系统状态影响大，这里只看趋势与斜率。
#
# 用法：
#   example/codex-dock/tests/run-leak-test.sh              # 默认 10 分钟，每 60s 采样
#   LEAK_MINUTES=30 example/codex-dock/tests/run-leak-test.sh
set -uo pipefail

cd "$(dirname "$0")/.."
APP=".build/CodexDock.app/Contents/MacOS/CodexDock"
MINUTES="${LEAK_MINUTES:-10}"
INTERVAL="${LEAK_INTERVAL:-60}"
OUT="${LEAK_OUT:-/tmp/codexdock-leak.csv}"

cleanup() { pkill -9 -x CodexDock 2>/dev/null; }
trap cleanup EXIT

# footprint 是物理内存口径，比 RSS 可靠（RSS 含共享页且会重复计入）。
# 输出形如 "Footprint: 23 MB" 或 "Footprint: 1168 KB"，需换算成 KB。
footprint_kb() {
  footprint -p "$1" 2>/dev/null | grep -o 'Footprint: .*' | head -1 |
  awk '{
    v = $2; u = $3
    if (u == "GB")      printf "%d", v * 1024 * 1024
    else if (u == "MB") printf "%d", v * 1024
    else if (u == "KB") printf "%d", v
    else                printf "%d", v / 1024   # 无单位按 bytes 理解
  }'
}

echo "Codex Dock 泄漏测试：${MINUTES} 分钟，每 ${INTERVAL}s 采样"
echo "注意：过程中请不要手动打开/关闭详情窗，也不要按刷新按钮"
echo

CODEX_BIN="${CODEX_BIN:-$(command -v codex)}" "$APP" >/tmp/codexdock-leak.log 2>&1 &
app_pid=$!
sleep 5

if ! kill -0 "$app_pid" 2>/dev/null; then
  echo "FAIL: 应用启动失败"; cat /tmp/codexdock-leak.log; exit 1
fi

printf 'elapsed_s,rss_kb,phys_footprint_kb,num_threads,num_fds,child_codex,swaps\n' >"$OUT"

samples=$(( MINUTES * 60 / INTERVAL ))
for i in $(seq 0 "$samples"); do
  if ! kill -0 "$app_pid" 2>/dev/null; then
    echo "WARN: 应用在第 $(( i * INTERVAL ))s 意外退出，提前结束"
    break
  fi
  line="$(ps -o rss= -p "$app_pid" | tr -d ' ')"
  kids="$(pgrep -P "$app_pid" 2>/dev/null | wc -l | tr -d ' ')"
  phys="$(footprint_kb "$app_pid")"
  threads="$(ps -M "$app_pid" 2>/dev/null | wc -l | tr -d ' ')"
  # macOS 无 /proc，句柄数走 lsof（只数该 pid 的 fd 行）
  fds="$(lsof -p "$app_pid" 2>/dev/null | awk 'NR>1 && $4 ~ /^[0-9]+[rwu]/ {n++} END{print n+0}')"
  swaps="$(sysctl -n vm.swapusage 2>/dev/null | awk '{print $6}' | tr -d ',')"
  printf '%d,%s,%s,%s,%s,%s,%s\n' "$(( i * INTERVAL ))" "$line" "${phys:-0}" "${threads:-0}" "$fds" "$kids" "${swaps:-0}" >>"$OUT"
  printf '  t=%4ds  rss=%7s KB  threads=%-4s fds=%-5s child=%s\n' \
    "$(( i * INTERVAL ))" "$line" "${threads:-?}" "$fds" "$kids"
  [ "$i" -lt "$samples" ] && sleep "$INTERVAL"
done

echo
echo "结果写入 $OUT"
python3 "$PWD/tests/trend.py" "$OUT"