# PoC-4（ROADMAP P1a）· TUN 窄通道系统级接管 —— 所有者手册

## 一条命令

```bash
cd /Users/zhangsike/codes/clashverge/claudeguard-test/poc4 && sudo ./run-tun.sh
```

预计 **3–4 分钟**，全程自动，任何退出路径（含 Ctrl-C）都会回滚。跑完把 `log.txt` 留着即可。

## 本实验证明什么

PoC-3 只接管"主动送进 7892 的进程"。本实验验证**裸进程**（`env -u http_proxy curl https://claude.ai`——不设代理、自己查 DNS、自己连 IP）同样被域名裁判管辖：

```
系统 DNS -> 127.0.0.1（本实验引擎）
  -> claude 系域名发 fake-ip (198.18.254.254)
  -> 仅 198.18.0.0/16 的窄路由进 utun（绝不抢默认路由！）
  -> 引擎按规则判域名 -> ClaudeExit(活节点) / REJECT
```

## 运行期间会发生什么（如实告知）

1. **整机 DNS 短暂指向实验引擎**（≤4 分钟）。白名单外域名走真实上游解析（预验已证零侵入）；claude 系固定发 fake-ip
2. **风险窗口**：若引擎在实验中途异常退出，DNS 会黑掉直到脚本回滚完成（秒级）。脚本对引擎做了启动门+DNS 切换前二次 sanity，正常不会发生
3. 不装 pf、不建系统用户、不碰 `/etc/hosts`、不碰你的 Clash 配置；只占用 7892/9095/53 三个端口 + 一个临时 utun 设备
4. 你正跑着的 Clash（7890 系统代理）**不受影响**；浏览器走代理的流量也不经过本实验

## 屏幕预期

`PHASE-0`（预检/孤儿清扫/DNS 取证）→ `PHASE-A`（引擎起、utun 出现、窄路由验证、引擎 DNS 双 sanity）→ `PHASE-B`（DNS 切换 + 系统解析收敛）→ `PHASE-A1`（裸 curl 三连 + judge 命中）→ `PHASE-B`（杀出口→看门注入 REJECT→裸 curl 计时）→ `PHASE-C`（复活→解除）→ `VERDICT`（J1/J2/J3）→ `PHASE-D ROLLBACK`（DNS 还原优先、路由删、端口清、网络四验）

## 预验结论（主会以普通用户权限实测，2026-10-24）

| 项 | 结果 |
|---|---|
| `mihomo -t` 两份配置 | 均 `test is successful` |
| **127.0.0.2 绑定** | ❌ macOS `bind: can't assign requested address`（无 lo0 alias 不可用）→ 设计改为 **127.0.0.1:53**；预验以 127.0.0.1:1053 实测绑定成功 |
| 引擎 DNS 白名单行为 | `claude.ai` / `api.anthropic.com` → `198.18.254.254`（fake-ip）；`example.org`、`apple.com` → 真实 IP（零侵入实证） |
| **AAAA 行为** | claude 系 AAAA 返回**空**（不泄露真实 v6）→ 应用回落 A 记录，v6 泄漏缺口在本路径下不成立 |
| 端口 | 当前 udp/tcp 53 全空（用户 Clash 的 `0.0.0.0:53` 实际未监听）；7892/9095 空闲 |
| 预验引擎清理 | 已杀净，端口复核释放 |

## root 部分未预验点（运行时留意，失败会自动回滚）

1. `pfctl` 无关：本实验不用 pf；但 **utun 创建**只在 root 下发生，非 root 无法预演
2. `networksetup -setdnsservers` 的实际生效与 mDNSResponder 收敛时间（脚本有 10 次重试）
3. `route -n add -net 198.18.0.0/16 -interface utunX` 的 macOS 行为（脚本验证 `route get` 回读）
4. 若 53 端口在你启动前被其他进程占用，脚本会拒绝启动（不会强杀）
