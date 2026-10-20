#!/bin/bash
# =========================================================================
# claudeguard PoC-3 端到端串联实验（pf 地址平面 + mihomo 域名裁判 + 看门状态机）
# 运行方式:  cd <repo>/claudeguard-test/poc3 && sudo ./run-e2e.sh
# 预计耗时:  ~4 分钟。全程只动本机 pf / 临时用户 / 实验端口，结束无条件回滚。
# 实验期间临时阻断 claude 系 + example.com/example.org 的【直连】（用户自己的
#   Clash 代理链不受影响），详见 README.md 告知。
# 幂等: 开头清理上次残留; trap EXIT/INT/TERM 无条件回滚（仿 PoC-1 pf-test.sh）。
# 依据: PoC-1 (block 无 quick + 后置 pass user 胜出; pf 默认 Disabled P12/P13)
#       PoC-2 (fake-ip 白名单零侵入; REST 热切; REJECT 0.01s; anytls 健康节点)
# =========================================================================
set -u
cd "$(dirname "$0")" || exit 1
LOG="log.txt"

MIHOMO="/Applications/Clash Verge.app/Contents/MacOS/verge-mihomo"
ENGINE_DIR="$PWD/engine"
ENGINE_CFG="$ENGINE_DIR/config.yaml"
ENGINE_LOG="$ENGINE_DIR/mihomo.log"
TESTUSER="_monetafw"
TESTUID=5011

CTRL="127.0.0.1:9095"
MIXED="http://127.0.0.1:7892"

PROBE_URL="https://example.org"   # 看门真值探针域（经 EdgeProbe; 预验见: example.com 当前被边缘 RST 不适合作探针）
PROBE_DOMAIN="example.org"
ALIAS_COM="example.com"           # 对照 alias（规则/封堵保留，不作探针）
NODE_OK_NAME="anytls-node"        # ClaudeExit 的"健康出口"目标（真实节点, 规则面用）
EDGE_OK_NAME="direct"             # EdgeProbe 的"健康出口"= direct 扮演（机械验证不依赖 relay 健康）
NODE_DEAD_NAME="dead"             # 死节点: 127.0.0.1:9 (RST 型)

WATCH_INTERVAL=15
FAIL_TO_INJECT=2                  # 连续 N 次探活失败 -> 注入 REJECT
OK_TO_RELEASE=2                   # REJECT 态连续 N 次成功 -> 解除

RULEFILE="test.rules"
RULES_BACKUP="rules.before.txt"
RULES_DURING="rules.during.txt"
PF_STATE="pf-initial-state.txt"
PF_WAS_ENABLED=0
CREATED_USER=0
WATCH_PID=""
RESTORED=0
INJECT_TS="(未发生)"
RELEASE_TS="(未发生)"
M_EL="?"
M_CODE="?"

hr(){ printf '\n========== %s ==========\n' "$*"; }
pass(){ printf '>>> PASS: %s\n' "$*"; }
fail(){ printf '>>> FAIL: %s\n' "$*"; }
note(){ printf '>>> INFO: %s\n' "$*"; }
ts(){ date '+%F %T'; }

# ---------- 日志: 屏幕 + log.txt 双写 ----------
if [ -t 1 ]; then
  exec > >(tee "$LOG") 2>&1
else
  exec >> >(tee -a "$LOG") 2>&1
fi

# 直连 HTTP 状态码（剥环境代理变量; 静默黑洞形态下 curl 满超时 exit 28）
HR_HTTP(){ env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
  curl -m "$1" -sS -o /dev/null -w '%{http_code}' "$2" 2>/dev/null; }

# 经引擎 mixed 口的探针（mihomo 自己解析域名，与 /etc/hosts 无关）
iprobe(){ curl -x "$MIXED" -m 8 -sS -o /dev/null -w '%{http_code}' "$PROBE_URL" 2>/dev/null; }

# REST 工具
grp_now(){ curl -s -m 3 "$CTRL/proxies/$1" 2>/dev/null | grep -o '"now":"[^"]*"' | cut -d'"' -f4; }
grp_set(){ curl -s -m 3 -X PUT "$CTRL/proxies/$1" -d "{\"name\":\"$2\"}" -o /dev/null -w '%{http_code}' 2>/dev/null; }

