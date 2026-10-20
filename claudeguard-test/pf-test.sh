#!/bin/bash
# claudeguard PoC: pf 全量封死 + 专属用户豁免 机制验证
# 运行方式:  cd /Users/zhangsike/codes/clashverge/claudeguard-test && sudo ./pf-test.sh
# 幂等：可重复运行；无条件回滚（含 Ctrl-C / 异常退出）；结束时删除实验用户、恢复 pf 原状。
# 目标域名固定 example.com（绝不触碰 claude.ai / anthropic.com 等生产域名）。
set -u
cd "$(dirname "$0")"
LOG="log.txt"

# ---------- 日志：全部输出同时落盘 ----------
if [ -t 1 ]; then
  exec > >(tee "$LOG") 2>&1
else
  exec >> >(tee -a "$LOG") 2>&1
fi

RULEFILE="test.rules"
RULES_BACKUP="rules.before.txt"
RULES_DURING="rules.during.txt"
TARGET="example.com"
TESTUSER="_monetafw"
TESTUID=5011
PF_WAS_ENABLED=0
CREATED_USER=0
RESTORED=0

hr(){ printf '\n========== %s ==========\n' "$*"; }
pass(){ printf '>>> PASS: %s\n\n' "$*"; }
fail(){ printf '>>> FAIL: %s\n\n' "$*"; }
note(){ printf '>>> INFO: %s\n' "$*"; }

hr "STEP 0 环境"
echo "时间: $(date '+%F %T')"
echo "内核: $(sw_vers -productVersion)  当前用户: $(whoami) ($(id -u))"
NET_UP(){ env -u http_proxy -u https_proxy -u all_proxy -u ALL_PROXY \
    curl -sS -m 8 -o /dev/null -w '%{http_code}' "https://$TARGET" 2>/dev/null; }

hr "STEP 1 解析实验目标 IP (v4+v6) 并固化"
TARGET_IPS_V4=$(dscacheutil -q host -a name "$TARGET" | awk '/ip_address/{print $2}' | sort -u)
TARGET_IPS_V6=$(dscacheutil -q host -a name "$TARGET" | awk '/ipv6_address/{print $2}' | sort -u)
echo "IPv4: $TARGET_IPS_V4"
echo "IPv6: $TARGET_IPS_V6"
{
  echo "# resolved $(date '+%F %T')"
  echo "v4: $TARGET_IPS_V4"
  echo "v6: $TARGET_IPS_V6"
} > target-ip.txt
[ -n "$TARGET_IPS_V4" ] || { fail "解析不到 IPv4，中止"; exit 1; }

hr "STEP 2 pf 初始状态与备份"
pfctl -si 2>&1 | sed 's/^/  /'
if pfctl -si 2>/dev/null | grep -qi 'Status: Enabled'; then
  PF_WAS_ENABLED=1
fi
echo "PF_WAS_ENABLED=$PF_WAS_ENABLED  (记录于 pf-initial-state.txt)"
printf 'PF_WAS_ENABLED=%s\n' "$PF_WAS_ENABLED" > pf-initial-state.txt
cp /etc/pf.conf ./pf.conf.orig 2>/dev/null && note "已备份 /etc/pf.conf -> pf.conf.orig"

pfctl -s rules > "$RULES_BACKUP" 2>/dev/null
echo "--- 原规则集备份 (rules.before.txt) ---"
cat "$RULES_BACKUP"

# 恢复回调：EXIT 时无条件执行
restore() {
  [ "$RESTORED" = 1 ] && return
  RESTORED=1
  hr "ROLLBACK 回滚"
  cat "$RULES_BACKUP" | pfctl -f - 2>&1 | sed 's/^/  /'
  if [ "$PF_WAS_ENABLED" = 0 ]; then
    pfctl -d 2>&1 | sed 's/^/  /'
    note "pf 原本为 Disabled，已执行 pfctl -d 恢复"
  fi
  if [ "$CREATED_USER" = 1 ]; then
    dscl . -delete "/Users/$TESTUSER" 2>/dev/null && note "实验用户 $TESTUSER 已删除"
  fi
  R=$(NET_UP)
  if [ "$R" = "200" ]; then
    note "回滚后直连 $TARGET => 200，网络已恢复正常"
  else
    note "警告：回滚后直连 $TARGET => '$R'，请人工检查网络！"
  fi
  hr "回滚完成"
}
trap restore EXIT
trap 'trap - EXIT; restore; exit 130' INT
trap 'trap - EXIT; restore; exit 143' TERM

