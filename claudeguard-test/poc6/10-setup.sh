#!/bin/bash
# PoC-6 PHASE 0: 隔离实验环境(一次性搭建, 全程复用)
# 对象: veth + netns cgpoc(10.233.6.0/30 + ULA fd00:c6::/64); host 侧仅临时 NAT + ip_forward
set -u
. /root/claudeguard-poc6/common.sh

hr "PHASE-0 BASELINE"
guard "setup-start"
[ "$(hostname)" = "vps-7aaa3e0d" ] || { say "WRONG HOST: $(hostname)"; exit 1; }
ip netns list | grep -qx cgpoc && { say "ABORT: netns cgpoc already exists"; exit 1; }
ip link show cgv0 >/dev/null 2>&1 && { say "ABORT: cgv0 already exists"; exit 1; }

# host netfilter 快照(本阶段前)
iptables-save    > "$EVID/10-iptables-pre-setup.txt"
ip6tables-save   > "$EVID/10-ip6tables-pre-setup.txt"
nft list ruleset > "$EVID/10-nft-pre-setup.txt" 2>&1
ip route         > "$EVID/10-iproute-pre-setup.txt"
sysctl -n net.ipv4.ip_forward > "$EVID/10-ipforward-pre.txt"
say "pre-setup snapshot: iptables=$(wc -c < "$EVID/10-iptables-pre-setup.txt")B nft=$(wc -c < "$EVID/10-nft-pre-setup.txt")B ip_forward=$(cat "$EVID/10-ipforward-pre.txt")"

hr "PHASE-1 netns + veth (v4 10.233.6.0/30 / v6 ULA fd00:c6::/64)"
ip netns add cgpoc
ip link add cgv0 type veth peer name cgv1
ip link set cgv1 netns cgpoc
ip addr add 10.233.6.1/30 dev cgv0
ip link set cgv0 up
ip -6 addr add fd00:c6::1/64 dev cgv0 nodad
nsx ip addr add 10.233.6.2/30 dev cgv1
nsx ip link set cgv1 up
nsx ip link set lo up
nsx ip -6 addr add fd00:c6::2/64 dev cgv1 nodad
nsx ip route add default via 10.233.6.1
nsx ip -6 route add fd00:c6::/64 dev cgv1
nsx sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1

# ns 专用 resolver(ip netns exec 会 bind-mount 到 ns 的 /etc/resolv.conf; 与宿主 /etc/resolv.conf 无关)
mkdir -p /etc/netns/cgpoc
printf 'nameserver 223.5.5.5\noptions timeout:2 attempts:2\n' > /etc/netns/cgpoc/resolv.conf

say "--- ns addresses ---"
nsx ip -br addr
say "--- ns routes ---"
nsx ip route
nsx ip -6 route

hr "PHASE-2 出网 NAT (host 侧临时规则, 带 cg- 标记, 收尾删净)"
sysctl -w net.ipv4.ip_forward=1
iptables -t nat -A POSTROUTING -s 10.233.6.0/30 -m comment --comment "cg-poc6-nat" -j MASQUERADE
# FORWARD 策略为 ACCEPT, 无需额外 FORWARD 规则(最小改动)
iptables -t nat -S POSTROUTING | tee "$EVID/10-nat-added.txt"
say "ip_forward now: $(sysctl -n net.ipv4.ip_forward)"

hr "PHASE-3 连通性验收"
C=$(nsx env -u http_proxy -u https_proxy curl -sS -m 15 -o /dev/null -w '%{http_code}' https://example.org 2>/dev/null)
say "ns -> https://example.org = ${C:-ERR}"
[ "$C" = "200" ] || { say "FAIL: netns 无出网能力, 停止后续实验"; exit 1; }
nsx dig +short @223.5.5.5 example.org | head -3

hr "PHASE-4 快照(实验基线, 收尾 diff 对照用)"
iptables-save    > "$EVID/10-iptables-with-nat.txt"
nft list ruleset > "$EVID/10-nft-with-nat.txt" 2>&1
guard "setup-done"
say "setup OK"
