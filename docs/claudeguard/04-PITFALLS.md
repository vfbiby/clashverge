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

## 脚本工程 / bash（PoC-3）

| 编号 | 坑 | 正确姿势 | 出处 |
|---|---|---|---|
| P16 | **macOS 自带 bash 3.2 的两个版本坑**：① `函数名() ( … ) &` 只把**函数定义本身**后台化（产程即退的哑进程），函数体永不执行——bash 5 无此行为，且"定义+行内模拟"式测试暴露不了它；② 字符串里 `$VAR` **后面紧跟 UTF-8 多字节字符**（→、×等）时，3.2 会把多字节首字节吞进变量名 → `set -u` 下整个脚本被 `unbound variable` 杀死 | ① 定义与后台调用显式拆开：`f() (…)` 先定义，另起一行 `f &`；② 变量统一加大括号 `${…}`，字符串内少用多字节符号（×/→ 换 x/->）；发布前用 **/bin/bash（3.2）** 跑一遍 mock 模拟，别只信 bash5/shellcheck | PoC-3 第1/2轮 复盘（experiments/0003） |
| P17 | 特权用户（daemon 身份）产生的日志/产物，在回滚**删除该用户之后就不可读**（目录 700 + uid 失联 = 谁也读不了）——判定现场证据凭空消失 | 回滚时序：先 `cp` 日志到公共区归档，再删用户/清目录；"删用户"永远排在取证之后 | PoC-3 第2轮 复盘 |
| P18 | 后台子壳的进程树可能**不止一层**：`kill $!` 打中的是即退的中间壳，真循环以 PPID=1 孤儿独立存活（实测逃逸 40+ 分钟，root 权限还导致用户态无法补刀）+ 僵尸看门按自身节拍对已死的 REST 反复"二次 INJECT"——后果：验证环境下无限重试 + 把实验日志污染 150 行 | 三重兜底：**停机文件**（看门每周期自查自杀）+ **验证式轮询击杀**（kill 后 `kill -0` 轮询到死，超时 -9）+ **模式化孤儿清扫**（`pgrep -f 本脚本` 中 ppid=1 者，只识别本实验产物的精确命令行）；root 进程的补杀必须由 root 步骤执行（STEP-0 幂等清扫） | PoC-3 归档时发现（log 在 commit 后仍增长；实证 82324 已死/82325 存活/81669 tee 孑遗） |
| P19 | **bash 3.2 主脚本 `exit 0` 后主进程滞留不退**（S 睡眠、WCHAN 无可归因点，42 分钟实证）——疑与 `exec > >(tee)` 的 prosub 管道/残留 fd 有关，机制未定论 | 退场序列：restore → `rm -f 停机文件` → **`exec >/dev/null 2>&1 </dev/null`** → exit 0；WCHAN 细查挂到 P1（产品看门须以 launchd 托管、不用 shell 长驻，绕开整类问题） | PoC-3 归档时发现 |

## TUN 接管 / macOS（PoC-5）

| 编号 | 坑 | 正确姿势 | 出处 |
|---|---|---|---|
| P20 | **macOS 的 127.0.0.2 默认不可绑**（`bind: can't assign requested address`，与 Linux 的 127/8 全段可绑不同）——把"系统 DNS 指向自己"设计成 127.0.0.2 会直接启动失败 | DNS 监听用 **127.0.0.1:53**（root 才能绑 53）；或先 `ifconfig lo0 alias 127.0.0.2 up` 但要多管理一份系统状态。另: mihomo fake-ip 对白名单域返回**空 AAAA**（实测），应用回落 A 记录——v6 泄漏路径不成立，验收可据此判定 | PoC-4 备料预验（2026-10-24） |
| P21 | 系统 DNS 接管撞上"53 已被其他软件占用"（Clash 的 `*:53` 是通配绑定，换本机 IP 也绑不上，实测 `EADDRINUSE`）；pf rdr 插错位置报 `Rules must be in order: options, normalization, queueing, translation, filtering`；多解析器同时发 fake-ip 时分不清谁在应答 | ① 用 **pf rdr**（`rdr pass on lo0 inet proto udp/tcp from any to 127.0.0.1 port 53 -> 127.0.0.1 port 1053`）接管，无需独占 53；② 装配顺序 = scrub 段 → **rdr** → anchor/filter，且先 `pfctl -nf` 预检；③ 金丝雀域名（引擎 `hosts` 注入一个只有我们认识的映射，如 `canary.monetafw.internal -> 198.18.254.251`）证明应答者身份；④ 其他软件已启用 pf 时：记录状态、恢复配置、**不要误关** | PoC-4（2026-10-24） |
| P22 | 回滚顺序错导致噪音：先杀引擎 → utun 设备消失 → 路由同时消失，再 `route delete` 报 `not in table` | 先 `route delete` 再杀引擎；对外"零残留"判定不受影响但日志会误导排查 | PoC-4 |
| P23 | **`mihomo -t` 不校验 tun 段的 key**：写错/写不存在的 key 仍报 successful（实测故意写错也过）——不能靠 `-t` 背书 tun 参数正确；另: v1.19.32 源码 `parseTun()` 把 tun 地址强制为 fake-ip range 的 `/30`（198.18.0.1/30，YAML 里 `inet4-address` 不生效）；`auto-route: true + route-address: [198.18.0.0/16]` 在 darwin 会因重复写 /30 connected route 报 EEXIST 导致启动失败 | tun 参数逐项对照源码/官方文档；窄路由优先用 `auto-route: false` + 脚本 `route add -net 198.18.0.0/16 <utun 网关>`（确定性/可验证/可回滚）；tun 地址别手写 | PoC-5 备料源码核对（2026-10-24，并入 PoC-4 台账） |

## 复现资产

- PoC-1：`claudeguard-test/pf-test.sh`（三重 trap 自动回滚）+ `log.txt`
- PoC-2：`claudeguard-test/poc2/`（run.sh / stop.sh / configs / evidence / REPORT.md）
