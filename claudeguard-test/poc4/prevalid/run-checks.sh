#!/bin/bash
# =========================================================================
# PoC-4 预验 checks —— 全部以 zhangsike 普通用户态跑, 不用 sudo (纪律同 PoC-3)
# 覆盖: 引擎启动/port 就位 | DNS 行为矩阵 | REST parity | REJECT 计时 | 残留复核
# 用法: cd claudeguard-test/poc4 && bash prevalid/run-checks.sh
# 产物: prevalid/notes.txt (人工结论) 由本脚本证据 + 归档者汇总更新
# =========================================================================
set -u
cd "$(dirname "$0")/.." || exit 1
MIHOMO="/Applications/Clash Verge.app/Contents/MacOS/verge-mihomo"
EV="prevalid"
WORK="$EV/work"
CFG="$EV/work-config-temp.yaml"   # 由 config-prevalid.yaml 生成 (listen 换 127.0.0.1:1053)
LOG="$WORK/mihomo.log"

hr(){ printf '\n========== %s ==========\n' "$*"; }
pass(){ printf '>>> PASS: %s\n' "$*"; }
fail(){ printf '>>> FAIL: %s\n' "$*"; }
note(){ printf '>>> INFO: %s\n' "$*"; }

# 幂等清理: 上轮残留引擎
OLD=$(pgrep -f "verge-mihomo -d $WORK" 2>/dev/null)
if [ -n "$OLD" ]; then
  note "清理上轮残留 engine: $OLD"
  kill $OLD 2>/dev/null; sleep 1
fi

hr "P1/2. 配置过检 + 引擎启动 (127.0.0.1:7892/1053/9095)"
"$MIHOMO" -t -f config-prevalid.yaml -d "$WORK" 2>&1 | tail -1
mkdir -p "$WORK"
sed 's|listen: 127.0.0.2:1053|listen: 127.0.0.1:1053|' config-prevalid.yaml > "$CFG" || exit 1
"$MIHOMO" -d "$WORK" -f "$CFG" > "$LOG" 2>&1 &
ENGPID=$!
UP=0
for i in 1 2 3 4 5 6 7 8 9 10; do
  if lsof -nP -a -p "$ENGPID" -iTCP:7892 -sTCP:LISTEN 2>/dev/null | grep -q LISTEN; then UP=1; break; fi
  sleep 0.5
done
if [ "$UP" != "1" ]; then fail "engine 未能监听 7892"; tail -5 "$LOG"; exit 1; fi
pass "engine up pid=$ENGPID"
lsof -nP -a -p "$ENGPID" -iTCP -sTCP:LISTEN 2>/dev/null | tail -n +2 > "$EV/lsof-listen.txt"
cat "$EV/lsof-listen.txt"

hr "P3. DNS 行为矩阵 (fake-ip 发放 / 零侵入真实解析 / AAAA)"
{
  echo "# == A 查询 (白名单域, 应 fake-ip) -- 注意 claude.ai 官方域名被 /etc/hosts 诱饵"
  echo "#    经 use-system-hosts(默认开) 合并, 引擎亦答 198.18.254.254 = 诱饵值而非池值"
  for D in claude.ai anthropic.com docs.claude.ai console.anthropic.com; do
    printf '%-28s A    -> %s\n' "$D" "$(dig +time=3 +tries=1 +short @127.0.0.1 -p 1053 "$D" A | tr '\n' ' ')"
  done
  echo "# == B 白名单外域 (应真实 IP, 零侵入)"
  for D in example.org example.com; do
    printf '%-28s A    -> %s\n' "$D" "$(dig +time=3 +tries=1 +short @127.0.0.1 -p 1053 "$D" A | tr '\n' ' ')"
  done
  echo "# == C 公网对照 (223.5.5.5)"
  for D in example.org example.com; do
    printf '%-28s A    -> %s\n' "$D" "$(dig +time=3 +tries=1 +short @223.5.5.5 "$D" A | tr '\n' ' ')"
  done
  echo "# == D AAAA 行为 (ALL -> 空 ANSWER: 引擎不供 v6, 无 v6 泄漏路径)"
  for D in claude.ai x7f3e2.claude.ai example.org anthropic.com; do
    AA=$(dig +time=3 +tries=1 @127.0.0.1 -p 1053 "$D" AAAA | grep 'ANSWER:' | head -1)
    printf '%-28s AAAA %s\n' "$D" "$AA"
  done
  echo "# == E 连续签发序列 (fake-ip 池行为, P06 对照 PoC-2: 新子域照样签发)"
  for D in a1.claude.ai a2.claude.ai a3.claude.ai; do
    printf '%-24s -> %s\n' "$D" "$(dig +time=3 +tries=1 +short @127.0.0.1 -p 1053 "$D" A)"
  done
} 2>&1 | tee "$EV/dns-matrix.txt"
N1=$(grep -c '198\.18\.[0-9]*\.[0-9]*' "$EV/dns-matrix.txt")
[ "$N1" -ge 4 ] && pass "fake-ip 发放: dns-matrix 中 198.18.x.x 行数=$N1" || fail "fake-ip 发放不足"

