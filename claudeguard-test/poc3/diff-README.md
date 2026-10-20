# poc3/config.yaml 相对 poc2/configs/config.yaml 的改动清单

对照基准: `../poc2/configs/config.yaml` (PoC-2 live 通道配置)
搬运动机: PoC-3 要在 PoC-2 之上加「看门真值探针 + 机械可控死节点 + alias 封禁」——
其余 (端口/白名单/claude 规则/兜底) 一字未动。

## 逐项 diff

| # | 项 | PoC-2 | PoC-3 | 理由 |
|---|---|---|---|---|
| 1 | `proxies` 列表 | anytls-node(154.53.75.226:8450) + vless-node(154.53.75.226:8451 reality) | **删 vless-node**; 保留 anytls-node 原样 | vless reality 8451 被对端 RST（PoC-2 补充证据），PoC-3 指定 anytls 为健康节点 |
| 2 | `proxies` 新增 | — | **新增 `dead` 节点**: type socks5, server 127.0.0.1, port 9 | 看门"杀节点"需通过 REST 热切换（PoC-2 dead-a 用改配置重引擎实现，无法热切）；127.0.0.1:9 即刻 RST 同 PoC-2 dead-a |
| 3 | `proxy-groups` ClaudeExit | select: anytls / vless / REJECT / DIRECT | select: **anytls / dead / REJECT / DIRECT** | 去掉 vless 后由 dead 顶位；REST PUT 始终可达 REJECT/anytls 两态（预验证 204） |
| 4 | `proxy-groups` EdgeProbe | 无 | **新增 select: anytls / dead（永不含 REJECT）** | 探活真值域专用组：隧道活刃+边缘收 200；节点死→探活必败；REJECT 永不在路——判定3 的 REJECT 态解除信任链依赖这一"永不含 REJECT" |
| 5 | `rules` 置顶 | 第一条是 claude 规则 | **新增 `DOMAIN-SUFFIX,example.org,EdgeProbe` 与 `DOMAIN-SUFFIX,example.com,EdgeProbe` 置顶**, 然后 claude 规则 | 探针/alias 机械判别 alias；邊缘经 EdgeProbe |
| 6 | 其余 `rules`（claude 5 条 + fake-ip 兜底 + MATCH,DIRECT） | 原样 | 原样 | 语义不变 |
| 7 | 端口 7892/1053/9095、external-controller、fake-ip 白名单、dns | 原样 | 原样 | PoC-2 已验证 |

## 顺带重要勘误（PoC-2 结论被本轮预验修订）
PoC-2 判定过 "example.com 经隧道 200"。本轮预验 (同一天晚些时候) 实测：
- example.com 任何时刻经 anytls 隧道在 TLS 握手即被 RST (000)，与 claude.ai / discord.com 同病征；
- example.org 同病征；
- REST delay 测试对本池 anytls 节点全 URL 失败 (隧道-中继层断，TLS 握手层已"Update padding succeed" 但 relay 死)。
故 PoC-3 采用 example.org 作真值探针域（而非任务书假设可用的 example.com），example.com 仅保留
规则/封堵作对照。若改为恢复 example.com 探针，仅需把 run-e2e.sh 中 PROBE_URL/PROBE_DOMAIN 换回。
