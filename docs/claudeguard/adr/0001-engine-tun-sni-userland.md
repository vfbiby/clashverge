# 主引擎走用户态 TUN+SNI；内容过滤器（NE/WFP 内核）不做首发

**Status**: accepted · 2026-10-20

产品的判定引擎采用用户态 TUN 虚拟网卡 + DNS/SNI 域名识别（mihomo 形态已在 PoC-2 以普通用户权限完整走通），不首发 macOS NE Content Filter 或 Windows 内核 callout 驱动这类"真杀软内核形态"。

**为什么**：① 准入摩擦——NE content-filter entitlement 需 Apple 特批 + Developer ID 签名公证 + 每台机器手动批准；Windows SNI 级 DPI 需内核驱动签名，周期与成本都足以拖死新产品。② 桌面 utun/wintun 无任何特批权限，普通用户可运行（PoC-2 实证 mihomo App bundle 内核可复用）。③ 桌面/Android/iOS 是同一套概念（TUN/VPN/DNS 三形态），一套核心跨端。④ 与用户已有代理（Clash 等）共存可控（窄通道模式，见 SPEC-7）。

**代价**（接受）：裸 IP 直连在域名平面不可见——由地址平面（ADR-0002）兜底；与全接管 VPN 互斥——需要自动降级逻辑（未实测）；SNI 只覆盖 TLS/QUIC 特征流量。

**Considered options**：A. 内容过滤器/杀软形态（拒绝：Apple 特批 + 驱动签名 + 手机端无路，后置为企业版增强层）；C. 云端 DNS 过滤产品（NextDNS 形态；拒绝为主引擎，但被采纳为手机端首选形态——iOS PacketTunnel 与隐私无关，且独占 VPN 位）。

**关联**：PoC-2（experiments/0002）；SPEC §1/§7；ROADMAP P1/P3。
