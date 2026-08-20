#!/bin/bash
# 一键编译 Windows 单文件绿色版 MonetaProxy.exe
cd "$(dirname "$0")"

USE_UPX=false

for arg in "$@"; do
  case $arg in
    --upx|-u)
      USE_UPX=true
      shift
      ;;
    --help|-h)
      echo "用法: ./build.sh [选项]"
      echo "选项:"
      echo "  -u, --upx     使用 UPX 压缩二进制文件以减小体积"
      echo "  -h, --help    显示此帮助信息"
      exit 0
      ;;
  esac
done

echo "1. 交叉编译 Windows 版 sing-box 精简内核..."
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go install -v -trimpath -ldflags "-s -w -buildid=" \
  -tags "with_vless,with_utls,with_anytls" \
  github.com/sagernet/sing-box/cmd/sing-box@v1.13.19

mkdir -p embedded
cp "$(go env GOPATH)/bin/windows_amd64/sing-box.exe" ./embedded/sing-box.exe
cp ../MonetaProxy/config.json ./embedded/config.json

if [ "$USE_UPX" = true ]; then
  if command -v upx >/dev/null 2>&1; then
    echo ">> 正在对内嵌 sing-box.exe 进行 UPX 压缩..."
    upx --lzma --best ./embedded/sing-box.exe
  else
    echo "⚠️ 未找到 upx 命令，跳过内嵌内核 UPX 压缩。"
  fi
fi

echo "2. 编译 MonetaProxy.exe (无控制台窗口)..."
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -H windowsgui" -o MonetaProxy.exe .

if [ "$USE_UPX" = true ]; then
  if command -v upx >/dev/null 2>&1; then
    echo ">> 正在对 MonetaProxy.exe 进行 UPX 压缩..."
    upx --lzma --best MonetaProxy.exe
  else
    echo "⚠️ 未找到 upx 命令，跳过 MonetaProxy.exe UPX 压缩。"
  fi
fi

echo "✅ 编译完成！最终单文件体积: $(ls -lh MonetaProxy.exe | awk '{print $5}')"
