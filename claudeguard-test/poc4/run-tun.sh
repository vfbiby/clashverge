#!/bin/bash
# PoC-4 (ROADMAP P1a) TUN 窄通道系统级接管实验  --  root 主脚本
# 运行:  cd claudeguard-test/poc4 && sudo ./run-tun.sh
# 语义: 系统 DNS -> 127.0.0.1 (本实验引擎) -> claude 系发 fake-ip(198.18/16)
#       -> 仅 198.18.0.0/16 进 utun (绝不抢默认路由) -> 引擎按规则判域名
# 纪律: 继承 poc3 (P16-P19): 变量大括号 / 无 UTF-8 紧邻 $VAR / 定义与后台调用分离 /
#       停机文件+验证式击杀+孤儿清扫 / 特权日志先取证后删 / 退场斩管道
# 回滚顺序: 停机->DNS 还原优先(用户体感第一)->引擎->路由->端口->网络三验
set -u
cd "$(dirname "$0")" || exit 1

LOG="log.txt"
MIHOMO="/Applications/Clash Verge.app/Contents/MacOS/verge-mihomo"
ENGINE_DIR="$PWD/engine"
ENGINE_CFG="$ENGINE_DIR/config.yaml"
ENGINE_SRC="$PWD/config-tun.yaml"
ENGINE_LOG="$ENGINE_DIR/mihomo.log"

CTRL="127.0.0.1:9095"
MIXED="http://127.0.0.1:7892"
DNS_SERVER="127.0.0.1"
PROBE_URL="https://example.org"
PROBE_DOMAIN="example.org"

SERVICE=""
ORIG_DNS=""
UTUN=""
ROUTE_NET="198.18.0.0/16"
PF_STATE="pf-initial-state.txt"
RULES_BACKUP="rules.before.txt"
PF_WAS_ENABLED=0

STOPFILE="stop.guard"
WATCH_PID=""
WATCH_INTERVAL=15
FAIL_TO_INJECT=2
OK_TO_RELEASE=2

RESTORED=0
hr(){ printf '\n========== %s ==========\n' "$*"; }
pass(){ printf '>>> PASS: %s\n' "$*"; }
fail(){ printf '>>> FAIL: %s\n' "$*"; }
note(){ printf '>>> INFO: %s\n' "$*"; }
ts(){ date '+%F %T'; }

# ---------- log: screen + file ----------
if [ -t 1 ]; then exec > >(tee "$LOG") 2>&1; else exec >> >(tee -a "$LOG") 2>&1; fi

# bare curl (no proxy env)
bare_http(){ env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u ftp_proxy -u FTP_PROXY \
  curl -sS -m "$1" -o /dev/null -w '%{http_code}' "$2" 2>/dev/null; }

# probe via engine mixed port
iprobe(){ curl -x "$MIXED" -m 8 -sS -o /dev/null -w '%{http_code}' "$PROBE_URL" 2>/dev/null; }

# REST helpers
grp_now(){ curl -s -m 3 "$CTRL/proxies/$1" 2>/dev/null | grep -o '"now":"[^"]*"' | cut -d'"' -f4; }
grp_set(){ curl -s -m 3 -X PUT "$CTRL/proxies/$1" -d "{\"name\":\"$2\"}" -o /dev/null -w '%{http_code}' 2>/dev/null; }

# system resolver lookup (mDNSResponder path)
rhost(){ dscacheutil -q host -a name "$1" 2>/dev/null | awk '/ip_address/{print $2}' | head -1; }
rhost6(){ dscacheutil -q host -a name "$1" 2>/dev/null | awk '/ipv6_address/{print $2}' | head -1; }

