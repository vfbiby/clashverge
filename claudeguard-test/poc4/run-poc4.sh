#!/bin/bash
# =========================================================================
# claudeguard PoC-4: Linux 等价性验证（Docker 容器 = Linux 测试台, 容器内全程 root 无宿主 sudo）
# 运行方式: docker exec monetafw-test bash /opt/poc4/run-poc4.sh
# 结构照搬 poc3/run-e2e.sh（P16-P19 教训常驻: 停机文件/验证式击杀/孤儿清扫/退场斩管道）
# 验证口径: SW1 owner 豁免+首匹配重排 / SW2 DROP vs REJECT / SW4 共存态 / SW5 conntrack 残留
#           + J1'/T1'/T2'/J2'/J3'（PoC-2/3 口径在 Linux 复跑）
# bash 5.1: P16/P17 两大 bash 3.2 坑自然消失——本脚本仍完全沿用加固形态,
#           以验证 "加固代码在 bash5 下行为一致"（07-LINUX-MAPPING 预判面）。
# =========================================================================
set -u
cd /opt/poc4 || exit 1
OUT=/out
mkdir -p "$OUT"
LOG="$OUT/log.txt"

ENGINE_DIR=/opt/monetafw/engine
ENGINE_CFG="$ENGINE_DIR/config.yaml"
ENGINE_LOG="$ENGINE_DIR/mihomo.log"
TESTUSER=monetafw
TESTUID=5011

CTRL="127.0.0.1:9095"
MIXED="http://127.0.0.1:7892"

PROBE_URL="https://example.org"
PROBE_DOMAIN="example.org"
ALIAS_COM="example.com"
NODE_OK_NAME="anytls-node"
EDGE_OK_NAME="direct"
NODE_DEAD_NAME="dead"

WATCH_INTERVAL=15
FAIL_TO_INJECT=2
OK_TO_RELEASE=2

STOPFILE="$OUT/stop.guard"
rm -f "$STOPFILE" 2>/dev/null
M_EL="?"
M_CODE="?"

hr(){ printf '\n========== %s ==========\n' "$*"; }
pass(){ printf '>>> PASS: %s\n' "$*"; }
fail(){ printf '>>> FAIL: %s\n' "$*"; }
note(){ printf '>>> INFO: %s\n' "$*"; }
ts(){ date '+%F %T'; }

exec > >(tee "$LOG") 2>&1

HD(){ env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
  curl -m "$1" -sS -o /dev/null -w '%{http_code}' "$2" 2>/dev/null; }
HT(){ env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
  curl -m "$1" -sS -o /dev/null -w '%{http_code} %{time_total}' "$2" 2>/dev/null; }
iprobe(){ curl -x "$MIXED" -m 8 -sS -o /dev/null -w '%{http_code}' "$PROBE_URL" 2>/dev/null; }
grp_now(){ curl -s -m 3 "$CTRL/proxies/$1" 2>/dev/null | grep -o '"now":"[^"]*"' | cut -d'"' -f4; }
grp_set(){ curl -s -m 3 -X PUT "$CTRL/proxies/$1" -d "{\"name\":\"$2\"}" -o /dev/null -w '%{http_code}' 2>/dev/null; }
dA(){ dig +short @223.5.5.5 "$1" A 2>/dev/null; }
dAAAA(){ dig +short @223.5.5.5 "$1" AAAA 2>/dev/null; }

# ---------- 规范链构造: 豁免(ACCEPT uid)在最前, 封禁(per-IP, 逐 IP 一条)在后 ----------
# 首匹配语义: 同目标命中先出现的规则; 故豁免必须在封禁之前 (与 macOS pf 后匹配相反)
canonical_chain(){
  local ACT="$1" OACT="$2"
  iptables -F MONETAFW 2>/dev/null; ip6tables -F MONETAFW 2>/dev/null
  iptables -A MONETAFW -m owner --uid-owner "$TESTUID" -m tcp -p tcp -m multiport --dports 80,443 -j ACCEPT
  ip6tables -A MONETAFW -m owner --uid-owner "$TESTUID" -m tcp -p tcp -m multiport --dports 80,443 -j ACCEPT
  for IP in $BLOCK_V4; do iptables -A MONETAFW -m tcp -p tcp -m multiport --dports 80,443 -d "$IP" -j "$ACT"; done
  for IP in $BLOCK_V6; do ip6tables -A MONETAFW -m tcp -p tcp -m multiport --dports 80,443 -d "$IP" -j "$OACT"; done
}
reverse_chain(){ iptables -F MONETAFW; ip6tables -F MONETAFW
  iptables -A MONETAFW -m tcp -p tcp -m multiport --dports 80,443 -d "$1" -j DROP
  iptables -A MONETAFW -m owner --uid-owner "$TESTUID" -m tcp -p tcp -m multiport --dports 80,443 -j ACCEPT; }
