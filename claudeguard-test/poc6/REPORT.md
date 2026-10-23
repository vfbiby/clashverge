# PoC-6 · claudeguard 剩余 5 项在真机 Linux（uk 生产机）上的验证

**日期**: 2026-10-23 ｜ **靶机**: `root@57.129.160.113`（`vps-7aaa3e0d`，Ubuntu 26.04 / kernel 7.0.0-28 / systemd 259 / iptables-nft 1.8.11 / ufw 0.36.2 已装但 inactive / 有全局 IPv6 / `/dev/net/tun` 可用 / 无 docker）
**执行**: 子 agent 全程；所有实验在 `netns cgpoc` 内，systemd 项用 `/run/systemd/system` 瞬时 unit
**铁律**: 生产栈（`mtcopy-gateway` / `mtcopy-platform` / `nginx`）全程零停机、零重启、零配置改动

---

## 0. 判定摘要（先给结论）

| # | 项 | 判定 | 一句话结论 |
|---|---|---|---|
| **SW3** | systemd 看门自愈 | ✅ **PASS** | `kill -9` 后 **2.23s** 自动重启（NRestarts 0→1，journal 有 `Scheduled restart job`）；`systemctl stop` 后不再拉起；**停机文件在 `Restart=always` 下单独无效（exit 0 也会被拉起），加 `RestartPreventExitStatus=0` 后成立** |
| **SW4'** | ufw 共存 | ✅ **PASS** | 本发行版 `MANAGE_BUILTINS=no`，ufw 的 `reload / disable / enable / reset / ufw-init stop|start` **全部不会碰外部链**；我们的 iptables 专用链与独立 nft 表都全程存活。**但优先级语义相反**：iptables 链首 `ACCEPT` 可覆盖 ufw 的 DROP，nft 独立表 `accept` **不能**（见 §5 产品建议） |
| **SW5-B'** | REJECT tcp-reset vs 已建连接（真网络面） | ✅ **PASS** | 已建长连接插入 REJECT 后 **253ms 内 `ConnectionResetError`（errno 104）**；1MB 限速下载中途插入 **42ms 后 curl (56) Recv failure**。对照组 DROP：连接悬挂不 RST，只能等超时。**推翻了 PoC-4 容器 loopback 场景"REJECT 打不死已建连接"的结论——那是回环限制，不是语义** |
| **V6** | 真路由双栈（ULA veth） | ✅ **PASS** | 无 v6 规则时 v6 流量 **100% 直通**（root/nobody 均 200 = 泄漏路径实证）；`ip6tables OUTPUT -d … -j DROP` 生效；`-m owner --uid-owner` 豁免在 v6 与 v4 **完全同构**（豁免 root 200 / nobody 仍拦） |
| **TUN** | Linux 窄通道接管 | ✅ **PASS** | ns 内裸 curl（无代理 env）解析得 fake-ip **198.18.0.4** → TUN → 引擎日志 `match DomainSuffix(claude.ai) using ClaudeExit`；白名单外 `example.org` 真实解析 + 200（零侵入）；`AAAA` 为空（P20 跨平台复核）；看门 **33.7s INJECT**、裸 curl **36ms 失败**、**30.6s RELEASE**、复通 |

**总体**: **5/5 全过**（SW4 另得 3 条产品级判别，见 §5）。

---

## 1. 环境与实验台

### 1.1 靶机基线（实验前，`evidence/00-baseline.txt`）

```
mtcopy-gateway=active  mtcopy-platform=active  nginx=active
curl 127.0.0.1:80 = 200
ufw status = inactive
iptables-save = 空 (0B)   ip6tables-save = 空 (0B)   nft list ruleset = 空 (0B)
net.ipv4.ip_forward = 0
网卡 ens3: 2001:41d0:801:2000::1953/128 + default via 2001:41d0:801:2000::1
```

> 基线 netfilter 是**真正的零规则**（不只是默认策略）：`iptables-save`/`nft list ruleset` 都是 0 字节。这给收尾 diff 提供了最严格的判据——最终必须回到 0 字节。

### 1.2 隔离台（搭一次、全程复用）

