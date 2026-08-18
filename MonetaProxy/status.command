#!/bin/bash
# MonetaProxy 状态查看 — 双击运行
cd "$(dirname "$0")"

if [ -f mihomo.pid ] && kill -0 "$(cat mihomo.pid)" 2>/dev/null; then
  echo "✅ mihomo 运行中 (PID $(cat mihomo.pid))"
else
  echo "❌ mihomo 未运行"
fi

echo "--- 系统代理状态 ---"
for svc in $(networksetup -listallnetworkservices 2>/dev/null | tail -n +2); do
  web=$(networksetup -getwebproxy "$svc" 2>/dev/null | grep -i enabled | awk '{print $2}')
  secure=$(networksetup -getsecurewebproxy "$svc" 2>/dev/null | grep -i enabled | awk '{print $2}')
  echo "  $svc: HTTP=$web HTTPS=$secure"
done

if [ -f mihomo.log ]; then
  echo "--- 最近日志 ---"
  tail -n 5 mihomo.log
fi
read -p "按回车键关闭窗口..."
