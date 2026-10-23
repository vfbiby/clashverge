#!/bin/bash
# TUN · Linux 窄通道接管 (netns cgpoc 内跑 mihomo + TUN + 看门)
set -u
. /root/claudeguard-poc6/common.sh

CFG=$BASE/config-tun-ns.yaml
WORK=$BASE/tunwork
ELOG=$WORK/mihomo.log
WLOG=$EVID/tun-watch.txt
CTRL="127.0.0.1:9095"
MIXED="http://127.0.0.1:7892"
STOPFILE=$BASE/stop.tun
WATCH_PID=""

grp_now(){ nsx curl -s -m 3 "$CTRL/proxies/$1" 2>/dev/null | grep -o '"now":"[^"]*"' | cut -d'"' -f4; }
grp_set(){ nsx curl -s -m 3 -X PUT "$CTRL/proxies/$1" -d "{\"name\":\"$2\"}" -o /dev/null -w '%{http_code}' 2>/dev/null; }
iprobe(){ nsx curl -x "$MIXED" -m 8 -sS -o /dev/null -w '%{http_code}' https://example.org 2>/dev/null; }
barew(){ nsx env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
  curl -sS -m "$1" -o /dev/null -w '%{http_code}|%{time_total}' "$2" 2>/dev/null; }


cleanup(){
  touch "$STOPFILE"
  [ -n "${WATCH_PID:-}" ] && kill "$WATCH_PID" 2>/dev/null
  nsx pkill -f "probe-keepalive|tun-watch" 2>/dev/null
  for P in $(pgrep -f "$WORK" 2>/dev/null); do kill "$P" 2>/dev/null; done
  sleep 1
  for P in $(pgrep -f "$WORK" 2>/dev/null); do kill -9 "$P" 2>/dev/null; done
  printf 'nameserver 223.5.5.5\noptions timeout:2 attempts:2\n' > /etc/netns/cgpoc/resolv.conf
  say "engine cleared: $(pgrep -fc "$WORK" 2>/dev/null || echo 0) procs"
}

hr "TUN-0 预检"
guard "tun-start"
mkdir -p "$WORK"
cp -f "$CFG" "$WORK/config.yaml"
"$BASE/mihomo-amd64" -t -d "$WORK" -f "$WORK/config.yaml" 2>&1 | tee "$EVID/tun-precheck.txt"
grep -q "test is successful" "$EVID/tun-precheck.txt" || { say "FAIL: 配置预检失败"; exit 1; }
nsx sh -c 'ss -lntu | grep -E ":(7892|9095|53)\b"' && { say "FAIL: ns 内端口被占"; exit 1; } || say "ns 内 7892/9095/53 均空闲"

hr "TUN-1 启动引擎(ns 内) + 手工窄路由"
nohup ip netns exec cgpoc "$BASE/mihomo-amd64" -d "$WORK" -f "$WORK/config.yaml" >"$ELOG" 2>&1 &
EPID=$!
say "engine pid=$EPID (netns cgpoc)"
TUN=""
for i in $(seq 1 40); do
  TUN=$(nsx ip -br link 2>/dev/null | awk '/cgtun0/{print $1}')
  [ -n "$TUN" ] && break
  sleep 0.5
done
[ -n "$TUN" ] || { say "FAIL: tun 设备未出现"; tail -30 "$ELOG"; cleanup; exit 1; }
say "tun device: $TUN"
nsx ip addr show "$TUN" | tee "$EVID/tun-iface.txt"
nsx ip route add 198.18.0.0/16 dev "$TUN"
say "route: $(nsx ip route | grep 198.18)"
sleep 2
say "ctrl api: $(nsx curl -s -m 3 http://$CTRL/version | head -c 120)"

hr "TUN-2 DNS 接管 (ns 内系统解析器 -> 127.0.0.1:53)"
printf 'nameserver 127.0.0.1\noptions timeout:2 attempts:2\n' > /etc/netns/cgpoc/resolv.conf
sleep 1
CL_IP=$(nsx getent ahostsv4 claude.ai | awk '{print $1}' | head -1)
EX_IP=$(nsx getent ahostsv4 example.org | awk '{print $1}' | head -1)
CL6=$(nsx dig +short AAAA claude.ai @127.0.0.1 | head -3)
say "ns 系统解析 claude.ai  => ${CL_IP:-EMPTY} (期望 198.18.x.x)"
say "ns 系统解析 example.org => ${EX_IP:-EMPTY} (期望真实 IP)"
say "dig claude.ai AAAA     => [$(echo "$CL6" | tr '\n' ' ')] (期望空)"
V6LEAK=$( [ -z "$CL6" ] && echo "NO-V6-LEAK" || echo "V6-LEAK:$CL6" )
hr "TUN-3 白名单外零侵入 (裸 curl, 无代理 env, 经 NAT 出公网)"
E1=$(barew 12 https://example.org); say "bare https://example.org => $E1 (期望 200|...)"
say "引擎日志中 example.org 判定: $(grep -c 'DomainSuffix(example.org)' "$ELOG" || true) 条"

hr "TUN-4 裸进程被域名裁判接管 (claude.ai -> fake-ip -> TUN -> ClaudeExit)"
H0=$(grep -c 'DomainSuffix(claude.ai)' "$ELOG" || true)
C1=$(barew 20 https://claude.ai); say "bare https://claude.ai [ClaudeExit=$(grp_now ClaudeExit)] => $C1 (边缘结果, 非唯一判据)"
C1b=$(barew 20 https://api.anthropic.com); say "bare https://api.anthropic.com => $C1b"
H1=$(grep -c 'DomainSuffix(claude.ai)' "$ELOG" || true)
say "引擎裁判命中: DomainSuffix(claude.ai) $H0 -> $H1"
grep -E 'match .*ClaudeExit' "$ELOG" | tail -5 | tee "$EVID/tun-judge-hits.txt"
[ "$H1" -gt "$H0" ] && TUNJ=PASS || TUNJ=FAIL
say ">>> TUN-4 域名裁判接管 => $TUNJ"
say "REST ClaudeExit -> DIRECT : HTTP $(grp_set ClaudeExit DIRECT)"
C2=$(barew 20 https://claude.ai); say "bare https://claude.ai [DIRECT] => $C2"
say "REST ClaudeExit -> anytls-node : HTTP $(grp_set ClaudeExit anytls-node)"

hr "TUN-5 看门(从 poc3/poc4 移植: 15s 间隔 / 2 连失败注入 / 2 连成功释放)"
cat > "$BASE/tun-watch.sh" <<'EOF'
#!/bin/bash
WLOG=/root/claudeguard-poc6/evidence/tun-watch.txt
STOPFILE=/root/claudeguard-poc6/stop.tun
CTRL=127.0.0.1:9095
MIXED=http://127.0.0.1:7892
INTERVAL=15; FAILN=2; OKN=2
now(){ date '+%F %T'; }
gnow(){ curl -s -m 3 "$CTRL/proxies/$1" 2>/dev/null | grep -o '"now":"[^"]*"' | cut -d'"' -f4; }
gset(){ curl -s -m 3 -X PUT "$CTRL/proxies/$1" -d "{\"name\":\"$2\"}" -o /dev/null; }
probe(){ curl -x "$MIXED" -m 8 -sS -o /dev/null -w '%{http_code}' https://example.org 2>/dev/null; }
WF=0; WO=0; WI=0
while :; do
  [ -f "$STOPFILE" ] && { echo "STOP $(now)" >> "$WLOG"; exit 0; }
  CODE=$(probe); NOW=$(gnow ClaudeExit)
  if [ "$WI" = 0 ]; then
    if [ "$CODE" = "200" ]; then WO=$((WO+1)); WF=0; else WF=$((WF+1)); WO=0; fi
    if [ "$WF" -ge "$FAILN" ]; then
      echo "INJECT-REJECT $(now) probe=$CODE claude_exit=$NOW" >> "$WLOG"
      gset ClaudeExit REJECT; WI=1
    fi
  else
    if [ "$CODE" = "200" ]; then WO=$((WO+1)); else WO=0; fi
    if [ "$WO" -ge "$OKN" ]; then
      echo "RELEASE $(now) probe=$CODE claude_exit=$NOW" >> "$WLOG"
      gset ClaudeExit DIRECT; WI=0
    fi
  fi
  echo "WATCH $(now) probe=$CODE claude_exit=$(gnow ClaudeExit) injected=$WI" >> "$WLOG"
  sleep "$INTERVAL"
done
EOF
chmod +x "$BASE/tun-watch.sh"
rm -f "$WLOG" "$STOPFILE"
nohup ip netns exec cgpoc "$BASE/tun-watch.sh" >/dev/null 2>&1 &
WATCH_PID=$!
sleep 2
say "watchdog pid=$WATCH_PID interval=15s fail_to_inject=2 ok_to_release=2"
# 探针健康门(EdgeProbe=direct)
G=000
for i in $(seq 1 5); do G=$(iprobe); say "  probe gate try$i: $G"; [ "$G" = "200" ] && break; sleep 3; done
[ "$G" = "200" ] || { say "FAIL: 探针不健康, 终止"; cleanup; exit 1; }

hr "TUN-6 J2: 切 dead -> <=45s INJECT-REJECT -> 裸 curl 瞬时失败"
say "REST ClaudeExit -> dead  : HTTP $(grp_set ClaudeExit dead)"
say "REST EdgeProbe  -> dead  : HTTP $(grp_set EdgeProbe dead)"
KTS=$(nowms); say "kill-point $(date '+%F %T')"
INJ=0
for i in $(seq 1 60); do
  if grep -q '^INJECT-REJECT' "$WLOG" 2>/dev/null || [ "$(grp_now ClaudeExit)" = "REJECT" ]; then INJ=1; break; fi
  sleep 1
done
KEL=$(( $(nowms) - KTS ))
say "INJECT=$INJ 注入延迟=${KEL}ms (~$((KEL/1000))s)"
T0=$(nowms); R=$(barew 20 https://claude.ai); T1=$(nowms)
say "REJECT 态裸 curl https://claude.ai => $R  elapsed=$((T1-T0))ms"
REJ_EL=$((T1-T0))
J2=FAIL
[ "$INJ" = "1" ] && [ "$KEL" -le 45000 ] && [ "$REJ_EL" -le 2000 ] && J2=PASS
say ">>> TUN-6 (J2) => $J2"
grep -E '^(INJECT-REJECT|RELEASE|WATCH)' "$WLOG" | tail -8 | tee -a "$EVID/tun-watch-evidence.txt"

hr "TUN-7 J3: 切回 direct -> RELEASE -> 复通"
say "REST EdgeProbe -> direct : HTTP $(grp_set EdgeProbe direct)"
RTS=$(nowms); REL=0
for i in $(seq 1 60); do
  if grep -q '^RELEASE' "$WLOG" 2>/dev/null || [ "$(grp_now ClaudeExit)" = "DIRECT" ]; then REL=1; break; fi
  sleep 1
done
REL_EL=$(( $(nowms) - RTS ))
say "RELEASE=$REL 释放延迟=${REL_EL}ms (~$((REL_EL/1000))s) ClaudeExit=$(grp_now ClaudeExit)"
R2=$(barew 20 https://claude.ai); say "RELEASE 后裸 curl https://claude.ai => $R2"
J3=FAIL
case "$R2" in 000*) ;; *) [ "$REL" = "1" ] && J3=PASS ;; esac
say ">>> TUN-7 (J3) => $J3"
say "RELEASE 后 example.org => $(barew 12 https://example.org)"
grep -E '^(INJECT-REJECT|RELEASE)' "$WLOG" | tee -a "$EVID/tun-watch-evidence.txt"

hr "TUN-8 证据汇总"
say "fake-ip 判定: claude.ai=${CL_IP} example.org=${EX_IP} AAAA泄漏=${V6LEAK}"
say "引擎日志裁判命中(ClaudeExit): $(grep -c 'match .*ClaudeExit' "$ELOG" || true)"
say "engine log tail:"; tail -12 "$ELOG" | tee "$EVID/tun-engine-tail.txt"

hr "TUN-9 拆除"
cleanup
sleep 1
say "ns 内端口: $(nsx ss -lntu | grep -E ':(7892|9095|53)\b' | wc -l) 个仍在监听 (期望 0)"
say "ns 内 tun: $(nsx ip -br link | grep -c cgtun0 || true) (期望 0)"
guard "tun-done"

hr "TUN VERDICT"
say "TUN-4 域名裁判接管      => $TUNJ"
say "TUN-6 J2 注入+瞬时失败  => $J2 (注入 ${KEL}ms / 失败 ${REJ_EL}ms)"
say "TUN-7 J3 释放+复通      => $J3 (释放 ${REL_EL}ms)"
say "P20 AAAA 跨平台复核     => $V6LEAK"
