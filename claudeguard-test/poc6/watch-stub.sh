#!/bin/bash
# claudeguard 看门桩: 探活循环 + 停机文件形态 (真实看门机的骨架)
STOPFILE=/root/claudeguard-poc6/stop.guard
while :; do
  if [ -f "$STOPFILE" ]; then
    echo "STOPFILE seen, clean exit 0 ($(date '+%F %T'))"
    exit 0
  fi
  echo "watchdog heartbeat pid=$$ $(date '+%F %T')"
  sleep 1
done
