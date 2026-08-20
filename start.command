#!/bin/bash
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

# 如果已经在运行则先停止
pkill -f "bun run server.ts" 2>/dev/null || true

echo "Starting Clash Verge Web Dashboard..."
nohup bun run server.ts > "$DIR/server.log" 2>&1 &

sleep 1
if pgrep -f "bun run server.ts" > /dev/null; then
    echo "Dashboard started successfully at http://127.0.0.1:9099"
    open "http://127.0.0.1:9099"
else
    echo "Failed to start. Please check server.log"
fi