hr "STEP 3 启用 pf（若原本 Disabled）"
if [ "$PF_WAS_ENABLED" = 0 ]; then
  if ! pfctl -E 2>&1; then
    note "pfctl -E 失败，恢复并中止"
    exit 1
  fi
fi
S=$(NET_UP)
if [ "$S" != "200" ]; then
  note "启用 pf 后直连 $TARGET => '$S'（异常：默认规则不应拦截正常流量），回滚并中止"
  exit 1
fi
pass "启用 pf 后直连 $TARGET => 200，环境安全，继续"

hr "STEP 4 创建专属实验用户 $TESTUSER"
UID_HITS=$(dscl . -list /Users UniqueID | awk -v u="$TESTUID" '$2==u{print $1}')
if [ -n "$UID_HITS" ]; then
  note "UID $TESTUID 已被占用："
  echo "$UID_HITS"
  fail "UID $TESTUID 冲突，请改 TESTUID 并重跑；中止"
  exit 1
fi
if id "$TESTUSER" >/dev/null 2>&1; then
  note "用户 $TESTUSER 已存在（上一次运行的遗留），本次复用、结束时不删除"
  CREATED_USER=0
else
  dscl . -create "/Users/$TESTUSER"               || exit 1
  dscl . -create "/Users/$TESTUSER" RealName "MonetaFW Test Daemon"
  dscl . -create "/Users/$TESTUSER" UniqueID "$TESTUID"
  dscl . -create "/Users/$TESTUSER" PrimaryGroupID 20
  dscl . -create "/Users/$TESTUSER" NFSHomeDirectory /var/empty
  dscl . -create "/Users/$TESTUSER" UserShell /usr/bin/false
  dscl . -passwd "/Users/$TESTUSER" '*' >/dev/null
  CREATED_USER=1
  note "已创建 $TESTUSER (uid=$TESTUID), 无登录密码"
fi
id "$TESTUSER"

V4_LIST=$(echo "$TARGET_IPS_V4" | tr '\n' ' ' | sed 's/ $//')
V6_LIST=$(echo "$TARGET_IPS_V6" | tr '\n' ' ' | sed 's/ $//')

hr "STEP 5 装载规则：block 全体出站 -> pass 豁免 $TESTUSER"
# 注意：block 不带 quick！pf 为"最后匹配胜出"，quick 会终止评估使后面的 pass 失效。
{
  cat "$RULES_BACKUP"
  echo "block drop out inet proto tcp to { $V4_LIST }"
  [ -n "$V6_LIST" ] && echo "block drop out inet6 proto tcp to { $V6_LIST }"
  echo "pass out inet proto tcp to { $V4_LIST } user $TESTUSER"
  [ -n "$V6_LIST" ] && echo "pass out inet6 proto tcp to { $V6_LIST } user $TESTUSER"
} > "$RULEFILE"
echo "--- 待装载规则 (test.rules) ---"
cat "$RULEFILE"
if ! pfctl -f "$RULEFILE" 2>&1; then
  note "规则装载失败，回滚并中止"
  exit 1
fi
pfctl -s rules > "$RULES_DURING"
echo "--- 实际生效规则 (rules.during.txt) ---"
cat "$RULES_DURING"
pfctl -si 2>&1 | sed 's/^/  /'

