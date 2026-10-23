# Linux 机制映射（macOS 验证结论 → Linux 等价实现）

**状态**：**已实测闭环**（PoC-4 容器轮 + PoC-6 真机轮，见 experiments/0004、0006）。分析稿保留作预判底稿；实测修正两处：REJECT 对已建连接在真网络面秒杀（loopback 为特例，P29）、Linux 规则策略以 ADR-0005 为准。凡例同 SPEC：未标"推定"的结论均有 macOS 实测背书；Linux 落地尚需 PoC-4 实测（ROADMAP P1.5）。

## 结论先行

PoC-1/2/3 验证过的每一件套，在 Linux 上都有一等公民等价物，**且多数比 macOS 侧更标准**（systemd 取代 launchd 自愈、REJECT=tcp-reset 原生、无 dscl 的密码政策怪癖）。架构不变、判定口径不变，产品可以"一套架构双平台"。

## 逐件套映射表

| 验证件套 | macOS 实测 | Linux 对应 | 等价性预判 | 备注/差异 |
|---|---|---|---|---|
| 地址平面封堵 | pf `block drop out` 全拦直连（PoC-1/3 J1） | iptables/nftables `OUTPUT` 链 DROP；或 `REJECT --reject-with tcp-reset`（=我们想要的快失败，比 pf 的 `return` 还原生） | ✔ 等价或更好 | 注意**首匹配胜出**与 pf 后匹配相反，豁免规则必须在 DROP **之前** |
| 单主体豁免 | pf `pass … user _monetafw`（套接字有效 UID 归属，PoC-1 T3/豁免复核） | iptables `-m owner --uid-owner 5011`（netfilter 同样按 socket 凭据归属） | ✔ 等价 | uid 归属语义同源（本机发起连接即生效） |
| 地址平面盲区（P04） | 远程出口代理令 IP 平面失明 | **同盲区**（套接字目的=节点服务器） | ✔ 教训直接平移 | 域名裁判必须在上游——不变式跨平台成立 |
| 域名裁判引擎 | mihomo v1.19.32 darwin-arm64（App bundle 复用） | mihomo 官方 linux 二进制（musl 静态版），**config.yaml PoC-2/3 原样可用**（fake-ip whitelist/1053/7892/REST 全平台一致） | ✔ 同源同配置 | 引擎行为差异应≈0；PoC-4 复跑 T1-T7 口径验收 |
| REJECT 注入/REST 热切 | external-controller REST，0.006s 生效 | 同 API 同语义 | ✔ | 看门脚本不变 |
| fail-closed 状态机 | bash 3.2 + 设定临界条件全 PASS（PoC-3 J2/J3） | 逻辑照搬；**P16/P19 两大 bash 3.2 坑自然消失**（Linux 系 bash ≥5），P17 取证纪律仍要带 | ✔ 且更少坑 | 30s→更优延迟可调 |
| 看门常驻 | launchd（产品阶段） | **systemd unit**（`User=`+`Restart=always`）——替代 launchd 自愈 | ✔ 更标准 | 早于 macOS 版本可做"不对称降级" |
| 专属用户 | dscl 六件套（P05 密码政策报错） | `useradd --system --no-create-home --shell /usr/sbin/nologin` | ✔ 无 P05 对应物 | |
| L3 兜底 hosts | root 维护 hosts 区块（全子域+v6+DoH 墙） | 同 `/etc/hosts`（hosts 影响 DNS 命中顺序不变）；systemd-resolved 环境下 hosts 依然最高优先 | ✔ | 写入幂等化由看门负责 |
| TUN 窄通道 | utun（产品 V1 未做，P1 待） | `/dev/net/tun` + `NET_ADMIN`，**无任何商店/entitlement 审批**（wintun 式零摩擦） | ✔ 权限面更简单 | ip rule fwmark 策略路由 = 全接管能力天花板更高 |
| 全接管模式/降级 | 推定 | 同场景同解 | 推定 | PoC-4 可一并验 |
| 双实例共存 | PoC-2 T7 证实 | 同（只要不抢端口/路由） | ✔ | |

## Linux 特有注意事项

1. **iptables 写入权**：云机/桌面机的防火墙框架（ufw / firewalld / nftables 混合栈）会与产品规则共存——产品必须探测现有栈（`iptables -L` 前实景）并把规则放进专用 chain（`MONETAFW-TO`）+ 主链挂钩，绝不能整表 flush/UFW 战争
2. **conntrack**：iptables OUTPUT 规则命中在 NEW 连接上即可，已建连接靠 conntrack 放过——切换 REJECT 后旧连接残留寿命要实测（SPEC §6 的"活→死滞后" authorities 加一条）
3. **容器场景**（产品"服务器自托管"形态）：iptables 需要 NET_ADMIN cap；TUN 需要 `/dev/net/tun` 设备映射——Docker `--cap-add NET_ADMIN --device /dev/net/tun` 即可，PoC-4 若用容器实验就在此场景内完成
4. **权限模型**：Linux 全程 root（sudo unit）即可完成所有件套——不像 macOS pf 得 root、引擎得专用用户两套混跑；下载内核二进制的供应链校验（sha256）应该加入安装器

## PoC-4 靶子（待 Linux 测试台就绪后执行）

- **验收口径**：照搬 PoC-3 的 J1/J2/J3 三判定 + PoC-2 的 T1/T2/T5 口径，在 Linux 上复跑；特别验收 SW1（iptables owner 豁免 + 首匹配重排）、SW2（REJECT tcp-reset 的客户端失败形态 vs DROP 黑洞）、SW3（systemd 单元看门的重启自愈）
- **依赖**：一台 Linux（现有 ovhe 云机 / 本机 colima 容器；见 ROADMAP）
