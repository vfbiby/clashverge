# claudeguard 技术规格（V0）

**状态**：草案。机制验证完成（PoC-1 / PoC-2），产品开发未开始。
**凡例**：关键断言均标注实测出处；标"推定"的未实测，验收前不算数。

## 1. 架构五件套

```
  任何进程                    ┌──────────────────────────────────────────┐
  curl/wget ────────────────▶│ 域名裁判（大脑）                          │
  浏览器                     │ DNS 接管(fake-ip 白名单) + TLS SNI(全接管) │
  Claude Code                │ 状态机 · 健康探测 · REJECT 注入            │
                             └────────┬──────────────────┬──────────────┘
                        放行(仅 claude 系)              断(claude 系)
                                      │                   ▼
                                      ▼            连接死亡：REJECT 0.01s / 节点死 ≤5s
                             ┌────────────────┐
                             │ 专属出口（右手） │──▶ 上游节点池
                             │ 受限代理        │     （探测对 claude.ai 本身）
                             └────────────────┘
                                      ▲ 唯一豁免主体
                             ┌────────┴─────────┐
                             │ 地址封堵（左手）   │  pf(macOS) / WFP(Windows)
                             │ block 全体出站    │
                             │ pass 看门进程 UID │
                             └──────────────────┘
  ┌────────────────────────────────────────────────────────────┐
  │ 看门进程（L2）：launchd / Windows Service                    │
  │ 探活 → 状态机 → REJECT 注入 → 引擎自愈 → pf 状态管理          │
  ├────────────────────────────────────────────────────────────┤
  │ 兜底层（L3）：hosts/系统 DNS 策略（全子域 + IPv6 + DoH 墙）    │
  │ 引擎全灭时的最后防线；看门维护；UI 名称"基础防护"              │
  └────────────────────────────────────────────────────────────┘
```

五件套 = 大脑（域名裁判）+ 左手（系统防火墙）+ 右手（专属出口）+ 看门（状态机）+ 兜底（L3）。

## 2. 三平面职责表（为什么必须拆）

| 平面 | 看得见什么 | 管得住什么 | 管不住什么 | 实测依据 |
|---|---|---|---|---|
| 地址平面（pf/WFP） | 本机套接字的目的 IP | 直连出网的一切进程 | **远程出口代理流量**——真实目标 IP 不落本机 | PoC-1 T1/T4 ✅；T2 失明实证 |
| 域名平面（DNS+SNI） | 域名（DNS 查询 / TLS ClientHello） | claude 系域名的 fake-ip 签发与路由；须经代理链的流量 | 不产生 DNS/TLS 特征的裸 IP 直连 | PoC-2 T1/T2 ✅ |
| 主体平面（pf user / WFP exe） | 套接字归属（UID / 程序路径） | 给看门进程开单行道豁免 | — | PoC-1 T3/T4 ✅ |

**结论**：两两互补，缺一即漏；**域名裁判必须站在代理链上游**——pf 失明于远程出口代理是 PoC-1 TEST2 用实测钉死的。两层拼装接口 = 一个 mixed 端口 + 一个豁免 UID。

## 3. 放行 / 断 的数据流

**放行**（状态机判定通路健康）：
```
应用查 DNS claude.ai → 裁判判定放行 → 签发 fake-ip (198.18.x.x)
→ 应用连 fake-ip → 引擎 match DomainSuffix(claude.ai) → ClaudeExit[活节点]
→ 节点 → claude 边缘   （前提：出口 IP 未被边缘拒绝——PoC-2 T3 教训）
```

**断**，三种形态分治：
1. **显式断**（策略/开关）：把专属出口切 REJECT → 本地秒断 **0.01s**（T6）
2. **失效断**（节点死/出口被拒）：url-test 判死 ≤5s → 看门注入 REJECT；注意 fake-ip 照常签发但 TCP 必死（P06），所以"断"必须定义在规则面（ADR-0003）
3. **兜底断**：引擎不在 → pf block 全体直连（PASS 单主体豁免也撤） + hosts 层全量注入

## 4. 状态机（看门进程的工作脚本）

| 状态 | 引擎动作 | pf 动作 | hosts 兜底 | 进入条件 |
|---|---|---|---|---|
| DISARMED | 无策略 | 无块规则 | 不注入 | 用户 OFF（彻底解除） |
| ARMED_OPEN | claude→ClaudeExit(活节点) | block 全体 + pass 看门 UID | 不注入 | 探活 claude.ai ✅（穿专属出口） |
| ARMED_CLOSED | ClaudeExit→REJECT | block 全体（无人豁免） | 全量注入 | 探活❌ / 引擎失联 / 状态不明 |

**fail-closed 原则**：任何不确定（探活超时、引擎无响应、pfctl 异常）一律落 ARMED_CLOSED。"点一次设置" = 进入 ARMED 的总闸；ARMED_OPEN/ARMED_CLOSED 之间由探活自动切换，无需人工干预。

## 5. 失效矩阵

