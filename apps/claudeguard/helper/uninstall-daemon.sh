#!/bin/bash
# ClaudeGuard 守护卸载器（root）——bootout + 撤 plist + 兜底恢复 pf
set -u
DIR=/tmp/claudeguard
PLIST=/Library/LaunchDaemons/com.claudeguard.guardd.plist
LABEL=com.claudeguard.guardd

launchctl bootout "system/com.claudeguard.engine" >/dev/null 2>&1
launchctl bootout "system/$LABEL" >/dev/null 2>&1
# 等待 guardd 的 trap 完成恢复
for _ in $(seq 1 25); do
  launchctl print "system/$LABEL" >/dev/null 2>&1 || break
  sleep 0.2
done
rm -f "$PLIST" /Library/LaunchDaemons/com.claudeguard.engine.plist

# 兜底恢复（若 trap 没来得及跑）
if [ -s "$DIR/rules.applied" ]; then
  pfctl -f /etc/pf.conf >/dev/null 2>&1
  if [ -f "$DIR/pf.state" ] && grep -q 'PF_WAS_ENABLED=0' "$DIR/pf.state" 2>/dev/null; then
    pfctl -d >/dev/null 2>&1
  fi
fi
# 兜底还原系统代理（若 trap 未跑完）
if [ -s "$DIR/proxy.before" ]; then
  svc=$(sed -n 's/^svc=//p' "$DIR/proxy.before" | head -1)
  we=$(sed -n 's/^web_enabled=//p' "$DIR/proxy.before" | head -1)
  ws=$(sed -n 's/^web_server=//p' "$DIR/proxy.before" | head -1)
  wp=$(sed -n 's/^web_port=//p' "$DIR/proxy.before" | head -1)
  se=$(sed -n 's/^secure_enabled=//p' "$DIR/proxy.before" | head -1)
  ss=$(sed -n 's/^secure_server=//p' "$DIR/proxy.before" | head -1)
  sp=$(sed -n 's/^secure_port=//p' "$DIR/proxy.before" | head -1)
  if [ -n "$svc" ]; then
    if [ "$we" = "Yes" ] && [ -n "$ws" ] && [ -n "$wp" ]; then networksetup -setwebproxy "$svc" "$ws" "$wp" >/dev/null 2>&1; else networksetup -setwebproxystate "$svc" off >/dev/null 2>&1; fi
    if [ "$se" = "Yes" ] && [ -n "$ss" ] && [ -n "$sp" ]; then networksetup -setsecurewebproxy "$svc" "$ss" "$sp" >/dev/null 2>&1; else networksetup -setsecurewebproxystate "$svc" off >/dev/null 2>&1; fi
  fi
fi
rm -f "$DIR/rules.applied" "$DIR/daemon.pid" "$DIR/stop" "$DIR/pf.state" "$DIR/rules.base" "$DIR/proxy.before"
echo "state=disarmed applied=0 ts=$(date '+%F %T')" > "$DIR/status"
echo "uninstalled"
