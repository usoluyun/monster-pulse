#!/bin/bash
# Codex Dock 异常路径测试
#
# 覆盖 README §验证记录 尚未完成的「睡眠/异常/强制终止路径测试」。
# 读层故障用 tests/fake-codex.sh 通过 CODEX_BIN 注入，不改真实登录状态、
# 不动系统网络，也就不会影响正在跑的 Codex 会话。
#
# 用法：
#   app/tests/run-abnormal-tests.sh            # 全部读层场景
#   app/tests/run-abnormal-tests.sh unauth     # 单场景
set -uo pipefail

cd "$(dirname "$0")/.."
APP=".build/MonsterPulse.app/Contents/MacOS/MonsterPulse"
FAKE="$PWD/tests/fake-codex.sh"

# 兜底：没给 CODEX_BIN 时若本机装了 codex，会误用真实 CLI
REAL_CODEX="$(command -v codex 2>/dev/null || true)"

pass=0; fail=0

# MonsterPulse 用 isExecutableFile 检查 CODEX_BIN，所以不能写成 "脚本 参数"，
# 每个 mode 生成一个独立的可执行 wrapper。
WRAPDIR="$(mktemp -d)"
cleanup() { rm -rf "$WRAPDIR"; }
trap cleanup EXIT
wrapper_for() {
  local mode="$1" path="$WRAPDIR/codex-$1"
  printf '#!/bin/bash\nexec %s %s "$@"\n' "$FAKE" "$mode" >"$path"
  chmod +x "$path"
  printf '%s' "$path"
}

# 每个场景：名称 | 假 codex 模式 | 期望退出码 | 说明
# 期望退出码：zero = 应读到额度并成功；nonzero = 应干净报错
# 用 python3 起子进程并带硬超时：万一 MonsterPulse 真的挂死，也要能出报告而不是卡住整轮
run_case() {
  local name="$1" mode="$2" expect="$3" desc="$4"
  local log; log="$(mktemp)"

  local out
  out="$(CODEX_BIN="$(wrapper_for "$mode")" python3 - "$APP" "$log" 45 <<'PY'
import os, subprocess, sys, time
app, log, limit = sys.argv[1], sys.argv[2], float(sys.argv[3])
t0 = time.time()
try:
    p = subprocess.run([app, "--probe"], stdout=open(log, "wb"),
                       stderr=subprocess.STDOUT, timeout=limit)
    rc, timed_out = p.returncode, False
except subprocess.TimeoutExpired:
    rc, timed_out = None, True
print("%.1f %s %s" % (time.time() - t0, "TIMEOUT" if timed_out else rc,
                      "yes" if timed_out else "no"))
PY
)"
  local elapsed rc timed_out
  read -r elapsed rc timed_out <<<"$out"

  # 超时算失败，且要把残留的假 codex / sleep 收干净，否则污染后续场景
  if [ "$timed_out" = "yes" ]; then
    pkill -f "$FAKE" 2>/dev/null
    sleep 0.3
    pkill -9 -f "$FAKE" 2>/dev/null
  fi

  local ok=1 why=""
  if [ "$timed_out" = "yes" ]; then
    ok=0; why="超过 45s 未退出（挂死）"
  elif [ "$expect" = "zero" ] && [ "$rc" -ne 0 ]; then
    ok=0; why="期望成功退出，实际 rc=$rc"
  elif [ "$expect" = "nonzero" ] && [ "$rc" -eq 0 ]; then
    ok=0; why="期望失败退出，实际 rc=0"
  fi
  if [ -n "$ok_msg_expect" ] && [ "$ok_msg_expect" != "-" ]; then
    grep -q "$ok_msg_expect" "$log" || { ok=0; why="$why; 缺少预期输出 '$ok_msg_expect'"; }
  fi

  if [ "$ok" = "1" ]; then
    pass=$((pass+1)); printf '  PASS  %-16s %5ss  rc=%s\n' "$name" "$elapsed" "$rc"
  else
    fail=$((fail+1)); printf '  FAIL  %-16s %5ss  rc=%s  (%s)\n' "$name" "$elapsed" "$rc" "$why"
  fi
  printf '        %s\n' "$desc"
  printf '        输出: %s\n' "$(tr '\n' '|' <"$log" | cut -c1-200)"
  rm -f "$log"
}

echo "Codex Dock 异常路径测试"
[ -n "$REAL_CODEX" ] && echo "提示：本机存在真实 codex ($REAL_CODEX)，已用 CODEX_BIN 覆盖"
echo