# DNS 解析（必须走公网 DNS, /etc/hosts 有 claude 系诱饵 198.18.254.254）
dA(){ dig +short @223.5.5.5 "$1" A 2>/dev/null; }
dAAAA(){ dig +short @223.5.5.5 "$1" AAAA 2>/dev/null; }

# ---------- 回滚 (任何退出路径无条件执行, 幂等) ----------
restore() {
  [ "$RESTORED" = 1 ] && return
  RESTORED=1
  hr "PHASE-D ROLLBACK (trap/正常收尾共用)"
  # 1) 看门子 shell
  if [ -n "$WATCH_PID" ] && kill -0 "$WATCH_PID" 2>/dev/null; then
    kill "$WATCH_PID" 2>/dev/null && note "看门循环 ($WATCH_PID) 已停"
  fi
  # 2) 引擎进程 (以 _monetafw 身份运行的 mihomo)
  for P in $(pgrep -u "$TESTUSER" -f verge-mihomo 2>/dev/null); do kill "$P" 2>/dev/null; done
  sleep 1
  for P in $(pgrep -u "$TESTUSER" -f verge-mihomo 2>/dev/null); do kill -9 "$P" 2>/dev/null; done
  note "引擎清除: 残留 $(pgrep -u "$TESTUSER" -f verge-mihomo 2>/dev/null | wc -l | tr -d ' ') 个"
  # 引擎日志先取证 (uid 将随用户删除而不可读), 再清工作目录
  if [ -s "$ENGINE_LOG" ]; then cp -f "$ENGINE_LOG" "engine-mihomo.log" 2>/dev/null && note "引擎日志已取证 engine-mihomo.log"; fi
  rm -rf "$ENGINE_DIR"; note "引擎工作目录已清理"
  # 3) 恢复 pf 原规则集 + 原 enable 状态 (P12)
  if [ -s "$RULES_BACKUP" ]; then
    cat "$RULES_BACKUP" | pfctl -f - 2>&1 | sed 's/^/  /'
    note "pf 原规则集已恢复 (rules.before.txt)"
  else
    fail "rules.before.txt 缺失, 无法恢复 pf 原规则集! 请人工核对 pfctl -s rules"
  fi
  if [ "$PF_WAS_ENABLED" = 0 ]; then
    pfctl -d 2>&1 | sed 's/^/  /'
    note "pf 原本 Disabled, 已 pfctl -d 恢复"
  fi
  # 4) 删实验用户 (只删本次创建的)
  if [ "$CREATED_USER" = 1 ]; then
    dscl . -delete "/Users/$TESTUSER" 2>/dev/null && note "实验用户 $TESTUSER 已删除"
  else
    note "实验用户非本次创建, 保留"
  fi
  # 5) 端口释放复核
  LEFT=$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | grep -E '127\.0\.0\.1:(7892|1053|9095)')
  if [ -z "$LEFT" ]; then
    pass "端口 7892/1053/9095 全部释放"
  else
    fail "端口仍被占用:"; echo "$LEFT"
  fi
  # 6) 网络三验
  R1=$(HR_HTTP 8 "https://$PROBE_DOMAIN")
  if [ "$R1" = "200" ]; then pass "网络验1 直连 $PROBE_DOMAIN => 200 (拦截已解除)"; else fail "网络验1 直连 $PROBE_DOMAIN => '$R1' (异常, 请人工检查)"; fi
  if lsof -nP -iTCP:7890 -sTCP:LISTEN 2>/dev/null | grep -q LISTEN; then
    R2=$(curl -x 127.0.0.1:7890 -m 8 -sS -o /dev/null -w '%{http_code}' "https://$PROBE_DOMAIN" 2>/dev/null)
    if [ "$R2" = "200" ]; then pass "网络验2 用户代理 7890 => 200 (用户流量零损伤)"; else fail "网络验2 用户代理 7890 => '$R2'"; fi
  else
    note "网络验2: 本机 7890 当前无监听 (用户代理形态与 PoC-2 当时不同), 该项跳过, 不影响判定"
  fi
  if lsof -nP -iTCP:1053 -sTCP:LISTEN 2>/dev/null | grep -q LISTEN; then
    fail "网络验3: DNS 端口 1053 仍被占用!"
  else
    pass "网络验3 DNS 端口 1053 已释放"
  fi
  hr "ROLLBACK 完成 $(ts)"
}
trap restore EXIT
trap 'trap - EXIT; restore; exit 130' INT
trap 'trap - EXIT; restore; exit 143' TERM