hook_up(){ iptables -I OUTPUT 1 -j MONETAFW 2>/dev/null; ip6tables -I OUTPUT 1 -j MONETAFW 2>/dev/null; }
hook_down(){ iptables -D OUTPUT 1 2>/dev/null; iptables -D OUTPUT 1 2>/dev/null
             ip6tables -D OUTPUT 1 2>/dev/null; ip6tables -D OUTPUT 1 2>/dev/null; }
cw(){ stat -c %s "$1" 2>/dev/null || echo 0; }
ste(){ ss -tn state established '( dport = :80 )' 2>/dev/null | grep -m1 '104.20.26.136' || echo "(established 表已无此连接)"; }

# ---------- 回滚 ----------
RESTORED=0
restore() {
  [ "$RESTORED" = 1 ] && return
  RESTORED=1
  hr "PHASE-D ROLLBACK"
  # 1) 看门: 停机文件 + 验证式击杀 + 孤儿清扫 (P18/P19 加固形态)
  touch "$STOPFILE" 2>/dev/null
  if [ -n "${WATCH_PID:-}" ] && kill -0 "$WATCH_PID" 2>/dev/null; then
    pkill -TERM -P "$WATCH_PID" 2>/dev/null
    kill "$WATCH_PID" 2>/dev/null
    _n=0
    while kill -0 "$WATCH_PID" 2>/dev/null; do _n=$((_n+1)); [ "$_n" -ge 10 ] && break; sleep 0.3; done
    kill -0 "$WATCH_PID" 2>/dev/null && kill -9 "$WATCH_PID" 2>/dev/null
  fi
  for Z in $(pgrep -f "bash /opt/poc4/run-poc4.sh" 2>/dev/null); do
    [ "$Z" = "$$" ] && continue
    ZP=$(ps -o ppid= -p "$Z" 2>/dev/null | tr -d ' ')
    [ "$ZP" = "1" ] && kill -9 "$Z" 2>/dev/null && note "孤儿 bash $Z 已击杀"
  done
  for T in $(pgrep -f "tee $LOG" 2>/dev/null); do
    TPAR=$(ps -o ppid= -p "$T" 2>/dev/null | tr -d ' ')
    if [ "$TPAR" = "1" ]; then kill -TERM "$T" 2>/dev/null; sleep 0.5; kill -9 "$T" 2>/dev/null; note "孤儿 tee $T 已击杀"; fi
  done
  note "看门循环已停"
  # 2) 引擎 (uid 5011) —— 日志先取证再删目录 (P18 时序纪律)
  for P in $(pgrep -u "$TESTUSER" -f mihomo 2>/dev/null); do kill "$P" 2>/dev/null; done
  sleep 1
  for P in $(pgrep -u "$TESTUSER" -f mihomo 2>/dev/null); do kill -9 "$P" 2>/dev/null; done
  note "引擎清除: 残留 $(pgrep -u "$TESTUSER" -f mihomo 2>/dev/null | wc -l | tr -d ' ') 个"
  if [ -s "$ENGINE_LOG" ]; then cp -f "$ENGINE_LOG" "$OUT/engine-mihomo.log" 2>/dev/null && note "引擎日志已取证 $OUT/engine-mihomo.log"; fi
  rm -rf "$ENGINE_DIR"; note "引擎工作目录已清理"
  # 3) iptables: 解钩 + 整体恢复进容器首拍的快照 (不留半套规则)
  hook_down
  if [ -s /tmp/base.rules ]; then
    iptables-restore < /tmp/base.rules; ip6tables-restore < /tmp/base6.rules
    note "iptables/ip6tables 已恢复 base 快照"
  else
    fail "base.rules 缺失, 无法恢复! 请人工 iptables -S 核对"
  fi
  # 4) SW5 副产物: lo 别名 + 本地流服务器 + 残余 curl
  ip addr del 104.20.26.136/32 dev lo 2>/dev/null && note "lo 别名 104.20.26.136/32 已删" || note "lo 别名不存在或已删"
  pkill -f poc4_stream_server 2>/dev/null && note "SW5 本地流服务器已杀" || true
  pkill -f 'stress.server' 2>/dev/null && true || true
  for QQ in $(pgrep -f '104.20.26.136' 2>/dev/null); do [ "$QQ" != "$$" ] && kill -9 "$QQ" 2>/dev/null && note "残余 SW5 客户端/服务端 $QQ 已清"; done
  # 5) 端口释放 + 链零残留 + 拦截解除三验
  L=$(ss -tln 2>/dev/null | grep -E ':(7892|1053|9095)')
  [ -z "$L" ] && pass "端口 7892/1053/9095 全部释放" || { fail "端口仍占用:"; echo "$L"; }
  R=$(iptables -S | grep -c MONETAFW || true)
  [ "$R" = "0" ] && pass "MONETAFW 链/挂钩零残留" || fail "MONETAFW 残留 $R 处!"
  RH=$(iptables -S OUTPUT | grep -cv '^$' || true)
  [ "$RH" = "0" ] && pass "OUTPUT 链恢复空基线" || { echo "OUTPUT 现状:"; iptables -S OUTPUT | sed 's/^/  /'; }
  R1=$(HD 8 "https://$PROBE_DOMAIN")
  [ "$R1" = "200" ] && pass "网络验1 直连 $PROBE_DOMAIN => 200 (拦截已解除)" || fail "网络验1 => '$R1' 异常"
  hr "ROLLBACK 完成 $(ts)"
}
trap restore EXIT
trap 'trap - EXIT; restore; exit 130' INT
trap 'trap - EXIT; restore; exit 143' TERM

