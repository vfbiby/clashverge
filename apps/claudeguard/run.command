#!/bin/bash
# 双击运行 ClaudeGuard（macOS）
cd "$(dirname "$0")" || exit 1
if [ ! -x target/release/claudeguard ]; then
  echo "首次运行，正在构建（约 1 分钟）…"
  cargo build --release || { echo "构建失败"; read -r -p "按回车关闭"; exit 1; }
fi
exec ./target/release/claudeguard
