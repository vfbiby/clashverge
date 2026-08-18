#!/bin/bash
# MonetaProxy 停止脚本 — 双击运行
cd "$(dirname "$0")"

if [ -f mihomo.pid ] && kill -0 "$(cat mihomo.pid)" 2>/dev/null; then
  kill "$(cat mihomo.pid)" 2>/dev/null
  sleep 1
  echo "✅ mihomo 已停止"
else
  echo "ℹ️  mihomo 未在运行"
fi
rm -f mihomo.pid

# 关闭系统代理 (对所有网络服务生效)
for svc in $(networksetup -listallnetworkservices 2>/dev/null | tail -n +2); do
  networksetup -setwebproxystate "$svc" off >/dev/null 2>&1
  networksetup -setsecurewebproxystate "$svc" off >/dev/null 2>&1
done
echo "✅ 系统代理已关闭"

osascript -e 'display notification "代理已停止, 系统代理已恢复" with title "MonetaProxy"' 2>/dev/null
read -p "按回车键关闭窗口..."