hr "PHASE-0 环境勘察"
echo "时间: $(ts)  内核: $(uname -srm)  用户: $(whoami) (uid $(id -u))"
echo "bash ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}  (P16/P17 为 bash3.2 坑, bash5 自然消失)"
iptables --version
note "iptables 快照留存 /tmp/base.rules + /tmp/base6.rules (进容器首拍备料时完成)"
echo "SW4 基线调查: 防火墙共存栈"
for C in ufw firewalld nftables; do dpkg -l $C 2>/dev/null | grep -q ^ii && echo "  => $C 已安装" || echo "  => $C 未安装"; done
echo "iptables -S 全景: $(iptables -S | wc -l | tr -d ' ') 行"; iptables -S | sed 's/^/  /'
ip6tables -S | sed 's/^/  /'
echo "conntrack 子系统: $(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo unavailable)"

hr "PHASE-0b 封禁目标解析 (dig @223.5.5.5 视图)"
CLAUDE_V4=$(for D in claude.ai claude.com clau.de anthropic.com claudeusercontent.com api.anthropic.com; do dA "$D"; done | grep -E '^[0-9]+\.' | sort -u)
CLAUDE_V6=$(for D in claude.ai claude.com clau.de anthropic.com claudeusercontent.com api.anthropic.com; do dAAAA "$D"; done | grep ':' | sort -u)
ALIAS_V4=$({ dA "$PROBE_DOMAIN"; dA "$ALIAS_COM"; } | grep -E '^[0-9]+\.' | sort -u)
ALIAS_V6=$({ dAAAA "$PROBE_DOMAIN"; dAAAA "$ALIAS_COM"; } | grep ':' | sort -u)
BLOCK_V4=$(echo "$CLAUDE_V4 $ALIAS_V4" | tr ' ' '\n' | grep -v '^$' | sort -u)
BLOCK_V6=$(echo "$CLAUDE_V6 $ALIAS_V6" | tr ' ' '\n' | grep -v '^$' | sort -u)
if echo "$BLOCK_V4" | grep -q '^198\.18\.'; then fail "封禁表混入 fake-ip 池, 中止"; exit 1; fi
[ -z "$(echo "$BLOCK_V4" | tr -d ' \n')" ] && { fail "解析不到封禁 IPv4, 中止"; exit 1; }
[ -z "$(echo "$BLOCK_V6" | tr -d ' ')" ] && note "警告: v6 封禁表为空 (P09: 漏 v6 = 泄漏)"
{
  echo "# run-poc4.sh resolved $(ts)  (视图: dig @223.5.5.5)"
  echo "claude_v4: $CLAUDE_V4"
  echo "claude_v6: $CLAUDE_V6"
  echo "alias_v4:  $ALIAS_V4"
  echo "alias_v6:  $ALIAS_V6"
  echo "# 容器自带 DNS (192.168.65.7) 视图对照:"
  for D in claude.ai claude.com anthropic.com example.org example.com; do
    echo "  container-dns $D: $(getent ahostsv4 "$D" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')"
  done
} > "$OUT/resolved-ips.txt"
cat "$OUT/resolved-ips.txt"
echo "封禁 v4: $(echo "$BLOCK_V4" | tr '\n' ' ')"
echo "封禁 v6: $(echo "$BLOCK_V6" | tr '\n' ' ')"

