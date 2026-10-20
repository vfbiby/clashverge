# claudeguard — 产品总览

**一句话定位**：装一次、常驻、全自动的 "Claude 出网管控器"，形态对标杀毒软件/防火墙——把 Claude/Anthropic 系域名在系统层面"断"或"放"，而不是靠改 hosts 这种一眼可拆的原始手段。

## 解决什么问题

hosts 方案的四宗罪（也是立项动机）：

1. **死名单**：静态精确匹配，无后缀语义，`sentry.claude.ai` 这类子域逐条穷举，漏一条漏一路
2. **IPv6 漏洞**：hosts 只写 IPv4，v6 真实 AAAA 照常解析直连（2026-10-20 在开发机上实测抓到）
3. **绕过面**：浏览器 DoH、程序内置解析、硬编码 IP 都不吃 hosts
4. **无状态**：谁在连、连没连上、何时断何时放，一概无日志无感知

产品语义：**装的时候点一次设置**，之后由常驻组件维持——通路健康时 Claude 走专属通道可用；通路不健康时，任何进程（curl、wget、浏览器、Claude Code CLI）都连不上 claude.ai/anthropic.com 系全部域名。

## 目标用户

先个人后企业：个人开发者自用起步，架构预留企业化接口（策略下发、审计报表、MDM 托管）。

## 平台路线

- **Win + macOS（V1）**：桌面双端共用一套用户态引擎方案（ADR-0001）
- Android（VpnService 窄通道）、iOS（DNS 层形态）后续再定——手机端 VPN 位独占是硬约束，决策推迟
- 未来企业层增强（macOS NE Content Filter / Windows 内核 callout）不是废弃选项，是叠加层（ADR-0001）

## 三条诚实边界

1. **机制可以藏，存在藏不住**：无 hosts 痕迹、规则在引擎内部，但系统设置里会显示服务/扩展——与所有正经杀软一致。不做反卸载/隐形监控
2. 企业场景的防篡改走 MDM 正规路线，不做对抗设备主人
3. 极端程序（硬编码 IP + 自带 DoH）V1 管不住域名平面，靠 pf/WFP 地址平面兜"指名直连"，全接管模式的 SNI 嗅探测推定可补——留待验证

## 现状（2026-10-20）

机制验证完成：PoC-1（pf 豁免）、PoC-2（域名裁判），两份实验记录 + 原始证据在案（`experiments/`）。**未进入产品开发**，下一步见 [05-ROADMAP.md](./05-ROADMAP.md)。

## 文档导航

| 文档 | 内容 |
|---|---|
| [02-SPEC.md](./02-SPEC.md) | 技术规格：架构、平面职责、状态机、失效矩阵、实测参数 |
| [adr/](./adr/) | 四个关键决策及理由（ADR-0001~0004） |
| [04-PITFALLS.md](./04-PITFALLS.md) | 坑账：平台差异与易错点，滚动追加 |
| [05-ROADMAP.md](./05-ROADMAP.md) | 待验证靶子与验收口径 |
| [experiments/](./experiments/) | PoC 实验记录（正文精选 + 原始证据链接） |
| [GLOSSARY.md](./GLOSSARY.md) | 术语表 |

## 证据资产（本仓库内）

```
claudeguard-test/            # 可复现实验资产（脚本/配置/原始输出）
├── pf-test.sh               # PoC-1 脚本（含三重回滚）
├── log.txt                  # PoC-1 全量日志
└── poc2/                    # PoC-2：REPORT.md + configs + evidence + run/stop.sh
```

凭据（节点 UUID/密码）不入文档，见 `MonetaProxy/config.json`。
