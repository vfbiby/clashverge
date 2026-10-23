# 实验 0006 · PoC-6：剩余 5 项真机 Linux 验证（uk 生产机，全程 netns 隔离）

**日期**：2026-10-23 ｜ **靶机**：`vps-7aaa3e0d`（57.129.160.113，Ubuntu 26.04 / kernel 7.0 / systemd 259 / iptables-nft 1.8.11 / ufw 已装 inactive / 全局 IPv6 / `/dev/net/tun`）
**执行**：子 agent（`netns cgpoc` 内全部网络实验 + `/run` 瞬时 systemd unit）→ 主会复核归档
**铁律**：生产栈（mtcopy-gateway/platform/nginx）**零停机零重启零改配置**；35 次护身符全绿、uptime 未变、三服务 NRestarts=0、iptables/ip6tables/nft 终态 0B diff。

## 判定表（5/5 PASS）

| # | 项 | 实测 | 判定 |
|---|---|---|---|
| **SW3** | systemd 看门自愈 | `kill -9` → **2.23s** 自动重启（NRestarts 0→1，journal 有 `Scheduled restart job`）；`systemctl stop` 后不拉起 | ✅ |
| **SW4'** | ufw 共存 | 该机 `MANAGE_BUILTINS=no`：`reload / disable / enable / reset / ufw-init stop|start` 六种框架动作**全都不碰**我们的外部链；宿主 `/etc/ufw` 清单逐行相同；`after.init` 钩子被 start/stop 各调一次 | ✅ |
| **SW5-B'** | REJECT tcp-reset vs 已建连接（真网络面） | 已建长连接 **253ms 内 `ConnectionResetError` errno 104**；1MB 限速下载中途插入 REJECT → **42ms 后 curl (56) Recv failure**；对照 DROP = 悬挂待超时 | ✅ **推翻 loopback 特例结论**（见修正） |
| **V6** | 双栈真路由 | 无 v6 规则时 v6 100% 直通（泄漏路径实证）；ip6tables DROP 生效；`-m owner` 豁免 v6/v4 **完全同构** | ✅ |
| **TUN** | Linux 窄通道接管 | ns 内裸 curl → fake-ip **198.18.0.4** → `match DomainSuffix(claude.ai) using ClaudeExit`；example.org 真实解析 200（零侵入）；AAAA 空（P20 跨平台复核）；看门 **33.7s INJECT** / 裸 curl **36ms 失败** / **30.6s RELEASE** / 复通 | ✅ |

## 修正记录（推翻前结论）

| 原结论 | 新证据 | 修正 |
|---|---|---|
| PoC-4 SW5-B：`REJECT tcp-reset` 对已建连接"不秒杀"（残留≈35s） | 真网络面实测 RST 在 253ms/42ms 到达 | **那是 loopback 自回环的内核特例，不是语义**——"已建连接/内核路径"类验证不得从容器 loopback 外推（→ P29） |
| — | systemd `Restart=always` 下 `exit 0` 也会被拉起（NRestarts 0→2 实测） | 停机语义必须配 `RestartPreventExitStatus=0`（→ P24） |
| — | `ufw default/allow` 会写 `/etc/default/ufw`（不在 `/etc/ufw` 快照范围内） | 快照范围扩到 `/etc/default/ufw`；内容未变仅 mtime（dpkg -V 校验通过，如实上报） |

## 环境/工程坑（均入 PITFALLS）

- 资产架构错配：预置 mihomo 为 arm64，靶机 x86_64 → 下载官方 amd64 v1.19.32（sha256 与 Release API digest 一致）；安装器必须做 arch 探测（→ P28）
- Ubuntu 26.04 用 uutils coreutils：`date +%s%3N` 不截断，毫秒计时失真（→ P26，本轮已重跑修正）
- `ip netns delete` 后 veth 对端残留，需显式 `ip link del`（→ P27）

## 产品级结论（→ ADR-0005）

1. **默认规则策略 = 独立 nft 表 + 看门周期性 re-assert**：全生命周期存活、不写发行版规则文件、nft `accept` 不会打穿框架 DROP（安全属性）；代价：宿主 `DEFAULT_OUTPUT_POLICY=DROP` 时豁免会失效 → 必须配链路自检
2. **仅在"豁免必须永远赢"时用 iptables 专用链挂 OUTPUT 首位**：实测 iptables `ACCEPT` 终止整表遍历、可覆盖 ufw DROP；但会打穿管理员策略，且 `MANAGE_BUILTINS=yes` 宿主会被 flush → 看门重装是硬要求
3. 不写 `/etc/ufw/user.rules`；确需集成走官方 `after.init`（已证被调用）

## 证据

- `claudeguard-test/poc6/REPORT.md`（全表+基线+产品建议）
- `claudeguard-test/poc6/evidence/`（99 件原始物证：netns/ufw/ip6tables/TUN 日志、护身符 35 次、diff 证明）
- `claudeguard-test/poc6/{10-setup.sh … 90-cleanup.sh}`（可复跑实验链）+ `config-tun-ns.yaml`
- 回传 tar.gz sha256 `46e277f6…`（远端/本地一致）

## 仍未覆盖（诚实清单）

真实公网 v6 出口（本轮 ULA veth）；systemd unit 正式安装形态（`User=monetafw`/enable/24h 观察）；`MANAGE_BUILTINS=yes` 的 flush 实测；firewalld / 纯 nft 发行版；`DEFAULT_OUTPUT_POLICY=DROP` 持久化；TUN fwmark 全接管；systemd-resolved per-link 集成；性能/并发；真实 relay 健康（当日 anytls 仍不可用，claude.ai 只能取到 DIRECT 403）；生产机直接 enable ufw 的窗口测试。