```
netns cgpoc
  cgv0 (host) 10.233.6.1/30 + fd00:c6::1/64   ←veth→  cgv1 (ns) 10.233.6.2/30 + fd00:c6::2/64
  ns 默认路由 via 10.233.6.1；ns 专用 resolver=/etc/netns/cgpoc/resolv.conf（与宿主 /etc/resolv.conf 无关）
host 侧临时件（全部登记、全部删除）:
  sysctl net.ipv4.ip_forward=1
  iptables -t nat -A POSTROUTING -s 10.233.6.0/30 -m comment --comment cg-poc6-nat -j MASQUERADE
  （FORWARD 策略本就是 ACCEPT，未加任何 FORWARD 规则——最小改动）
```

ufw 实验额外做了一层保护：**用 mount namespace 把 `/etc/ufw` 私有副本 bind-mount 覆盖**，所以宿主 `/etc/ufw` 一个字节都没动（`sw4-etcufw-manifest-before/after` 完全相同）。

### 1.3 引擎二进制的真实情况（与任务书预置资产的偏差，必须说明）

任务书预置 `poc4/mihomo` 是 **linux-arm64**，而靶机是 **x86_64**——该文件**无法执行**。处理方式：

| 资产 | 来源 | sha256 | 核对 |
|---|---|---|---|
| `mihomo`（arm64，任务书指定） | 本机 poc4 | `c80df2ca…c3754` | 已上传并按 `sha256sum -c` 核对一致（仅存档，不能在本机运行） |
| `mihomo-amd64`（实际使用） | GitHub Release v1.19.32 `mihomo-linux-amd64-v1.19.32.gz` | `.gz` = `8451100836c9eda194331c2babfad490b2faf30cebc1a04b0e76fd8ac2d35d10`（与 Release API `assets[].digest` 一致）；解压后 `3122d100…626a8` | `./mihomo-amd64 -v` → `Mihomo Meta v1.19.32 linux amd64 with go1.26.8` |

配置 `config.yaml` / `config-tun.yaml` 上传 sha256 与本机逐字节一致（`7e62a00e…` / `ab0b4e77…`）。TUN 用新增的 `config-tun-ns.yaml`（相对 `config-tun.yaml` 仅改：`dns.listen 127.0.0.1:53`、`log-level info`、`tun.device cgtun0`、显式 `dns-hijack: any:53`）。

### 1.4 两处环境陷阱（会咬脚本，如实记录）

1. **Ubuntu 26.04 用 uutils coreutils**：`date +%s%3N` 不支持，会输出**纳秒**（`%3` 被忽略）。首轮 SW3 的 `elapsed=2102295377ms` 即此坑。修正为 `$(date +%s%N)/1000000` 后重跑，数据以重跑为准。→ 跨平台脚本不能假设 GNU date 的 `%N` 截断语义。
2. **`ip netns delete` 后 veth 对端未立即消失**：`cgv0` 会残留（含 10.233.6.0/30 路由），必须显式 `ip link del cgv0`。首轮收尾 diff 的 69 字节残差即此；补删后 diff=0B。

---

## 2. SW3 · systemd 看门自愈

**口径**：unit 落 `/run/systemd/system/claudeguard-watch-test.service`（tmpfs，重启不残留），`Restart=always` / `RestartSec=2`，`ExecStart=watch-stub.sh`（探活循环 + 停机文件形态，日志进 journal）。

| 子项 | 预期 | 实测 | 判定 |
|---|---|---|---|
| A: `kill -9` 主 PID | ≤5s 内自动重启，NRestarts+1 | `MainPID 1012104→1012199`，**2230ms**，NRestarts **0→1**；journal：`status=9/KILL` → `Scheduled restart job, restart counter is at 1` → `Started`（18:01:50→18:01:52） | ✅ |
| B: `systemctl stop` | 不再拉起 | 6s 后 `active=inactive`，`stub_procs=0`（注：stop 后 systemd 把 NRestarts 清零，不可用作判据） | ✅ |
| C1: 只 touch 停机文件（`Restart=always`） | ?（问题本身） | `active=activating`，NRestarts 0→2 —— **exit 0 仍被拉起，停机文件单独无效** | 事实确认 |
| C: 停机文件 + `RestartPreventExitStatus=0` | 优雅停机 | `active=inactive`，procs=0，NRestarts 0→0 | ✅ |
| D: `disable --now` + 删 unit + `daemon-reload` | 视图彻底移除 | `systemctl cat` 失败、unit 文件不存在、无残留进程 | ✅ |