hr "PHASE-0 预检 & 残留清理 & 环境勘察"
echo "时间: $(ts)  内核: $(sw_vers -productVersion)  用户: $(whoami) (uid $(id -u))"
[ "$(id -u)" = "0" ] || { fail "必须以 root 运行: sudo ./run-e2e.sh"; exit 1; }
[ -x "$MIHOMO" ] || { fail "引擎二进制不可执行: $MIHOMO"; exit 1; }

# 幂等清理: 残留引擎进程（只动我们自己的 _monetafw 进程）
LEFTOVER=$(pgrep -u "$TESTUSER" -f verge-mihomo 2>/dev/null | wc -l | tr -d ' ')
if [ "$LEFTOVER" != "0" ]; then
  note "上次残留引擎进程 $LEFTOVER 个, 清理"
  pkill -u "$TESTUSER" -f verge-mihomo 2>/dev/null
  sleep 1
fi
# 三端口必须空闲, 否则中止（绝不杀陌生占用者）
for PORT in 7892 1053 9095; do
  OCC=$(lsof -nP -iTCP:$PORT -sTCP:LISTEN 2>/dev/null | tail -n +2)
  if [ -n "$OCC" ]; then
    fail "端口 $PORT 已被占用 (非实验残留), 中止: $OCC"
    exit 1
  fi
done
note "端口 7892/1053/9095 空闲"

# 解析封禁目标真实 IP (v4+v6 同批, P09; 绕 hosts)
CLAUDE_V4=$(for D in claude.ai claude.com clau.de anthropic.com claudeusercontent.com api.anthropic.com; do dA "$D"; done | grep -E '^[0-9]+\.' | sort -u)
CLAUDE_V6=$(for D in claude.ai claude.com clau.de anthropic.com claudeusercontent.com api.anthropic.com; do dAAAA "$D"; done | grep ':' | sort -u)
ALIAS_V4=$({ dA "$PROBE_DOMAIN"; dA "$ALIAS_COM"; } | grep -E '^[0-9]+\.' | sort -u)
ALIAS_V6=$({ dAAAA "$PROBE_DOMAIN"; dAAAA "$ALIAS_COM"; } | grep ':' | sort -u)
BLOCK_V4=$(echo "$CLAUDE_V4 $ALIAS_V4" | tr ' ' '\n' | grep -v '^$' | sort -u)
BLOCK_V6=$(echo "$CLAUDE_V6 $ALIAS_V6" | tr ' ' '\n' | grep -v '^$' | sort -u)
# 防呆: 封禁表严禁混入 fake-ip 池 (hosts 诱饵 198.18.254.254 也在这段)
if echo "$BLOCK_V4" | grep -q '^198\.18\.'; then fail "封禁表混入 fake-ip 池地址, 中止"; exit 1; fi
if [ -z "$(echo "$BLOCK_V4" | tr -d ' \n')" ]; then fail "解析不到任何封禁 IPv4, 中止"; exit 1; fi
if [ -z "$(echo "$BLOCK_V6" | tr -d ' \n')" ]; then note "警告: v6 解析为空 (P09: 漏 v6 = 流量走 v6 泄漏)"; fi
{
  echo "# run-e2e.sh resolved $(ts)"
  echo "claude_v4: $CLAUDE_V4"
  echo "claude_v6: $CLAUDE_V6"
  echo "alias_v4:  $ALIAS_V4"
  echo "alias_v6:  $ALIAS_V6"
  echo "# 对照 design-ips.txt (设计期固化底稿, 运行时以本轮解析为准)"
} > resolved-ips.txt
echo "封禁 v4: $(echo "$BLOCK_V4" | tr '\n' ' ')"
echo "封禁 v6: $(echo "$BLOCK_V6" | tr '\n' ' ')"

hr "STEP-2 pf 初始状态与备份 (P12/P13)"
pfctl -si 2>&1 | sed 's/^/  /'
pfctl -si 2>/dev/null | grep -qi 'Status: Enabled' && PF_WAS_ENABLED=1
printf 'PF_WAS_ENABLED=%s\n' "$PF_WAS_ENABLED" > "$PF_STATE"
cp /etc/pf.conf ./pf.conf.orig 2>/dev/null && note "已备份 /etc/pf.conf -> pf.conf.orig"
pfctl -s rules > "$RULES_BACKUP" 2>/dev/null
echo "--- 原规则集备份 (rules.before.txt) ---"; cat "$RULES_BACKUP"

