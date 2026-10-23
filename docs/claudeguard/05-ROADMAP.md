# ROADMAP — 待验证靶子与验收口径

**状态**（2026-10-20）：PoC-1/PoC-2 完成，机制三平面已坐实两平面半（地址平面 ✅、域名平面 ✅、TUN 接管半 ✅——引擎能力实证但未做系统级接管）。按依赖关系排序；每项附验收口径，验收不过不算完成。

## P0 · PoC-3：端到端串联 ✅（2026-10-20 完成，三判定全 PASS）

**结论**：闭环成立——pf 拦直连(含 --resolve 真实IP)+单主体豁免、引擎域名裁判、看门自动注入/解除 REJECT（杀→断 ≈29s、切断 0.006s、复通≈16s）全链路实测通过。详见 experiments/0003；两轮 FAIL 的根因（bash 3.2 两坑+取证时序）已入坑账 P16–P18。→ 下一步主线切 P1。

## P1 · 系统级接管两件（可与 P0 并行）

1. ~~**TUN 窄通道接管**~~ ✅ **2026-10-24 完成**（PoC-5 全 PASS）：裸进程被管辖（fake-ip+judge 命中）、零侵入（白名单外真实解析/AAAA 空）、看门注入 35s、REJECT 切断瞬时、回滚零残留。技术要点：53 被其他软件占用时用 pf rdr 53→1053；金丝雀域名证明应答来源。详见 experiments/0005。
2. **Windows WFP PoC**：在 Windows 机器/VM 上用 `Fwpm*` API 实现"block 全体 + 高权重 sublayer 豁免我们的 exe"，并验证与 PoC-1 等价的行为。
   验收：普通程序直连被拦 + 豁免 exe 通 + 重启后规则持久/清理行为符合预期。

## P1.5 · Linux 验证 ✅ 真机轮完成（2026-10-23，PoC-6 五项全 PASS：SW3 systemd 自愈 2.23s / SW4' ufw 六动作零冲突 / SW5-B' 真网面 RST 253ms / V6 双栈同构 / TUN 裸进程接管 33.7s+36ms）。详见 [experiments/0006](./experiments/0006-poc-linux-realmachine.md)；规则策略决策 [ADR-0005](./adr/0005-linux-rule-strategy.md)。

**未覆盖 → 并入 P2/后续**：真实公网 v6 出口；systemd unit 正式形态（`User=monetafw`/enable/24h）；`MANAGE_BUILTINS=yes` flush 实测；firewalld/纯 nft 发行版；`DEFAULT_OUTPUT_POLICY=DROP` 持久化；TUN fwmark 全接管；systemd-resolved per-link；性能/并发；真实 relay 健康。

## P2 · 产品骨架（立项开发第一步）——进行中

**2026-10-24 起步**：macOS v0.1 GUI 原型落地（`apps/claudeguard/`，egui + root 守护 + pf 执行层）：
自动/强制封禁/放行三模式、通路健康探测、IP 自动刷新、事件日志、一键自测；实测直连封禁/还原/自愈。
已知边界：pf 仅封直连，远程出口代理链路需 v0.2 域名平面（引擎）补齐。

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
