#!/bin/bash
pkill -f "bun run server.ts" 2>/dev/null && echo "Dashboard stopped." || echo "Dashboard is not running."
