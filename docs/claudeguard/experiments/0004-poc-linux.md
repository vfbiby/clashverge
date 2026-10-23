# 实验 0004 · PoC-4：Linux 等价性验证（Docker 容器 = Linux 测试台）

**日期**：2026-10-24 ｜ **执行**：子 agent 全程（容器内 root、宿主零 sudo）→ 主会复核归档
**想验证的一件事**：[07-LINUX-MAPPING.md](../../07-LINUX-MAPPING.md) 的预判——macOS 验证过的三平面件套（pf + mihomo + 看门）能否在 Linux 上"一类等价物一行行对上"。

## 方法要点

- 测试台：ubuntu 22.04 容器（`--cap-add NET_ADMIN --device /dev/net/tun`），iptables 1.8.7（nf_tables 后端）、dnsutils/curl；装好后宿主零涉入
- 引擎：mihomo v1.19.32 linux-arm64 官方 release（**下载 sha256 与 GitHub Release API digest 比对一致**），uid 5011 运行；**config.yaml = poc3 版逐字节原样**（diff 同源）——引擎跨平台零改动是本次最重要的工程事实
- 封禁 IP 表：容器内 `dig @223.5.5.5` 解析 claude 系 6 域 + example.org/example.com 防呆同 PoC-3（零 198.18.0.0/16 混入）
- 脚本：`run-poc4.sh`（照搬 poc3 的 P16–P19 加固形态：停机文件/验证式击杀/看门 15s）+ `run-poc4b.sh`（SW1 反序判别补跑）

## 判定表（摘录，全表见 `claudeguard-test/poc4/REPORT.md`）

| # | 场景 | 实测 | 判定 |
|---|---|---|---|
| T1'/T2' | fake-ip / 零侵入 | 198.18.0.4 / 真实 IP | ✅ 同 PoC-2 |
| J1' | victim 直连被拦（--resolve 钉真实 IP；DROP 黑洞 4.5–6s 满超时） | **exit=28** | ✅ 同 PoC-3 J1 |
| SW1 | owner 豁免（uid 5011 的 curl 200）+ **首匹配重排判别**（DROP 在前时豁免也被拦 `000`） | 豁免规则**必须缀在 DROP 之前** | ✅ **与 pf 后匹配相反，映射稿预判实证** |
| SW2 | DROP 黑洞 vs `REJECT --reject-with tcp-reset` | 4.50s vs **0.002s（exit 7, RST 到达）** | ✅ **顺差 ~2250 倍，Linux 原生快失败** |
| J2'/J3' | 杀节点→INJECT（**+29s**，elapsed **0.000698s**）；复活→RELEASE（+31s）→复通 200 | 三证齐 | ✅ 与 PoC-3 同形（29s vs 29s） |
| SW5-A/B/C | 已建连接：DROP = 立即停流；REJECT tcp-reset 对 **loopback 自回环**已建连接不回馈 RST（内核已知语义，真机需复测）；链首加 `--ctstate ESTABLISHED ACCEPT` = 24.5MB 续流不受影响 | | ⚠️+✅ Conntrack 放行产品语义在 Linux 实证；SW5-B 标遗留 |
| SW4 | 容器空栈 + 专用链模式 | 零冲突记录 | ✅（真机 ufw 场景留真机轮） |
| SW3 | systemd 看门自愈 | **跳过**（容器 PID1 非 systemd） | ⏳ 留 ovhe 真机轮 |

**结论**：三平面在 Linux 全部实证成立；同因不通的失败形态（边缘 RST）在容器内同样如实记录，口径完全可比。

## 本轮工程坑修正记录

1. `iptables-save` 基线首拍 0 字节没挡住——补拍 + 字节数校验门（回滚依据不能是空文件，教训同 P17 的"取证先于变更"）
2. SW1 判别首版只钉 1 个 IP（容器 DNS 视图其余 IP 从另一路绕出）→ **判别前重钉全部 BLOCK_V4**——与 P09"全 IP 双栈覆盖"同源的坑

## 证据

- `claudeguard-test/poc4/REPORT.md`（16 项判定全表）+ `evidence/`（21 件原始物证，含 `watch.txt` 事件线与 SW5 字节流物证）
- `claudeguard-test/poc4/run-poc4.sh`（可复现主脚本）/ `run-poc4b.sh`（反序补跑）/ `config.yaml`（与 poc3 同源）

## 遗留（→ ovhe 真机轮，ROADMAP P1.5 已标注）

- SW3 systemd 版看门自愈；SW4 ufw/firewalld 真实共存；SW5-B 真网络面（非 loopback）REJECT 对已建连接的 RST 行为；v6 真路由双栈；TUN 全接管；Docker 桥接 DNS 偏置的排除

> **勘误（2026-10-23，PoC-6 真机复核）**：本页 SW5-B「REJECT 对已建连接不秒杀」是**容器 loopback 自回环的内核特例**，真网络面实测 RST 253ms/42ms 到达。语义以 0006 为准。
