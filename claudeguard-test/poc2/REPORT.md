# PoC-2 判定报告：域名平面关键裁判实验 —— DNS/TUN 引擎 + 健康探测 fail-closed + 专属代理通道

日期：2026-10-20 ｜ 执行机：zhangsike macOS（全程用户态、零 root、TUN 未做留给手动包）
目录：`claudeguard-test/poc2/`（run.sh / stop.sh / configs/ / evidence/ · 引擎进程已全部杀净，端口 7892/1053/9095 已释放）

## 一、引擎选型（含决策过程）

| 资产 | 勘察结果 | 结论 |
|---|---|---|
| MonetaProxy/sing-box（19MB，tags: with_vless,with_utls,with_anytls） | 可执行；节点同源。但**无 DNS inbound 类型**（`sing-box check` 报 `unknown inbound type: dns`，先写 1.12 新格式 config.json 被否） | 备用（实际未用） |
| `/Library/.../cores/verge-mihomo` | 目录+二进制 root 700，**普通用户读不了** | 不可用 |
| `~/.config/clash/service/clash-core-service` | `rw-r--r-- root:wheel`，**无执行位** | 不可用 |
| **`/Applications/Clash Verge.app/Contents/MacOS/verge-mihomo`** | `Mihomo Meta v1.19.32 darwin arm64`，zhangsike:admin 可执行可读，功能全（fake-ip 白名单模式 / mixed / url-test / REJECT / clash API） | ✅ **选定** |

选型理由：① 三处"服务端"内核资产均因 root 权限不可用；② App bundle 内 mihomo 是唯一功能完整+可用户态二次启动的引擎；③ 域名裁判所需全部要件（DNS 端口监听 + fake-ip 白名单 + select 组 + url-test + REST API 切换）mihomo 原生支持，配置即产品政策语义。sing-box 试写配置被 check 拒绝即弃用（保留 `configs/config.json` 作证据）。

配置要件实现（mihomo YAML，`configs/config.yaml`）：
- inbound A：mixed `127.0.0.1:7892`；inbound B：DNS `127.0.0.1:1053`（TCP+UDP）
- **零侵入 DNS 技巧**：`fake-ip-filter-mode: whitelist` + 白名单=claude 系 5 个域名（`+.claude.ai` 等）→ 白名单内发 fake-ip，**其余一切域名走真实 DNS（udp://223.5.5.5）**
- 组：`ClaudeExit`（select: anytls / vless / REJECT / DIRECT）、`Probe`（url-test，两节点，interval 30s）
- 规则置顶：5 条 DOMAIN-SUFFIX → ClaudeExit；`IP-CIDR,198.18.0.0/16 → ClaudeExit` 兜底；`MATCH,DIRECT`
- 控制面：external-controller `127.0.0.1:9095`（切换 ClaudeExit 用 REST API，无需重启引擎）
- 节点：从 MonetaProxy/config.json 原样抄（anytls:8450 + vless reality:8451@154.53.75.226）

## 二、判定表（预期 | 实测 | 判定）

| # | 场景 | 命令 | 预期 | 实测 | 判定 |
|---|---|---|---|---|---|
| T1 | 域名裁判放行 | `dig @127.0.0.1 -p 1053 claude.ai A` | 198.18.x.x | `198.18.254.254` | ✅ |
| T2 | 零侵入 | `dig @127.0.0.1 -p 1053 example.com A` | 真实公网 IP | `104.20.23.154 / 172.66.147.243`（非 198.18） | ✅ |
| T3 | 专属通道 | `curl -x http://127.0.0.1:7892 https://claude.ai` | 任意 HTTP 状态码 | `http_code=000`，TLS 握手 0.14s 被切（SSL_ERROR_SYSCALL）；明文:80 得本地 502 | ⚠️ 部分（见下） |
| T4 | 零影响 | 直连 curl example.com（无代理） | 200 | 200（全程多次） | ✅ |
| T5 | fail-closed | 节点置死 + 重启引擎（3 种死法） | 彻底失败且失败得干净 | 详下表 | ✅ |
| T6 | 主动拦截 vs 黑洞 | ClaudeExit→REJECT 计时 vs T5 计时 | 显式秒回 vs 节点死等 | 0.01s vs 1.8–5.0s | ✅ |
| T7 | 二次实例互不干扰 | `curl -x 127.0.0.1:7890 https://example.com`（用户 Clash） | 200 照旧 | 全程 200（每阶段前后），claude.ai 403（HTTP 正常应答） | ✅ |

T3 差异原因分析（关键教训，非裁判层缺陷）：
- 引擎行为全对：日志确认 `[TCP] ... --> claude.ai:443 match DomainSuffix(claude.ai) using ClaudeExit[anytls-node]`，同一隧道 example.com/ipinfo.io 均 200（隧道健康）
- 失败在**目标侧**：claude.ai（和 discord.com 对照同样被切）在 TLS 握手即 RST，来自隧道远端；本机 1053 DNS 与规则层无关。两个可用节点是同一台 VPS（154.53.75.226），其出口 IP 被 Claude/Cloudflare 边缘拒绝（TCP 通、ClientHello 后被切）；用户现有干净节点出口拿到 403，证明 claude 边缘服务本身正常
- vless 补充证据：切 vless 后日志显示 `154.53.75.226:8451 connect error: read tcp ...: connection reset by peer` —— **连隧道都被对端本地网络 RST**（reality 端口疑似被墙/干扰）
- 结论：域名裁判+专属通道**机制**成立（路由、DNS、切换全实证），但**出口 IP 质量是 T3 拿状态码的必要条件**——产品节点池必须含 Claude 友好 IP，且需健康探测针对 claude.ai 本身

