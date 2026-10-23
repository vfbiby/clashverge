#!/bin/bash
# ClaudeGuard v0.2 privileged helper (root, launchd)
# 职责: 武装时 ①起内置引擎(127.0.0.1:7893) ②接管系统 HTTP/HTTPS 代理 ③pf 封直连
#       解除时 ①还原系统代理 ②杀引擎 ③恢复 pf
# 协议(control): mode=armed|disarmed / ips4= / ips6= / domains=a b c / upstream=7890|none
set -u
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

DIR=/tmp/claudeguard
PIDF="$DIR/daemon.pid"
CONTROL="$DIR/control"
STATUS="$DIR/status"
STOP="$DIR/stop"
LOG="$DIR/guardd.log"
RULESF="$DIR/rules.applied"
PFS="$DIR/pf.state"
PROXYB="$DIR/proxy.before"

ENGINE_BIN="/Applications/Clash Verge.app/Contents/MacOS/verge-mihomo"
ENGINE_DIR="$DIR/engine"
ENGINE_CFG="$ENGINE_DIR/config.yaml"
ENGINE_LOG="$DIR/engine.log"
ENGINE_PLIST="/Library/LaunchDaemons/com.claudeguard.engine.plist"
ENGINE_LABEL="com.claudeguard.engine"
ENGINE_PORT=7893

APPLIED=0
LAST_SIG=""
SVC=""

