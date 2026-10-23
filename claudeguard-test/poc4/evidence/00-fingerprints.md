# PoC-4 供应链与资产指纹记录（2026-10-24）

## 引擎二进制 (Linux 侧)
- 版本: **v1.19.32**（对齐 macOS 侧 PoC-2/3 验证过的 1.19.x）
- 平台: linux/arm64 (glibc 动态; 来源为官方 release 的 `.gz` 裸二进制)
- 下载 URL: `https://github.com/MetaCubeX/mihomo/releases/download/v1.19.32/mihomo-linux-arm64-v1.19.32.gz`
- **校验**: 本地 `sha256(gz)` = `9dd862e28b46ff7d775f169cceebc28deccaa0a9e804237d421cd2571e0caba0`
  对照 GitHub Release API `assets[].digest` 字段（官方发布后元数据）: `sha256:9dd862e28b46ff7d775f169cceebc28deccaa0a9e804237d421cd2571e0caba0` → **一致 ✅**
  （注: 该 release 无独立 checksum 资产文件, 以 API digest 为对照物; 解出裸二进制 `mihomo`
   sha256 = `c80df2ca5159567804da883401e0118908fc1155e05df2baf3dbd4d3ecfc3754`）
- 宿主侧下载（走宿主 http_proxy 127.0.0.1:7890）→ `docker cp` 进容器 /usr/local/bin/mihomo

## 引擎配置
- `config.yaml` = poc3/config.yaml **逐字节原样**（含 ClaudeExit/EdgeProbe/dead/direct、
  mixed 7892、DNS 1053 白名单 fake-ip、external-controller 127.0.0.1:9095；0 改动）
- sha256(poc3) = sha256(poc4): `7e62a00ec062f8c0a08425aec7307a2228e16bb0f5342b3be4bb5079bafb9540`
- 预检: `mihomo -t -f /tmp/cfg.yaml -d engine/` → "test is successful"（见 evidence/prevalid-mihomo-t.txt）
- 引擎在容器内以 **uid 5011 (user monetafw)** 运行 — owner 豁免的区分主体

## 看门脚本与对照
- 容器内 bash 5.1.16（对照 macOS bash 3.2 的 P16/P17 坑——本轮加固形态沿用且行为一致）
- 容器内补跑见 `evidence/log_b.txt`；主跑 `evidence/log.txt`；WATCH 事件线 `evidence/watch.txt`
