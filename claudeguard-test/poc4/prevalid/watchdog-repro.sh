#!/bin/bash
# =========================================================================
# PoC-4 预验: 看门+回滚代码在 macOS /bin/bash (3.2) 下的抽取复跑 (kill-repro harness)
# 抄自 poc3/run-e2e.sh 的 watch_loop / 停机文件 / 验证式击杀 / 孤儿清扫,
# iprobe/grp 用 mock 序列代替真实探针; 验证四件事:
#   R1: watch_loop 在 bash 3.2 下函数体真的执行 (P16 防回归)
#   R2: pseq=000,000,200,200 与 PoC-3 同款: INJECT x1 -> RELEASE x1, 无 flap 无双发
#   R3: 停机文件+验证式击杀 让看门确定性退场 (P18)
#   R4: P16 地雷静态扫描 (VAR漏括号+多字节邻接) 本 harness 干净, 正稿同法扫
# 用法: cd claudeguard-test/poc4 && /bin/bash prevalid/watchdog-repro.sh
# =========================================================================
set -u
cd "$(dirname "$0")" || exit 1
echo "bash version: $(/bin/bash --version | head -1)"

WATCH_INTERVAL=1        # mock 加速: 1s 周期
FAIL_TO_INJECT=2
OK_TO_RELEASE=2
STOPFILE="./stop.repro"
LOG="./repro.log"
rm -f "$STOPFILE" "$LOG"
MOCK_N=0

ts(){ date '+%T'; }
pass(){ printf '>>> PASS: %s\n' "$*"; }
fail(){ printf '>>> FAIL: %s\n' "$*"; }

# mock 序列 (文件计数): 000,000,200,200 循环 —— 与 PoC-3 P6 转态模拟同 pseq
# NOTE: 计数不能用普通 shell 变量 —— iprobe 被放在 $() 里跑, 每次都是新子壳,
# 变量计数永不跨调用递增 (bash 3.2/bash5 同此); 必须落盘跨子壳。
iprobe(){
  N=$(( $(cat seq.count 2>/dev/null || echo 0) + 1 ))
  echo "$N" > seq.count
  case $(( (N-1) % 4 )) in
    0|1) echo 000 ;;
    *)   echo 200 ;;
  esac
}
grp_now(){ echo "(mock)"; }
grp_set(){ printf 'MOCK-SET %s\n' "$*"; return 0; }

# ---------- 抽取段: 与 run-tun.sh 载入的看门代码逐字一致 ----------
watch_loop() (
  WFAIL=0; WOK=0; WINJ=0
  while :; do
    [ -f "$STOPFILE" ] && exit 0    # P18: 停机文件先行
    WCODE=$(iprobe)
    WNOW=$(grp_now ClaudeExit)
    [ -z "$WNOW" ] && WNOW="(control-lost)"
    if [ "$WINJ" = 0 ]; then
      if [ "$WCODE" = "200" ]; then WOK=$((WOK+1)); WFAIL=0; else WFAIL=$((WFAIL+1)); WOK=0; fi
      if [ "$WFAIL" -ge "$FAIL_TO_INJECT" ]; then
        printf 'INJECT-REJECT %s probe=%s claude_exit=%s\n' "$(ts)" "$WCODE" "$WNOW"
        grp_set ClaudeExit REJECT >/dev/null
        WINJ=1
      fi
    else
      if [ "$WCODE" = "200" ]; then WOK=$((WOK+1)); else WOK=0; fi
      if [ "$WOK" -ge "$OK_TO_RELEASE" ]; then
        printf 'RELEASE %s probe=%s claude_exit=%s\n' "$(ts)" "$WCODE" "$WNOW"
        grp_set ClaudeExit anytls-node >/dev/null
        WINJ=0
      fi
    fi
    printf 'WATCH %s probe=%s claude_exit=%s injected=%d\n' "$(ts)" "$WCODE" "$WNOW" "$WINJ"
    sleep "$WATCH_INTERVAL"
  done
)

# P16: 定义+显式调用分离 —— 不写 `watch_loop() (…) &`
# watchdog 输出接进 log (正稿里由 exec tee 天然完成)
watch_loop >> "$LOG" 2>&1 &
WATCH_PID=$!
echo "watchdog pid=$WATCH_PID"
sleep 10   # 10 周期: 恒定慢节拍, 校验无 flap

# R1/R2 校验
W_LINES=$(grep -c '^WATCH ' "$LOG" 2>/dev/null)
case "$W_LINES" in ''|*[!0-9]*) W_LINES=0 ;; esac
[ "$W_LINES" -ge 6 ] && pass "R1 bash3.2 函数体在跑 (WATCH 行=$W_LINES)" || fail "R1 WATCH 行=$W_LINES"
NI=$(grep -c '^INJECT-REJECT ' "$LOG" 2>/dev/null); case "$NI" in ''|*[!0-9]*) NI=0 ;; esac
NR=$(grep -c '^RELEASE ' "$LOG" 2>/dev/null); case "$NR" in ''|*[!0-9]*) NR=0 ;; esac
[ "$NI" -ge 1 ] && pass "R2a INJECT 触发 (x$NI)" || fail "R2a 无 INJECT"
[ "$NR" -ge 1 ] && pass "R2b RELEASE 触发 (x$NR)" || fail "R2b 无 RELEASE"
# 10 周期下 pseq=000,000,200,200 循环: 3 段连败 -> 3 INJECT; 2 段连胜 -> 2 RELEASE;
# 计数恰等于分段数即"无 flap/无双发/每段恰好一次" 的确定性证据
if [ "$NI" = "3" ] && [ "$NR" = "2" ]; then
  pass "R2c 计数确定性 (INJECT x$NI / RELEASE x$NR = 连败/连胜分段数, 无 flap)"
else
  fail "R2c 期望 INJECT x3 RELEASE x2, 实际 x$NI / x$NR"
fi

# R3: 停机文件 + 验证式击杀 (正稿逐字抽取段)
touch "$STOPFILE" 2>/dev/null
kill -0 "$WATCH_PID" 2>/dev/null && ALIVE_BEFORE=1 || ALIVE_BEFORE=0
pkill -TERM -P "$WATCH_PID" 2>/dev/null
kill "$WATCH_PID" 2>/dev/null
_n=0
while kill -0 "$WATCH_PID" 2>/dev/null; do
  _n=$((_n+1)); [ "$_n" -ge 10 ] && break
  sleep 0.3
done
kill -0 "$WATCH_PID" 2>/dev/null && kill -9 "$WATCH_PID" 2>/dev/null
sleep 0.2
if kill -0 "$WATCH_PID" 2>/dev/null; then fail "R3 看门未死"; else pass "R3 看门已死 (停机文件+验证击杀; 击杀前alive=$ALIVE_BEFORE)"; fi
tail -4 "$LOG"

# R4: P16 静态地雷扫描: 变量紧邻多字节 UTF-8 首 byte 的可疑点 (本 harness 自扫)
SC=$(LC_ALL=C perl -ne 'print "$ARGV:$.: $_" if /\$[A-Za-z_][A-Za-z0-9_]*[^\x20-\x7e\x0a\}\{;"\)\( >&\/\$=,+\-*.!\[\]\x27]/' "$0" "$(dirname "$0")/run-checks.sh" 2>/dev/null | head -8)
[ -z "$SC" ] && pass "R4 P16 扫描: harness+run-checks 无 VAR 漏括号/多字节邻接地雷" || { echo "可疑行(需人工复核):"; echo "$SC"; }
rm -f "$STOPFILE" "$LOG"
echo "预验 watchdog-repro 完成"
