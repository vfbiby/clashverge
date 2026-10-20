#!/bin/bash
# PoC-2 引擎启动器: 用户态运行 mihomo, 不碰系统任何配置
cd "$(dirname "$0")"
MIHOMO="/Applications/Clash Verge.app/Contents/MacOS/verge-mihomo"
CONFIG="${1:-configs/config.yaml}"
LOG="work/mihomo.log"

if [ -f work/mihomo.pid ] && kill -0 "$(cat work/mihomo.pid)" 2>/dev/null; then
  echo "engine already running: pid $(cat work/mihomo.pid)"
  exit 1
fi

nohup "$MIHOMO" -d work -f "$CONFIG" >> "$LOG" 2>&1 &
PID=$!
echo "$PID" > work/mihomo.pid
disown "$PID"
echo "engine started: pid=$PID config=$CONFIG (ports 7892/1053/9095)"