hr "STEP-3 启用 pf + 装规则前 sanity check"
if [ "$PF_WAS_ENABLED" = 0 ]; then
  pfctl -E 2>&1 | sed 's/^/  /' || { note "pfctl -E 失败, 中止"; exit 1; }
fi
S=$(HR_HTTP 8 "https://$PROBE_DOMAIN")
if [ "$S" != "200" ]; then
  note "启用 pf 后直连 $PROBE_DOMAIN => '$S' (异常: 默认规则不应拦截正常流量), 中止"
  exit 1
fi
pass "启用 pf 后直连 $PROBE_DOMAIN => 200, 环境安全"

hr "STEP-4 创建专属实验用户 $TESTUSER"
UID_HITS=$(dscl . -list /Users UniqueID 2>/dev/null | awk -v u="$TESTUID" '$2==u{print $1}')
if [ -n "$UID_HITS" ]; then
  fail "UID $TESTUID 已被占用: $UID_HITS —— 改 TESTUID 重跑; 中止"; exit 1
fi
if id "$TESTUSER" >/dev/null 2>&1; then
  note "用户 $TESTUSER 已存在 (上次运行遗留), 本次复用, 结束不删除"
  CREATED_USER=0
else
  dscl . -create "/Users/$TESTUSER" || exit 1
  dscl . -create "/Users/$TESTUSER" RealName "MonetaFW PoC3 Daemon"
  dscl . -create "/Users/$TESTUSER" UniqueID "$TESTUID"
  dscl . -create "/Users/$TESTUSER" PrimaryGroupID 20
  dscl . -create "/Users/$TESTUSER" NFSHomeDirectory /var/empty
  dscl . -create "/Users/$TESTUSER" UserShell /usr/bin/false
  dscl . -passwd "/Users/$TESTUSER" '*' >/dev/null 2>&1   # P05: eDSAuthPasswordQualityCheckFailed 忽略, sudo -u 不受影响
  CREATED_USER=1
  note "已创建 $TESTUSER (uid=$TESTUID)"
fi
id "$TESTUSER"

# 装定实验规则集: block 全体(目标 IP) -> 后置 pass by user（P02: 不带 quick, 后匹配胜出）
V4_LIST=$(echo "$BLOCK_V4" | tr '\n' ' ' | sed 's/ $//')
V6_LIST=$(echo "$BLOCK_V6" | tr '\n' ' ' | sed 's/ $//')
{
  cat "$RULES_BACKUP"
  echo "block drop out inet proto tcp to { $V4_LIST }"
  if [ -n "$(echo "$V6_LIST" | tr -d ' ')" ]; then echo "block drop out inet6 proto tcp to { $V6_LIST }"; fi
  echo "pass out inet proto tcp to { $V4_LIST } user $TESTUSER"
  if [ -n "$(echo "$V6_LIST" | tr -d ' ')" ]; then echo "pass out inet6 proto tcp to { $V6_LIST } user $TESTUSER"; fi
} > "$RULEFILE"
echo "--- 待装载规则 (test.rules) ---"; cat "$RULEFILE"

# 引擎工作目录 (归 _monetafw 可写)
rm -rf "$ENGINE_DIR"
mkdir -p "$ENGINE_DIR"
cp config.yaml "$ENGINE_CFG"
chown -R "$TESTUSER" "$ENGINE_DIR"
chmod 700 "$ENGINE_DIR"

hr "PHASE-A 引擎启动 (_monetafw 身份) + 三端口就位 + 节点健康门"
sudo -u "$TESTUSER" "$MIHOMO" -d "$ENGINE_DIR" -f "$ENGINE_CFG" >>"$ENGINE_LOG" 2>&1 &
# 注: 重定向由 root 侧 shell 执行 (SC2024 提示项), fd 由引擎进程继承, 功能正确
ENG_UP=0
for _I in $(seq 1 20); do
  if lsof -nP -iTCP:7892 -sTCP:LISTEN 2>/dev/null | grep -q LISTEN; then ENG_UP=1; break; fi
  sleep 0.5
done
EPID=$(pgrep -u "$TESTUSER" -f verge-mihomo | head -1)
ENGINE_AS=$(ps -o user= -p "$EPID" 2>/dev/null | tr -d ' ')
if [ "$ENG_UP" != "1" ] || [ "$ENGINE_AS" != "$TESTUSER" ]; then
  fail "引擎未能以 $TESTUSER 身份监听 7892 (up=$ENG_UP as=$ENGINE_AS)"; tail -5 "$ENGINE_LOG" 2>/dev/null; exit 1