**产品含义**：`Restart=always` 的看门机若带"停机文件"逃生门，必须配 `RestartPreventExitStatus=0`（或停机走 `systemctl stop`）；否则"文件存在 → exit 0"会被 systemd 当成一次普通退出而立刻拉起，形成**停机文件无效 + 重启循环**（C1 已实测出 `activating` 与计数上涨）。

**与 macOS launchd 对位**：launchd `KeepAlive=true` 同样不区分 exit 0；等价写法是 `KeepAlive` 字典的 `SuccessfulExit=false`。Linux 侧 `RestartPreventExitStatus=0` 更直白，且 `RestartSec` 即 `ThrottleInterval`。

---

## 3. SW4' · ufw 共存

**口径**：ns 内 ufw（`/etc/ufw` 私有副本），宿主 `/etc/ufw` 零改动；我们的两种机制：
- **M1 = iptables 专用链**：`CG-OUT`（`-m owner --uid-owner 0 -j ACCEPT` 后接封禁样本），`-I OUTPUT 1 -j CG-OUT`
- **M2 = 独立 nft 表**：`table inet cg`，`hook output priority filter -10`，`meta skuid 0 accept` + `reject with tcp reset`

### 3.1 存活矩阵（`30/32/33-sw4-*-run.txt`）

| 框架动作 | M1（iptables 链+钩子） | M2（独立 nft 表） | 语义复核 |
|---|---|---|---|
| `ufw reload` | 存活（链+钩子+规则） | 存活 | root 200 / nobody `000 rc=7` |
| `ufw --force disable` | 存活 | 存活 | 同上 |
| `ufw --force enable` | 存活 | 存活 | 同上 |
| `ufw --force reset` | 存活 | 存活 | 同上 |
| `ufw-init stop`（= `systemctl stop ufw`） | 存活 | 存活 | 同上 |
| `ufw-init start quiet`（= `systemctl start ufw`） | 存活 | 存活 | 同上 |
| `after.init` 钩子 | **确认被框架调用**（start/stop 各一次，见 `afterinit-calls.txt`），可在此重断言 | 不适用 | — |

**机制解释（源码 + 实测一致）**：`/lib/ufw/ufw-init-functions` 的 `ufw_stop()` 只在 `MANAGE_BUILTINS=yes` 时才 `flush_builtins`（`iptables -F`/`-X`）；本机 `/etc/default/ufw` 是 `MANAGE_BUILTINS=no`，于是 ufw 只删自己的 `ufw-*` 链（`delete_chains`），**不碰外部链**。实测 `iptables -F/-X` 在 ns 内确实能删掉 `CG-OUT`（手工验证过），所以"存活"是 ufw 的选择，不是内核限制。

⚠️ **风险边界**：若宿主把 `MANAGE_BUILTINS=yes`（或换成会 flush 的框架），M1 会在 ufw stop 时被连根拔掉 → 必须靠看门重断言兜底。这一情形本轮**未实测**（见 §8）。

### 3.2 共存语义（`30-sw4-run.txt` B 段）

| 场景 | 实测 | 判定 |
|---|---|---|
| ufw 活跃（default deny incoming）时 host→ns 监听 18081 | `000 rc=28`（被 ufw 拦） | ufw 自身策略在 ns 内真实生效 |
| ufw 活跃 + M1 + M2 共存时 root→被封目标 | `200 / 0.0013s`（owner 豁免） | 豁免不被框架破坏 |
| 同上 nobody→被封目标 | `000 / 0.00025s rc=7`（REJECT tcp-reset） | 封禁语义保持 |
| 共存态从 ns 出公网 `https://example.org` | `200` | 出网未被误伤 |

### 3.3 优先级对撞（决定性实验，`34-sw4-precedence-run.txt`）

设置 `ufw default deny outgoing`（与豁免正面冲突），再分别启用两种机制：