log(){ printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

detect_service(){
  local ifc
  ifc=$(route get default 2>/dev/null | awk '/interface/{print $2; exit}')
  SVC=$(networksetup -listallhardwareports 2>/dev/null | awk -v i="$ifc" '
    /^Hardware Port: /{s=substr($0,16)}
    /^Device: /{if ($2==i) print s}' | head -1)
  log "service detected: iface=$ifc svc=$SVC"
}

get_proxy_field(){ # $1=web|secure $2=field(Enabled|Server|Port)
  networksetup -get${1}proxy "$SVC" 2>/dev/null | awk -F': ' -v k="$2" '$1==k{print $2}' | head -1
}

capture_proxy(){
  [ -n "$SVC" ] || detect_service
  [ -s "$PROXYB" ] && return 0
  {
    echo "svc=$SVC"
    echo "web_enabled=$(get_proxy_field web Enabled)"
    echo "web_server=$(get_proxy_field web Server)"
    echo "web_port=$(get_proxy_field web Port)"
    echo "secure_enabled=$(get_proxy_field secure Enabled)"
    echo "secure_server=$(get_proxy_field secure Server)"
    echo "secure_port=$(get_proxy_field secure Port)"
  } > "$PROXYB"
  log "proxy state captured: $(tr '\n' ' ' < "$PROXYB")"
}

set_sys_proxy(){
  networksetup -setwebproxy "$SVC" 127.0.0.1 "$ENGINE_PORT" 2>&1 | sed 's/^/  /'
  networksetup -setsecurewebproxy "$SVC" 127.0.0.1 "$ENGINE_PORT" 2>&1 | sed 's/^/  /'
  log "system proxy -> 127.0.0.1:$ENGINE_PORT"
}

restore_sys_proxy(){
  [ -s "$PROXYB" ] || return 0
  local svc we ws wp se ss sp
  svc=$(sed -n 's/^svc=//p' "$PROXYB" | head -1)
  [ -n "$svc" ] || return 0
  we=$(sed -n 's/^web_enabled=//p' "$PROXYB" | head -1)
  ws=$(sed -n 's/^web_server=//p' "$PROXYB" | head -1)
  wp=$(sed -n 's/^web_port=//p' "$PROXYB" | head -1)
  se=$(sed -n 's/^secure_enabled=//p' "$PROXYB" | head -1)
  ss=$(sed -n 's/^secure_server=//p' "$PROXYB" | head -1)
  sp=$(sed -n 's/^secure_port=//p' "$PROXYB" | head -1)
  if [ "$we" = "Yes" ] && [ -n "$ws" ] && [ -n "$wp" ]; then
    networksetup -setwebproxy "$svc" "$ws" "$wp" >/dev/null 2>&1; log "web proxy restored -> $ws:$wp"
  else
    networksetup -setwebproxystate "$svc" off >/dev/null 2>&1; log "web proxy restored -> off"
  fi
  if [ "$se" = "Yes" ] && [ -n "$ss" ] && [ -n "$sp" ]; then
    networksetup -setsecurewebproxy "$svc" "$ss" "$sp" >/dev/null 2>&1; log "secure proxy restored -> $ss:$sp"
  else
    networksetup -setsecurewebproxystate "$svc" off >/dev/null 2>&1; log "secure proxy restored -> off"
  fi
}

write_engine_cfg(){ # $1=upstream_port_or_none  $2=domains(space sep)
  local up="$1" doms="$2" r
  mkdir -p "$ENGINE_DIR"
  {
    echo "mixed-port: $ENGINE_PORT"
    echo "allow-lan: false"
    echo "bind-address: '127.0.0.1'"
    echo "mode: rule"
    echo "log-level: warning"
    if [ "$up" != "none" ]; then
      echo "proxies:"
      echo "  - { name: upstream, type: http, server: 127.0.0.1, port: $up }"
      echo "proxy-groups:"
      echo "  - { name: Egress, type: select, proxies: [upstream, DIRECT] }"
    fi
    echo "rules:"
    for r in $doms; do
      echo "  - 'DOMAIN-SUFFIX,$r,REJECT'"
    done
    if [ "$up" != "none" ]; then echo "  - 'MATCH,Egress'"; else echo "  - 'MATCH,DIRECT'"; fi
  } > "$ENGINE_CFG"
}

engine_alive(){
  launchctl print "system/$ENGINE_LABEL" >/dev/null 2>&1 ||
    return 1
  lsof -nP -iTCP:$ENGINE_PORT -sTCP:LISTEN >/dev/null 2>&1
}

engine_up(){ # $1=upstream  $2=domains
  if engine_alive; then return 0; fi
  [ -x "$ENGINE_BIN" ] || { log "engine binary missing: $ENGINE_BIN"; return 1; }
  [ -f "$ENGINE_PLIST" ] || { log "engine plist missing: $ENGINE_PLIST"; return 1; }
  if lsof -nP -iTCP:$ENGINE_PORT -sTCP:LISTEN >/dev/null 2>&1; then
    log "port $ENGINE_PORT occupied before bootstrap -> abort arm"
    return 1
  fi
  write_engine_cfg "$1" "$2"
  launchctl bootout "system/$ENGINE_LABEL" >/dev/null 2>&1
  launchctl bootstrap system "$ENGINE_PLIST" >/dev/null 2>&1
  local i=0
  while [ "$i" -lt 30 ]; do
    if engine_alive; then
      local pid; pid=$(launchctl print "system/$ENGINE_LABEL" 2>/dev/null | awk '/pid = /{print $3; exit}')
      log "engine up (launchd job $ENGINE_LABEL pid=${pid:-?}, port=$ENGINE_PORT, upstream=$1)"
      return 0
    fi
    sleep 0.5; i=$((i+1))
  done
  log "engine FAILED to listen on $ENGINE_PORT"
  tail -3 "$ENGINE_LOG" 2>/dev/null | sed 's/^/  ENG: /' >> "$LOG"
  engine_down
  return 1
}

engine_down(){
  launchctl bootout "system/$ENGINE_LABEL" >/dev/null 2>&1
  local i=0
  while [ "$i" -lt 10 ]; do
    lsof -nP -iTCP:$ENGINE_PORT -sTCP:LISTEN >/dev/null 2>&1 || break
    sleep 0.5; i=$((i+1))
  done
  if lsof -nP -iTCP:$ENGINE_PORT -sTCP:LISTEN >/dev/null 2>&1; then
    launchctl kill SIGKILL "system/$ENGINE_LABEL" >/dev/null 2>&1
    sleep 1
  fi
  log "engine stopped (job unloaded, port released)"
}

restore_pf(){
  [ "$APPLIED" = "1" ] || return 0
  pfctl -f /etc/pf.conf >/dev/null 2>&1 && log "pf restored (/etc/pf.conf)"
  if [ -f "$PFS" ] && grep -q 'PF_WAS_ENABLED=0' "$PFS" 2>/dev/null; then
    pfctl -d >/dev/null 2>&1 && log "pf disabled (was disabled before arming)"
  fi
  APPLIED=0
}

apply_pf(){ # $1=ips4 $2=ips6
  if [ "$APPLIED" = "0" ]; then
    if [ ! -f "$PFS" ]; then
      if pfctl -si 2>/dev/null | grep -qi 'Status: Enabled'; then
        echo "PF_WAS_ENABLED=1" > "$PFS"
      else
        echo "PF_WAS_ENABLED=0" > "$PFS"
      fi
    fi
    pfctl -E >/dev/null 2>&1
  fi
  {
    cat /etc/pf.conf
    [ -n "$1" ] && echo "block drop out inet proto tcp to { $1 }"
    [ -n "$1" ] && echo "block drop out inet proto udp to { $1 }"
    [ -n "$2" ] && echo "block drop out inet6 proto tcp to { $2 }"
    [ -n "$2" ] && echo "block drop out inet6 proto udp to { $2 }"
  } > "$RULESF"
  if pfctl -f "$RULESF" >/dev/null 2>&1; then
    APPLIED=1
    log "pf applied: v4=[$1] v6=[$2]"
    return 0
  fi
  log "pfctl -f FAILED"
  return 1
}

write_status(){
  local mode="$1" eng="$2" px="$3"
  echo "state=$mode applied=$APPLIED engine=$eng sysproxy=$px ts=$(date '+%F %T')" > "$STATUS"
}

full_arm(){ # $1=ips4 $2=ips6 $3=upstream $4=domains
  capture_proxy
  if ! engine_up "$3" "$4"; then
    log "ARM ABORTED: engine failed; leaving system untouched"
    write_status error stopped off
    return 1
  fi
  set_sys_proxy
  if ! apply_pf "$1" "$2"; then
    restore_sys_proxy
    engine_down
    write_status error stopped off
    return 1
  fi
  write_status armed running on
}

full_disarm(){
  restore_sys_proxy
  engine_down
  restore_pf
  write_status disarmed stopped off
}

cleanup(){
  log "daemon stopping"
  full_disarm
  rm -f "$PIDF" "$STOP"
  log "daemon stopped"
  exit 0
}

case "${1:-}" in
start)
  mkdir -p "$DIR"; chmod 777 "$DIR" 2>/dev/null
  if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null; then echo "already-running"; exit 0; fi
  nohup "$0" run >> "$LOG" 2>&1 &
  echo $! > "$PIDF"; echo "started"; exit 0 ;;
stop)
  touch "$STOP" 2>/dev/null
  if [ -f "$PIDF" ]; then
    P=$(cat "$PIDF" 2>/dev/null)
    for _ in $(seq 1 20); do kill -0 "$P" 2>/dev/null || break; sleep 0.2; done
    kill -9 "$P" 2>/dev/null
  fi
  # 兜底
  restore_sys_proxy 2>/dev/null
  engine_down 2>/dev/null
  if [ -s "$RULESF" ]; then
    pfctl -f /etc/pf.conf >/dev/null 2>&1
    if [ -f "$PFS" ] && grep -q 'PF_WAS_ENABLED=0' "$PFS" 2>/dev/null; then pfctl -d >/dev/null 2>&1; fi
    rm -f "$RULESF"
  fi
  rm -f "$PIDF" "$STOP"
  write_status disarmed stopped off
  echo "stopped"; exit 0 ;;
