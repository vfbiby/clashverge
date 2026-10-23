# Linux 规则策略：默认用独立 nft 表 + 看门重 assert；iptables 专用链仅用于"豁免必须赢"

**Status**: accepted · 2026-10-23

Linux 侧的封堵规则默认落在**产品自有 nft 表**（独立 table，看门周期性 re-assert 存活）；只有"豁免必须永远压过宿主策略"的场景（如宿主 `DEFAULT_OUTPUT_POLICY=DROP`）才切到 **iptables 专用链挂 `OUTPUT` 首位**。

**为什么**（PoC-6 真机实测，Ubuntu 26.04 / iptables-nft 1.8.11 / ufw 0.36.2）：
- ufw 在 `MANAGE_BUILTINS=no` 下对六种框架动作（reload/disable/enable/reset/ufw-init stop/start）**不碰外部链**——产品自有规则天然存活
- **优先级语义相反且都可利用**：iptables 链首 `ACCEPT` 会终止整表遍历、**能覆盖 ufw 的 DROP**；而 nft 独立表的 `accept` 不能覆盖框架 DROP。前者换来"豁免必胜"，代价是打穿管理员策略，且 `MANAGE_BUILTINS=yes` 的宿主 flush 会冲掉专用链 → 看门重 assert 成为硬要求
- 不写发行版规则文件（`/etc/ufw/user.rules` 等）；官方集成点只有 `after.init`（实测被 start/stop 各调用一次）

**Consequences**：
- 默认策略下必须做**链路自检**：宿主 `DEFAULT_OUTPUT_POLICY=DROP` 时 nft `accept` 无法放行豁免 → 产品需在健康探测里区分"规则未生效"与"节点不可用"并给出明确降级提示
- 两种策略共用一套看门状态机；规则引擎以 `nft` 为第一实现、`iptables` 为兼容层（老发行版/firewalld）
- 真机轮遗留的 `MANAGE_BUILTINS=yes` flush 场景、firewalld 发行版适配并入 ROADMAP P2

**关联**：experiments/0006（SW4' 全表）；07-LINUX-MAPPING；PITFALLS P24–P29；ROADMAP P1.5/P2。
