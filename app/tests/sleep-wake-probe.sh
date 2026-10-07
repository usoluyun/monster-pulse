#!/bin/bash
# 睡眠/唤醒真机验证的编排与事后分析。
#
# 用法（两步，中间需要人操作）：
#   bash app/tests/sleep-wake-probe.sh start    # 启动应用并开始记录
#   bash app/tests/sleep-wake-probe.sh analyze  # 读 CSV + events 出结论
#
# 为什么应用要用 `launchctl setenv` + `open -a` 启动，而不是直接跑二进制：
# 直接跑会继承当前 shell 的 http_proxy 等环境变量，而从 Dock / 登录项启动的
# 应用读不到 .zshrc，两者环境不同。AGENTS.md 验证纪律第 1 条就是为这件事写的。
# `launchctl setenv` 把变量注入用户 GUI 启动域，LaunchServices 启动的进程能继承，
# 因此既拿到诊断变量、又不引入 shell 环境。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="/Applications/MonsterPulse.app"
[ -d "$APP" ] || APP="$ROOT/app/.build/MonsterPulse.app"
CSV="${MP_PROBE_CSV:-/tmp/sleepwake.csv}"
EVENTS="$CSV.events"
MODE="${1:-}"

cleanup_env() {
    # 必须清：不清会让之后所有 GUI 启动的应用都带着这个变量
    launchctl unsetenv MP_SAMPLE_LOG 2>/dev/null || true
}

case "$MODE" in
start)
    pkill -f "MonsterPulse.app/Contents/MacOS/MonsterPulse" 2>/dev/null
    sleep 1
    [ -x "$APP/Contents/MacOS/MonsterPulse" ] || { echo "先跑 bash app/build.sh" >&2; exit 1; }
    rm -f "$CSV" "$EVENTS"
    launchctl setenv MP_SAMPLE_LOG "$CSV"
    open -a "$APP"
    sleep 3
    PID="$(pgrep -f "$APP/Contents/MacOS/MonsterPulse" | head -1)"
    if [ -z "$PID" ]; then echo "应用没起来" >&2; cleanup_env; exit 1; fi
    echo "已启动 pid=$PID  记录到 $CSV"
    # 验证手段本身要成立：确认变量真的进了 GUI 进程，而不是我们以为进了
    if ps eww -p "$PID" 2>/dev/null | tr ' ' '\n' | grep -q "^MP_SAMPLE_LOG=$CSV$"; then
        echo "变量已进 GUI 进程：验证手段成立"
    else
        echo "警告：变量未出现在 GUI 进程环境里，本次记录可能不完整" >&2
    fi
    echo "现在请合盖睡眠，10 分钟后唤醒，然后跑 analyze"
    ;;

analyze)
    python3 - "$CSV" "$EVENTS" <<'PY'
import csv, sys, os
csv_path, ev_path = sys.argv[1], sys.argv[2]

print("=" * 68)
print("睡眠/唤醒验证")
print("=" * 68)

print("\n[1] 事件（willSleep / didWake 是否真的触发）")
if not os.path.exists(ev_path):
    print("  无 events 文件 —— 进程没写事件，不能判定。")
else:
    for line in open(ev_path, encoding="utf-8"):
        print("  " + line.rstrip())
    print("  判据：willSleep 与 didWake 各出现 1 次才算两个通知都收到了")

if not os.path.exists(csv_path):
    sys.exit("\n无 CSV，采样没落盘")
def num(row, key):
    """CSV 里的缺失值是 "-"：reset() 清掉基准后第一次采样就没有值。"""
    v = row.get(key, "-")
    try:
        return float(v)
    except (TypeError, ValueError):
        return None

rows = list(csv.DictReader(open(csv_path, encoding="utf-8")))
print(f"\n[2] 采样：{len(rows)} 条")
if len(rows) < 3:
    sys.exit("  样本太少")

ts = [float(r["t"]) for r in rows]
gaps = [(ts[i + 1] - ts[i], i) for i in range(len(ts) - 1)]
big = [(g, i) for g, i in gaps if g > 60]
print(f"  跨度 {ts[-1] - ts[0]:.0f}s；最大相邻间隔 {max(g for g, _ in gaps):.0f}s")
if not big:
    print("  没有 >60s 的间隔 —— 没测到睡眠，或采样间隔被拉长")
else:
    g, i = max(big)
    print(f"  发现 {len(big)} 处 >60s 间隔，最大 {g:.0f}s（在第 {i} 与 {i+1} 条之间）")

    print("\n[3] 唤醒后前 3 次采样 vs 睡眠前最后 3 次")
    print(f"  {'t(s)':>9} {'cpu':>8} {'memfrac':>8} {'read MB/s':>11} {'write MB/s':>11}")
    for label, rng in (("睡前", range(max(0, i - 2), i + 1)),
                       ("醒后", range(i + 1, min(len(rows), i + 4)))):
        print(f"  -- {label} --")
        for j in rng:
            r = rows[j]
            def mb(k):
                v = num(r, k)
                return "        -" if v is None else f"{v/1048576:>11.1f}"
            c = num(r, "cpu")
            m = num(r, "memfrac")
            print(f"  {float(r['t']):>9.1f} "
                  f"{'       -' if c is None else f'{c:>8.4f}'} "
                  f"{'       -' if m is None else f'{m:>8.4f}'} "
                  f"{mb('read_bps')} {mb('write_bps')}")

    pre = [num(rows[j], "cpu") for j in range(max(0, i - 5), i + 1)]
    post = [num(rows[j], "cpu") for j in range(i + 1, min(len(rows), i + 6))]
    postr = [num(rows[j], "read_bps") for j in range(i + 1, min(len(rows), i + 6))]
    pre = [x for x in pre if x is not None]
    post = [x for x in post if x is not None]
    postr = [x / 1048576 for x in postr if x is not None]
    allr = [x / 1048576 for x in (num(r, "read_bps") for r in rows) if x is not None]
    if pre:
        print(f"\n  睡前 CPU 均值 {sum(pre)/len(pre)*100:.1f}%")
    if post:
        print(f"  醒后 CPU 均值 {sum(post)/len(post)*100:.1f}%")
    if num(rows[i], "cpu") is None:
        print(f"  ★ 缺口那一条 cpu 为空 —— 与 reset() 清基准一致，但空值也可能是"
              f"「期间 tick 增量为 0」，两者要靠 events 里的探针区分")
    print(f"  醒后磁盘读速率 {['%.1f' % x for x in postr]} MB/s；全程最大 {max(allr):.1f} MB/s")
    if postr and max(postr) > max(allr) * 0.5:
        print("  ⚠️ 醒后磁盘速率显著高于全程峰值的一半，值得看探针给的「若不 reset」值")
    else:
        print("  ✓ 醒后磁盘速率正常")

print("\n[4] 结论要点")
print("  · willSleep/didWake 各触发一次 → 两个通知都收到了，处理器有效")
print("  · 醒后 CPU 回到低值而非异常高值 → 基线重置生效")
print("  · uptime 是否跨睡眠增长 → 看 events 里那一行，跨不过就有除零风险")
PY
    ;;

stop)
    pkill -f "MonsterPulse.app/Contents/MacOS/MonsterPulse" 2>/dev/null
    cleanup_env
    echo "已停止并清掉 launchctl 环境变量"
    ;;

*)
    echo "用法: $0 {start|analyze|stop}" >&2; exit 64 ;;
esac