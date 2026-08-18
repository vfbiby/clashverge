#!/bin/bash
# 一键编译 Windows 单文件绿色版 MonetaProxy.exe
cd "$(dirname "$0")"

echo "1. 交叉编译 Windows 版 sing-box 精简内核..."
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go install -v -trimpath -ldflags "-s -w -buildid=" \
  -tags "with_vless,with_utls,with_anytls" \
  github.com/sagernet/sing-box/cmd/sing-box@v1.13.19

mkdir -p embedded
cp "$(go env GOPATH)/bin/windows_amd64/sing-box.exe" ./embedded/sing-box.exe
cp ../MonetaProxy/config.json ./embedded/config.json

echo "2. UPX 压缩内核..."
upx --lzma --best ./embedded/sing-box.exe

echo "3. 编译 MonetaProxy.exe (无控制台窗口)..."
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -H windowsgui" -o MonetaProxy.exe .

echo "4. UPX 最终压缩..."
upx --lzma --best MonetaProxy.exe

echo "✅ 编译完成！最终单文件体积: $(ls -lh MonetaProxy.exe | awk '{print $5}')"
