# 实验 0002 · PoC-2：域名平面关键裁判（DNS 引擎 + fail-closed + 专属通道）

**日期**：2026-10-20 ｜ **执行**：子 agent 全程（普通用户态、零 root）→ 主会抽查复核
**想验证的一件事**：PoC-1 TEST2 定立的架构假设——域名裁判（DNS/fake-ip + 规则面）能否在"零侵入用户网络"的前提下对 claude 系域名实现：放行→专属通道、判死→干净失败。

## 方法（引擎选型 → 配置 → 测试矩阵）

- **选型**（表见 `poc2/REPORT.md` §一）：MonetaProxy sing-box 因无 `dns` inbound 被 `check` 拒（P14）；服务端两个内核根部权限不可用（P11）；**胜者 = `/Applications/Clash Verge.app` 内的 mihomo v1.19.32**（用户态可执行、功能全套：fake-ip whitelist / mixed / url-test / REJECT / REST 切组）
- 配置要件：mixed 7892 + DNS 1053 + `fake-ip-filter-mode: whitelist`（白名单 = claude 系 5 域）+ ClaudeExit（select: anytls/vless/REJECT/DIRECT）+ Probe（url-test, 30s）+ 置顶规则 5 条 DOMAIN-SUFFIX → ClaudeExit、`IP-CIDR 198.18.0.0/16 → ClaudeExit`、MATCH DIRECT
- 节点：从 MonetaProxy/config.json 抄（154.53.75.226 anytls:8450 / vless reality:8451）

## 判定表

| # | 场景 | 预期 | 实测 | 判定 |
|---|---|---|---|---|
| T1 | 裁判放行：`dig @127.0.0.1 -p 1053 claude.ai` | fake-ip | 198.18.254.254 | ✅ |
| T2 | 零侵入：`dig … example.com` | 真实 IP | 104.20.23.154 / 172.66.147.243 | ✅ 白名单外完全不经 fakeip 池 |
| T3 | 专属通道：curl 经 7892 → claude.ai | 任意 HTTP 码 | `000`——TLS 握手 0.14s 被切 | ⚠️ 见发现③ |
| T4 | 零影响：直连 curl example.com | 200 | 200（全程多次） | ✅ |
| T5 | fail-closed：三种节点死法 | 干净失败 | 见时长表 | ✅ |
| T6 | 显式拦截 vs 黑洞计时 | 秒回 vs 死等 | **0.01s** vs 1.8–5.0s | ✅ |
| T7 | 二实例共存：用户 Clash 7890 照常 | 200 | 全程 200 | ✅ |

## fail-closed 时长表（产品参数，SPEC §6 引用）

| 死法 | 模拟 | 引擎判死 | 客户端端到端失败 | 形态 |
|---|---|---|---|---|
| dead-a 127.0.0.1:9 | 本地 RST | ≈0s | 1.8–2.3s | 干净，SSL_ERROR_SYSCALL |
| dead-b 154.53.75.226:9 | 远端 RST | ≈2s | 3.3–5.0s | 干净 |
| dead-c 198.51.100.1:9 | 真黑洞（SYN 丢） | ≈5s（dial 兜底） | 5.0s | 干净，无悬挂 |
| REJECT 切换 | 显式拦截 | — | **0.01s** | 本地秒断 |

## 定论（三条核心产品语义）

1. **fake-ip 不感知出口健康**：全部节点死透后 `dig claude.ai` 照发 fake-ip（全新子域 en.claude.ai 也新签 198.18.0.4）——"断"必须定义在 TCP/规则面，由看门注入 REJECT（→ ADR-0003）
2. **健康探测必须对目标域本身**：T3 中隧道完全健康（example.com 经隧道 200），claude.ai 在 TLS 握手被边缘切——两个节点（同一 VPS）出口 IP 被 Claude/Cloudflare 边缘拒绝，vless reality 端口更是被对端本地网络 RST（隧道层都死）。通用探测测不出"目标拒绝你"（→ ADR-0004）；并行对照：用户自己的 7890 拿 claude.ai 403（HTTP 正常应答，边缘服务本身活着）
3. **引擎能力全部实证**：路由/DNS/热切换/判死/互不干扰五项全过，Engine 作为产品"大脑"的可行性成立；出口 IP 质量是"通道可用"的一等公民变量（节点池必须含 Claude 友好 IP）

## 修正记录

- T3 预期"任意 HTTP 状态码"未达成——但**不是裁判层缺陷**：引擎日志确认 `--> claude.ai:443 match DomainSuffix using ClaudeExit[anytls]` 规则全对，失败在目标侧 TLS 指纹拒绝。把"通道放行成功"的验收口径细化为两级：规则面命中（必达）+ 边缘握手成功（依赖出口质量）。

## 证据

- `claudeguard-test/poc2/REPORT.md`（全量判定与选型过程）
- `claudeguard-test/poc2/evidence/T1..T7*.txt`（原始输出，T6 三连 0.01s 实录）
- `claudeguard-test/poc2/configs/`（live + 三种死法配置）、`work/mihomo.log`（引擎侧日志）
- `claudeguard-test/poc2/run.sh` / `stop.sh`（可复现启停）

**遗留**：TUN 系统级接管未做（需 root，列 ROADMAP P1）；exit 实验后进程杀净、端口 7892/1053/9095 释放经 lsof 复核。
