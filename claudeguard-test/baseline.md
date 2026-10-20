# 基线记录（子 agent 无 sudo 阶段，2026-10-20）

- 免密 sudo 探测：`sudo -n true` → 失败（`sudo: a password is required`），故走路径 B，准备人工执行包
- pf 状态：普通用户不可读（`pfctl -si` → `pfctl: /dev/pf: Permission denied`），只能假设默认 Disabled，脚本内以 root 精确记录并按原状态恢复
- 实验目标解析（example.com，Cloudflare 代理，注意 IP 并不稳定）：
  - IPv4: 172.66.147.243, 104.20.23.154
  - IPv6: 2606:4700:10::ac42:93f3, 2606:4700:10::6814:179a
- 直连可达性基线（未走代理，unset proxy env）：
  `curl https://example.com` → http_code=200, remote_ip=172.66.147.243, exit=0
- 环境：macOS 26.7.1，当前用户 zhangsike(uid 501)
- 预占用检查：UID 5011 空闲；用户 `_monetafw` 不存在
