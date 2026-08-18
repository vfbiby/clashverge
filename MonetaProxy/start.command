#!/bin/bash
# MonetaProxy 启动脚本 — 双击运行
cd "$(dirname "$0")"

PORT=7891

if [ -f sing-box.pid ] && kill -0 "$(cat sing-box.pid)" 2>/dev/null; then
  echo "✅ sing-box 已在运行 (PID $(cat sing-box.pid))"
else
  rm -f sing-box.pid
  nohup ./sing-box run -c "$PWD/config.json" >> sing-box.log 2>&1 &
  echo $! > sing-box.pid
  sleep 1
  if kill -0 "$(cat sing-box.pid)" 2>/dev/null; then
    echo "✅ sing-box 已启动 (PID $(cat sing-box.pid), 端口 $PORT)"
  else
    echo "❌ sing-box 启动失败, 请查看 sing-box.log"
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
