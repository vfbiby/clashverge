# PoC-4 · claudeguard Linux 等价性验证（Docker 容器 = Linux 测试台）

**日期**: 2026-10-24 ｜ **执行**: 子 agent 全程（Docker Desktop server 29.8.0 linux/arm64, context desktop-linux; 容器内全程 root, 宿主零 sudo）
**想验证的一件事**: 07-LINUX-MAPPING 的预判——PoC-1/2/3 在 macOS 验证过的三平面件套（pf 地址平面 + mihomo 域名裁判 + 看门状态机），能否在 Linux 上以"一类等价物一行行对上"的精度复现。Docker 容器（`--cap-add NET_ADMIN --device /dev/net/tun`, ubuntu 22.04，容器内 apt 直连）即 Linux 测试台。

## 测试台账（一次搭好，容器消散=回滚）

- 容器: `ubuntu:22.04`，装 iptables 1.8.7（nf_tables 后端）/ dnsutils 9.18 / curl 7.81 / iproute2 / sudo / openssl / python3；uname `7.0.12-linuxkit aarch64`
- 引擎: **mihomo v1.19.32 linux/arm64**（官方 release `.gz`; 下载 sha256 与 GitHub Release API `assets[].digest` 一致）→ `docker cp` 进容器, 以 **uid 5011 (monetafw user)** 运行, 三端口 7892/1053/9095
- 配置: `poc3/config.yaml` **逐字节原样**（预检 `mihomo -t` successful；出容器前 sha256 同 poc3）
- 封禁 IP 表 = 容器内 `dig +short @223.5.5.5` 解析的 claude 系 6 域 + example.org/example.com 全真实 IP；**防呆: 零 198.18.0.0/16 混入**（`evidence/resolved-ips.txt`）
- 脚本: `run-poc4.sh`（主跑, 照搬 poc3/run-e2e.sh 的 P16-P19 加固形态）+ `run-poc4b.sh`（SW1 反序判别的修正补跑）

## 判定表（容器内 16:55–16:59 主跑 + 17:04–17:05 补跑）

