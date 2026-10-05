#!/bin/bash
# Codex Dock 退出路径测试：验证查询进行中退出时辅助 Codex 子进程的回收情况。
#
# 三条路径必须分开测，它们走完全不同的代码：
#   · Command-Q  → NSApplication.terminate → applicationWillTerminate
#                   → queue.cancelAllOperations + waitUntilAllOperationsAreFinished（优雅）
#   · SIGTERM    → 进程默认直接终止，**不会**执行 applicationWillTerminate
#   · SIGKILL    → 强杀，子进程必然变孤儿
#
# 用 hang 模式注入：辅助进程挂住不响应，查询持续 20s，足够在查询期间动手。
#
# 用法：app/tests/run-termination-tests.sh
set -uo pipefail

cd "$(dirname "$0")/.."
APP=".build/MonsterPulse.app/Contents/MacOS/MonsterPulse"
BUNDLE_ID="local.monsterpulse"
FAKE="$PWD/tests/fake-codex.sh"

WRAPDIR="$(mktemp -d)"
WRAP="$WRAPDIR/codex-hang"
printf '#!/bin/bash\nexec %s hang "$@"\n' "$FAKE" >"$WRAP"
chmod +x "$WRAP"

cleanup() {
  pkill -9 -f "$FAKE" 2>/dev/null
  pkill -9 -x MonsterPulse 2>/dev/null
}
# 只在退出时删 wrapper 目录：循环开头调 cleanup 时不能删，否则 app 拿到已删除的 CODEX_BIN
trap 'cleanup; rm -rf "$WRAPDIR"' EXIT

count_kids() { pgrep -f "fake-codex.sh hang" 2>/dev/null | wc -l | tr -d ' '; }

pass=0; fail=0; notes=""

echo "Codex Dock 退出路径测试（查询进行中退出）"
echo

for mode in quit term kill; do
  cleanup; sleep 1

  CODEX_BIN="$WRAP" "$APP" >/tmp/monsterpulse-term.log 2>&1 &
  app_pid=$!
  sleep 3   # hang 模式下查询会持续 20s，此刻正处于查询进行中

  before="$(count_kids)"
  if [ "$before" = "0" ]; then
    fail=$((fail+1))
    printf '  FAIL  %-16s 应用未能在 3s 内拉起辅助子进程，测试前置不成立\n' "$mode"
    cat /tmp/monsterpulse-term.log
    continue
  fi

  case "$mode" in
    quit) osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 ;;
    term) kill -TERM "$app_pid" 2>/dev/null ;;
    kill) kill -KILL "$app_pid" 2>/dev/null ;;
  esac
  sleep 3

  after="$(count_kids)"
  alive="no"; kill -0 "$app_pid" 2>/dev/null && alive="yes"

  case "$mode" in
    quit)
      # 优雅退出的验收标准：应用退出且辅助子进程零残留
      if [ "$after" = "0" ] && [ "$alive" = "no" ]; then
        pass=$((pass+1))
        printf '  PASS  %-16s 查询中 Command-Q：%s → 0 个辅助进程，应用已退出\n' "quit(优雅)" "$before"
      else
        fail=$((fail+1))
        printf '  FAIL  %-16s 查询中 Command-Q：残留 %s 个（应用存活=%s），期望 0\n' "quit(优雅)" "$after" "$alive"
      fi
      ;;
    term)
      if [ "$after" = "0" ] && [ "$alive" = "no" ]; then
        pass=$((pass+1))
        printf '  PASS  %-16s 查询中 SIGTERM：%s → 0 个辅助进程\n' "term(SIGTERM)" "$before"
        notes="${notes}SIGTERM 下辅助进程无残留
"
      else
        fail=$((fail+1))
        printf '  FAIL  %-16s 查询中 SIGTERM：残留 %s 个（应用存活=%s）\n' "term(SIGTERM)" "$after" "$alive"
        notes="${notes}SIGTERM 退出时残留 ${after} 个孤儿辅助 codex 进程：NSApplication 默认不处理 SIGTERM，因此 applicationWillTerminate 里的 cancelAllOperations + waitUntilAllOperationsAreFinished 根本没执行，辅助进程失去父进程后继续存活。真实 codex 同样是独立进程，会一样泄漏
"
      fi
      ;;
    kill)
      # 强杀无法保证回收子进程，残留属预期行为，记录为已知限制而非失败
      if [ "$after" = "0" ]; then
        pass=$((pass+1))
        printf '  PASS  %-16s 查询中 SIGKILL：%s → 0 个（本次子进程恰好已被查询超时回收）\n' "kill(强杀)" "$before"
      else
        printf '  WARN  %-16s 查询中 SIGKILL：残留 %s 个孤儿辅助进程\n' "kill(强杀)" "$after"
        notes="${notes}SIGKILL 强杀会留下孤儿辅助 codex 进程（本次 ${after} 个），应用自身无法回收——这是进程强杀的固有结果，不算缺陷，但说明「强杀后需外部清理」不能靠应用保证
"
      fi
      ;;
  esac
done

echo
if [ -n "$notes" ]; then
  echo "记录："
  printf '%s\n' "$notes" | sed 's/^/  - /'
  echo
fi
echo "结果：PASS $pass / FAIL $fail"
[ "$fail" -eq 0 ] || exit 1