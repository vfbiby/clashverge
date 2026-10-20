# 封堵层用操作系统自带防火墙（macOS pf / Windows WFP），不自研内核驱动

**Status**: accepted · 2026-10-20

地址平面封堵直接调用系统组件：macOS 用 pf（anchors + `user` UID 豁免，PoC-1 root 脚本实测成立），Windows 用 WFP 用户态 `Fwpm*` API 添加 block + 高权重 sublayer 的 exe 豁免（未实测）。

**为什么**：① pf/WFP 系统自带、零驱动零签名、pfctl/Fwpm 可脚本化——这是"调用现成的东西"的正解。② 第三方产品不可用：LuLu 无对外控制 API（GPL，规则封在自家 App），Little Snitch 闭源付费——它们最多作"可选集成"（导出规则包），不能当引擎。③ 能力实测足够：block 全拦直连一切进程 + 单主体 UID 豁免精准（PoC-1 T1/T3/T4）。

**代价**（接受，且是本 ADR 与 0001 共生的重要原因）：地址平面天生**失明于远程出口代理**——代理进程出站的目的地址是节点服务器，真实目标 IP 出现在隧道远端（PoC-1 TEST2 实测 200）。因此地址平面必须与域名平面（0001）搭配，两者互为必要条件。另有 pf table 生命周期（CDN IP 漂移需定期重解析，P09）与 pf enable 状态管理（P12）两条运营成本。

**关联**：PoC-1（experiments/0001）；SPEC §2/§5；ROADMAP P0/P1。