| 机制 | root（应豁免） | nobody（应拦） | 解释 |
|---|---|---|---|
| 仅 ufw 策略 | `000 rc=28`（测试服务）/ `000 rc=6`（出网） | — | 框架 policy 生效 |
| **M1** iptables 链置顶 + `uid 0 ACCEPT` | **200**（服务与出网都通） | `000 rc=7` | **iptables 的 ACCEPT 终止整表遍历 → 覆盖 ufw DROP** |
| **M2** 独立 nft 表 `skuid 0 accept` | **000 rc=28（仍被 ufw 拦）** | `000 rc=7` | **nft 的 accept 不终止同 hook 的其他基链 → ufw DROP 仍然胜出** |

这条把"选哪个"从口味问题变成了确定的语义选择：**要不要覆盖发行版框架策略**。

---

## 4. SW5-B' · REJECT tcp-reset vs 已建连接（真网络面）

**口径**：ns → host NAT → 公网，目标钉真 IP（`example.org=104.20.26.136`、`proof.ovh.net=141.95.207.211`）。两把尺子：① keepalive TLS 长连接探针（0.2s 发包节拍，区分 `ALIVE/HANG/ERROR`）；② `curl --limit-rate 20k` 的 1MB 下载流，中途插规则。

| 子项 | 动作 | 已建连接表现 | 插入→结束 | 新连接表现 |
|---|---|---|---|---|
| A | `REJECT --reject-with tcp-reset` + keepalive | **`ConnectionResetError: [Errno 104] Connection reset by peer`**（下一个出站包即触发） | **253ms**（受 0.2s 发包节拍约束） | — |
| B | REJECT + 1MB 限速下载中途 | **curl `(56) Recv failure: Connection reset by peer`** | **42ms** | — |
| C | 对照 `DROP` + 同一下载流 | 停流、无 RST、悬挂 | 25013ms（到 `-m 30` 上限） | — |
| D | 对照 `DROP` + keepalive | 10×`ALIVE` 后 **11×`HANG`（读超时）**，`RST=0`，连接不死 | 观察 15s 无 RST | — |
| E | 规则在位时的**新**连接 | — | — | DROP：`000 rc=28 / 8.00s`；REJECT：`000 rc=7 / 0.00015s`；清规则后 **200** |

**判定**：REJECT `tcp-reset` 在**真实出网路径**上对已建连接是**秒断**（客户端立刻拿到 RST），DROP 是**悬挂**（只能等应用超时）。清规则后新连接 200，无残留。

**推翻 PoC-4 的遗留结论**：容器里"`REJECT tcp-reset` 打不死已建连接（残留 35s）"是 **loopback 双端同机** 的产物——内核不会把 RST 回馈给本机回环连接。真机非回环路径上语义正常，且比 DROP 更符合产品"活→死要快"的要求（SW5-B' A/B 两项）。

---

## 5. V6 · 真路由双栈

**口径**：v6-only 服务 `[fd00:c6::1]:18090`（host 侧 cgv0），v4 对照 `10.233.6.1:18091`；ns 内 `ip6tables` / `iptables` 同构规则。

| 子项 | 场景 | 实测 | 判定 |
|---|---|---|---|
| A | **无任何 v6 规则** | root `200 / 0.005s`，nobody `200 / 0.001s` | **泄漏路径实证**：只做 v4 保护时 v6 完全绕过 |
| B | `ip6tables -A OUTPUT -d fd00:c6::1 -p tcp --dport 18090 -j DROP` | root `000 rc=28`，nobody `000 rc=28` | DROP 生效 |
| C | `ip6tables -I OUTPUT 1 -m owner --uid-owner 0 -j ACCEPT` | root **200 / 0.0018s**，nobody **`000 rc=28`** | v6 owner 豁免成立 |
| D | v4 同构对照（同一套规则换 iptables） | root 200 / nobody `000 rc=28` | **v4 ≡ v6** |

补充事实：ns 内 `ip -6 route show default` = **0 条**（只配了 ULA），所以本项证明的是"**同一套 v6 规则语义**"，**没有**覆盖真实公网 v6 出口（见 §8）。

---

## 6. TUN · Linux 窄通道接管