hr "PHASE-1 引擎启动 (uid=$TESTUID) + T1'/T2' + 健康门"
rm -rf "$ENGINE_DIR"; mkdir -p "$ENGINE_DIR"
cp /tmp/cfg.yaml "$ENGINE_CFG"
chown -R "$TESTUSER:users" "$ENGINE_DIR"
chmod 700 "$ENGINE_DIR"
sudo -u "$TESTUSER" /usr/local/bin/mihomo -d "$ENGINE_DIR" -f "$ENGINE_CFG" >>"$ENGINE_LOG" 2>&1 &
ENG_UP=0
for _I in $(seq 1 40); do
  if ss -tln | grep -q '127.0.0.1:7892'; then ENG_UP=1; break; fi
  sleep 0.5
done
EPID=$(pgrep -u "$TESTUSER" -f mihomo | head -1)
ENGINE_AS=$(ps -o user= -p "$EPID" 2>/dev/null | tr -d ' ')
if [ "$ENG_UP" != "1" ] || [ "$ENGINE_AS" != "$TESTUSER" ]; then
  fail "引擎未能以 $TESTUSER 监听 (up=$ENG_UP as=$ENGINE_AS)"; tail -5 "$ENGINE_LOG" 2>/dev/null; exit 1
fi
pass "引擎已启动: pid=$EPID user=$ENGINE_AS (uid=$(ps -o uid= -p "$EPID" | tr -d ' '))"
echo "--- 三端口 ---"; ss -tlnp | grep -E ':(7892|1053|9095)' | sed 's/^/  /'
T1R=$(dig +short @127.0.0.1 -p 1053 claude.ai A 2>/dev/null | head -1)
T2R=$(dig +short @127.0.0.1 -p 1053 example.org A 2>/dev/null | grep -E '^[0-9]' | head -1)
case "$T1R" in 198.18.*) pass "T1' fake-ip: claude.ai @1053 => $T1R"; T1=PASS;; *) fail "T1': '$T1R'"; T1=FAIL;; esac
case "$T2R" in 198.18.*) fail "T2' 零侵入被破: example.org => '$T2R'"; T2=FAIL;; *) pass "T2' 零侵入: example.org @1053 => $T2R (真实 IP)"; T2=PASS;; esac
echo "$T2R" > "$OUT/t2_real_ip.txt"
GATE_OK=0
for I in $(seq 1 5); do
  G=$(iprobe); echo "  gate try$I: probe=$G claude_exit=$(grp_now ClaudeExit)"
  [ "$G" = "200" ] && { GATE_OK=1; break; }
  sleep 5