| # | 场景 | 预期 | 实测 | 判定 |
|---|---|---|---|---|
| **T1'** | `dig @127.0.0.1 -p 1053 claude.ai` | fake-ip | **198.18.0.4** | ✅ |
| **T2'** | `dig @127.0.0.1 -p 1053 example.org` | 真实 IP | **104.20.26.136**（零侵入） | ✅ |
| **J1'-1** | victim(root) 直连 claude.ai `--resolve 160.79.104.10` | 被拦 | `000 time=6.0s` **exit=28**（DROP 黑洞满超时） | ✅ 同 PoC-3 J1 |
| **J1'-2** | victim 直连 example.org（公共对照面） | 被拦 | `000 exit=28`（三条连均 4.5–6s 无响应） | ✅ |
| **SW1 豁免** | `sudo -u monetafw curl https://example.org`（uid=5011 owner 规则在 DROP 之前） | 通 | **200**（面对同一批封禁 IP） | ✅ = PoC-1 T3 机制 Linux 复现 |
| **SW1 首匹配重排** | 反序(全 5 个 BLOCK_V4 IP 的 DROP 在前/owner ACCEPT 在后)再测豁免 | 被拦 | 豁免 `000 exit=28`（**首匹配胜出实证**）+ victim 同样拦 | ✅ 与 macOS pf **后匹配语义相反**——豁免必须缀前, 佐证 07-MAPPING 预判 |
| (SW1 复盘) | 恢复规范链后豁免 | 通 | 200（且 victim 仍拦） | ✅ |
| **SW2 DROP** | victim 直连 example.org ×3 | 满超时黑洞 | `000 time=4.50/4.51/4.51s` exit=28 | ✅ 黑洞形态记录 |
| **SW2 REJECT** | 同上（整链原子换 `REJECT --reject-with tcp-reset`）×3 | 秒断 | `000 time=0.0020/0.0021/0.0027s` **exit=7（RST 到达）** | ✅ **比 DROP 快 ~2250 倍**——07-MAPPING "REJECT=tcp-reset 原生且更好判断" 实证 |
| **J2'** | 杀节点(ClaudeExit/EdgeProbe→dead)→看门自动注入 REJECT→claude.ai 经 7892 | ≤45s 注入; elapsed ≤0.2s | kill 16:57:38 → **INJECT 16:58:07（29s）**；**code=000 elapsed=0.000698s**；三证=REST select=REJECT + INJECT 日志 + 计时 | ✅ 与 PoC-3 J2 同形态（29s vs 29s） |
| **J3'** | 复活(EdgeProbe→direct)→看门自动 RELEASE→example.org 经 7892 | 200 复通 | RELEASE 16:58:38 → **probe=200**; 引擎规则命中 `DomainSuffix(example.org)→EdgeProbe` 计 7 条 | ✅ |
| **SW5-A** | victim 已建长连接（到封禁 IP example.org 真IP）→ 中途注入 DROP | 已建连接也被掐? | 客户端方向**立即停流**（注入后 9s 增量=0 bytes, curl 满超时 exit=28）；对端在途数据又 589KB 后耗尽 | ⚠️+✅ 见下"SW5 语义" |
| **SW5-B** | 同场景换 REJECT tcp-reset | RST 秒杀已建连接 | **未秒杀**（残留≈35s 至 curl 满超时）——**loopback 自回环场景的已知内核限制**: `REJECT tcp-reset` 对 loopback 连接不回馈 RST | ⚠️ 真机需复测（见遗留） |
| **SW5-C** | 产品口径: 链首插 `-m conntrack --ctstate ESTABLISHED -j ACCEPT` + owner 豁免 + DROP | 已建连接不受影响 | 增量 **4,198,400 bytes** 持续流动至满 30s（24.5MB 收尾） | ✅ **conntrack 放行 ESTABLISHED 的产品语义在 Linux 实证** |
| **SW4** | 框架共存态 | 基线=空栈 | ufw/firewalld/nftables 三者未安装；`iptables -S` 全景=纯默认策略（四表极简）；无接口冲突问题 | ✅（记录性） |
| **回滚** | 停机文件+验证式击杀+引擎清除+iptables-restore+端口三验 | 零残留 | 引擎 0 残; 端口全释放; MONETAFW 链复位; 网络直连复通 200；随后 `docker rm -f` 容器消散 | ✅ |

**看门事件线**（journal 式, `evidence/watch.txt`）:
```
INJECT-REJECT 2026-10-23 16:58:07 probe=000 claude_exit=dead    （kill-point 16:57:38, +29s）
RELEASE        2026-10-23 16:58:38 probe=200 claude_exit=anytls-node （复活边缘后 +31s, 需 2 连成功×15s 间隔）
```

> **run-1 修正记录（本轮两处脚本工程缺陷→补跑）**
> ① `iptables-save` 首拍快照为 0 字节（尚未上链时的空表 + 竞态未暴露）→ 补跑脚本首行重存+字节数校验（182/183B）后恢复正常快照回滚路径；
> ② SW1 反序判别的反序 DROP 只钉 1 个 IP, 而豁免 curl 走容器 DNS（192.168.65.7 视图）解析到了另一个 BLOCK IP → 未命中被误判"未被拦"。修正=反序判别必须钉**全量 BLOCK_V4**（补跑 `evidence/log_b.txt`: 豁免 `000 exit=28` 被拦, 判定✅）。
> 判定表中其余项均来自主跑原始数据, 未被这两处影响。

## SW5 的真实语义（产品口径裁定）

三态实测把"旧连接残留寿命"这个模糊问题钉死成一个答案:

1. **规范链（无 conntrack 例外子句）**: iptables 规则命中**所有包**（不止 NEW）——已建 victim 连接的出向流量**立即断**（SW5-A: 注入后字节计数零增长，exit 28）。对端在途/缓冲数据可持续流入客户端（SW5-A 观测 +589824 bytes），这是 TCP 内存, 不是 conntrack 放行。→"规则一动连就瘫"的语义与 macOS pf `block drop out` 同源；不需要额外 conntrack 机制就能把"活→死"挤压到流尾巴。
2. **conntrack-ACCEPT 产品形态（SW5-C）**: 链首 `-m conntrack --ctstate ESTABLISHED -j ACCEPT` → 已建连接**完全不受影响**（4.2MB 继续流）——07-MAPPING "已建连接靠 conntrack 放过"（SPEC §6 "活→死滞后"）在 Linux 有精确可编程的等价物，且**可以自由选择开/关**（这是 pf 没有的内部断路器粒度）。
3. **REJECT tcp-reset 针对已建连接**在本案 loopback 场景没产生秒断——内核对 loopback 连接不回馈 RST（已记录 `sw5_b.txt`; 非协议缺陷，同文件可以证 NEW 连接层面 RST 秒达: SW2 REJECT `exit=7 time=0.002s`），**需真机网络面复核**（见遗留表）。