fi
pass "引擎已启动: pid=$EPID user=$ENGINE_AS"
echo "--- 三端口 ---"
lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | grep -E '127\.0\.0\.1:(7892|1053|9095)'
note "mixed=7892 dns=1053 ctl=9095 | 对照 pf: 引擎出网 uid=$TESTUSER 豁免, 其余进程同目标被拦"
# 正式装载 pf 规则（在引擎已监听之后装载块规则, 时序更稳）
if ! pfctl -f "$RULEFILE" 2>&1; then note "规则装载失败, 回滚中止"; exit 1; fi
pfctl -s rules > "$RULES_DURING" 2>/dev/null
echo "--- 实际生效规则 (rules.during.txt) 尾部 ---"; tail -8 "$RULES_DURING"
pfctl -si 2>&1 | sed 's/^/  /'

# ---------- 看门状态机（后台子 shell, 全程 15s 周期） ----------
watch_loop() (
  WFAIL=0; WOK=0; WINJ=0
  while :; do
    CODE=$(iprobe)
    NOW=$(grp_now ClaudeExit)
    [ -z "$NOW" ] && NOW="(control-lost)"
    if [ "$WINJ" = 0 ]; then
      if [ "$CODE" = "200" ]; then WOK=$((WOK+1)); WFAIL=0; else WFAIL=$((WFAIL+1)); WOK=0; fi
      if [ "$WFAIL" -ge "$FAIL_TO_INJECT" ]; then
        printf 'INJECT-REJECT %s probe=%s claude_exit=%s\n' "$(ts)" "$CODE" "$NOW"
        grp_set ClaudeExit REJECT >/dev/null
        WINJ=1
      fi
    else
      if [ "$CODE" = "200" ]; then WOK=$((WOK+1)); else WOK=0; fi
      if [ "$WOK" -ge "$OK_TO_RELEASE" ]; then
        printf 'RELEASE %s probe=%s claude_exit=%s\n' "$(ts)" "$CODE" "$NOW"
        grp_set ClaudeExit "$NODE_OK_NAME" >/dev/null
        WINJ=0
      fi
    fi
    printf 'WATCH %s probe=%s claude_exit=%s injected=%d\n' "$(ts)" "$CODE" "$(grp_now ClaudeExit)" "$WINJ"
    sleep "$WATCH_INTERVAL"
  done
)

# P16(bash 3.2 版本坑): 不能写 `watch_loop() (…) &` —— 3.2 会只把"函数定义"丢进后台
# (生产即退的哑进程), 函数体永远不执行; 必须显式"定义完再调用"。
watch_loop &
WATCH_PID=$!
pass "看门已上线 (pid=$WATCH_PID, interval=${WATCH_INTERVAL}s, fail x ${FAIL_TO_INJECT} -> INJECT, ok x ${OK_TO_RELEASE} -> RELEASE)"

# 节点健康门: 健康节点必须探得 200, 否则整场实验失真（预验见节点时好时坏, 故设门）
note "节点健康门: EdgeProbe[direct] 探到 200 为止, 最多 ~40s..."
GATE_OK=0
for I in $(seq 1 5); do
  G=$(iprobe)
  echo "  gate try$I: probe=$G claude_exit=$(grp_now ClaudeExit)"
  [ "$G" = "200" ] && { GATE_OK=1; break; }
  sleep 7
done
if [ "$GATE_OK" = "0" ]; then
  fail "直连扮演出口竟然探不到 200 (direct + pf 豁免都不通 => 本机网络真正异常)。"
  fail "继续跑会让 PHASE-A/C 判定失真 —— 本轮中止(已自动回滚)。建议: 检查本机网络后重跑。"
  exit 1
fi
pass "健康门通过: 看门探针已拿到 200"