# ---------- rollback ----------
restore() {
  [ "$RESTORED" = 1 ] && return
  RESTORED=1
  hr "PHASE-D ROLLBACK (trap/normal shared)"

  # 1) watchdog: stopfile + verified kill + orphan sweep (P18)
  touch "$STOPFILE" 2>/dev/null
  if [ -n "${WATCH_PID:-}" ] && kill -0 "$WATCH_PID" 2>/dev/null; then
    pkill -TERM -P "$WATCH_PID" 2>/dev/null
    kill "$WATCH_PID" 2>/dev/null
    _n=0
    while kill -0 "$WATCH_PID" 2>/dev/null; do
      _n=$((_n+1)); [ "$_n" -ge 10 ] && break; sleep 0.3
    done
    kill -0 "$WATCH_PID" 2>/dev/null && kill -9 "$WATCH_PID" 2>/dev/null
  fi
  for Z in $(pgrep -f "bash \./run-tun.sh" 2>/dev/null); do
    [ "$Z" = "$$" ] && continue
    [ "$(ps -o ppid= -p "$Z" 2>/dev/null | tr -d ' ')" = "1" ] && kill -9 "$Z" 2>/dev/null && note "orphan bash $Z killed"
  done
  for T in $(pgrep -f "tee ./log.txt" 2>/dev/null); do
    [ "$(ps -o ppid= -p "$T" 2>/dev/null | tr -d ' ')" = "1" ] && kill -9 "$T" 2>/dev/null && note "orphan tee $T killed"
  done
  note "watchdog stopped"

  # 2) DNS restore FIRST (user-facing impact priority)
  if [ -n "$SERVICE" ]; then
    if [ -z "$ORIG_DNS" ]; then
      networksetup -setdnsservers "$SERVICE" Empty 2>&1 | sed 's/^/  /'
      note "DNS restored to Empty (DHCP) on $SERVICE"
    else
      networksetup -setdnsservers "$SERVICE" $ORIG_DNS 2>&1 | sed 's/^/  /'
      note "DNS restored to [$ORIG_DNS] on $SERVICE"
    fi
    dscacheutil -flushcache 2>/dev/null; killall -HUP mDNSResponder 2>/dev/null
    sleep 1
    NOW_DNS=$(networksetup -getdnsservers "$SERVICE" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')
    case "$NOW_DNS" in
      *"aren't any"*) NOW_DNS="Empty" ;;
    esac
    note "dns now: ${NOW_DNS}"
  else
    note "SERVICE empty (never detected), skip dns restore"
  fi

  # 3a) route delete first (utun disappears with engine -> delete must precede kill)
  if [ -n "$UTUN" ]; then
    route -n delete -net "$ROUTE_NET" 2>&1 | sed 's/^/  /'
    note "route ${ROUTE_NET} deleted"
  fi

  # 3) engine kill + evidence
  for P in $(pgrep -f "$ENGINE_CFG" 2>/dev/null); do kill "$P" 2>/dev/null; done
  sleep 1
  for P in $(pgrep -f "$ENGINE_CFG" 2>/dev/null); do kill -9 "$P" 2>/dev/null; done
  note "engine cleared: left $(pgrep -f "$ENGINE_CFG" 2>/dev/null | wc -l | tr -d ' ')"
  if [ -s "$ENGINE_LOG" ]; then cp -f "$ENGINE_LOG" "engine-mihomo.log" 2>/dev/null && note "engine log archived"; fi
  rm -rf "$ENGINE_DIR"; note "engine dir cleaned"

  # 4.5) pf restore (rdr + enable state, P12)
  if [ -s pf.conf.orig ]; then
    pfctl -f pf.conf.orig 2>&1 | sed 's/^/  /'; note "pf config restored (pf.conf.orig)"
  elif [ -s "$RULES_BACKUP" ]; then
    pfctl -f "$RULES_BACKUP" 2>&1 | sed 's/^/  /'; note "pf rules restored (backup)"
  fi
  if [ "$PF_WAS_ENABLED" = 0 ]; then pfctl -d 2>&1 | sed 's/^/  /'; note "pf disabled (was disabled)"; fi

  # 5) ports free
  LEFT=$(lsof -nP -iTCP:7892 -iTCP:9095 -iUDP:1053 -iTCP:1053 2>/dev/null | grep -E '^(verge|mihomo)' )
  LEFT2=$(lsof -nP -iTCP:7892 -iTCP:9095 2>/dev/null | grep LISTEN)
  if [ -z "$LEFT" ] && [ -z "$LEFT2" ]; then
    pass "ports 7892/9095/1053 free (53 belongs to user Clash, excluded)"
  else
    fail "ports still occupied:"; echo "$LEFT"; echo "$LEFT2"
  fi

  # 6) network tri-verify
  R1=$(bare_http 8 "https://$PROBE_DOMAIN")
  if [ "$R1" = "200" ]; then pass "net1 bare curl $PROBE_DOMAIN => 200"; else fail "net1 bare curl $PROBE_DOMAIN => '$R1'"; fi
  if lsof -nP -iTCP:7890 -sTCP:LISTEN 2>/dev/null | grep -q LISTEN; then
    R2=$(curl -x 127.0.0.1:7890 -m 8 -sS -o /dev/null -w '%{http_code}' "https://$PROBE_DOMAIN" 2>/dev/null)
    if [ "$R2" = "200" ]; then pass "net2 user proxy 7890 => 200"; else fail "net2 user proxy 7890 => '$R2'"; fi
  else
    note "net2: 7890 not listening, skipped"
  fi
  R3=$(rhost "$PROBE_DOMAIN")
  case "$R3" in
    "") fail "net3 system resolver empty after restore" ;;
    198.18.*) note "net3 resolver => $R3 (fake-ip; user Clash DNS behavior, accepted)" ;;
    *) pass "net3 system resolver $PROBE_DOMAIN => $R3 (real)" ;;
  esac
  NDNS=$(networksetup -getdnsservers "$SERVICE" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')
  case "$NDNS" in *"aren't any"*) NDNS="Empty" ;; esac
  if [ -z "$ORIG_DNS" ]; then
    [ "$NDNS" = "Empty" ] && pass "net5 dns restored (Empty/DHCP)" || fail "net5 dns mismatch: '$NDNS'"
  else
    [ "$NDNS" = "$ORIG_DNS" ] && pass "net5 dns restored" || fail "net5 dns mismatch: '$NDNS' vs '$ORIG_DNS'"
  fi
  R4=$(route -n get 198.18.254.254 2>/dev/null | awk '/interface/{print $2}')
  [ "$R4" = "$UTUN" ] && fail "net4 route still via $UTUN" || pass "net4 198.18/16 route restored (iface=${R4:-none})"
  hr "ROLLBACK done $(ts)"
}
trap restore EXIT
trap 'trap - EXIT; restore; exit 130' INT
trap 'trap - EXIT; restore; exit 143' TERM