run)
  mkdir -p "$DIR"
  echo $$ > "$PIDF"
  trap cleanup TERM INT HUP
  rm -f "$STOP"
  log "daemon started (pid=$$, launchd-managed, v0.2)"
  write_status disarmed stopped off
  TICK=0
  while :; do
    [ -f "$STOP" ] && cleanup
    MODE="disarmed"; IPS4=""; IPS6=""; DOMS="claude.ai claude.com clau.de anthropic.com claudeusercontent.com"; UP="none"
    if [ -f "$CONTROL" ]; then
      MODE=$(sed -n 's/^mode=//p' "$CONTROL" | head -1)
      IPS4=$(sed -n 's/^ips4=//p' "$CONTROL" | head -1)
      IPS6=$(sed -n 's/^ips6=//p' "$CONTROL" | head -1)
      D=$(sed -n 's/^domains=//p' "$CONTROL" | head -1); [ -n "$D" ] && DOMS="$D"
      UP=$(sed -n 's/^upstream=//p' "$CONTROL" | head -1); [ -z "$UP" ] && UP="none"
    fi
    SIG="$MODE|$IPS4|$IPS6|$UP|$DOMS"
    if [ "$MODE" = "armed" ] && [ -n "$IPS4$IPS6" ]; then
      if [ "$APPLIED" = "0" ] || [ "$SIG" != "$LAST_SIG" ]; then
        if [ "$APPLIED" = "1" ]; then full_disarm >/dev/null 2>&1; fi
        full_arm "$IPS4" "$IPS6" "$UP" "$DOMS"
        LAST_SIG="$SIG"
        TICK=0
      else
        # 运行中健康巡检: 引擎挂了 -> 尝试重启; 失败则退化为直连代理 (不把用户网络打挂)
        if ! engine_alive; then
          log "engine unhealthy while armed -> restart"
          if engine_up "$UP" "$DOMS"; then set_sys_proxy; write_status armed running on; else restore_sys_proxy; write_status degraded stopped off; fi
        fi
      fi
    else
      if [ "$APPLIED" = "1" ]; then
        full_disarm
        LAST_SIG=""
      fi
    fi
    if [ "$MODE" = "armed" ] && [ "$APPLIED" = "1" ] && [ $((TICK % 5)) -eq 0 ]; then
      cur_s=$(networksetup -getwebproxy "$SVC" 2>/dev/null | awk -F': ' '$1=="Server"{print $2; exit}')
      cur_p=$(networksetup -getwebproxy "$SVC" 2>/dev/null | awk -F': ' '$1=="Port"{print $2; exit}')
      if [ "$cur_s" != "127.0.0.1" ] || [ "$cur_p" != "$ENGINE_PORT" ]; then
        log "system proxy drifted (${cur_s:-?}:${cur_p:-?}) -> re-takeover"
        set_sys_proxy
      fi
    fi
    TICK=$((TICK+1))
    if [ "$MODE" = "armed" ] && [ "$APPLIED" = "1" ] && [ "$TICK" -ge 20 ]; then
      if ! pfctl -s rules 2>/dev/null | grep -q "block drop out inet proto tcp"; then
        log "pf rules missing -> reapply"
        APPLIED=0; LAST_SIG=""
      fi
      TICK=0
    fi
    sleep 1
  done
  ;;
*)
  echo "usage: $0 start|stop|run"; exit 1 ;;
esac
