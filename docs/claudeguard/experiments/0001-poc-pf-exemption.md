# 实验 0001 · PoC-1：pf 全量封死 + 专属用户豁免

**日期**：2026-10-20 ｜ **执行**：任务书（主会起草）→ 子 agent 备料 → 所有者 root 终端执行 → 主会复核
**想验证的一件事**：不用内核驱动、不用特批 entitlement，仅靠系统自带 pf 能否实现"封禁所有进程 + 精准豁免唯一守护进程账户"。

## 方法

- 实验目标 = example.com（刻意避开生产域名，防止弄断正在使用的 Claude）
- 脚本 `pf-test.sh`：建专属用户 `_monetafw` (uid 5011) → `pfctl -E` → 装载规则（block 全体 + 后置 pass by user）→ 四项判定 → EXIT/INT/TERM 三重 trap 无条件回滚（恢复原规则集、恢复 Disabled、删用户）
- 关键规则（顺序即语义）：
  ```
  block drop out inet proto tcp to { <v4> }
  block drop out inet6 proto tcp to { <v6> }
  pass  out inet proto tcp to { <v4> } user _monetafw
  pass  out inet6 proto tcp to { <v6> } user _monetafw
  ```

## 判定表

| # | 场景 | 预期 | 实测 | 判定 |
|---|---|---|---|---|
| T1 | 普通用户直连 | 失败 | `http_code='000' exit=28`（超时） | ✅ |
| T2 | 经 Clash 代理 | （当时预期）失败 | **200** | ⚠️ 预期错误 → 最有价值发现 |
| T3 | 豁免用户直连 | 200 | `200` | ✅ 核心验证点成立 |
| T4 | 复测普通用户 | 仍失败 | `000 / exit=28` | ✅ 豁免粒度单一主体 |
| 回滚 | — | 零残留 | pf Disabled、用户已删、网络 200 | ✅ |

## 定论

1. **pf 地址平面封堵成立**：block 对一切进程的直连生效（curl 等系统解析应用全部被拦）
2. **UID 豁免成立**：pf `user` 按套接字**有效 UID** 匹配（man 证实），单主体精准放行——"我们的程序怎么放行"的答案被实测坐实
3. **drop 语义**：静默黑洞、客户端满超时（6s）——产品策略可换 `block return`（RST 快失败）
4. **TEST2 修正（预测错→发现）**：原预测"mihomo 直连 example.com IP 会被拦"。实测 200。真因：mihomo 按域名分流后出站目的地是**节点服务器**，example.com 的 IP 只在隧道远端出现——**远程出口代理令 IP 平面彻底失明**。这直接确立架构：地址平面兜直连泄漏，须经代理链的流量由域名平面在代理链上游裁定（ADR-0001/0002 的实测根基）
5. **运营事实**：macOS pf 默认 Disabled；enable 状态与规则生命周期必须由产品自记录自恢复（P12）；`dscl -passwd '*'` 有坑（P05）

## 证据

- `claudeguard-test/pf-test.sh`（可复现脚本，含全部修复后的规则）
- `claudeguard-test/log.txt`（全量日志：环境/规则装载/TEST1-4/汇总/回滚）
- `claudeguard-test/rules.before.txt` / `rules.during.txt`（规则集前后快照）、`pf.conf.orig`、`target-ip.txt`

**遗留**：机器零残留（log 末段回滚记录为凭）。
