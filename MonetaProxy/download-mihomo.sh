#!/bin/bash
# 下载 mihomo 核心 (macOS) — 重新下载或更新时运行
cd "$(dirname "$0")"

ARCH=$(uname -m)
case "$ARCH" in
  arm64)  PATTERN="darwin-arm64" ;;
  x86_64) PATTERN="darwin-amd64" ;;
  *) echo "❌ 不支持的架构: $ARCH"; exit 1 ;;
esac

URL=$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases/latest \
  | grep -oE 'https://[^"]*'"$PATTERN"'[^"]*\.gz' | head -1)
if [ -z "$URL" ]; then
  echo "❌ 获取下载地址失败, 请检查网络"
  exit 1
fi

echo "📥 下载: $URL"
curl -L -o mihomo.gz "$URL" && gunzip -f mihomo.gz && chmod +x mihomo
echo "✅ 完成: $(ls -lh mihomo | awk '{print $5}')"