# --- 读层故障：靠假 codex 注入 ---
ok_msg_expect="-"
run_case "baseline-ok" ok zero "基线：假 codex 正常响应，--probe 应成功并打印额度"

ok_msg_expect="Codex 查询失败"
run_case "unauth" unauth nonzero "未登录/凭据无效：initialize 回 error，应给出登录与网络提示"

ok_msg_expect="-"
run_case "crash" crash nonzero "辅助进程立即崩溃：应干净报错退出，不得挂死"

ok_msg_expect="查询超时"
run_case "hang" hang nonzero "子进程永不响应：20s deadline 生效并回收子进程"

ok_msg_expect="查询超时"
run_case "hang-after-init" hang-after-init nonzero "只回 initialize 后挂死：应超时退出"

ok_msg_expect="-"
run_case "garbage" garbage zero "输出混入非 JSON 行：应跳过脏行仍读到额度"

ok_msg_expect="-"
run_case "huge" huge nonzero "响应超 1 MiB：应触发大小上限保护"

ok_msg_expect="-"
run_case "slow" slow zero "延迟响应：仍应成功（顺带观察总耗时是否接近 20s 上限）"

# --- 真实场景：需要本机装了真实 codex ---
echo
echo "真实 codex 场景（不经假 codex 注入）"
if [ -z "$REAL_CODEX" ]; then
  echo "  SKIP  本机未安装 codex"
else
  # 真实未登录：指向一个空 CODEX_HOME，不动真凭据
  EMPTY_HOME="$(mktemp -d)/codex-home"
  mkdir -p "$EMPTY_HOME"
  out="$(CODEX_HOME="$EMPTY_HOME" "$APP" --probe 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "login status 和网络"; then
    pass=$((pass+1)); printf '  PASS  %-16s 真实未登录：空 CODEX_HOME 下干净报错且文案正确\n' "real-unauth"
  else
    fail=$((fail+1)); printf '  FAIL  %-16s rc=%s 输出: %s\n' "real-unauth" "$rc" "$out"
  fi
  rm -rf "$(dirname "$EMPTY_HOME")"

  # 真实断网：给子进程注入死代理，只影响这次查询，不改系统网络
  DEAD_WRAP="$(mktemp -d)/codex-deadproxy"
  printf '#!/bin/bash\nexport HTTPS_PROXY=http://127.0.0.1:1\nexport HTTP_PROXY=http://127.0.0.1:1\nexport ALL_PROXY=http://127.0.0.1:1\nexport https_proxy=http://127.0.0.1:1\nexport http_proxy=http://127.0.0.1:1\nexport all_proxy=http://127.0.0.1:1\nexport NO_PROXY=\nexport no_proxy=\nexec %s "$@"\n' "$REAL_CODEX" >"$DEAD_WRAP"
  chmod +x "$DEAD_WRAP"
  started=$(date +%s)
  out="$(CODEX_BIN="$DEAD_WRAP" "$APP" --probe 2>&1)"; rc=$?
  elapsed=$(( $(date +%s) - started ))
  # CLI 可能立即报网络错误，也可能等待到应用的 20s deadline；两条都应干净失败。
  if [ "$rc" -ne 0 ] && [ "$elapsed" -le 25 ] && \
      printf '%s' "$out" | grep -Eq 'Codex 查询(失败|超时或进程退出)' && \
      printf '%s' "$out" | grep -q '网络'; then
    pass=$((pass+1)); printf '  PASS  %-16s 真实断网：死代理下 %ss 内报错并提示检查网络\n' "real-offline" "$elapsed"
  else
    fail=$((fail+1)); printf '  FAIL  %-16s rc=%s 输出: %s\n' "real-offline" "$rc" "$out"
  fi
  rm -rf "$(dirname "$DEAD_WRAP")"
fi

echo
echo "结果：PASS $pass / FAIL $fail"
echo
echo "未覆盖（需真机操作，不能靠注入伪造）："
echo "  · 查询进行中退出的子进程回收：需跑真实 GUI 应用，另见 run-termination-tests.sh"
echo
echo "已用真机覆盖（脚本化，app/tests/sleep-wake-probe.sh）："
echo "  · 系统睡眠与唤醒：willSleep/didWake 由系统在真实睡眠时发出，无法注入伪造，"
echo "    所以走真机 Clamshell Sleep。2026-10-07 实测两个通知都收到，时间能与"
echo "    pmset 对上；并测得 systemUptime 跨睡眠只走 5.5%，不能当时间分母。"

[ "$fail" -eq 0 ] || exit 1