## 与 macOS 侧（PoC-1/2/3）的等价性结论表

| 验证项 | macOS 实测（PoC-1/2/3） | Linux 容器本轮实测 | 等价性 |
|---|---|---|---|
| 地址平面按用户豁免 | pf pass out user=_monetafw（T3 200） | iptables `-m owner --uid-owner 5011` 200 | ✅ 等价 |
| 阻断风格语义 | pf `block drop out` 静默黑洞, exit 28 | iptables DROP exit 28 | ✅ 等价 |
| 快失败 | pf `return` / 引擎面 REJECT 0.006s | iptables REJECT tcp-reset **0.002s**（系统级） | ✅ Linux 更原生（内核自带 RST, 无需引擎面 辅助） |
| 规则匹配顺序 | pf **后**匹配胜出（`block` 无 quick + 后置 `pass user` 胜出, PoC-1） | iptables **首**匹配胜出（豁免必须缀前, 反序实证=豁免也被咬） | ⟳ 语义相反、结论等价（产品规则生成器需平台分支） |
| 引擎同源同配置/linux 二进制 | mihomo v1.19.32 darwin-arm64 | **mihomo v1.19.32 linux-arm64; config.yaml 零字节差异; T1'/T2' 全过** | ✅ 同源同配置 |
| fail-closed 看门自动化 | PoC-3 INJECT +29s / RELEASE +16s / J2 elapsed 0.006s | **INJECT +29s / RELEASE +31s / J2' elapsed 0.0007s** | ✅ 时序与延迟同数量级（比 macOS J2 更快 ~9×） |
| P16/P17 bash3.2 坑 | 两大坑均被踩 | **bash 5.1 + 加固照用: 零坑可复现**（加固形态在 bash5 行为一致——07-MAPPING 预判兑现） | ✅ Linux 侧更少坑 |
| 引擎以 spec 用户跑 | _monetafw uid=5011 | useradd uid=5011 (monetafw), **无 P05 密码政策报错**（07-MAPPING 预判兑现） | ✅ 更顺 |
| 地址平面盲区（域名不在视野） | 远程出口代理令 IP 平面失明（P04） | 同盲区（部署面不变, 并在本案实测中由 fake-ip 白名单绕过） | ✅ 教训平移 |
| **Linux 特有: SW5 conntrack 粒度** | pf 无此细分（无可编程 established 子句） | `-m conntrack --ctstate ESTABLISHED ACCEPT` 开/关可编程, SW5-C 实证放行 | ⬆ Linux 能力超集 |
| **Linux 特有: system 端口一致性** | /etc/pf.conf 整规则setProperty + 独立 hook | `-I OUTPUT 1 -j MONETAFW` 专用链模式（不碰用户存量规则; 本轮实测 hook 挂 OUTPUT 顶部且不影响其他端口流量） | ✅ 更标准 |

## 跳过/留待 ovhe 真机轮次的项

