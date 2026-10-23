# ClaudeGuard v0.2（macOS）

egui 界面的 Claude 出网管控工具。v0.2 起**连代理链路一起断**：武装时接管系统代理，Claude 域在本机直接 REJECT，其余流量链式转发给你的 Clash——所以「开着梯子」也能被强制封禁。

## 快速使用

```bash
open run.command          # 首次自动 cargo build --release
```

1. 点 **「启动守护（管理员授权）」** → 一次授权（安装两个 launchd job：控制守护 + 引擎）
2. 模式选 **自动**（通路断→封禁 / 恢复→放行）、**强制封禁**、**放行**
3. 看「实际生效」：`已生效（pf 已装载）` + `引擎 运行 · 系统代理 已接管(7893)` 才算真正在拦
4. **「自测拦截效果」**：直连 / 经 Clash(7890) / 经 ClaudeGuard(7893) / 对照 example.org
5. 解除：**「停止并解除」**（还原系统代理、卸载引擎、恢复 pf）

## 工作机制（v0.2）

```
应用（浏览器等）
  │ 系统代理 -> 127.0.0.1:7893 (ClaudeGuard 引擎)
  ▼
claude 系域名 ──▶ REJECT（本机拒绝，~5ms）
其他域名     ──▶ 链式转发 -> Clash 7890（或直连，取决于通路健康）
                     │
不走系统代理的应用 ──▶ 直连目标 IP ──▶ pf 兜底封禁（v0.1 能力）
```

- 引擎由 launchd 独立托管（`com.claudeguard.engine`，KeepAlive）：崩溃自动拉起
- 系统代理状态在首次武装前快照（`proxy.before`），解除/卸载时**精确还原**（含"原本关闭"的情况）
- pf 基线永远取 `/etc/pf.conf`，武装=基线+block，解除=重载系统配置

## 已实测（2026-10-24，v0.2）

| 项 | 结果 |
|---|---|
| 经 ClaudeGuard(7893) 访问 claude.ai | ✅ `000 / 0.005s`（本机 REJECT，立即失败） |
| 经 ClaudeGuard(7893) 访问 example.org | ✅ `200 / 0.61s`（链式转发到 Clash，正常上网） |
| 直连 claude.ai | ✅ `000 / 6.00s`（pf 黑洞） |
| 对照直连 example.org | ✅ `200` |
| 引擎被 SIGKILL | ✅ launchd 3s 内拉起，代理链路恢复 |
| 解除 | ✅ 系统代理还原为 `127.0.0.1:7890`、引擎卸载、pf 0 条封禁规则 |
| 卸载 | ✅ 两个 plist/job 清除、无残留监听 |

## 仍然存在的边界

1. **应用自己写死代理指向 Clash**（例如 `curl -x 127.0.0.1:7890`、某些不走系统代理的 SDK）：不经本引擎 → 仍会经远程节点访问 Claude。直连部分由 pf 兜底，这条显式代理路径 v0.2 管不到。
2. 系统代理接管期间，**所有**走系统代理的应用都经过本引擎（非 Claude 流量性能取决于链式转发到 Clash）。
3. `/tmp/claudeguard` 是原型协议（control 文件可写），**不要以此形态分发**；产品化需换签名 helper + IPC 校验。

## 文件/协议

| 路径 | 作用 |
|---|---|
| `/Library/LaunchDaemons/com.claudeguard.guardd.plist` | 控制守护（常驻） |
| `/Library/LaunchDaemons/com.claudeguard.engine.plist` | 引擎（武装时 bootstrap，解除时 bootout） |
| `/tmp/claudeguard/control` | 应用写：mode/ips4/ips6/domains/upstream |
| `/tmp/claudeguard/status` | 守护写：state/applied/engine/sysproxy |
| `/tmp/claudeguard/guardd.log`、`engine.log` | 事件与引擎日志 |
| `/tmp/claudeguard/proxy.before` | 系统代理快照（卸载后删除） |

## 架构与台账

机制来源：`docs/claudeguard/experiments/0001`（pf 封堵）、`0002/0004`（域名裁判/TUN）、`0003`（状态机）。
版本：v0.1 地址平面 + launchd；v0.2 系统代理接管 + 独立引擎 job。