hr "PHASE-0 preflight"
echo "time: $(ts)  os: $(sw_vers -productVersion)  user: $(whoami) (uid $(id -u))"
[ "$(id -u)" = "0" ] || { fail "must run as root: sudo ./run-tun.sh"; exit 1; }
[ -x "$MIHOMO" ] || { fail "mihomo not executable: $MIHOMO"; exit 1; }
[ -f "$ENGINE_SRC" ] || { fail "config missing: $ENGINE_SRC"; exit 1; }
rm -f "$STOPFILE" 2>/dev/null

# orphan sweep (P18)
for Z in $(pgrep -f "bash \./run-tun.sh" 2>/dev/null); do
  [ "$Z" = "$$" ] && continue
  [ "$(ps -o ppid= -p "$Z" 2>/dev/null | tr -d ' ')" = "1" ] && kill -9 "$Z" 2>/dev/null && note "orphan bash $Z killed"
done
for T in $(pgrep -f "tee ./log.txt" 2>/dev/null); do
  [ "$(ps -o ppid= -p "$T" 2>/dev/null | tr -d ' ')" = "1" ] && kill -9 "$T" 2>/dev/null && note "orphan tee $T killed"
done

# ports free? (53 requires root-owned free port; utf8 note: ascii strings)
for P in 7892 9095; do
  O=$(lsof -nP -iTCP:$P -sTCP:LISTEN 2>/dev/null | tail -n +2)
  [ -n "$O" ] && { fail "port $P occupied: $O"; exit 1; }
done
O1053=$(lsof -nP -iUDP:1053 2>/dev/null | tail -n +2)
[ -n "$O1053" ] && { fail "udp:1053 occupied: $O1053"; exit 1; }
O1053t=$(lsof -nP -iTCP:1053 2>/dev/null | tail -n +2)
[ -n "$O1053t" ] && { fail "tcp:1053 occupied: $O1053t"; exit 1; }
note "ports free: 7892/9095/1053(udp+tcp)"