done
[ "$GATE_OK" = "1" ] && pass "健康门通过: EdgeProbe[direct] 探活 200" || { fail "健康门未过, 中止"; exit 1; }
NY=$(curl -x "$MIXED" -m 8 -sS -o /dev/null -w '%{http_code} %{time_total}' https://claude.ai 2>/dev/null)
note "基线参考: claude.ai 经 7892 (ClaudeExit=anytls-node) => $NY (边缘握手如实记录)"

hr "SW5 连接残留实验 (已建连接面上: DROP / REJECT / conntrack-accept 三态)"
note "造 victim(root) 到封禁 IP 的长连接: lo 加别名 example.org 真IP 104.20.26.136 = 本地流服务器"
ip addr add 104.20.26.136/32 dev lo 2>&1 | sed 's/^/  /'
ip addr show lo | grep -q '104.20' && note "lo 别名已加: 到封禁 IP 的流量=自回环, OUTPUT 链照常命中"
cat > /tmp/poc4_stream_server.py <<'PYEOF'
import http.server, socketserver, time
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type','application/octet-stream')
        self.send_header('Content-Length','36000000')
        self.end_headers()
        chunk=b'\x00'*24000
        for i in range(2400):
            try:
                self.wfile.write(chunk); self.wfile.flush()
            except Exception: return
            if i%40==0: time.sleep(0.02)
    def log_message(self,*a,**k): pass
class S(socketserver.ThreadingTCPServer): allow_reuse_address=True
S(('104.20.26.136',80),H).serve_forever()
PYEOF
python3 /tmp/poc4_stream_server.py >/dev/null 2>&1 &
SRVPID=$!
sleep 1
ss -tlnp | grep '104.20.26.136:80' | sed 's/^/  /' || fail "SW5 本地流服务器未监听"
iptables -N MONETAFW 2>/dev/null; ip6tables -N MONETAFW 2>/dev/null
hook_up
permissive(){ iptables -F MONETAFW 2>/dev/null; ip6tables -F MONETAFW 2>/dev/null; }
permissive
note "SW5 场景基线: 链挂 OUTPUT 且空 = 全通 (此即'未装拦截'的状态)"

note "SW5-A DROP: 5s 处落入 DROP 形态, 观察已建连接是否被掐"
D5="$OUT/sw5_a.bin"; rm -f "$D5"
curl -sS -o "$D5" --limit-rate 800k -m 20 http://104.20.26.136/ >/dev/null 2>&1 &
CPID=$!
sleep 5
B1=$(cw "$D5")
pass "SW5-A t0: victim(uid=$(id -u)) 长连接已建, 已收 $B1 bytes (通路全)[iptables 空]"
canonical_chain DROP DROP
sleep 3; B2=$(cw "$D5")
sleep 3; B3=$(cw "$D5")
sleep 4; B4=$(cw "$D5")
wait "$CPID" 2>/dev/null; EXITC=$?
echo "  SW5-A 时序: t0=$B1 -> 注DROP -> +3s=$B2 +6s=$B3 +10s=$B4 bytes"
echo "  SW5-A 终态: curl exit=$EXITC(28=黑洞满超时)  conn: $(ste)"
GROW=$((B4-B1))
[ "$GROW" -eq 0 ] && pass "SW5-A 已建连接同被掐死: DROP 规则命中在所有包上 (非只 NEW)" \
                  || fail "SW5-A 注入后仍流动 $GROW bytes (需复核: DROP 竟未命中 established?)"
echo "sw5A t0=$B1 +3s=$B2 +6s=$B3 +10s=$B4 exit=$EXITC conn=$( ste 2>/dev/null; true)" > "$OUT/sw5_a.txt"

note "SW5-B REJECT tcp-reset: 通路恢复->再建->5s 处直接落 REJECT 形态, 计旧连接残留寿命"
permissive
D5B="$OUT/sw5_b.bin"; rm -f "$D5B"
curl -sS -o "$D5B" --limit-rate 800k -m 40 http://104.20.26.136/ >/dev/null 2>&1 &
CPID=$!
sleep 5
B1=$(cw "$D5B")
pass "SW5-B t0: 新长连接 $B1 bytes (链仍空=全通)"
T1J=$(date +%s.%N)
canonical_chain REJECT REJECT
sleep 1; B2=$(cw "$D5B")
wait "$CPID" 2>/dev/null; EXITC=$?; T2J=$(date +%s.%N)
LIFE=$(awk -v a="$T1J" -v b="$T2J" 'BEGIN{printf "%.2f", b-a}')
echo "  SW5-B 时序: 收$B1 -> 落REJECT(@T1) -> +1s=$B2 -> 连接终结 @$LIFE s 后"
echo "  SW5-B 终态: curl exit=$EXITC  conn: $(ste)"
[ "$EXITC" -ne 28 ] && [ "$(awk -v l="$LIFE" 'BEGIN{print (l<=5)?1:0}')" = "1" ] \
  && pass "SW5-B REJECT 对已建连接也是干净快杀 (RST 秒达, 残留≈$LIFE s, exit=$EXITC 非 28)" \
  || note "SW5-B 残留≈$LIFE s exit=$EXITC (观测复核)"
echo "sw5B t0=$B1 +1s=$B2 life=$LIFE exit=$EXITC" > "$OUT/sw5_b.txt"

hr "SW1 iptables owner 豁免 + 首匹配重排"
note "恢复规范链 (DROP 形态): 豁免 ACCEPT(uid=$TESTUID) 在前, 封禁在后 首匹配胜出"
canonical_chain DROP DROP
iptables -S MONETAFW | sed 's/^/  /'; ip6tables -S MONETAFW | sed 's/^/  /'
echo '--- OUTPUT 挂钩 ---'; iptables -S OUTPUT | sed 's/^/  /'
J1=PASS
note "J1'-1 victim(root) 直连 claude.ai --resolve 钉 223.5.5.5 视图真实 IP 160.79.104.10 (铁证: 与 DNS 无关的机械拦截)"
CR=$(env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
  curl --resolve claude.ai:443:160.79.104.10 -m 6 -sS -o /dev/null -w '%{http_code} time=%{time_total}' https://claude.ai 2>/dev/null); RCR=$?
case "$CR" in 200*) fail "J1'-1 => '$CR' 未被拦!!"; J1=FAIL;; *) pass "J1'-1 => '$CR' exit=$RCR (被拦)";; esac
echo "j1 --resolve 160.79.104.10: $CR exit=$RCR" > "$OUT/sw1_j1_resolve.txt"
note "J1'-2 victim 直连 example.org (封禁表内另一域: DNS 陷阱与 hosts 全无关的公共对照面)"
E=$(HT 6 "https://$PROBE_DOMAIN" 2>/dev/null); ER=$?
case "$E" in 200*) fail "J1'-2 '200'!!"; J1=FAIL;; *) pass "J1'-2 => '$E' exit=$ER (被拦)";; esac
note "SW1 豁免判别: uid=$TESTUID 直连 example.org 应 200 (owner ACCEPT 第一匹配)"
SC3=$(sudo -u "$TESTUSER" env -u http_proxy -u https_proxy -u all_proxy -u ALL_PROXY \
  /usr/bin/curl -m 8 -sS -o /dev/null -w '%{http_code}' "https://$PROBE_DOMAIN" 2>/dev/null)