hr "PHASE-A (t0~45s) 正常态: 探活 200×3 + pf 拦直连"
note "观察 ~3 个看门周期..."
sleep 50
echo "--- 看门观察 ---"
grep -E '^(WATCH|INJECT-REJECT|RELEASE) ' "$LOG" 2>/dev/null | tail -6
NOWC=$(grp_now ClaudeExit)
[ "$NOWC" = "$NODE_OK_NAME" ] && pass "PHASE-A: ClaudeExit=$NOWC (未误注入)" || fail "PHASE-A: ClaudeExit=$NOWC 异常"
OK3=$(grep '^WATCH ' "$LOG" 2>/dev/null | tail -3 | grep -c 'probe=200')
if [ "${OK3:-0}" -ge 3 ]; then pass "PHASE-A 探活: 最近 3 周期 probe=200 ×3"; else note "PHASE-A 探活: 最近 3 周期 probe=200 计 ${OK3:-0}/3 (不足不硬卡, 看门自愈)"; fi

# 判定1: 普通进程(本脚本=root)直连 claude 系/alias 被 pf 拦死（黑洞形态, 满超时 exit 28）
note "判定1: 直连被封（pf block 静默黑洞）"
J1=PASS
for U in "https://claude.ai" "https://$ALIAS_COM" "https://$PROBE_DOMAIN"; do
  C=$(HR_HTTP 6 "$U"); RC=$?
  if [ "$C" = "200" ]; then
    fail "判定1 $U => '$C' exit=$RC (未被拦截!!)"; J1=FAIL
  else
    pass "判定1 $U => '$C' exit=$RC (被拦)"
  fi
done
# claude.ai 直连有 hosts 诱饵干扰: 用 --resolve 强制真实 IP 再测（真正的 pf 层机械主证）
CL_FIRST=$(echo "$CLAUDE_V4" | head -1)
CR=$(env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
  curl --resolve "claude.ai:443:$CL_FIRST" -m 6 -sS -o /dev/null -w '%{http_code}' https://claude.ai 2>/dev/null); RCR=$?
if [ "$CR" = "200" ]; then
  fail "判定1 --resolve 真实IP($CL_FIRST) 直连 claude.ai => '200' (未被拦截!!)"; J1=FAIL
else
  pass "判定1 --resolve 真实IP($CL_FIRST) 直连 claude.ai => '$CR' exit=$RCR (被拦)"
fi
# 豁免通道复核 (PoC-1 机制回归, 观察项)
C3=$(sudo -u "$TESTUSER" env -u http_proxy -u https_proxy -u all_proxy -u ALL_PROXY \
  /usr/bin/curl -m 8 -sS -o /dev/null -w '%{http_code}' "https://$PROBE_DOMAIN" 2>/dev/null)
[ "$C3" = "200" ] && pass "豁免复核: sudo -u $TESTUSER 直连 $PROBE_DOMAIN => 200 (pass 规则生效)" \
                 || note "豁免复核: '$C3' (观察项, 不作判定; PoC-1 已证机制)"

hr "PHASE-B (t~45+): 杀节点 -> 看门注入 REJECT -> 判定2"
note "REST ClaudeExit -> $NODE_DEAD_NAME : HTTP $(grp_set ClaudeExit "$NODE_DEAD_NAME")"
note "REST EdgeProbe  -> $NODE_DEAD_NAME : HTTP $(grp_set EdgeProbe "$NODE_DEAD_NAME")"
KILL_TS=$(ts)
note "kill-point $KILL_TS"
INJ_OK=0
for _I in $(seq 1 30); do   # 最多 60s 等 INJECT (2×15s 周期 + 探活耗时)
  if grep -q '^INJECT-REJECT ' "$LOG" 2>/dev/null; then INJ_OK=1; break; fi
  NOWC=$(grp_now ClaudeExit)
  [ "$NOWC" = "REJECT" ] && { INJ_OK=1; break; }
  sleep 2
done
INJECT_TS=$(grep '^INJECT-REJECT ' "$LOG" 2>/dev/null | head -1 | awk '{print $2" "$3}')
[ "$INJ_OK" = "1" ] && pass "PHASE-B 看门已注入 REJECT (INJECT-REJECT @${INJECT_TS:-unknown})" \
                   || fail "PHASE-B 60s 内未见 INJECT-REJECT (看门失灵?)"
# 判定2: REJECT 态下 claude.ai 经 7892 —— 三证 = REST select + 注入日志 + elapsed
MING=$(curl -x "$MIXED" -m 4 -sS -o /dev/null -w '%{http_code} %{time_total}' https://claude.ai 2>/dev/null || true)
M_CODE=$(echo "$MING" | awk '{print $1}')
M_EL=$(echo "$MING" | awk '{print $2}')
M_NOW=$(grp_now ClaudeExit)
case "$M_CODE" in ''|*[!0-9]*) M_CODE="?" ;; esac
case "$M_EL" in ''|*[!0-9.eE-]*) M_EL="999" ;; esac
awk -v c="$M_CODE" -v e="$M_EL" 'BEGIN{printf "  measured: code=%s elapsed=%ss (阈值≤0.2)\n", c, e}'
FAST=$(awk -v e="$M_EL" 'BEGIN{print (e<=0.2)?1:0}')
if [ "$M_NOW" = "REJECT" ] && [ "$FAST" = "1" ]; then
  J2=PASS; pass "判定2 三证齐: REST claude_exit=REJECT + INJECT 日志 + elapsed=${M_EL}s"
