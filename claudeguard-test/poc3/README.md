# PoC-3 端到端串联实验（pf + mihomo 域名裁判 + 看门状态机）

## 唯一命令

```
cd /Users/zhangsike/codes/clashverge/claudeguard-test/poc3 && sudo ./run-e2e.sh
```

预计 **~4–5 分钟**，全程自动推进，结束无条件回滚（Ctrl-C / 异常退出同样自动回滚）。

## 告知（先读这段再跑）

- 实验会临时 **阻断本机对 claude 系域名 + example.com + example.org 的【直连】** 约 4 分钟
  （这正是实验内容: pf 地址平面封直连, 仅实验引擎 UID 豁免）。**你自己的 Clash/代理链路
  不受影响**；实验结束立即恢复 pf 原规则集并还原启用状态。
- 临时创建系统用户 `_monetafw` (uid 5011, 无密码，shell=false)，结束即删。
- 引擎占用本机 127.0.0.1 的 7892(mixed)/1053(DNS)/9095(REST) 三端口，结束即释放。
- **节点健康门**: 开跑后若探针拿不到 200，脚本会在 ~40s 内判定"出口异常"自动中止+回滚。
  ⚠️ 2026-10-20 交付后修订（主会复核时实测：relay 层较 PoC-2 进一步恶化，example.org 经 anytls 也 TLS 握手即切），
  看**门探针出口已改由 `direct` 扮演**（引擎自身出网、uid=_monetafw、pf 豁免——正是机械要验的对象），健康门不再依赖真实 relay；
  ClaudeExit 的"健康出口"仍指向真实 anytls 节点（规则面命中照测，边缘握手结果如实记录、不作 PASS 条件）。
  中止=正常退出，无需惊慌。

## 屏幕会看到什么

1. `PHASE-0` — 环境/端口预检 + 解析封禁 IP。
2. `STEP-2/3/4` — pf 状态备份、启用、创建 `_monetafw`。
3. `PHASE-A` — 引擎以 `_monetafw` 启动，看门 15s 一探（`WATCH ... probe=200 ...` 行不断滚出）；
   随后三连直连 curl 应当**全部被 pf 拦死**（`判定1` 应打 PASS）。
4. `PHASE-B` — 脚本用 REST 把引擎两个组同时切到 `dead`（= 杀节点）；
   ~30s 内滚出 `INJECT-REJECT <时间戳>`，随后 `判定2` 给出 `elapsed≈0.0s` 的读数（PASS 阈值 ≤0.2s）。
5. `PHASE-C` — REST 把 EdgeProbe 切回 `anytls`；两个周期内滚出 `RELEASE <时间戳>`；
   `判定3a` 显示 example.org 经 7892 恢复 200（复通）。
6. `PHASE-D ROLLBACK + VERDICT` — 回滚明细（pf 恢复、用户删除、端口释放、网络三验）+
   `J1/J2/J3 PASS/FAIL` 汇总。**`>>> 结论: PoC-3 端到端串联 【PASS】`即达成**。

跑完把 `log.txt` 交回（同目录还有 `resolved-ips.txt` / `rules.*.txt` / `engine/mihomo.log` 佐证）。

## 预验结论（预验者已用普通用户权限做过、已达成的项）

| # | 预验项 | 结果 | 证据 |
|---|---|---|---|
| 1 | `mihomo -t` 语法过检 | PASS | `prevalid/notes.txt` P1 |
| 2 | 引擎三端口用户态启动+释放 | PASS（三端口正常监听、kill 后零残听） | notes P2 |
| 3 | REST GET/PUT 路径、body、响应码 | PASS（PUT 均返回 204；组内伪名→404）| notes P3 |
| 4 | REJECT 注入秒断 (判定2 的机器证) | PASS（elapsed 0.015s ≤ 阈值 0.2s）| notes P4 |
| 5 | 死节点探活失败形态/耗时 | PASS（code=000, ~3.6s, 8s 探活超时内）| notes P5 |
| 6 | 看门状态机转态模拟 | PASS（INJECT/RELEASE 各命中一次，无双发/flap）| notes P6 |
| 7 | 节点健康（**不达标非本包问题**）| **当前 unhealthy**: anytls 会话建立到 padding 但 relay 死, 例行各类 URL 探测失败 | notes P7 |
| 8 | 封禁 IP 解析 + fake-ip 防呆 | PASS（v4=5 个 / v6=5 个, 无 198.18.x.x 混入）| `design-ips.txt`（脚本运行时会重解析并落 `resolved-ips.txt`）|
| 9 | pf 规则集生成（v4+inet6 双栈、无 quick、user 后置） | 就绪，root 端未装（无法作 root 预验）| run-e2e.sh 自查 + `bash -n` / `shellcheck` |

配置对照 PoC-2 的逐项差异见 `diff-README.md`。

## 限制（预验未覆盖、运行时留意）

1. **root 侧整个 pf 装载与回滚流程预验不到**（superuser-only）。若 `pfctl -f` 装载失败
   脚本会自动中止+回滚（STEP-3 启用后、装规则前都做了 sanity check，应当排除意外）。
2. **节点池当前 unhealthy**——若健康门中止出现，等节点恢复/换节点再跑（不是包的逻辑坏）。
3. 本机若已有任何东西占 7892/1053/9095 三端口之一，脚本会拒绝启动 rather than 强杀。
4. 实验进行中请勿手动碰 pfctl / 杀 `_monetafw` 进程，避免停断中断状态机。

## 得到什么

`PHASE-A` 三类判定 = PoC-1 (pf 拦直连/UID 豁免) + PoC-2 (域名裁判/秒断/热切) 的拼装链路是否
能在一台机器上由看门闭环: 探活失败→fail-closed 注入 REJECT；节点复活→自动 RELEASE；
这一实验的成功即 `02-SPEC` 第 4 节 ARMED_OPEN / ARMED_CLOSED 状态机首次全链路实证。