| 失效 | 行为 | 恢复 |
|---|---|---|
| 引擎进程被杀 | 看门 5s 内拉起；期间 pf+hosts 保证断 | 拉起后重探活，回 ARMED_OPEN |
| 看门被杀 | launchd / Service 自启 | — |
| 全部节点死 | ≤5s 判死 → REJECT 注入 | 节点复活 → 探活 → 自动放回 |
| 出口被 Claude 边缘拒 | 同上（探测必须对 claude.ai 本身才能发现，ADR-0004） | 节点池可换可配 |
| 隧道死（端口被 RST） | 同上；日志区分"隧道死 vs 出口拒"两类归因 | — |
| pf 状态被重置/覆盖 | 看门重装 anchor，记录并恢复 Enable 状态（P12） | — |
| 用户开全接管 TUN VPN | 窄通道被抢占 → 自动降级 DNS 层形态（**推定，未实测**） | 对方关闭后自动恢复 |
| hosts 兜底被其他工具覆盖 | 看门定期重assert（自愈） | — |

## 6. 实测参数表（产品策略基线）

| 参数 | 值 | 出处 |
|---|---|---|
| 显式 REJECT 生效 | **0.006s** 本地 RST（PoC-3 判定2；PoC-2 为 0.01s，同量级） | PoC-3 J2 |
| 看门"杀→自动注入 REJECT"真实延迟 | **≈29s**（15s×2 周期 + 探耗时；预算 ≤45s）；复通≈16s | PoC-3 事件线 |
| 本地死节点（RST 型）判死 | ≈0s（首个探测周期）；客户端失败 1.8–2.3s | PoC-2 T5 dead-a |
| 远端 RST 判死 | ≈2s；客户端失败 3.3–5.0s | PoC-2 T5 dead-b |
| 真黑洞（SYN 丢弃）判死 | ≈5s（dial 超时兜底）；客户端 5.0s | PoC-2 T5 dead-c |
| 运行中"活→死"识别滞后 | 最坏 ≈30s（url-test 周期边界），需源码确认 interval 与空闲交互 | PoC-2 T5 观察 |
| pf 直连拦截反馈形态 | 静默黑洞（curl exit 28、满超时）；产品可选 `block return`（RST 快失败） | PoC-1 T1 |
| 白名单外域名解析 | 真实解析、完全不经 fakeip 池（零侵入由模式保证） | PoC-2 T2 |
| PF 平面对 hosts 诱饵的免疫 | `--resolve` 强制真实 IP 直连照样被 pf 拦——判定与 hosts 无关 | PoC-3 判定1 |

## 7. 与用户已有代理的共存矩阵

| 用户形态 | 共存 | 依据 |
|---|---|---|
| 系统代理模式（如 Clash 7890） | ✅ 零冲突、零感知 | PoC-2 T7 |
| 二次实例（如 MonetaProxy 7891） | ✅ 端口各自独立 | PoC-2 T7 |
| TUN 全接管 VPN | ⚠️ 抢默认路由 → 产品检测后自动降级（推定） | 待 ROADMAP P1 实测 |

## 8. 技术基线（V1 验证所用）

- **引擎**：mihomo（验证版 v1.19.32；`/Applications/Clash Verge.app/Contents/MacOS/verge-mihomo` 用户态可复用是 PoC-2 的关键发现）。`fake-ip-filter-mode: whitelist` + DNS 1053 + mixed 7892 + external-controller REST 热切组
- **引擎许可**：mihomo GPLv3，产品化需决策（合规嵌入 / 自研），见 ROADMAP P2
- **封堵**：macOS pf anchors + `user` 豁免（实测）；Windows 用 WFP 用户态 `Fwpm*` API，block + 高权重 sublayer 的 exe 豁免（**未实测**）
- **专属出口**：受限代理 = MonetaProxy 形态（sing-box 裁剪核心，domain 白名单唯一出口）
- **看门**：launchd（Win：Service）；探活 = 对 claude.ai HEAD，穿专属出口
- **兜底**：hosts 管理区间（全子域 v4+v6 诱饵 + DoH 域名 sinkhole）

## 9. 封禁库

- **内容**：claude/anthropic 全子域枚举、遥测域（statsig/sentry 类）、DoH 域名墙、对应 AAAA 域清单
- **形态**：云端分发、本地热更新，对外呈现即"病毒库自动更新"的心智
- **边界**：Claude Code 出网面不止 claude.ai——这是持续运营资产，不是一次性清单
- **纪律**：凭据（UUID/密码）永远不入库，只指向 `MonetaProxy/config.json`

## 10. 权限与安装形态

- 一次管理员授权安装包；此后全部组件用户态运行
- pf 的 enable/disable 初始状态先记录、后变更、异常时恢复（P12）
- 对 `/etc/hosts` 的写入只发生在 兜底层，由看门维护，UI 不暴露"hosts"字样

## 11. 未实测/不确定清单（验收前不算数）

- 硬编码 IP + 程序内置 DoH：域名平面不可见；全接管模式 SNI 嗅探可补（**推定**）
- 睡眠唤醒、快速用户切换后的状态机恢复时序
- Windows 侧全部行为（WFP 豁免 sublayer 权重、wintun、服务生命周期）
- TUN 窄通道对"不走代理端口的应用"的实际接管效果（需系统 DNS 指向引擎 + sudo）