[ "$SC3" = "200" ] && pass "SW1 豁免: sudo -u $TESTUSER 直连 $PROBE_DOMAIN => 200 (PoC-1 T3 机制在 Linux 复现)" \
                 || fail "SW1 豁免: '$SC3' 应通未通"
note "SW1 首匹配反序判别: DROP 排前豁免排后 => 豁免也被拦 (与 macOS pf 后匹配语义相反, 论证豁免必须缀前)"
reverse_chain 104.20.26.136
echo "反序链: $(iptables -S MONETAFW | tr '\n' '|')"
SC4=$(sudo -u "$TESTUSER" env -u http_proxy -u https_proxy -u all_proxy -u ALL_PROXY \
  /usr/bin/curl -m 6 -sS -o /dev/null -w '%{http_code}' "https://$PROBE_DOMAIN" 2>/dev/null)
case "$SC4" in 200) fail "SW1 反序: 豁免 got '200'?? 语义不符"; ;; *) pass "SW1 反序 => '$SC4' (被拦 = 首匹配胜出实证)";; esac
note "复盘规范链: 豁免重排回最前"
canonical_chain DROP DROP
SC5=$(sudo -u "$TESTUSER" env -u http_proxy -u https_proxy -u all_proxy -u ALL_PROXY \
  /usr/bin/curl -m 8 -sS -o /dev/null -w '%{http_code}' "https://$PROBE_DOMAIN" 2>/dev/null)
[ "$SC5" = "200" ] && pass "SW1 规范链复盘: 豁免 => 200" || fail "SW1 规范链复盘: '$SC5'"
echo "exempt_canonical=$SC3 reverse=$SC4 canonical_recheck=$SC5" > "$OUT/sw1_exempt_seq.txt"

hr "SW2 快失败形态: DROP(黑洞满超时) vs REJECT --reject-with tcp-reset(秒断)"
note "victim 直连 example.org, 两形态各 3 连计时 (curl -m6)"
for ONE in 1 2 3; do
  T1J=$(date +%s.%N)
  HR=$(env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
    curl -m 6 -sS -o /dev/null -w 'code=%{http_code} time=%{time_total}' "https://$PROBE_DOMAIN" 2>/dev/null); RC=$?
  T2J=$(date +%s.%N)
  PCT=$(awk -v a="$T1J" -v b="$T2J" 'BEGIN{printf "%.3f", b-a}')
  echo "  DROP #$ONE: 历时$PCT s | $HR | curl exit=$RC (28=满超时黑洞)"
  echo "DROP #$ONE dur=$PCT $HR exit=$RC" >> "$OUT/sw2.txt"
done
canonical_chain REJECT REJECT
note "可感知切换: 整链原子替换为 REJECT 形态"
for TWO in 1 2 3; do
  T1J=$(date +%s.%N)
  HR=$(env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
    curl -m 6 -sS -o /dev/null -w 'code=%{http_code} time=%{time_total}' "https://$PROBE_DOMAIN" 2>/dev/null); RC=$?
  T2J=$(date +%s.%N)
  PCT=$(awk -v a="$T1J" -v b="$T2J" 'BEGIN{printf "%.3f", b-a}')
  echo "  REJECT #$TWO: 历时$PCT s | $HR | curl exit=$RC (56/104=收到 RST 干净失败)"
  echo "REJECT #$TWO dur=$PCT $HR exit=$RC" >> "$OUT/sw2.txt"
done
canonical_chain DROP DROP
note "回 DROP 形态 (后续默认)"