else
  J2=FAIL; fail "判定2: now=$M_NOW elapsed=${M_EL}s code=$M_CODE"
fi
note "对齐 t~120 预算, 稍停..."
sleep 20

hr "PHASE-C (t~120+): 复活边缘 -> 看门解除 -> 判定3"
note "REST EdgeProbe -> $EDGE_OK_NAME : HTTP $(grp_set EdgeProbe "$EDGE_OK_NAME")"
REL_OK=0
for _I in $(seq 1 30); do   # 2 周期 + 探活耗时, 上限 60s
  if grep -q '^RELEASE ' "$LOG" 2>/dev/null; then REL_OK=1; break; fi
  NOWC=$(grp_now ClaudeExit)
  [ "$NOWC" = "$NODE_OK_NAME" ] && { REL_OK=1; break; }
  sleep 2
done
RELEASE_TS=$(grep '^RELEASE ' "$LOG" 2>/dev/null | head -1 | awk '{print $2" "$3}')
NOWC=$(grp_now ClaudeExit)
if [ "$REL_OK" = "1" ] && [ "$NOWC" = "$NODE_OK_NAME" ]; then
  pass "PHASE-C 看门已解除 (RELEASE @${RELEASE_TS:-unknown}, ClaudeExit=$NOWC)"
else
  fail "PHASE-C 60s 内未恢复: ClaudeExit=$NOWC"
fi
# 判定3a: 复通 —— 探针域经 7892 = 200
F1=$(iprobe)
if [ "$F1" = "200" ]; then J3_PART1=PASS; pass "判定3a: $PROBE_DOMAIN 经 7892 => 200 (复通)"; else J3_PART1=FAIL; fail "判定3a: probe=$F1"; fi
# 判定3b (观察): claude.ai 经 7892 —— 规则面命中看引擎日志; 边缘握手结果如实记录, 不作 PASS 条件
CC=$(curl -x "$MIXED" -m 8 -sS -o /dev/null -w '%{http_code}' https://claude.ai 2>/dev/null)
MATCHED=$(tail -n 300 "$ENGINE_LOG" 2>/dev/null | grep -c 'claude.ai.*match DomainSuffix(claude.ai).*ClaudeExit')
note "判定3b: 引擎日志 claude.ai 命中 ClaudeExit 行计数=${MATCHED:-0}, 边缘握手 code=$CC (如实记录)"
if [ "$J3_PART1" = "PASS" ]; then J3=PASS; else J3=FAIL; fi

hr "VERDICT (回滚在下方随 trap 执行)"
echo "看门事件线:"
grep -E '^(INJECT-REJECT|RELEASE) ' "$LOG" 2>/dev/null | sed 's/^/  /'
echo ""
echo "J1 pf 拦直连 (含 --resolve 真实IP)                          => $J1"
echo "J2 REJECT 注入三证 (REJECT@${INJECT_TS:-?} elapsed=${M_EL}s)  => $J2"
echo "J3 复通+解除 (RELEASE@${RELEASE_TS:-?}; probe200=$J3_PART1)  => $J3"
if [ "$J1" = "PASS" ] && [ "$J2" = "PASS" ] && [ "$J3" = "PASS" ]; then
  echo ">>> 结论: PoC-3 端到端串联 【PASS】 — pf 豁免喂引擎 + 域名裁判 + 看门注入/解除 全链路成立"
else
  echo ">>> 结论: 【FAIL/PARTIAL】 — 请把 log.txt 交回复核"
fi
note "留存资产: log.txt / resolved-ips.txt / rules.before.txt / rules.during.txt / engine/mihomo.log / pf-initial-state.txt"

# 正常收尾: restore 实体执行 (trap EXIT 幂等保护已置位, 不会跑两遍)
restore
exit 0
