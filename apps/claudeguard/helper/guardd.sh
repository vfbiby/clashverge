#!/bin/bash
# ClaudeGuard privileged helper (root) — pf enforcement daemon
# 协议: 应用写 /tmp/claudeguard/control, 本脚本读取并执行; 状态写 status
#   control: mode=armed|disarmed / ips4="1.2.3.4 ..." / ips6="::1 ..."
# 纪律: 备份后变更 / 异常恢复 / 停止文件 / 幂等 / 日志落盘
set -u

DIR=/tmp/claudeguard
PIDF="$DIR/daemon.pid"
CONTROL="$DIR/control"
STATUS="$DIR/status"
STOP="$DIR/stop"
LOG="$DIR/guardd.log"
BASE="$DIR/rules.base"
RULESF="$DIR/rules.applied"
PFS="$DIR/pf.state"

APPLIED=0
ARMED=0
PF_WAS_ENABLED=0
LAST_SIG=""

log(){ printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

restore_pf(){
  [ "$APPLIED" = "1" ] || return 0
  if [ -s "$BASE" ]; then
    pfctl -f "$BASE" >/dev/null 2>&1 && log "pf restored from base snapshot"
  else
    pfctl -f /etc/pf.conf >/dev/null 2>&1 && log "pf restored from /etc/pf.conf"
  fi
  if [ "$PF_WAS_ENABLED" = "0" ]; then
    pfctl -d >/dev/null 2>&1 && log "pf disabled (was disabled)"
  fi
  APPLIED=0
  echo "state=disarmed applied=0 ts=$(date '+%F %T')" > "$STATUS"
}

apply_pf(){
  # args: "<ips4>" "<ips6>"
  local ips4="$1" ips6="$2"
  if [ "$APPLIED" = "0" ]; then
    pfctl -si 2>/dev/null | grep -qi 'Status: Enabled' && PF_WAS_ENABLED=1 || PF_WAS_ENABLED=0
    echo "PF_WAS_ENABLED=$PF_WAS_ENABLED" > "$PFS"
    pfctl -s rules > "$BASE" 2>/dev/null
    [ "$PF_WAS_ENABLED" = "0" ] && pfctl -E >/dev/null 2>&1
  fi
  {
    cat "$BASE"
    [ -n "$ips4" ] && echo "block drop out inet proto tcp to { $ips4 }"
    [ -n "$ips4" ] && echo "block drop out inet proto udp to { $ips4 }"
    [ -n "$ips6" ] && echo "block drop out inet6 proto tcp to { $ips6 }"
    [ -n "$ips6" ] && echo "block drop out inet6 proto udp to { $ips6 }"
    echo "# claudeguard marker"
  } > "$RULESF"
  if pfctl -f "$RULESF" >/dev/null 2>&1; then
    APPLIED=1
    log "pf applied: v4=[$ips4] v6=[$ips6]"
    echo "state=armed applied=1 v4=$(echo "$ips4" | wc -w | tr -d ' ') v6=$(echo "$ips6" | wc -w | tr -d ' ') ts=$(date '+%F %T')" > "$STATUS"
  else
    log "pfctl -f FAILED; restoring"
    restore_pf
    echo "state=error applied=0 ts=$(date '+%F %T')" > "$STATUS"
  fi
}

cleanup(){
  log "daemon stopping"
  restore_pf
  rm -f "$PIDF" "$STOP"
  log "daemon stopped"
  exit 0
}

case "${1:-}" in
start)
  mkdir -p "$DIR"; chmod 777 "$DIR" 2>/dev/null
  if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null; then
    echo "already-running"; exit 0
  fi
  nohup "$0" run >> "$LOG" 2>&1 &
  echo $! > "$PIDF"
  echo "started"
  exit 0
  ;;
stop)
  touch "$STOP" 2>/dev/null
  if [ -f "$PIDF" ]; then
    P=$(cat "$PIDF" 2>/dev/null)
    for _ in $(seq 1 20); do kill -0 "$P" 2>/dev/null || break; sleep 0.2; done
    kill -9 "$P" 2>/dev/null
  fi
  rm -f "$PIDF" "$STOP"
  # 兜底: 若进程被 9 杀, 手工恢复 pf
  if [ -s "$RULESF" ]; then
    if [ -s "$BASE" ]; then pfctl -f "$BASE" >/dev/null 2>&1; fi
    if [ -f "$PFS" ] && grep -q 'PF_WAS_ENABLED=0' "$PFS" 2>/dev/null; then pfctl -d >/dev/null 2>&1; fi
    rm -f "$RULESF"
  fi
  echo "state=disarmed applied=0 ts=$(date '+%F %T')" > "$STATUS"
  echo "stopped"
  exit 0
  ;;
run)
  mkdir -p "$DIR"
  trap cleanup TERM INT HUP
  rm -f "$STOP"
  log "daemon started (pid=$$)"
  echo "state=disarmed applied=0 ts=$(date '+%F %T')" > "$STATUS"
  TICK=0
  while :; do
    [ -f "$STOP" ] && cleanup
    MODE="disarmed"; IPS4=""; IPS6=""
    if [ -f "$CONTROL" ]; then
      MODE=$(sed -n 's/^mode=//p' "$CONTROL" | head -1)
      IPS4=$(sed -n 's/^ips4=//p' "$CONTROL" | head -1)
      IPS6=$(sed -n 's/^ips6=//p' "$CONTROL" | head -1)
    fi
    SIG="$MODE|$IPS4|$IPS6"
    if [ "$MODE" = "armed" ] && [ -n "$IPS4$IPS6" ]; then
      if [ "$APPLIED" = "0" ] || [ "$SIG" != "$LAST_SIG" ]; then
        apply_pf "$IPS4" "$IPS6"
        LAST_SIG="$SIG"
        TICK=0
      fi
    else
      if [ "$APPLIED" = "1" ]; then
        restore_pf
        LAST_SIG=""
      fi
    fi
    # 周期性自愈: 规则被外部覆盖时重装 (20s)
    TICK=$((TICK+1))
    if [ "$MODE" = "armed" ] && [ "$APPLIED" = "1" ] && [ "$TICK" -ge 20 ]; then
      if ! pfctl -s rules 2>/dev/null | grep -q "block drop out inet proto tcp to"; then
        log "rules missing -> reapply"
        APPLIED=0; LAST_SIG=""
      fi
      TICK=0
    fi
    sleep 1
  done
  ;;
*)
  echo "usage: $0 start|stop|run"; exit 1
  ;;
esac