hr "PHASE-B 看门状态机: 杀节点 -> 看门自动注入 -> J2'"
watch_loop() (
  WFAIL=0; WOK=0; WINJ=0
  while :; do
    [ -f "$STOPFILE" ] && exit 0    # P19: 停机文件先行
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
# P17: 显式"定义完再 & 调用"(bash3.2 不能写 `f() (…) &`); bash5 无此坑, 加固形态原样保留以证一致
watch_loop &
WATCH_PID=$!
pass "看门已上线 (pid=$WATCH_PID, interval=${WATCH_INTERVAL}s, failx${FAIL_TO_INJECT}->INJECT, okx${OK_TO_RELEASE}->RELEASE)"
sleep 40
grep -E '^(WATCH|INJECT-REJECT|RELEASE) ' "$LOG" 2>/dev/null | tail -4 | sed 's/^/  /'
NYC=$(grp_now ClaudeExit)
[ "$NYC" = "$NODE_OK_NAME" ] && pass "正常态未误注入: ClaudeExit=$NYC" || fail "正常态异常: ClaudeExit=$NYC"
note "kill-point: REST ClaudeExit -> $NODE_DEAD_NAME ; REST EdgeProbe -> $NODE_DEAD_NAME (同 PoC-3: 双杀令探活失败在列)"
grp_set ClaudeExit "$NODE_DEAD_NAME" >/dev/null
grp_set EdgeProbe  "$NODE_DEAD_NAME" >/dev/null
KILL_TS=$(ts)
note "kill-point $KILL_TS"
INJ_OK=0
for _I in $(seq 1 30); do
  if grep -q '^INJECT-REJECT ' "$LOG" 2>/dev/null; then INJ_OK=1; break; fi
  NOWC=$(grp_now ClaudeExit); [ "$NOWC" = "REJECT" ] && { INJ_OK=1; break; }
  sleep 2
done
INJECT_TS=$(grep '^INJECT-REJECT ' "$LOG" 2>/dev/null | head -1 | awk '{print $2" "$3}')
[ "$INJ_OK" = "1" ] && pass "PHASE-B 看门已注入 (INJECT-REJECT @${INJECT_TS:-?})" || fail "PHASE-B 60s 未见 INJECT-REJECT"
MING=$(curl -x "$MIXED" -m 4 -sS -o /dev/null -w '%{http_code} %{time_total}' https://claude.ai 2>/dev/null)
M_CODE=$(echo "$MING" | awk '{print $1}'); M_EL=$(echo "$MING" | awk '{print $2}')
M_NOW=$(grp_now ClaudeExit)
case "$M_EL" in ''|*[!0-9.eE-]*) M_EL="999";; esac
awk -v c="$M_CODE" -v e="$M_EL" 'BEGIN{printf "  measured: code=%s elapsed=%ss (阈值≤0.2)\n", c, e}'
FAST=$(awk -v e="$M_EL" 'BEGIN{print (e<=0.2)?1:0}')
if [ "$M_NOW" = "REJECT" ] && [ "$FAST" = "1" ]; then
  J2=PASS; pass "J2' 三证齐: REST claude_exit=REJECT + INJECT 日志 + elapsed=${M_EL}s"
else J2=FAIL; fail "J2': now=$M_NOW elapsed=${M_EL}s code=$M_CODE"; fi
sleep 10

hr "PHASE-C 复活 -> 看门自动解除 -> J3'"
grp_set EdgeProbe  "$EDGE_OK_NAME" >/dev/null
grp_set ClaudeExit "$NODE_OK_NAME" >/dev/null
note "复活: EdgeProbe=$EDGE_OK_NAME, ClaudeExit=$NODE_OK_NAME"
REL_OK=0
for _I in $(seq 1 30); do
  if grep -q '^RELEASE ' "$LOG" 2>/dev/null; then REL_OK=1; break; fi
  sleep 2
done
RELEASE_TS=$(grep '^RELEASE ' "$LOG" 2>/dev/null | head -1 | awk '{print $2" "$3}')
NOWC=$(grp_now ClaudeExit)
[ "$REL_OK" = "1" ] && [ "$NOWC" = "$NODE_OK_NAME" ] && pass "PHASE-C 已解除 (RELEASE @${RELEASE_TS:-?})" \
                    || fail "PHASE-C 未恢复: ClaudeExit=$NOWC"
F1=$(iprobe)
[ "$F1" = "200" ] && J3=PASS && pass "J3': $PROBE_DOMAIN 经 7892 => 200 (复通)" || { J3=FAIL; fail "J3': probe=$F1"; }
J3B=$(tail -n 500 "$ENGINE_LOG" 2>/dev/null | grep -c 'match DomainSuffix(example\.org).*EdgeProbe' || true)
note "J3b 观察: 引擎日志 example.org→EdgeProbe 规则命中计数=$J3B (非 PASS 条件, 取证)"

hr "SW5-C 产品口径: 封禁链承载 conntrack-ESTABLISHED 放行 (07-MAPPING 预判复测)"
note "permissive -> 建长连 -> 链首插 conntrack-ESTAB-ACCEPT + owner豁免 + 全量 DROP -> 老连接应不受影响"
permissive
D5C="$OUT/sw5_c.bin"; rm -f "$D5C"
curl -sS -o "$D5C" --limit-rate 800k -m 30 http://104.20.26.136/ >/dev/null 2>&1 &
CPID=$!
sleep 5
B1=$(cw "$D5C")
pass "SW5-C t0: ($B1 bytes 已收)"
iptables -I MONETAFW 1 -m conntrack --ctstate ESTABLISHED -j ACCEPT
canonical_chain_others(){ iptables -A MONETAFW -m owner --uid-owner "$TESTUID" -m tcp -p tcp -m multiport --dports 80,443 -j ACCEPT
  for IP in $BLOCK_V4; do iptables -A MONETAFW -m tcp -p tcp -m multiport --dports 80,443 -d "$IP" -j DROP; done; }
canonical_chain_others
ip6tables -A MONETAFW -m owner --uid-owner "$TESTUID" -m tcp -p tcp -m multiport --dports 80,443 -j ACCEPT
ip6tables -A MONETAFW -m conntrack --ctstate ESTABLISHED -j ACCEPT
for IP in $BLOCK_V6; do ip6tables -A MONETAFW -m tcp -p tcp -m multiport --dports 80,443 -d "$IP" -j DROP; done
echo "SW5-C 生效链: $(iptables -S MONETAFW | tr '\n' '|')"
sleep 5; B2=$(cw "$D5C")
wait "$CPID" 2>/dev/null; EXITC=$?
G2=$((B2-B1))
echo "  SW5-C 时序: t0=$B1 -> 上链 -> +5s=$B2 bytes (增量=$G2; curl exit=$EXITC)"
[ "$G2" -gt 2000000 ] && pass "SW5-C ESTABLISHED 放行实证: conntrack 层放过老连接 + 正常收流 $G2 bytes" \
                     || fail "SW5-C 老连接没流动? (增量仅 $G2, exit=$EXITC, 复核)"
permissive
note "SW5-C 临时变体已撤, 恢复规范吨链 (后续为空, 回滚仍走基线快照)"

hr "VERDICT"
echo "看门事件线:"
grep -E '^(INJECT-REJECT|RELEASE) ' "$LOG" 2>/dev/null | sed 's/^/  /'
echo ""
echo "== PoC-4 判定面 =="
echo "T1' fake-ip: dig @1053 claude.ai => $T1R   => $T1"
echo "T2' 零侵入 : dig example.org => $T2R (真实IP)  => $T2"
echo "J1' iptables 拦直连 (claude --resolve + example.org) => $J1"
echo "SW1 豁免: 正$SC3 / 反序$SC4 / 复盘$SC5   (证据: sw1_exempt_seq.txt + log)"
echo "SW2 对比: DROP vs REJECT 各 3 计时 (证据: sw2.txt)"
echo "J2' 三证: exit=$M_NOW elapsed=${M_EL}s  => $J2"
echo "J3' 复通: probe=$F1  => $J3"
echo "SW5: DROP=掐死已建连接 / REJECT=残留≈${LIFE:-?}s RST 秒杀 / conntrack-est=放行(SW5-C)"
if [ "$T1" = "PASS" ] && [ "$T2" = "PASS" ] && [ "$J1" = "PASS" ] && [ "$J2" = "PASS" ] && [ "$J3" = "PASS" ]; then
  echo ">>> 结论: PoC-4 Linux 等价性验证 【PASS】 — iptables 等价 pf + 引擎同源同配置 + 看门复刻成立"
else
  echo ">>> 结论: 【FAIL/PARTIAL】 — 取 /out/log.txt 复核"
fi
grep -E '^(WATCH|INJECT-REJECT|RELEASE) ' "$LOG" 2>/dev/null > "$OUT/watch.txt"
note "journal 式 WATCH 事件线已另存 $OUT/watch.txt; 证据目录: /out/*"
note "留存资产: /out/{engine-mihomo.log,resolved-ips.txt,watch.txt,sw*.txt,t2_real_ip.txt,...}"

restore
rm -f "$STOPFILE"
exec >/dev/null 2>&1 </dev/null
exit 0
