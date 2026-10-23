# ClaudeGuard v0.1（macOS）

把四轮 PoC 验证过的机制装进一个可点、可看、可自测的 Mac 工具：

- **egui 界面**：通路/守护/策略/目标 IP/日志、三种模式、一键自测
- **pf 执行层 + launchd 常驻守护**：点一次授权，守护长期在（崩溃自动拉起、规则被覆盖 20s 自愈）
- **无 hosts 改动**：封的是 IP 平面（v4+v6），自定义 DNS/DoH 绕不过去
- **状态耦合**：自动模式下「代理通路不健康 → 自动封禁；恢复 → 自动放行」

## 快速使用

```bash
open run.command          # 首次会自动 cargo build --release
```

1. 点 **「启动守护（管理员授权）」** → 系统授权一次（安装 launchd 服务 `com.claudeguard.guardd`）
2. 模式选 **自动** / **强制封禁** / **放行**
3. 观察「实际生效」：`已生效（pf 已装载）` 才算真正在拦
4. 点 **「自测拦截效果」**：直连 claude.ai / 经代理 claude.ai / 对照 example.org 三行结果
5. 要解除：点 **「停止并解除」**（卸载服务并恢复 pf），一般不需要手动命令

## ⚠️ 为什么「强制封禁」下还能打开 claude.ai 网页？

**这是 v0.1 的已知边界，不是失效**：pf 只能看到"本机连到哪个 IP"。当你开着 Clash：

- 浏览器把 **域名** 交给 Clash（CONNECT claude.ai:443），Clash 经 **远程节点** 出网
- 本机真正发出的连接目标是 **节点服务器**，Claude 的 IP 只出现在节点那一端
- 所以本层拦不到这条链路——这是信息边界（PoC-1 实验已实证），不是 bug

**怎么验证封禁真的生效：**

1. 关掉 Clash（或至少关掉系统代理），刷新 claude.ai → 打不开
2. 看「自测」第一行：直连 claude.ai 显示 `000 in ~6s`（pf 黑洞），对照 example.org 仍 `200`
3. 后台确认：`sudo pfctl -s rules | grep "block drop out"` 应看到 4 条规则

**要"连代理链路一起断"需要 v0.2 域名平面**（DNS fake-ip + SNI 判定 + REJECT 注入，PoC-2/4 已验证）——届时由本工具内置引擎接管，不再依赖系统代理出口。

## 文件/协议

| 路径 | 作用 |
|---|---|
| `/Library/LaunchDaemons/com.claudeguard.guardd.plist` | launchd 服务定义（点「启动守护」时写入） |
| `/tmp/claudeguard/control` | 应用写：`mode=armed|disarmed` + `ips4=` + `ips6=` |
| `/tmp/claudeguard/status` | 守护写：状态/生效条数/时间 |
| `/tmp/claudeguard/guardd.log` | 守护日志（安装/武装/自愈/恢复） |
| `/tmp/claudeguard/rules.applied` | 实际装载的 pf 规则（可审计） |

设计纪律：**原始基线永远是 `/etc/pf.conf`**（不依赖运行期快照，避免"崩溃重启把已封规则当基线"这类污染）；武装 = 基线 + block 规则；解除 = 重新加载 `/etc/pf.conf`；若武装前 pf 是关闭状态，解除时一并关闭。

## 已实测（2026-10-24）

| 项 | 结果 |
|---|---|
| release 构建 | ✅ |
| launchd 安装/卸载 | ✅ `state = running` / 卸载后 plist 清除 |
| 武装直连 | ✅ `claude.ai` → `000 / 6.00s`；`example.org` → 200 |
| 崩溃自愈 | ✅ `kill -9` 后 launchd 3s 内拉起、规则保持 |
| 解除还原 | ✅ 规则 0 条、pf 回系统默认配置 |
| 重复武装/解除 | ✅ 幂等 |

## 安全/分发说明

- `/tmp/claudeguard` 是原型协议（控制文件可写），**不要以此形态分发**
- 产品化应改为 SMAppService/签名校验的特权 helper，并加 IPC 校验
- 守护常驻、应用退出不影响封禁；忘记解除时按 README 的按钮或 `sudo launchctl bootout system/com.claudeguard.guardd`

## 架构与台账

```
egui App ──control──▶ guardd.sh (launchd root) ──pfctl──▶ pf
   ▲                        │
   └──── status / log ──────┘
```

机制来源：`docs/claudeguard/experiments/0001`（pf 封堵）、`0003`（状态机）、`0004`（TUN 接管）。v0.2 把 0002/0004 的域名平面接入本工具。