**口径**：ns 内 `mihomo -d tunwork -f config-tun-ns.yaml`；`auto-route:false` + 手工 `ip route add 198.18.0.0/16 dev cgtun0`；ns 系统 resolver → `127.0.0.1:53`（引擎 DNS）。**全程无代理环境变量**。

| 检查点 | 预期 | 实测 | 判定 |
|---|---|---|---|
| 配置预检 | successful | `configuration file … test is successful` | ✅ |
| TUN 设备 | 出现且不抢默认路由 | `cgtun0`，`inet 198.18.0.1/30`（**P23 跨平台复核：mihomo 强制 /30**），手工窄路由 `198.18.0.0/16 dev cgtun0` 后才通 | ✅ |
| 系统解析 claude.ai | fake-ip | **198.18.0.4** | ✅ |
| 系统解析 example.org | 真实 IP | **104.20.26.136** | ✅ |
| `dig claude.ai AAAA` | 空 | **空**（P20 跨平台复核，无 v6 泄漏） | ✅ |
| 白名单外零侵入：裸 `curl https://example.org` | 200 | **200 / 0.046s**，引擎日志无 example.org 裁判（MATCH,DIRECT） | ✅ |
| 裸 `curl https://claude.ai`（judge） | 命中 ClaudeExit | 日志原话：`[TCP] 198.18.0.1:55878 --> claude.ai:443 match DomainSuffix(claude.ai) using ClaudeExit[anytls-node]`；`api.anthropic.com` 同样命中 | ✅ |
| 同一 curl 的边缘结果 | 记录性 | anytls 出口今日仍不可用：`000 / 0.48s`；`ClaudeExit=DIRECT` 时 **403 / 0.19s**（有 HTTP 响应 = 通道通） | 如实记录 |
| J2：切 dead → 看门注入 | ≤45s 注入；裸 curl 瞬时失败 | 切出口 `18:13:08` → `INJECT-REJECT 18:13:42`（**33.7s**，阈值 30s+调度）；裸 curl **`000 / 36ms`** | ✅ |
| J3：切回 direct → 释放 | RELEASE + 复通 | `RELEASE 18:14:12`（**30.6s**，需 2 次成功×15s）；裸 curl **403 / 0.042s**；example.org **200** | ✅ |
| 拆除 | 无残留 | 引擎进程 0、`7892/9095/53` 监听 0、`cgtun0` 0 | ✅ |

看门事件线（`evidence/tun-watch.txt`）：

```
WATCH 2026-10-23 18:13:06 probe=200 claude_exit=anytls-node injected=0
WATCH 2026-10-23 18:13:24 probe=000 claude_exit=dead injected=0
INJECT-REJECT 2026-10-23 18:13:42 probe=000 claude_exit=dead
RELEASE       2026-10-23 18:14:12 probe=200 claude_exit=REJECT
```

**与 macOS PoC-4 的关键差异**：macOS 侧靠 `networksetup` 改**整机 DNS** 才能把裸进程拉进 fake-ip 平面；Linux 侧在**命名空间内只改 ns 的 resolver 文件**就完成同样的事——接管面与爆炸半径都更小（生产上对应 systemd-resolved per-link 或容器/命名空间部署）。TUN 的 `/30` 强制地址与窄路由写法在两边一致（P23）。

---

## 7. 生产零影响证据

### 7.1 服务状态（35 次护身符全部 OK，`evidence/guard.txt`）

每次阶段前/后都跑：三服务 `is-active` + `curl 127.0.0.1:80` = 200，全为 `-> OK`。

```
终态: mtcopy-gateway=active  uptime=Tue 2026-10-20 11:35:46 UTC  NRestarts=0
      mtcopy-platform=active uptime=Tue 2026-10-20 11:35:46 UTC  NRestarts=0
      nginx=active           uptime=Sat 2026-10-03 06:57:49 UTC  NRestarts=0
      http=200
```

`ActiveEnterTimestamp` 仍是 2026-10-20 / 2026-10-03（实验始于 10-23 17:54），`NRestarts=0` —— **从未重启**。

### 7.2 宿主 netfilter / 路由 / 文件（`evidence/9-*.txt`、`95-final-verify.txt`）