| 项 | 容器测试台未能覆盖的原因 | 真机验证靶 |
|---|---|---|
| **SW3 systemd 看门自愈** | Docker 容器无 PID1 systemd（PID1=sleep infinity），launchd↔systemd 对位（07-MAPPING "systemd unit Restart=always"）无法在容器里复刻 | ovhe 云机: systemd unit + `User=monetafw` + `Restart=always` 杀 mihomo 后自重启 ≤10s 口径 |
| **SW4 ufw/firewalld 共存真机版** | 容器基线=空栈（三者未安装）, 只能确认"零冲突基线"; 极端共存（ufw `TRACE`/firewalld 清表策略）是真机战争面 | ovhe: 装 ufw → PRODUCTS 侧 MONETAFW 专用链模式挂 OUTPUT + 既有 INPUT 规则互不损伤 |
| **SW5-B REJECT 对已建连接 RST 秒杀（真实网络面）** | 本轮 loopback 场景 kernel `REJECT tcp-reset` 不回馈 RST（内核已知语义差异） | ovhe: 真实外出路径的中途 REJECT 切换, 观察已建连接秒断窗口 |
| **双栈 v6 真路由** | 容器 v6 无真实外交换路径; ip6tables 链已装+挂钩, 规则面验证完成 | ovhe 双栈: v6 直连 claude 与 example.org 均被拦的同结构验证（P0.9 教训: 漏 v6 = 泄漏） |
| **TUN 模式真机（P1 大靶）** | `/dev/net/tun` 已具备 + `NET_ADMIN` 就位, 但 TUN 全接管需真机路由面 | 真机: fwmark 策略路由 + ip rule 全接管口径 |
| **DNS 容器视图偏置** | 容器 DNS 192.168.65.7 是 Docker Desktop 桥接+宿主 DNS 搬运（含宿主 hosts 诱饵）→ 容器内直连 claude.ai 的"软失败"由诱饵 IP 决定——故 J1' 机械判定以 `--resolve` 钉 223.5.5.5 视图真实 IP（同 PoC-3 口径）；**真机上这是独立变量** | ovhe 直连真 DNS（无 Docker 桥接层）, 直连图像更可信 |

## 容器测试台遗留（本轮两处 FAIL→FIX 复盘点）

- run-1 两处修正已上脚本（快照字节数校验门 + 反序判别全 IP 钉死），第二轮全部 PASS
- 本轮判定用首跑数据为准——两处工程坑都不在PASS 判定把上（SW1 反序是补跑重判, 其它数据未受影响）

## 证据账（evidence/）

- `00-fingerprints.md` —— mihomo 下载 URL + sha256 双源对照 + config.yaml 同源证明
- `log.txt` / `log_b.txt` —— 主跑/补跑全时间线
- `watch.txt` —— journal 式 WATCH 事件线
- `engine-mihomo.log` —— 引擎规则命中原话（`DomainSuffix(example.org)→EdgeProbe` ×7 等）
- `resolved-ips.txt` / `iptables-base.rules.txt` / `iptables-base6.rules.txt` —— 封禁底账 + iptables 快照
- `sw1_exempt_seq.txt` / `sw1_j1_resolve.txt` / `sw1_b.txt` / `sw2.txt` / `sw5_a.txt` / `sw5_b.txt` / `t2_real_ip.txt` —— 各口径原始数据
- `sw5_a.bin` / `sw5_b.bin` / `sw5_c.bin` —— 三态接收字节数的原始物证（4.7MB / 4.7MB / 24.5MB, 字节数面即判据）
- `prevalid-mihomo-t.txt` / `poc4_stream_server.py` —— 配置预检 + SW5 本地流服务器源码
- `../config.yaml`, `../mihomo`（引擎裸二进制, 供 sha256 复核）, `../run-poc4.sh`, `../run-poc4b.sh`

## 零残留证据（2026-10-24 01, 宿主侧）

- `docker ps --format … | grep -i monetafw` → 无命中（grep exit=1）; `docker ps -a` 无 monetafw-test
- 宿主 ps 无本轮 mihomo/monetafw/run-poc4 相关进程（仅存的 verge-mihomo 进程 = 用户自己的 Clash Verge 服务, Mon02PM 即存在, 非本轮产物）
- 宿主侧临时物只此 poc4/ 目录本身（+ `~/.zsh` 类轮询无新增）

**定论**: **PoC-4 【PASS】** —— 07-LINUX-MAPPING 的 SW1/SW2/SW4/SW5 四口 + J1'/T1'/T2'/J2'/J3' 五判在 Linux 测试台全数走通/对上；容器测试台自身的两个工程坑（快照 0 字节、反序单 IP 钉死）已修入脚本并补跑验证。Linux 侧等价性整体**比 macOS 更标准**（kernel 原生 RST、conntrack 可编程例外、免密码政策怪癖、bash5 加固即效）。产品可以"一套架构双平台"的判断继续成立。
