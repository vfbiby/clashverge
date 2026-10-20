# 引擎 DNS 用 fake-ip whitelist 模式；健康探测必须针对目标域名本身

**Status**: accepted · 2026-10-20

两个引擎行为决策：① 采用 `fake-ip-filter-mode: whitelist`（仅封禁库域名进 fake-ip 池），而不是常见的黑名单模式；② 通路的健康探测 URL 用 claude.ai 本身（如 HEAD /，穿专属出口），不用 gstatic 类通用探测。

**为什么**：① 零侵入由**模式**保证而非由规则保证——T2 实证白名单外域名完全不经 fakeip 池、直接真实解析；规则数量再大、再漂移，兜底行为都安全。② T3 实测：代理隧道完全健康（example.com 经隧道 200），claude.ai 却在 TLS 握手被目标边缘切断——节点的出口 IP 被 Claude/Cloudflare 边缘拒绝。通用探测只测"代理通不通"，永远测不出"目标拒绝你"。

**代价**（接受）：白名单必须与封禁库同步联动（封禁库更新=引擎配置热更新）；对 claude.ai 的周期性探活本身构成"本机在做 claude 探测"这一流量模式，个人版可接受、记录在案。

**关联**：PoC-2 T2/T3（experiments/0002）；SPEC §4/§6；ADR-0003（探活结论驱动 REJECT 注入）。