# service detection: default iface -> hardware port name
IFACE=$(route get default 2>/dev/null | awk '/interface/{print $2; exit}')
[ -n "$IFACE" ] || { fail "cannot detect default interface"; exit 1; }
SERVICE=$(networksetup -listallhardwareports 2>/dev/null | awk -v ifc="$IFACE" '
  /^Hardware Port: /{s=substr($0,16)}
  /^Device: /{if ($2==ifc) print s}' | head -1)
[ -n "$SERVICE" ] || { fail "cannot map $IFACE to a network service"; exit 1; }
note "default iface=$IFACE service=$SERVICE"
echo "$SERVICE" > service-name.txt

# DNS forensics
RAW_DNS=$(networksetup -getdnsservers "$SERVICE" 2>/dev/null)
{ echo "# $(ts) service=$SERVICE"; echo "$RAW_DNS"; } > dns-before.txt
case "$RAW_DNS" in
  *"aren't any"*) ORIG_DNS="" ;;
  *) ORIG_DNS=$(echo "$RAW_DNS" | tr '\n' ' ' | sed 's/ $//') ;;
esac
note "original dns: [${ORIG_DNS:-EMPTY/DHCP}]"
scutil --dns 2>/dev/null > scutil-dns-before.txt
note "scutil dns snapshot saved"

# route/utun pre-state
route -n get 198.18.254.254 2>/dev/null > route-19818-before.txt
IFC0=$(route -n get 198.18.254.254 2>/dev/null | awk '/interface/{print $2}')
note "198.18.254.254 pre-route iface=${IFC0:-none}"
case "$IFC0" in utun*) fail "198.18/16 already routed to $IFC0, abort"; exit 1 ;; esac
ifconfig -l > utun-before.txt

hr "PHASE-A engine start (root, tun enabled) + narrow route"
rm -rf "$ENGINE_DIR"; mkdir -p "$ENGINE_DIR"
cp "$ENGINE_SRC" "$ENGINE_CFG"
"$MIHOMO" -d "$ENGINE_DIR" -f "$ENGINE_CFG" >> "$ENGINE_LOG" 2>&1 &
UP=0
for I in $(seq 1 30); do
  lsof -nP -iTCP:7892 -sTCP:LISTEN 2>/dev/null | grep -q LISTEN && { UP=1; break; }
  sleep 0.5
done
[ "$UP" = "1" ] || { fail "engine failed to listen 7892"; tail -8 "$ENGINE_LOG" 2>/dev/null; exit 1; }
pass "engine listening (root)"

# find NEW utun device
NEWU=""
for I in $(seq 1 20); do
  for U in $(ifconfig -l 2>/dev/null); do
    case "$U" in utun*) grep -qw "$U" utun-before.txt || NEWU="$U" ;; esac
  done
  [ -n "$NEWU" ] && break
  sleep 0.5
done
[ -n "$NEWU" ] || { fail "no new utun device appeared"; tail -10 "$ENGINE_LOG"; exit 1; }
UTUN="$NEWU"
pass "tun device: $UTUN"
IFC=$(ifconfig "$UTUN" 2>/dev/null | awk '/inet /{print $2}')
note "tun iface address: ${IFC:-none}"

route -n add -net "$ROUTE_NET" -interface "$UTUN" 2>&1 | sed 's/^/  /'
RIF=$(route -n get 198.18.254.254 2>/dev/null | awk '/interface/{print $2}')
[ "$RIF" = "$UTUN" ] && pass "route ${ROUTE_NET} -> $UTUN (verified)" || { fail "route verify failed (iface=$RIF)"; exit 1; }

# engine DNS sanity (before touching system dns)
echo "--- engine dns sanity ---"
D1=$(dig +short @127.0.0.1 -p 1053 claude.ai A | head -1)
D2=$(dig +short @127.0.0.1 -p 1053 "$PROBE_DOMAIN" A | head -1)
echo "engine-dns claude.ai=$D1  $PROBE_DOMAIN=$D2"
case "$D1" in
  198.18.*) pass "engine dns fake-ip ok" ;;
  *) fail "engine dns claude.ai => '$D1' (not fake-ip)"; exit 1 ;;
esac
case "$D2" in
  198.18.*) fail "engine dns $PROBE_DOMAIN => fake-ip (whitelist broken!)"; exit 1 ;;
  "") fail "engine dns $PROBE_DOMAIN empty"; exit 1 ;;
  *) pass "engine dns whitelist ok (real ip)" ;;
esac

hr "PHASE-B-0 pf rdr setup (53 -> 1053; reason: user Clash occupies *:53)"
pfctl -si 2>/dev/null | grep -qi 'Status: Enabled' && PF_WAS_ENABLED=1
echo "PF_WAS_ENABLED=$PF_WAS_ENABLED" > "$PF_STATE"
cp /etc/pf.conf pf.conf.orig 2>/dev/null && note "pf.conf backed up"
pfctl -s rules > "$RULES_BACKUP" 2>/dev/null
if [ "$PF_WAS_ENABLED" = 0 ]; then
  pfctl -E 2>&1 | sed 's/^/  /' || { fail "pfctl -E failed"; exit 1; }
