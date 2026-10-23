# 实验 0005 · PoC-5（ROADMAP P1a）：TUN 窄通道系统级接管

**日期**：2026-10-24 ｜ **执行**：主会全程（agent 额度用尽后自建；root 步骤经所有者授权密码用 `sudo -S` 无人值守执行）
**想验证的一件事**：不设任何代理变量的**裸进程**（自查 DNS、自连 IP 的 curl/wget/任意程序），是否也会被域名裁判管辖——即"TUN 窄通道接管"是否成立。

## 方法

```
系统 DNS -> 127.0.0.1:53  --pf rdr--> 127.0.0.1:1053 (实验引擎)
  -> claude 系发 fake-ip 198.18.254.254（白名单外真实解析）
  -> 仅 198.18.0.0/16 窄路由进 utun6（绝不抢默认路由）
  -> 引擎规则 --> ClaudeExit(anytls) / REJECT
```

**环境适配（本轮遇到的两个现实变量）**：
1. 用户的 Clash 根服务（pid 1004）占着 `*:53`（UDP+TCP），任何本机 IP:53 都绑不上 → 放弃"引擎直接听 53"，改为 **pf rdr 把 53 重定向到 1053**（`rdr pass on lo0 … port 53 -> 127.0.0.1 port 1053`）
2. pf 已处于 Enabled（其他软件先前启用）→ 脚本记录状态、只叠加 rdr，尾声按备份恢复配置且**不**误关

**反冒认设计（金丝雀）**：Clash 的 DNS 也发 fake-ip（198.18.0.x），普通查询分不清谁答的；配置里加 `hosts: canary.monetafw.internal -> 198.18.254.251`，系统解析返回该值才证明**应答者是我们引擎**。

## 判定表

| # | 场景 | 预期 | 实测 | 判定 |
|---|---|---|---|---|
| A0 | 引擎（root）+ utun 出现 | 失败即回滚 | utun6，地址 198.18.0.1；窄路由回读命中 | ✅ |
| A1 | 引擎 DNS 白名单 | claude=fake-ip / 其他=真实 | claude=198.18.254.254；example.org=172.66.157.237 | ✅ |
| B0 | rdr 装载 | nat 表含 1053 | 2 条 rdr（udp+tcp） | ✅ |
| B1 | 系统解析切换（含金丝雀） | canary=198.18.254.251 | try1 即命中：canary=198.18.254.251 / claude=fake / example.org=真实 | ✅ |
| **J1** | 裸 curl claude.ai 被管辖 | fake-ip + judge 命中；其他域零侵入 | resolve=198.18.254.254；引擎日志 `match …ClaudeExit` ×1；example.org/example.com 均 200；**AAAA 空（无 v6 泄漏）** | ✅ |
| **J2** | 杀出口→看门注入 REJECT→裸 curl 快断 | ≤45s 注入；快失败 | kill 01:42:22 → **INJECT 01:42:57（35s）**；REJECT 态裸 curl `elapsed=0.000s`（瞬时）；REST select=REJECT | ✅ |
| **J3** | 复活→解除→复通 | RELEASE 后 200 | RELEASE 01:43:28（+31s）；probe 200；ClaudeExit=anytls-node | ✅ |
| R | 回滚 | 零残留、DNS 原样 | DNS 还原为 Empty/DHCP、引擎 0 残、引擎日志归档、rdr 撤销（pf.conf 恢复）、路由回 en0、网络 4+1 验全 PASS | ✅（端口检查误报见修正） |

## 定论

1. **TUN 窄通道接管成立**：裸进程（无代理变量、自解析自连 IP）被域名裁判完整管辖——产品"点一次设置，任何程序都断/放"的最后一环闭合
2. **零侵入再次坐实**：白名单外域名真实解析（example.org/com 200）；**claude 系 AAAA 返回空**，v6 泄漏路径在本机制下不成立
3. **接管不必独占 53**：当其他软件已占用 53，pf rdr（lo0 53→1053）是一种零冲突接管方式——同时适用于"用户已有本地 DNS 服务"的产品部署场景
4. **看门在 TUN 路径上同样工作**：注入 35s、切断瞬时、解除 31s（15s 周期×2 的自然结果）
5. **可复用验证技巧**：金丝雀域名（hosts 注入）用于证明"这份 DNS 应答确实来自我们"——多解析器共存环境下必备

## 修正记录

| 现象 | 根因 | 修复 |
|---|---|---|
| 首跑 PHASE-0 直接 FAIL（udp:53 occupied） | 环境变化：用户 Clash 中途启用 DNS/*:53 与 pf | 改为 rdr 方案；pf 状态改为"记录并保留"（不误关） |
| rdr 装载语法错 ×2 | pf 语法要求：options → normalization(scrub) → **translation(rdr)** → filtering；rdr 插错位置，且插在两条 scrub 之间也错 | 按 `scrub` 行数切分，rdr 插在 scrub 段之后、anchor/filter 之前；装载前 `pfctl -nf` 预检 |
| 首检 127.0.0.2 绑定失败 | macOS 无 lo0 别名时 127.0.0.2 不可绑（P20） | 改 127.0.0.1 + rdr；别名方案放弃 |
| 回滚报"端口占用"误报 | 检查列表里还带着 53（属用户 Clash） | 检查范围收窄为实验自有端口 7892/9095/1053 |
| route delete 报 not in table | 先杀引擎 → utun 消失 → 路由同时消失 | 调整顺序：先删路由再杀引擎 |

## 证据

- `claudeguard-test/poc4/log.txt`（全量时间线：rdr/金丝雀/判定/回滚）
- `claudeguard-test/poc4/engine-mihomo.log`（judge 命中原文、DNS debug）
- `claudeguard-test/poc4/dns-before.txt`、`scutil-dns-before.txt`、`route-19818-before.txt`（环境取证）
- `claudeguard-test/poc4/run-tun.sh`（终态脚本，含上述全部修复）

**遗留**：机器零残留；pf 保持运行前状态（Enabled，配置已还原）；无系统用户/无 hosts 改动。
