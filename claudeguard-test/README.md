# claudeguard PoC：pf 全量封死 + 专属用户豁免 验证

## 怎么跑
```bash
cd /Users/zhangsike/codes/clashverge/claudeguard-test
sudo ./pf-test.sh
```
跑完后把 `log.txt`（或终端完整输出）交回来复核。

## 脚本行为（只针对 example.com，不碰 claude.ai/anthropic.com）
1. 解析并固化 example.com 的 IPv4+IPv6 → `target-ip.txt`
2. 记录 pf 初始状态；备份现有规则集 → `rules.before.txt`（另存 `/etc/pf.conf` → `pf.conf.orig`）
3. 若 pf 原本 Disabled → `pfctl -E` 启用；启用后先直连测试确认网络未被默认规则破坏，异常即中止
4. 创建专用用户 `_monetafw`（uid 5011，无密码、shell=/usr/bin/false、home=/var/empty）
5. 装载规则：原有规则 + `block drop out proto tcp to {目标IP}`（**不带 quick**）+ 后置 `pass out ... user _monetafw` → `test.rules`、`rules.during.txt`
6. 四项测试（普通直连应拦 / 走 Clash 代理应拦 / 豁免用户直连应 200 / 复测普通用户应拦）
7. **无条件回滚**（EXIT/INT/TERM trap）：恢复规则集；pf 原本 Disabled 则 `pfctl -d`；删除 `_monetafw`；验证恢复后直连 200

## 文件清单
| 文件 | 说明 |
|---|---|
| `pf-test.sh` | 幂等测试脚本（可重复执行） |
| `log.txt` | 脚本运行全程输出（跑完后生成） |
| `rules.before.txt` / `rules.during.txt` / `test.rules` / `target-ip.txt` / `pf-initial-state.txt` / `pf.conf.orig` | 各阶段留档（跑完后生成） |
| `README.md` | 本文件 |

## 为什么 block 规则不写 `quick`
pf 规则是**最后匹配胜出（last-match-wins）**：不带 `quick` 时，后置的 `pass out ... user _monetafw` 能覆盖前面的 `block`，这正是"全量封死+按用户豁免"的机制根基。若写成 `block drop out quick`，命中即终止评估，后面的 pass 永远不会被匹配——豁免直接失效。实验脚本按正确语义写入。