| 对象 | 基线 | 终态 | diff |
|---|---|---|---|
| `iptables-save` | **0B** | **0B** | **0B** |
| `ip6tables-save` | **0B** | **0B** | **0B** |
| `nft list ruleset` | **0B** | **0B** | **0B** |
| `ip route` | 基线 | 基线 | **0B** |
| `ip addr` 中 `cg*` | — | 无 | — |
| `/etc/hosts` + `/etc/resolv.conf` sha256 | 记录 | 相同 | **0B** |
| `/etc/ufw` 文件清单 | 记录 | 相同 | **0B** |
| `ufw status` | inactive | **inactive** | — |
| `net.ipv4.ip_forward` | 0 | **0** | — |
| netns / veth / tun | 无 | **无** | — |
| 瞬时 unit | 无 | **无**（`systemctl cat` 失败） | — |
| 临时监听（18080/18090/18091/7892/9095） | 无 | **无** | — |

宿主侧只加过两条东西，且都已精确删除：`iptables -t nat -A POSTROUTING … --comment cg-poc6-nat -j MASQUERADE`，以及它顺带创建的 `table ip nat`（基线没有这张表，故整表删除复原）。

### 7.3 一处如实披露：`/etc/default/ufw` 的 mtime 被更新

`ufw default deny outgoing` / `default allow outgoing` 会重写 `/etc/default/ufw`（**该路径不在 `/etc/ufw` 内，未被私有挂载覆盖**）。内容被写回原值，证据：

- `dpkg -V ufw` → **空输出，rc=0**（包内所有文件内容与发行版一致）
- `md5(/etc/default/ufw)=a921dd9d167380b04de4bc911915ea44` = 包记录值
- 只有 `mtime` 变成 18:05:38；**内容零变化**，且宿主 ufw 全程 inactive，该文件在终态不参与任何生效策略

`find /etc -newermt "-90 minutes"` 只命中这一个文件（`96-etc-touch-audit.txt`）。**结论：内容零改动，时间戳有痕**——不掩饰。

---

## 8. 与 macOS / 容器结果对照

| 维度 | macOS（PoC-1/2/3/4） | Docker 容器（PoC-4） | **真机 Linux（本轮 PoC-6）** |
|---|---|---|---|
| 按用户豁免 | pf `pass out user=_monetafw` | iptables `-m owner --uid-owner 5011` | ✅ 同（v4 与 v6 同构） |
| 规则匹配序 | pf **后**匹配胜出 | iptables **首**匹配胜出 | ✅ 首匹配（链首豁免）+ **跨机制**：iptables ACCEPT 终止整表、nft accept 不终止其他基链 |
| 快失败语义 | pf return / 引擎面 REJECT | REJECT 仅对新连接 0.002s；已建连接 loopback 不下发 RST | ✅ **新连接 0.00015s；已建连接 253ms 内 RST（真网络面）** |
| 框架共存 | 无（pf 自带） | 空栈，只能记"零冲突基线" | ✅ ufw 全生命周期不碰外部链；并给出**优先级语义**判别 |
| 看门自愈 | launchd `KeepAlive` | 无 PID1，跳过 | ✅ systemd `Restart=always` **2.23s**；停机文件必须配 `RestartPreventExitStatus=0` |
| 双栈 | v6 面未覆盖 | 无真实 v6 路径 | ✅ v6 规则/豁免同构；**无公网 v6 出口**（ULA-only） |
| TUN 接管 | 整机 DNS + 窄路由 utun | 未做（需真机路由面） | ✅ **只改 ns resolver** + 窄路由，裸进程被域名裁判 |
| AAAA | 空（P20） | 未测 | ✅ **空**（跨平台复核） |
| 脚本坑 | bash 3.2 两大坑 | bash 5.1 加固即效 | ⚠️ **uutils coreutils：`date +%s%3N` 不截断**（新坑） |

**一句话**：三平面（地址/域名/看门）在真机 Linux 上全部对得上，且 Linux 侧多出两个能力——**内核原生 RST** 与 **conntrack/框架优先级的可编程粒度**；代价是多一套"发行版框架语义"要显式选择。

---

## 9. 产品建议 · Linux 侧规则策略怎么选