fi
S=$(bare_http 8 "https://$PROBE_DOMAIN")
[ "$S" = "200" ] || { fail "post-pf sanity $PROBE_DOMAIN => '$S'"; exit 1; }
# pf 语法顺序: normalization(scrub) -> translation(rdr) -> filtering(anchor/rules)
SCRL=$(grep -c '^scrub' "$RULES_BACKUP" 2>/dev/null)
[ -z "$SCRL" ] && SCRL=0
{
  if [ "$SCRL" -gt 0 ]; then head -n "$SCRL" "$RULES_BACKUP"; fi
  echo "rdr pass on lo0 inet proto udp from any to 127.0.0.1 port 53 -> 127.0.0.1 port 1053"
  echo "rdr pass on lo0 inet proto tcp from any to 127.0.0.1 port 53 -> 127.0.0.1 port 1053"
  tail -n +$((SCRL+1)) "$RULES_BACKUP"
} > rules.rdr
pfctl -nf rules.rdr 2>&1 | sed 's/^/  /' || { fail "pf syntax check failed"; exit 1; }
pfctl -f rules.rdr 2>&1 | sed 's/^/  /' || { fail "pfctl load rdr failed"; exit 1; }
pfctl -s nat > rules.during.nat 2>/dev/null
grep -q "port 1053" rules.during.nat && pass "rdr loaded (udp+tcp 53 -> 1053)" || { fail "rdr not present in nat table"; exit 1; }

hr "PHASE-B switch system DNS -> $DNS_SERVER (the only user-visible change)"
networksetup -setdnsservers "$SERVICE" "$DNS_SERVER" 2>&1 | sed 's/^/  /'
dscacheutil -flushcache 2>/dev/null; killall -HUP mDNSResponder 2>/dev/null
OK=0
for I in $(seq 1 10); do
  A=$(rhost claude.ai); B=$(rhost "$PROBE_DOMAIN"); C=$(rhost canary.monetafw.internal)
  echo "  resolver try$I: claude.ai=$A $PROBE_DOMAIN=$B canary=$C"
  case "$A" in 198.18.*) case "$B" in ""|198.18.*) : ;; *) [ "$C" = "198.18.254.251" ] && OK=1 ;; esac ;; esac
  [ "$OK" = "1" ] && break
  sleep 1
done
[ "$OK" = "1" ] || { fail "resolver did not converge or canary mismatch (engine not answering?)"; exit 1; }
pass "system dns now via OUR engine (canary hit, fake-ip for claude, real for others)"

# ---------- watchdog (15s loop; stopfile; def then call = P16) ----------
watch_loop() (
  WFAIL=0; WOK=0; WINJ=0
  while :; do
    [ -f "$STOPFILE" ] && exit 0
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
        grp_set ClaudeExit anytls-node >/dev/null
        WINJ=0
      fi
    fi
    printf 'WATCH %s probe=%s claude_exit=%s injected=%d\n' "$(ts)" "$CODE" "$(grp_now ClaudeExit)" "$WINJ"
    sleep "$WATCH_INTERVAL"
  done
)
watch_loop &
WATCH_PID=$!
pass "watchdog up (pid=$WATCH_PID, interval=${WATCH_INTERVAL}s)"

# health gate on probe path (engine relay-independent via direct)
GATE=0
for I in $(seq 1 5); do
  G=$(iprobe); echo "  gate try$I: probe=$G"
  [ "$G" = "200" ] && { GATE=1; break; }
  sleep 7
done
[ "$GATE" = "1" ] || { fail "probe path unhealthy, abort+rollback"; exit 1; }
pass "health gate ok"

