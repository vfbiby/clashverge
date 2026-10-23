#!/bin/bash
# PHASE-9 · 收尾: 环境拆除 + 零残留 diff 证明 + 取证打包
set -u
. /root/claudeguard-poc6/common.sh

hr "CLEAN-0 拆除前状态"
guard "cleanup-start"
say "netns: $(ip netns list | tr '\n' ' ')"
say "cg links: $(ip -br link | awk '/^cg/{print $1}' | tr '\n' ' ')"
say "host nat: $(iptables -t nat -S POSTROUTING | tr '\n' ' ')"
say "ip_forward: $(sysctl -n net.ipv4.ip_forward)"
say "unit: $(systemctl cat claudeguard-watch-test >/dev/null 2>&1 && echo PRESENT || echo absent)"

hr "CLEAN-1 进程/端口/路由清理"
touch "$BASE/stop.guard" "$BASE/stop.tun"
for f in httpd.pid nshttpd.pid v6httpd.pid v4httpd.pid; do
  [ -f "$BASE/$f" ] && kill "$(cat "$BASE/$f")" 2>/dev/null && say "killed $(cat "$BASE/$f") ($f)"
done
# pid 文件可能记录的是外层子 shell, 再按端口模式兜底一次(避免 pkill 自匹配)
pkill -f "http[.]server 1808" 2>/dev/null
pkill -f "http[.]server 1809" 2>/dev/null
for P in $(pgrep -f "$BASE/tunwork" 2>/dev/null); do kill "$P" 2>/dev/null; say "killed engine $P"; done
for P in $(pgrep -f "$BASE/tun-watch.sh" 2>/dev/null); do kill "$P" 2>/dev/null; say "killed watchdog $P"; done
sleep 1
for P in $(pgrep -f "$BASE/tunwork" 2>/dev/null); do kill -9 "$P" 2>/dev/null; say "SIGKILL engine $P"; done
say "残留(本实验)进程: $(pcount "$BASE/(tunwork|tun-watch|probe-keepalive|http.server)")"

hr "CLEAN-2 宿主临时 netfilter 规则删除 + 快照 diff"
iptables -t nat -D POSTROUTING -s 10.233.6.0/30 -m comment --comment "cg-poc6-nat" -j MASQUERADE 2>&1 | sed 's/^/  /'
# 我们引入的 nat 表在基线中并不存在 -> 删表复原
if nft list table ip nat >/dev/null 2>&1; then
  nft list table ip nat > "$EVID/clean-nat-table-before-delete.txt" 2>&1
  REMAIN=$(nft list table ip nat 2>/dev/null | grep -c 'cg-poc6' || true)
  if [ "$REMAIN" = "0" ]; then nft delete table ip nat && say "deleted nft table ip nat (我们引入, 基线不存在)"; else say "WARN: nat 表仍有 cg-poc6 规则, 不删表"; fi
fi
sysctl -w net.ipv4.ip_forward=0 >/dev/null
say "ip_forward restored: $(sysctl -n net.ipv4.ip_forward)"

iptables-save    > "$EVID/9-iptables-final.txt"
ip6tables-save   > "$EVID/9-ip6tables-final.txt"
nft list ruleset > "$EVID/9-nft-final.txt" 2>&1
diff "$EVID/01-iptables-baseline.txt"  "$EVID/9-iptables-final.txt"  > "$EVID/9-diff-iptables.txt"  2>&1
diff "$EVID/02-ip6tables-baseline.txt" "$EVID/9-ip6tables-final.txt" > "$EVID/9-diff-ip6tables.txt" 2>&1
diff "$EVID/03-nft-baseline.txt"       "$EVID/9-nft-final.txt"       > "$EVID/9-diff-nft.txt"       2>&1
say "iptables diff: $(wc -c < "$EVID/9-diff-iptables.txt")B  ip6tables diff: $(wc -c < "$EVID/9-diff-ip6tables.txt")B  nft diff: $(wc -c < "$EVID/9-diff-nft.txt")B"

hr "CLEAN-3 netns / veth / resolv 覆盖拆除"
ip netns delete cgpoc 2>&1 | sed 's/^/  /'
sleep 1
# 实测: ip netns delete 后 veth 对端可能残留, 必须显式删
ip link show cgv0 >/dev/null 2>&1 && { ip link del cgv0; say "deleted residual veth cgv0"; }
rm -rf /etc/netns/cgpoc
[ -d /etc/netns ] && rmdir /etc/netns 2>/dev/null
say "netns list: [$(ip netns list | tr '\n' ' ')]"
say "cg links: [$(ip -br link | awk '/^cg/{print $1}' | tr '\n' ' ')]"
say "/etc/netns exists? $([ -e /etc/netns/cgpoc ] && echo YES || echo NO)"

hr "CLEAN-4 路由/地址快照对照"
ip addr    > "$EVID/9-ipaddr-final.txt"
ip route   > "$EVID/9-iproute-final.txt"
say "ip route diff vs baseline:"; diff "$EVID/05-iproute-baseline.txt" "$EVID/9-iproute-final.txt" | tee "$EVID/9-diff-iproute.txt" | sed 's/^/  /'
say "ip addr 中 cg 残留: $(grep -c 'cgv' "$EVID/9-ipaddr-final.txt" || true)"
sha256sum /etc/hosts /etc/resolv.conf > "$EVID/9-hosts-resolv-final.txt"
diff "$EVID/07-hosts-resolv-baseline.txt" "$EVID/9-hosts-resolv-final.txt" > "$EVID/9-diff-hosts-resolv.txt" 2>&1
say "/etc/hosts + /etc/resolv.conf 改动: $( [ -s "$EVID/9-diff-hosts-resolv.txt" ] && echo CHANGED || echo UNCHANGED )"

hr "CLEAN-5 systemd unit / ufw 终态"
systemctl stop claudeguard-watch-test 2>/dev/null
systemctl disable claudeguard-watch-test 2>/dev/null
rm -f /run/systemd/system/claudeguard-watch-test.service
systemctl daemon-reload; systemctl reset-failed claudeguard-watch-test 2>/dev/null
say "unit present? $(systemctl cat claudeguard-watch-test >/dev/null 2>&1 && echo YES || echo NO)"
say "host ufw: $(ufw status | head -1)"

hr "CLEAN-6 /root 清理"
rm -rf "$BASE/ufw-shadow" "$BASE/ufw-shadow2" "$BASE/testroot" "$BASE/sw5" "$BASE/tunwork" "$BASE/ufw-backup" 2>/dev/null
rm -f "$BASE"/*.pid "$BASE/stop.guard" "$BASE/stop.tun" "$BASE"/mihomo-amd64.gz 2>/dev/null
ls -la "$BASE" | tee "$EVID/9-rootdir.txt"

hr "CLEAN-7 生产栈终态自检"
guard "cleanup-done"
for s in $PROD_SVCS; do printf '%s: %s (uptime %s)\n' "$s" "$(systemctl is-active "$s")" "$(systemctl show -p ActiveEnterTimestamp --value "$s")"; done | tee "$EVID/9-prod-final.txt"
say "http: $(curl -m 3 -s -o /dev/null -w '%{http_code}' http://127.0.0.1/)"
say "cleaning done"
