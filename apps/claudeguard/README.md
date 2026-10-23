# ClaudeGuard v0.1（macOS）

把四轮 PoC 验证过的机制装进一个可点、可看、可自测的 Mac 工具：

- **egui 界面**：状态面板（通路/守护/策略/目标 IP/日志）、三种模式、自测按钮
- **pf 执行层**（`helper/guardd.sh`，root 守护）：按应用写入的 control 文件安装/撤销封禁规则
- **无 hosts 改动**：封的是 IP 平面（v4+v6），DoH/自定义解析绕不过去
- **状态耦合**：自动模式下「代理通路不健康 → 自动封禁；恢复 → 自动放行」

## 快速使用

```bash
# 构建（首次）
cd apps/claudeguard && cargo build --release

# 运行
open run.command        # 或 ./run.command / cargo run --release
```

1. 点 **「启动守护（管理员授权）」** —— 弹一次系统授权框（输密码），root 守护进入 /tmp/claudeguard
2. 模式选 **自动**（推荐）或 强制封禁 / 放行
3. 点 **「自测拦截效果」**：会跑三条 curl（直连 claude.ai / 经代理 claude.ai / 对照 example.org）
4. 退出应用不会自动解除：守护会继续按最后策略执行；要解除请点 **「停止并解除」**，或手动：
   ```bash
   sudo ./helper/guardd.sh stop
   ```

## 文件/协议

| 路径 | 作用 |
|---|---|
| `/tmp/claudeguard/control` | 应用写：`mode=armed|disarmed` + `ips4=` + `ips6=` |
| `/tmp/claudeguard/status` | 守护写：当前状态/生效条数/时间 |
| `/tmp/claudeguard/guardd.log` | 守护日志（执行/自愈/恢复） |
| `/tmp/claudeguard/rules.applied` | 实际装载的 pf 规则（可审计） |

守护纪律：首次武装时快照 pf 状态与规则；停止/异常时恢复原规则、恢复原启用状态；规则被外部覆盖时 20s 自愈。

## v0.1 边界（重要，如实告知）

1. **pf 只能封"直连"出口**。若流量经远程出口代理（Clash 节点等），真实连接发生在节点那一端，本层拦不住——这是 PoC-1 TEST2 已验证的物理边界。
   例：武装状态下 `curl --noproxy '*'` 直连 claude.ai 会黑洞（实测 6s 超时），但 `curl -x 127.0.0.1:7890` 仍可能通（403）。
   要"连代理一起断"，需要 **域名平面**（内置引擎：DNS fake-ip + SNI 判定 + REJECT 注入，PoC-2/PoC-4 已验证）——那是 v0.2。
2. 本机若在 `claude.ai` 直连本就不可达（国内常态），"放行"时直连测试仍会失败——用「对照 example.org」区分是网络问题还是本工具封禁。
3. `/tmp/claudeguard` 为原型协议（world-writable 控制文件），**不要**以此形态分发；产品化应换 SMAppService/特权 helper + 签名校验。
4. 守护退出后 pf 恢复为"脚本启动前"的状态；若其他软件也在改 pf，以它为准（不抢占/不误关）。

## 架构（与台账对应）

```
egui App ──写 control──▶ guardd.sh (root) ──pfctl──▶ pf 规则
   ▲                        │
   └──读 status/日志────────┘
```

- 机制来源：`docs/claudeguard/experiments/0001`（pf 封堵+UID 豁免）、`0002`（域名裁判）、`0003`（状态机）、`0004`（TUN 接管）
- 本工具实现的是其中的"地址平面 + 状态机"；域名平面（引擎）是下一版

## 已知待办

- v0.2：内置 mihomo 引擎（DNS+REJECT 注入+专属出口）→ 连代理链路一起断/放
- v0.2：启动守护改用 SMAppService（一次授权、长期免密）
- UI：模式持久化、开机自启、目标域名导入导出