hr "PHASE-A1 bare process captured (J1)"
CL_IP=$(rhost claude.ai)
note "bare curl claude.ai resolves to $CL_IP (fake-ip expected)"
CB=$(bare_http 10 https://claude.ai); note "bare curl claude.ai => '$CB' (edge result, not a PASS criterion)"
HIT=$(grep -c 'match .*ClaudeExit' "$ENGINE_LOG" 2>/dev/null)
note "engine judge hits: $HIT"
[ "${HIT:-0}" -ge 1 ] && J1A=PASS || J1A=FAIL
E1=$(bare_http 10 "https://$PROBE_DOMAIN")
[ "$E1" = "200" ] && J1B=PASS || J1B=FAIL
note "bare curl $PROBE_DOMAIN => '$E1'"
E2=$(bare_http 10 "https://example.com")
[ "$E2" = "200" ] && J1C=PASS || J1C=FAIL
note "bare curl example.com => '$E2'"
V6=$(rhost6 claude.ai)
note "claude.ai AAAA => [${V6:-empty}] (empty=no v6 leak path)"
if [ "$J1A" = "PASS" ] && [ "$J1B" = "PASS" ] && [ "$J1C" = "PASS" ]; then J1=PASS; pass "J1: bare process fully governed by domain judge"; else J1=FAIL; fail "J1: judge=$J1A probe=$J1B com=$J1C"; fi

hr "PHASE-B kill exit -> inject REJECT (J2)"
note "REST ClaudeExit -> dead : HTTP $(grp_set ClaudeExit dead)"
note "REST EdgeProbe  -> dead : HTTP $(grp_set EdgeProbe dead)"
KILL_TS=$(ts); note "kill-point $KILL_TS"
INJ=0
for I in $(seq 1 30); do
  grep -q '^INJECT-REJECT ' "$LOG" 2>/dev/null && { INJ=1; break; }
  [ "$(grp_now ClaudeExit)" = "REJECT" ] && { INJ=1; break; }
  sleep 2
done
INJ_TS=$(grep '^INJECT-REJECT ' "$LOG" 2>/dev/null | head -1 | awk '{print $2" "$3}')
[ "$INJ" = "1" ] && pass "watchdog injected REJECT (@${INJ_TS:-?})" || fail "no INJECT within 60s"
T0=$(date +%s)
CB2=$(bare_http 5 https://claude.ai)
T1=$(date +%s)
EL=$((T1-T0))
NOWX=$(grp_now ClaudeExit)
M_EL=$(printf '%s.%s' "$EL" "000")
note "bare curl claude.ai in REJECT state => code='$CB2' elapsed=${M_EL}s rest=$NOWX"
if [ "$INJ" = "1" ] && [ "$NOWX" = "REJECT" ] && [ "$EL" -le 1 ]; then J2=PASS; pass "J2: REJECT injection + fast cut verified"; else J2=FAIL; fail "J2: inj=$INJ rest=$NOWX elapsed=${M_EL}s"; fi

hr "PHASE-C revive -> release (J3)"
note "REST EdgeProbe -> direct : HTTP $(grp_set EdgeProbe direct)"
REL=0
for I in $(seq 1 30); do
  grep -q '^RELEASE ' "$LOG" 2>/dev/null && { REL=1; break; }
  [ "$(grp_now ClaudeExit)" = "anytls-node" ] && { REL=1; break; }
  sleep 2
done
REL_TS=$(grep '^RELEASE ' "$LOG" 2>/dev/null | head -1 | awk '{print $2" "$3}')
NOWY=$(grp_now ClaudeExit)
E3=$(bare_http 10 "https://$PROBE_DOMAIN")
if [ "$REL" = "1" ] && [ "$NOWY" = "anytls-node" ] && [ "$E3" = "200" ]; then J3=PASS; pass "J3: released (@${REL_TS:-?}), probe 200"; else J3=FAIL; fail "J3: rel=$REL rest=$NOWY probe='$E3'"; fi

hr "VERDICT (rollback follows via trap)"
echo "watchdog events:"; grep -E '^(INJECT-REJECT|RELEASE) ' "$LOG" 2>/dev/null | sed 's/^/  /'
echo ""
echo "J1 bare process judged/zero-intrusion        => $J1"
echo "J2 reject injection + fast cut               => $J2"
echo "J3 revive + release                          => $J3"
if [ "$J1" = "PASS" ] && [ "$J2" = "PASS" ] && [ "$J3" = "PASS" ]; then
  echo ">>> RESULT: PoC-4 TUN takeover [PASS]"
else
  echo ">>> RESULT: [FAIL/PARTIAL] hand log.txt back for review"
fi
note "artifacts: log.txt / engine-mihomo.log / dns-before.txt / scutil-dns-before.txt / route-19818-before.txt"

restore
rm -f "$STOPFILE"
exec >/dev/null 2>&1 </dev/null
exit 0