hr "TEST 1  普通用户直连 $TARGET (预期: 失败)"
echo '$ env -u http_proxy -u https_proxy curl -sS -m 6 -o /dev/null -w %{http_code} https://example.com'
C=$(NET_UP 2>/tmp/pftest.err); RC=$?
[ -s /tmp/pftest.err ] && echo "curl stderr: $(head -c 300 /tmp/pftest.err)"
echo "输出: http_code='$C' exit=$RC"
if [ "$RC" -ne 0 ] || [ "$C" != "200" ]; then
  pass "普通用户直连被 pf 拦截（符合预期）"; J1=PASS
else
  fail "普通用户直连仍 200，block 未生效！"; J1=FAIL
fi

hr "TEST 2  普通用户经 Clash 代理 127.0.0.1:7890 (预期: 也失败，代理出站同被拦)"
echo '$ env http_proxy=http://127.0.0.1:7890 https_proxy=http://127.0.0.1:7890 curl -sS -m 10 -o /dev/null -w %{http_code} https://example.com'
C2=$(env http_proxy=http://127.0.0.1:7890 https_proxy=http://127.0.0.1:7890 \
     curl -sS -m 10 -o /dev/null -w '%{http_code}' "https://$TARGET" 2>&1); RC2=$?
echo "输出: '$C2' exit=$RC2"
case "$C2" in 200*) J2=FAIL;; *) J2=PASS;; esac
if [ "$J2" = PASS ]; then pass "代理出站同样被 pf 拦截（符合预期，证明拦截对代理进程生效）"; else fail "走代理居然拿到 200，mihomo 进程匹配到了豁免规则？"; fi

hr "TEST 3  豁免用户 $TESTUSER 直连 $TARGET (预期: 200 —— 本次实验核心验证点)"
echo "\$ sudo -u $TESTUSER env -u http_proxy ... curl -sS -m 8 -o /dev/null -w %{http_code} https://example.com"
C3=$(sudo -u "$TESTUSER" env -u http_proxy -u https_proxy -u all_proxy -u ALL_PROXY \
     /usr/bin/curl -sS -m 8 -o /dev/null -w '%{http_code}' "https://$TARGET" 2>&1); RC3=$?
echo "输出: '$C3' exit=$RC3"
J3=$([ "$C3" = "200" ] && echo PASS || echo FAIL)
if [ "$J3" = PASS ]; then pass "豁免用户直连 => 200，user 豁免机制成立！"; else fail "豁免用户直连失败，user 豁免机制不成立"; fi

hr "TEST 4  移除豁免后复测普通用户 (预期: 仍失败，豁免只对单一主体生效)"
echo '$ env -u http_proxy -u https_proxy curl -sS -m 6 -o /dev/null -w %{http_code} https://example.com'
C4=$(NET_UP); RC4=$?
echo "输出: http_code='$C4' exit=$RC4"
if [ "$RC4" -ne 0 ] || [ "$C4" != "200" ]; then pass "普通用户仍被拦截（符合预期，豁免粒度为单一 user）"; else fail "普通用户竟然恢复 200，违反预期！"; fi
J4=$([ "$RC4" -ne 0 ] || [ "$C4" != "200" ] && echo PASS || echo FAIL)

hr "结果汇总（自动回滚在下方随 EXIT trap 执行）"
echo "TEST1 普通用户直连被拦   预期:失败  实测:'$C' exit=$RC   => $J1"
echo "TEST2 代理出站被拦       预期:失败  实测:'$C2' exit=$RC2  => $J2"
echo "TEST3 豁免用户直连       预期:200   实测:'$C3' exit=$RC3  => $J3"
echo "TEST4 普通用户仍被拦     预期:失败  实测:exit=$RC4  => $J4"
if [ "$J1" = PASS ] && [ "$J2" = PASS ] && [ "$J3" = PASS ] && [ "$J4" = PASS ]; then
  echo ">>> 结论: pf「block 全量封死 + 后置 pass 按 user 豁免」机制 【成立】"
else
  echo ">>> 结论: 机制【不成立/部分成立】，请把 log.txt 交给复核"
fi
