#!/bin/bash
# PoC-2 引擎停止器
cd "$(dirname "$0")"
if [ -f work/mihomo.pid ]; then
  PID=$(cat work/mihomo.pid)
  if kill -0 "$PID" 2>/dev/null; then
    kill "$PID"
    for i in $(seq 1 20); do
      kill -0 "$PID" 2>/dev/null || break
      sleep 0.2
    done
    kill -0 "$PID" 2>/dev/null && { kill -9 "$PID"; echo "force killed $PID"; }
  fi
  rm -f work/mihomo.pid
  echo "engine stopped (pid $PID)"
else
  echo "no pidfile / not running"
fi
# 确认端口释放
LEFT=$(lsof -nP -iTCP:7892 -iTCP:1053 -iTCP:9095 -sTCP:LISTEN 2>/dev/null | tail -n +2)
if [ -z "$LEFT" ]; then echo "ports 7892/1053/9095 all released"; else echo "STILL LISTENING:"; echo "$LEFT"; fi
