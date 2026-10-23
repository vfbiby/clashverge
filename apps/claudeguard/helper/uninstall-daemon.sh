#!/bin/bash
# ClaudeGuard 守护卸载器（root）——bootout + 撤 plist + 兜底恢复 pf
set -u
DIR=/tmp/claudeguard
PLIST=/Library/LaunchDaemons/com.claudeguard.guardd.plist
LABEL=com.claudeguard.guardd

launchctl bootout "system/$LABEL" >/dev/null 2>&1
# 等待 guardd 的 trap 完成恢复
for _ in $(seq 1 25); do
  launchctl print "system/$LABEL" >/dev/null 2>&1 || break
  sleep 0.2
done
rm -f "$PLIST"

# 兜底恢复（若 trap 没来得及跑）
if [ -s "$DIR/rules.applied" ]; then
  pfctl -f /etc/pf.conf >/dev/null 2>&1
  if [ -f "$DIR/pf.state" ] && grep -q 'PF_WAS_ENABLED=0' "$DIR/pf.state" 2>/dev/null; then
    pfctl -d >/dev/null 2>&1
  fi
fi
rm -f "$DIR/rules.applied" "$DIR/daemon.pid" "$DIR/stop" "$DIR/pf.state" "$DIR/rules.base"
echo "state=disarmed applied=0 ts=$(date '+%F %T')" > "$DIR/status"
echo "uninstalled"
