# PITFALLS — 坑账

平台差异与易错点滚动账。每条含正确姿势与出处；移植 Windows/手机端前先通读一遍。编号不重排，只追加。

## pf / macOS（PoC-1）

| 编号 | 坑 | 正确姿势 | 出处 |
|---|---|---|---|
| P01 | pf **没有** `proto tcp6`（`/etc/protocols` 无此协议名），写了中国 pfctl 解析直接失败、规则整体装不进去 | IPv6 家族用 `inet6` 关键字 + `proto tcp`：`block drop out inet6 proto tcp to …`，v4/v6 必须分两条 | PoC-1 实验复盘（pf-test.sh 修复记录） |
| P02 | `block … quick` 会**终止规则评估**，后置的 `pass user xxx` 永远不生效，豁免整体失效 | pf 是**后匹配胜出**：block 不带 quick，pass 豁免规则放在 block 之后 | PoC-1 设计（REPORT 有详述）；原任务书曾写错 |
| P03 | pf `user` 匹配的是**套接字的有效 UID**（man 证实）；setuid 流程以创建套接字时的凭据为准 | sudo -u 场景归属正确（T3 实证）；产品安装器创建 daemon 专用用户的时序要跟 pf 规则解析对齐（规则装载时按名解析用户） | man pf.conf；PoC-1 T3 |
| P04 | **远程出口代理令 IP 平面失明**：代理进程出站的目的地址是节点服务器，真实目标 IP 只在隧道远端出现——pf "拦不住"代理流量是物理边界不是缺陷 | 地址平面只兜"直连泄漏"；须经代理链的流量由域名平面在代理链上游裁定 | PoC-1 TEST2（实测 200 推翻预测） |
| P05 | `dscl . -passwd user '*'` 报 `eDSAuthPasswordQualityCheckFailed` | 账号功能不受影响（sudo -u 正常）；产品安装器需换创建无密码服务账户的姿势（候选 `dscl . -create … Password '*'`，**未验证**） | PoC-1 log STEP 4 |
| P09 | 目标域在 Cloudflare 后面，IP 池漂移（example.com 一次解析出 2 个 v4 + 2 个 v6） | 封禁 IP 表必须**定期重解析**，且 **v4/v6 双栈同批覆盖**，漏 v6 = "测试假失败/流量从 v6 泄漏" | PoC-1 STEP1 / PoC-2 T3 复盘 |
| P12 | macOS pf **默认 Disabled**；启用/禁用是系统级状态 | 产品先记录初始状态（Enabled?）→ 变更 → 异常/卸载时恢复原状并 `pfctl -d`；启用后先做连通性 sanity check 再装规则 | PoC-1 STEP2/3 + log |
| P13 | 对生产域名做拦截实验会把用户正在用的 Claude 弄断（代理/直连所有流量一起断） | 实验目标用中性域名（example.com）；生产验证用独立参数开关 | PoC-1 任务书安全条款 |

## 引擎 / mihomo（PoC-2）

| 编号 | 坑 | 正确姿势 | 出处 |
|---|---|---|---|
| P06 | **fake-ip 不感知出口健康**：节点全死后 `dig` 照发 fake-ip，全新子域照常新签发（198.18.0.4）——"DNS 停发"语义引擎原生不存在 | "断"定义在 TCP/规则面：看门把出口切 REJECT（见 ADR-0003） | PoC-2 T5 |
| P07 | 通用探测（gstatic 类）测不出"目标拒绝你"：隧道健康 + claude 边缘在 TLS 握手就切出口 IP，同一台 VPS 上 anytls 活、vless reality 端口 8451 被对端 RST | 探活 URL 对目标域本身（HEAD claude.ai）；日志区分"隧道死 vs 出口拒"两类归因；节点池可换 | PoC-2 T3 + vless 补充证据 |
| P08 | anytls/mihomo 会在单连接内重试会话建立（约 8 次），把"节点死了"的瞬时错误拉长到 ~2s 才回给客户端 | "更快断"不靠等探活，直接 REJECT 兜底（0.01s）；~2s/5s 是探活恢复路径的体验参数 | PoC-2 T5 dead-a |
| P11 | 引擎复用事实：服务端内核资产（/Library/.../verge-mihomo root 700、clash-core-service 无执行位）用户态**不可用**；App bundle 内核（/Applications/Clash Verge.app 内）可执行——产品安装器必须自带内核，不赌系统里恰好有 | PoC-2 选型表 |
| P14 | sing-box 裁剪版无 `dns` inbound 类型（`check` 直接拒）；裁剪前先核对 feature tag（with_tun/with_gvisor…） | 产品内嵌核心按 feature 全集重新裁剪；配置写完必过 `sing-box check` / `mihomo -t` | PoC-2 选型 |
| P15 | `fake-ip` 常用**黑名单模式**会把无关域名也进池（与"零侵入"目标相反） | 用 `fake-ip-filter-mode: whitelist`，白名单=封禁库，零侵入由模式保证 | PoC-2 配置 |

## 背景遗留（立项动机，hosts 时代）

| 编号 | 坑 | 出处 |
|---|---|---|
| P10 | hosts 无后缀语义（子域逐条穷举）、无 IPv6 行（v6 真实 AAAA 直接漏）、DoH 绕过、无日志——四宗罪即产品立项动机 | /etc/hosts 实测（2026-10-20）；02-SPEC "解决什么问题" |

## 复现资产

- PoC-1：`claudeguard-test/pf-test.sh`（三重 trap 自动回滚）+ `log.txt`
- PoC-2：`claudeguard-test/poc2/`（run.sh / stop.sh / configs / evidence / REPORT.md）
