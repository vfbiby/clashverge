#!/bin/bash
# 本地编译极简精简版 sing-box 核心 (仅保留 VLESS+Reality+AnyTLS)
cd "$(dirname "$0")"

echo "🔨 开始编译极简 sing-box 核心..."
CGO_ENABLED=0 go install -v -trimpath -ldflags "-s -w -buildid=" \
  -tags "with_vless,with_utls,with_anytls" \
  github.com/sagernet/sing-box/cmd/sing-box@latest

if [ $? -eq 0 ]; then
  cp "$(go env GOPATH)/bin/sing-box" ./sing-box
  chmod +x ./sing-box
  echo "✅ 编译完成: $(ls -lh sing-box | awk '{print $5}')"
else
  echo "❌ 编译失败，请检查 Go 环境及网络"
  exit 1
fi