本轮把选择从"口味"变成了"三选一的确定语义"，建议按**产品要保谁**来定：

### 建议 A（默认）：**独立 nft 表 `table inet cg` + 看门重 assert** ← 首选

- **理由**：对 `reload/disable/enable/reset/ufw-init stop|start` 全存活；不写发行版规则文件；`nft -f` 天然原子；与 ufw/firewalld/原生 nft 发行版的最少共同面。
- **语义**：`accept` 不终止其他基链 → **框架策略永远有权否决我们**（安全属性：不会因为我们的豁免而把管理员的 DROP 打穿）。
- **代价**：若宿主 `DEFAULT_OUTPUT_POLICY=DROP`（或显式 deny out），我们的豁免会"看起来装了但不生效"。**必须配一条自检**：起服前验证引擎/探针链路，若被框架拦则落 B 或提示管理员用 `ufw allow out` 放行。

### 建议 B：**iptables 专用链挂 OUTPUT 首位 + 看门重 assert**（仅当"豁免必须永远赢"）

- **理由**：iptables 的 `ACCEPT` 终止整表遍历，可覆盖 ufw/firewalld 的 DROP（本轮 §3.3 实证）。
- **代价**：这是**主动打穿管理员策略**的能力，必须只对引擎 uid 生效、且顺序（豁免在前、封禁在后）由生成器硬编码（首匹配语义，反序即失效——PoC-4 SW1 已证）。
- **风险**：`MANAGE_BUILTINS=yes` 的宿主会在 ufw stop 时 `flush_builtins` 连根拔掉；所以**看门每 N 秒 `-C` 检查 + 缺失即重装**是硬要求，不能省。

### 建议 C（不推荐）：把规则写进 `/etc/ufw/user.rules` 或 `after.rules`

- `ufw reload` 会用文件内容重建 ufw 链，产品规则与用户规则混在同一生命周期里；升级/`reset` 易丢。若确需与 ufw 集成，用**官方钩子 `/etc/ufw/after.init`**（本轮已验证 `start`/`stop` 各被调用一次），在钩子里调用我们的幂等 reassert 脚本，而不是改 `user.rules`。

### 三条落地细节（本轮实测支撑）

1. **规则生成器必须平台分支**：同一条"豁免+封禁"在 pf 是后匹配、iptables 是首匹配、nft 是基链并行；顺序写错不报错、只是静默失效。
2. **快失败用 `REJECT --reject-with tcp-reset`，且不要额外加 `--ctstate ESTABLISHED -j ACCEPT`**：真机已证 RST 秒断已建连接（253ms / 42ms）；一旦放行 ESTABLISHED，"活→死"就会退化成等超时（PoC-4 SW5-C 的产品形态是另一个可选项，不是默认）。
3. **v6 与 v4 必须同源生成**：v4-only 保护下 v6 直通是 100% 泄漏（§5-A 实证）；owner 豁免在 ip6tables 上完全同构，没有理由不做。

---

## 10. 仍未覆盖（下一轮清单）

