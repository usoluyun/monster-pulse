#!/bin/bash
# 故障注入用的假 Codex CLI。真实 codex 走 app-server 协议，这里只回最小 JSON-RPC。
# 由 tests/run-abnormal-tests.sh 按场景选用，通过 CODEX_BIN 注入 CodexDock。

mode="${1:-ok}"

# CodexDock 把子进程 stderr 接到 nullDevice，排障时靠这个文件看它实际收到了什么。
TRACE="${FAKE_CODEX_TRACE:-/tmp/fake-codex-trace.log}"
say() { echo "[fake-codex:$mode] $*" >>"$TRACE"; }
say "start args=$*"

# 记录每条收到的输入行
dump_in() { echo "  <- $1" >>"$TRACE"; }

case "$mode" in
  ok)
    # 正常路径：initialize 回 id=1，收到 initialized 后回 id=2 的额度
    while IFS= read -r line; do
      dump_in "$line"
      case "$line" in
        *'"initialize"'*)
          say "reply id=1 initialize"
          echo '{"jsonrpc":"2.0","id":1,"result":{"userAgent":"fake"}}' ;;
        *rateLimits*read*)
          say "reply id=2 rateLimits"
          echo '{"jsonrpc":"2.0","id":2,"result":{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":25.0,"windowDurationMins":300,"resetsAt":1791000000}}}}}' ;;
      esac
    done
    say "stdin closed"
    ;;

  unauth)
    # 未登录 / 凭据无效：initialize 直接回 error
    say "模拟未登录：initialize 返回 error"
    while IFS= read -r line; do
      # JSONSerialization 会把 / 转义成 \/，匹配前先还原
      clean="$line"
      dump_in "$clean"
      case "$clean" in
        *'"initialize"'*)
          echo '{"jsonrpc":"2.0","id":1,"error":{"code":-32001,"message":"not logged in"}}' ;;
      esac
    done
    ;;

  crash)
    # 进程立即崩溃：read() 应走「进程退出」分支而不是挂死
    say "模拟崩溃：立即退出"
    exit 3
    ;;

  hang)
    # 永不响应：验证 20s deadline 生效，且超时后子进程被回收
    say "模拟挂死：不响应任何请求，等待被超时杀掉"
    sleep 300
    ;;

  hang-after-init)
    # initialize 有响应但后续请求无响应：验证等待预算被 initialize 消耗后的行为
    say "模拟半挂死：只回 initialize，之后不响应"
    first=1
    while IFS= read -r line; do
      if [ "$first" = "1" ] && echo "$line" | grep -q '"initialize"'; then
        echo '{"jsonrpc":"2.0","id":1,"result":{"userAgent":"fake"}}'
        first=0
      fi
    done
    sleep 300
    ;;

  garbage)
    # 非 JSON 输出：验证解析容错（无法解析的行应被跳过而非崩溃）
    say "模拟脏输出：非 JSON 行"
    printf 'not json at all\n\x00\x01binary\n'
    while IFS= read -r line; do
      # JSONSerialization 会把 / 转义成 \/，匹配前先还原
      clean="$line"
      dump_in "$clean"
      case "$clean" in
        *'"initialize"'*)
          echo '{"jsonrpc":"2.0","id":1,"result":{"userAgent":"fake"}}' ;;
        *rateLimits*read*)
          echo 'this line is not json either'
          echo '{"jsonrpc":"2.0","id":2,"result":{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":25.0,"windowDurationMins":300}}}}}' ;;
      esac
    done
    ;;

  huge)
    # 超大响应：验证 1 MiB 上限保护
    say "模拟超大响应"
    while IFS= read -r line; do
      # JSONSerialization 会把 / 转义成 \/，匹配前先还原
      clean="$line"
      dump_in "$clean"
      case "$clean" in
        *'"initialize"'*)
          echo '{"jsonrpc":"2.0","id":1,"result":{"userAgent":"fake"}}' ;;
        *rateLimits*read*)
          # 单行超过 1 MiB，且不带换行
          printf '{"jsonrpc":"2.0","id":2,"result":{"pad":"'
          head -c 1200000 /dev/zero | tr '\0' 'x'
          printf '"}}\n' ;;
      esac
    done
    ;;

  slow)
    # 延迟响应：验证查询不重叠（loading 标志）与总等待预算
    say "模拟慢响应：每步延迟 3 秒"
    sleep 3
    while IFS= read -r line; do
      # JSONSerialization 会把 / 转义成 \/，匹配前先还原
      clean="$line"
      dump_in "$clean"
      case "$clean" in
        *'"initialize"'*)
          sleep 3
          echo '{"jsonrpc":"2.0","id":1,"result":{"userAgent":"fake"}}' ;;
        *rateLimits*read*)
          sleep 3
          echo '{"jsonrpc":"2.0","id":2,"result":{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":25.0,"windowDurationMins":300}}}}}' ;;
      esac
    done
    ;;

  *)
    echo "未知模式: $mode" >&2; exit 64 ;;
esac