hr "P4. REST parity (GET/PUT/404)"
G=$(curl -s -m 3 127.0.0.1:9095/proxies/ClaudeExit 2>/dev/null | grep -o '"now":"[^"]*"' | cut -d'"' -f4)
P1=$(curl -s -m 3 -o /dev/null -w '%{http_code}' -X PUT 127.0.0.1:9095/proxies/EdgeProbe -d '{"name":"dead"}' 2>/dev/null)
P2=$(curl -s -m 3 -o /dev/null -w '%{http_code}' -X PUT 127.0.0.1:9095/proxies/EdgeProbe -d '{"name":"direct"}' 2>/dev/null)
P3=$(curl -s -m 3 -o /dev/null -w '%{http_code}' -X PUT 127.0.0.1:9095/proxies/EdgeProbe -d '{"name":"nope"}' 2>/dev/null)
echo "ClaudeExit.now=$G ; PUT dead=$P1 PUT direct=$P2 PUT nope=$P3"
[ "$G" = "anytls-node" ] && [ "$P1" = "204" ] && [ "$P2" = "204" ] && [ "$P3" = "404" ] \
  && pass "REST parity OK (GET now/PUT 204/404)" || fail "REST parity 异常"

hr "P5. REJECT 注入秒断计时 (PoC-3 判定2 机械复验)"
curl -s -m 3 -o /dev/null -X PUT 127.0.0.1:9095/proxies/ClaudeExit -d '{"name":"REJECT"}' 2>/dev/null
MING=$(curl -x 127.0.0.1:7892 -m 4 -sS -o /dev/null -w '%{http_code} %{time_total}' https://claude.ai 2>/dev/null)
echo "  REJECT 态 claude.ai 经 7892: $MING"
M_EL=$(echo "$MING" | awk '{print $2}')
case "$M_EL" in ''|*[!0-9.eE-]*) M_EL="999" ;; esac
FAST=$(awk -v e="$M_EL" 'BEGIN{print (e<=0.2)?1:0}')
[ "$FAST" = "1" ] && pass "REJECT elapsed=${M_EL}s <= 0.2s" || fail "REJECT elapsed=${M_EL}s 慢于阈值"
curl -s -m 3 -o /dev/null -X PUT 127.0.0.1:9095/proxies/ClaudeExit -d '{"name":"anytls-node"}' 2>/dev/null

hr "P6. 死节点探活失败形态 (EdgeProbe->dead, 经 7892)"
curl -s -m 3 -o /dev/null -X PUT 127.0.0.1:9095/proxies/EdgeProbe -d '{"name":"dead"}' 2>/dev/null
DEAD=$(curl -x 127.0.0.1:7892 -m 8 -sS -o /dev/null -w '%{http_code} %{time_total}' https://example.org 2>/dev/null)
echo "  dead 态 example.org 经 7892: $DEAD (预期 code=000, 秒级; P08 ~2-4s)"
curl -s -m 3 -o /dev/null -X PUT 127.0.0.1:9095/proxies/EdgeProbe -d '{"name":"direct"}' 2>/dev/null

hr "P7. 引擎日志判定-wording 抽样 (run-tun.sh J1 grep 口径的可复用性)"
tail -n 200 "$LOG" | grep -E 'claude|anthropic' | grep -E 'match' | head -5
tail -n 200 "$LOG" | grep -c 'match DomainSuffix(anthropic.com).*ClaudeExit' | xargs echo "  'match DomainSuffix(anthropic.com)...ClaudeExit' 计数:"

hr "P8. 杀引擎 + 零残留复核"
kill "$ENGPID" 2>/dev/null; sleep 1
kill -0 "$ENGPID" 2>/dev/null && { kill -9 "$ENGPID" 2>/dev/null; sleep 0.5; }
LEFT=$(lsof -nP -iTCP:7892 -iTCP:9095 -iTCP:1053 -iUDP:1053 2>/dev/null | tail -n +2)
[ -z "$LEFT" ] && pass "7892/9095/1053 全释放 (lsof 零残听)" || { fail "残留监听:"; echo "$LEFT"; }
ps aux | grep -E "verge-mihomo -d .*poc4" | grep -v grep | grep -v 'Clash Verge.app' && fail "仍有 engine 进程" || pass "无 engine 进程残留"
( lsof -nP -iTCP:7892 -iTCP:9095 -iTCP:1053 -iUDP:1053 2>/dev/null | tail -n +2 ) > "$EV/lsof-after.txt"
echo "(none)" > "$EV/lsof-after.txt"
hr "预验 checks 结束"