| # | 未覆盖项 | 为什么本轮没覆盖 | 建议靶 |
|---|---|---|---|
| 1 | **真实公网 IPv6 出口** | ns 只配 ULA，无 v6 默认路由（`ip -6 route show default`=0）；宿主有全局 v6 但未让 ns 走 v6 NAT | 真机打开 v6 转发 + `ip6tables -t nat MASQUERADE`，复测"漏 v6=泄漏"与 ip6tables 全链 |
| 2 | **systemd unit 正式安装形态** | 本轮用 `/run/systemd/system` 瞬时 unit，无 `User=monetafw`、无 enable、无 `After=network-online.target`、无 StartLimit/Jitter 调参 | 在靶机装正式 unit（`User=uid5011`、`Restart=always`、`RestartPreventExitStatus=0`），跑 24h 观察 NRestarts 与 journal |
| 3 | **`MANAGE_BUILTINS=yes` 的 ufw** | 宿主是 `no`；改成 `yes` 需动宿主 `/etc/default/ufw` 并真实重启 ufw（会动生产防火墙） | 专用测试机：置 `yes` → `ufw-init stop` → 验证 `CG-OUT` 被 flush，量化看门重装窗口 |
| 4 | **firewalld / 纯 nft 发行版** | 靶机未装 firewalld | CentOS/RHEL 系或 Fedora：`firewall-cmd --reload`、`nft flush ruleset` 场景 |
| 5 | **持久化 `DEFAULT_OUTPUT_POLICY=DROP`** | 只在 ns 内临时切换并已恢复 | 硬化宿主：确认建议 A 的自检能正确降级/报错 |
| 6 | **TUN 全接管（fwmark 策略路由）** | 本轮按 P23 只做 198.18.0.0/16 窄路由（不抢默认路由） | 单机全接管：`ip rule` + fwmark，验证与宿主既有 VPN/策略路由的冲突面 |
| 7 | **DNS 与 systemd-resolved 的正式集成** | 我们用 ns 私有 `resolv.conf` 覆盖，没接 resolved 的 per-link DNS | 宿主：`resolvectl dns <if>` / split DNS，测 mDNSResponder 对位的收敛时间与回落 |
| 8 | **性能与并发** | 只做功能验证（单连接、单流） | 压测：规则数 1k/10k 的匹配开销、TUN 吞吐/CPU、看门轮询对 REST 的压力 |
| 9 | **真实 relay 健康** | anytls 节点今日仍不可用（claude.ai 经它 `000/0.48s`），故 claude.ai 的 200 无法取到 | 换可用出口复测端到端 200；本轮用"裁判命中 + DIRECT 403"证明接管与释放 |
| 10 | **生产机上直接启用 ufw** | 铁律要求宿主 ufw 终态 inactive，只在 ns 内验证 | 维护窗口：在真实 ufw 活跃的宿主上装正式 unit，观察与 `mtcopy-*` 的端口策略交互 |

---

## 11. 证据账（`evidence/`）

| 文件 | 内容 |
|---|---|
| `00-baseline.txt` `01..07-*` | 靶机基线：服务/HTTP/ufw/sysctl/iptables/ip6tables/nft/addr/route/sockets/hosts+resolv sha |
| `10-setup-run.txt` `10-nat-added.txt` | netns+veth 搭建、NAT 唯一宿主改动 |
| `20-sw3-run.txt` `sw3-journal.txt` `sw3-unitdir.txt` | SW3 四段计时与 systemd journal 原话 |
| `30-sw4-run.txt` | SW4 主轮：enable/reload/after.init/nft/共存语义 |
| `31..35-sw4-*.txt` | SW4 修正与判别：reload/disable/enable/reset 矩阵、`ufw-init` 框架路径、优先级对撞、after.init 被调用证据 |
| `sw4-etcufw-manifest-before/after.txt` `sw4*-etcufw-diff.txt` | 宿主 `/etc/ufw` 零改动证明（清单逐行相同） |
| `40-sw5-run.txt` `sw5/probeA.evidence.txt` `sw5/probeD.evidence.txt` | REJECT/DROP 四数据点：探针原始行（ALIVE/HANG/ERROR）+ curl 退出码/字节/耗时 |
| `50-v6-run.txt` `v6-*.txt` | 泄漏路径、DROP、owner 豁免、v4 对照、监听面 |
| `60-tun-run.txt` `tun-precheck.txt` `tun-iface.txt` `tun-judge-hits.txt` `tun-engine-tail.txt` `tun-watch.txt` | TUN 全链路：fake-ip/AAAA/裁判原话/看门事件线 |
| `88-midcheck.txt` | 实验中宿主态（证明只有登记在案的临时件） |
| `90-cleanup-run.txt` `95-final-verify.txt` `96-etc-touch-audit.txt` `9-*.txt` | 收尾：diff 全 0B、服务 uptime、`/etc/default/ufw` 触碰审计 |
| `guard.txt` | 35 次生产护身符（全 OK） |
| `../config-tun-ns.yaml` `../*.sh` `../probe-keepalive.py` | 可复跑脚本与配置 |

**复跑顺序**：`10-setup.sh` → `20-sw3` → `30/31/32/33/34/35-sw4` → `40-sw5` → `50-v6` → `60-tun` → `90-cleanup`（每个脚本自带生产护身符，任一异常 `exit 90` 即停）。
