# ROADMAP — 待验证靶子与验收口径

**状态**（2026-10-20）：PoC-1/PoC-2 完成，机制三平面已坐实两平面半（地址平面 ✅、域名平面 ✅、TUN 接管半 ✅——引擎能力实证但未做系统级接管）。按依赖关系排序；每项附验收口径，验收不过不算完成。

## P0 · PoC-3：端到端串联（下一件事）

**靶子**：把 PoC-1 的 pf 层 + PoC-2 的引擎 + 一个看门脚本（launchd 之外的简单版）串成完整闭环：pf 豁免喂引擎 mixed 口 → 域名分流 → 探活判死 → REJECT 注入 → 状态切换全程可观测。

**验收口径**：
1. 普通进程直连 claude 系域名 → pf 拦死（无代理端口路径）
2. 经引擎端口的进程 → claude 走专属出口，example.com 走 DIRECT
3. 人工杀节点 → ≤5s 判死 → REJECT 注入 → 客户端 0.01s 被断；节点复活 → 自动放回
4. 全程 log.txt 记录每次状态切换时间戳
5. 结束后机器零残留（pf/hosts/进程三清）

**依赖**：需要 root（用户手动跑，同 PoC-1 模式：我们备脚本+复核输出）。

## P1 · 系统级接管两件（可与 P0 并行）

1. **TUN 窄通道接管**：系统 DNS 指向引擎 + utun 窄路由（198.18.0.0/16），验证"不走代理端口的应用"（裸 `env -u proxy curl https://claude.ai`）也被域名裁判接管——断或走专属通道。
   验收：不设 proxy env 的 curl/wget 被域名裁判管理；用户 Clash（系统代理模式）不受影响；路由撤销后一切还原。
   依赖：root。
2. **Windows WFP PoC**：在 Windows 机器/VM 上用 `Fwpm*` API 实现"block 全体 + 高权重 sublayer 豁免我们的 exe"，并验证与 PoC-1 等价的行为。
   验收：普通程序直连被拦 + 豁免 exe 通 + 重启后规则持久/清理行为符合预期。

## P2 · 产品骨架（立项开发第一步）

1. **封禁库 v1**：claude/anthropic 全子域枚举（含遥测域、DoH 墙、AAAA 清单）+ 生成器脚本 → 产出引擎配置与 hosts 兜底块。验收：单脚本重建两份产物；diff 稳定。
   - 注意：Claude Code 实际出网面需要一次实测盘点（开引擎日志观察一个完整 Claude Code 会话触达的全部域名）作为库的种子。
2. **安装器 + 组件打包**：专用服务账户创建（绕开 P05 的 dscl 姿势问题）、launchd 定义、内核分发（产品自营内核，不赌系统里恰好有——P11）、许可证决策（mihomo GPLv3：合规嵌入或自研）。
3. **看门正式版**：状态机（DISARMED/ARMED_OPEN/ARMED_CLOSED，fail-closed 原则）、探活、REJECT 注入、pf 状态管理（P12）、自愈（引擎拉起、hosts 重 assert）。
4. **UI 面板 + 日志**：三态显示、封锁/放行切换、连接事件流（哪条规则命中）。"断流提示"分级阈值用实测参数：0.01s / ~2s / ~5s（SPEC §6）。

## P3 · 平台扩展（架构已定，时机另议）

- **Android**：VpnService 窄通道 + 内置转发；注意 VPN 位独占——先做"DNS 层形态"（Private DNS 指向云端过滤解析器）
- **iOS**：NEDNSSettingsManager（DNS 层，消费者可装）为主；PacketTunnelProvider 与用户 VPN 互斥，评估后再定
- **企业层**：macOS NE Content Filter（Apple 特批 entitlement）+ Windows 内核 callout 作为叠加增强，补硬编码 IP/内置 DoH 的极端面；MDM 托管部署

## 悬而未决（争论时要回看的记录）

- 为什么不首发内容过滤器：ADR-0001
- 为什么"断"在规则面不在 DNS 面：ADR-0003
- 为什么 pf 拦不住代理流量还要留 pf：ADR-0002 + PoC-1 TEST2
