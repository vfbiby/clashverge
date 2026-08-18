#!/bin/bash
# MonetaProxy 启动脚本 — 双击运行
cd "$(dirname "$0")"

PORT=7891

if [ -f mihomo.pid ] && kill -0 "$(cat mihomo.pid)" 2>/dev/null; then
  echo "✅ mihomo 已在运行 (PID $(cat mihomo.pid))"
else
  rm -f mihomo.pid
  nohup ./mihomo -d "$PWD" -f "$PWD/config.yaml" >> mihomo.log 2>&1 &
  echo $! > mihomo.pid
  sleep 1
  if kill -0 "$(cat mihomo.pid)" 2>/dev/null; then
    echo "✅ mihomo 已启动 (PID $(cat mihomo.pid), 端口 $PORT)"
  else
    echo "❌ mihomo 启动失败, 请看 mihomo.log"
    read -p "按回车键关闭窗口..."
    exit 1
  fi
fi

# 设置系统代理 (对所有网络服务生效)
for svc in $(networksetup -listallnetworkservices 2>/dev/null | tail -n +2); do
  networksetup -setwebproxy "$svc" 127.0.0.1 $PORT >/dev/null 2>&1
  networksetup -setsecurewebproxy "$svc" 127.0.0.1 $PORT >/dev/null 2>&1
  networksetup -setwebproxystate "$svc" on >/dev/null 2>&1
  networksetup -setsecurewebproxystate "$svc" on >/dev/null 2>&1
done
echo "✅ 系统代理已开启 (monetamarket.com 走节点, 其他网站直连)"

osascript -e 'display notification "monetamarket.com 代理已启动" with title "MonetaProxy"' 2>/dev/null
echo ""
echo "提示: 停止请双击 stop.command, 查看状态请双击 status.command"
read -p "按回车键关闭窗口..."