## 三、T5/T6 时长对比表（fail-closed 灵敏度参数）

三种"节点死法"（引擎重启即模拟，每节点均实时观测 Probe verdict）：

| 死法 | 模拟故障 | 引擎判定全死用时（启动→verdict） | 客户端端到端失败用时 | 失败形态 |
|---|---|---|---|---|
| dead-a：127.0.0.1:9 | 本地连接即刻 RST | **≈0s**（首个 url-test 周期即标记 false） | 1.8–2.3s | 引擎主动断开，curl 得 SSL_ERROR_SYSCALL；底层 dial `connection refused` 瞬时，mihomo/anytls 在一次连接内重试约 8 次会话建立拉长到 ~2s |
| dead-b：154.53.75.226:9 | 远端 RST | ≈2s（首个探测周期内） | 3.3–5.0s | 同上（`dial tcp 154.53.75.226:9: connect: connection refused`） |
| dead-c：198.51.100.1:9 | **真黑洞**（SYN 静默丢弃） | **≈5s**（默认 dial 超时兜底） | **5.0s 整** | mihomo 自己 dial 超时后 RST 客户端连接；不干等到 curl 的 40s 上限 |
| T6 REJECT（live 引擎上切换） | 显式拦截策略 | — | **0.01s** | 本地秒断，干净 HTTP 层语义 |
| 对照：节点健康时 | — | — | 200 in 1.0s（example.com 经隧道） | — |

关键观测（产品参数）：
1. **探测判定足够快**：三种死法全部在首批 url-test 周期内判死（RST 型 ≈0–2s，黑洞型 ≈5s=dial 超时），interval 30s 在"启动即死"场景下不是瓶颈；**但运行中从活→死:** 判定受 interval 30s 限制——url-test 只在周期边界重探（本实验未单独量测活→死切换滞后，产品需在源码层确认 interval 与 IdleTimeout 交互），最坏滞后 ≈30s
2. **DNS 语义与 TCP 语义解耦（核心产品语义）**：节点全死后 `dig claude.ai` **仍返回 fake-ip**（缓存类 198.18.254.254 照常、**全新子域 en.claude.ai 照常新签发 198.18.0.4**）——mihomo 的 fake-ip 是本地 DNS 行为，不感知出口健康。即"通路死了 DNS 还在指路"，断链只发生在 TCP 层
3. 失败"干净"程度：三种死法失败后无任何残留连接泄漏，curl 均以 exit 35（SSL 层断）收场，无 30s/60s 悬挂

## 四、产品视角发现清单（≤6）

1. **fake-ip + REJECT 组合足以满足"点一次设置就断 Claude 全链路"的域名平面需求，但断的语义要定准**：切 REJECT = TCP 层 0.01s 秒回（体验最好）；节点死 = fake-ip 仍在发（dig 照常回答）但 TCP 层必死。DNS 裁判层（URL 过滤的 DNS 面）**不感知出口健康**——产品的"断"必须定义在 **TCP/代理规则面**（ClaudeExit→REJECT），不能定义为"DNS 不再应答"（mihomo 天然不提供该语义，须上层在出口死亡时才注入 REJECT 规则/切换策略组来实现）
2. **与 PoC-1 pf 层拼装**：cookiecrumbly 架构 = PoC-1 pf 地址平面（拦直连任何进程 + UID 豁免放行裁判进程）Facade 在前，PoC-2 域名裁判（本实验）在后：进程流量被 pf 豁免喂给引擎 mixed 口 → 引擎按域名分流（claude→专属出口，其余→DIRECT 出本机）→ 专出口靠健康探测 fail-closed（T5 语义：不通即断）。两层各管一平面，接口就是"一个 mixed 端口 + 一个 engine 豁免 UID"
3. **专属出口 IP 会被 Claude 边缘选择性封禁**（T3 主教训）：渠道 IP 质量是"通道可用"的一等公民变量——anytls 节点 TLS 握手即被 claude.ai 切、discord.com 同被切、example.com 无事；健康探测 URL 若用 gstatic 只测代理通，**测不出"目标拒绝你"**。产品健康探测应对 claude.ai 本身（如 HEAD /）判活，节点池要可换
4. **隧道自己也可能是最脆弱的一环**：vless reality 端口 8451 被对端网关 RST（隧道未建立），而 anytls 8450 隧道健康——同一台 VPS 两种协议命运不同；引擎 fail-closed 对"隧道死"与"出口拒绝"两种失败给出的都干净（≤5s），产品日志必须区分两类 dial error 归因（mihomo warning 里已天然区分）
5. **fake-ip 白名单模式是零侵入 DNS 的正解**：`fake-ip-filter-mode: whitelist`（仅 claude 系入白名单）比常见黑名单模式更贴合"最小命中面"——非白名单域名**完全不经 fakeip 池**，直接真实解析（T2 铁证）；且引擎不接管系统 DNS，用户环境全程无感（T4/T7 双料零损伤）
6. **REJECT 秒回 vs 死亡滞后的体验梯度**已量化（0.01s / ~2s / 5s），可作为产品"断流提示"的分级阈值依据；另发现 mihomo/anytls 会在单连接内重试会话建立把瞬时错误拉长到 ~2s——若产品要"更快的断"，可在 ClaudeExit 层直接用 REJECT 兜底而非等服务面判死

## 五、可复现的资产

- `run.sh`（默认起 live 配置）· `stop.sh`（杀进程+校验端口释放）
- `configs/config.yaml`（live 通道）· `config-dead-a/b/c.yaml`（三种死法）· `config.json`（sing-box 弃案证据）
- `evidence/T1..T7 *.txt` 全部原始输出；引擎日志在 `work/mihomo.log`（末次 live 版残留）
