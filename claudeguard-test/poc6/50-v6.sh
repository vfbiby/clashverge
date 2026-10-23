#!/bin/bash
# V6 · 真路由双栈: ULA veth 上的 v6 服务 + ip6tables owner 豁免与 v4 等价
set -u
. /root/claudeguard-poc6/common.sh

V6URL='http://[fd00:c6::1]:18090/'
V4URL='http://10.233.6.1:18091/'
SRVDIR=$BASE/testroot

probe_root(){ local o r; o=$(nsx curl -sS -g -m 6 -o /dev/null -w '%{http_code}|%{time_total}' "$1" 2>/dev/null); r=$?; echo "code=${o:-000} rc=$r"; }
probe_nobody(){ local o r; o=$(nsx setpriv --reuid=65534 --regid=65534 --clear-groups curl -sS -g -m 6 -o /dev/null -w '%{http_code}|%{time_total}' "$1" 2>/dev/null); r=$?; echo "code=${o:-000} rc=$r"; }

hr "V6-0 准备: 双栈测试服务 (host 侧 cgv0)"
guard "v6-start"
# 清掉上一阶段在 ns 里留下的 ufw 框架空链(仅本 ns), 让泄漏路径观察面干净
nsx iptables -F; nsx iptables -X 2>/dev/null
nsx ip6tables -F; nsx ip6tables -X 2>/dev/null
say "ns OUTPUT 初始: v4=[$(nsx iptables -S OUTPUT | tr '\n' ' ')] v6=[$(nsx ip6tables -S OUTPUT | tr '\n' ' ')]"
mkdir -p "$SRVDIR"; echo "cg-poc6-v6-ok" > "$SRVDIR/index.html"
( cd "$SRVDIR" && nohup python3 -m http.server 18090 --bind fd00:c6::1 >"$EVID/v6-httpd6.log" 2>&1 & echo $! > "$BASE/v6httpd.pid" )
( cd "$SRVDIR" && nohup python3 -m http.server 18091 --bind 10.233.6.1 >"$EVID/v6-httpd4.log" 2>&1 & echo $! > "$BASE/v4httpd.pid" )
sleep 1.5
say "host listeners:"; ss -lntp | grep -E '1809[01]' | tee "$EVID/v6-listeners.txt"
say "ns routes (v6): $(nsx ip -6 route | tr '\n' ' ')"
say "ns v6 global addr: $(nsx ip -6 -br addr show cgv1 | tr -s ' ')"
say "ns public v6 egress exists? $(nsx ip -6 route show default | wc -l) default routes (0 = 无公网 v6 出口)"

hr "V6-A 无 v6 规则时: v6 流量直通 (证明'漏 v6 = 泄漏'的实际路径)"
A1=$(probe_root "$V6URL"); say "v6 无规则 root => $A1 (预期 200)"
A2=$(probe_nobody "$V6URL"); say "v6 无规则 nobody => $A2 (预期 200)"
SWV6A=$( echo "$A1" | grep -q 'code=200' && echo LEAK-PATH-CONFIRMED || echo UNEXPECTED )
say ">>> V6-A => $SWV6A (v4-only 保护下 v6 完全绕过)"
say "v4 对照(无规则) root => $(probe_root "$V4URL")"

hr "V6-B ip6tables DROP 该 v6 目标 -> ns 内 curl 失败"
nsx ip6tables -A OUTPUT -d fd00:c6::1 -p tcp --dport 18090 -m comment --comment cg-poc6-v6 -j DROP
nsx ip6tables -S OUTPUT | tee "$EVID/v6-ip6tables-drop.txt"
B1=$(probe_root "$V6URL"); say "v6 DROP 后 root => $B1"
B2=$(probe_nobody "$V6URL"); say "v6 DROP 后 nobody => $B2"
SWV6B=$( echo "$B1" | grep -q 'code=000' && echo PASS || echo FAIL )
say ">>> V6-B => $SWV6B"

hr "V6-C ip6tables -m owner --uid-owner 0 豁免 (与 v4 同构)"
nsx ip6tables -I OUTPUT 1 -m owner --uid-owner 0 -m comment --comment cg-poc6-v6-exempt -j ACCEPT
nsx ip6tables -S OUTPUT | tee "$EVID/v6-ip6tables-exempt.txt"
C1=$(probe_root "$V6URL"); say "v6 owner 豁免后 root => $C1 (预期 200)"
C2=$(probe_nobody "$V6URL"); say "v6 owner 豁免后 nobody => $C2 (预期仍被拦)"
SWV6C=$( echo "$C1" | grep -q 'code=200' && echo "$C2" | grep -q 'code=000' && echo PASS || echo FAIL )
say ">>> V6-C => $SWV6C"

hr "V6-D v4 同构对照 (iptables owner 豁免)"
nsx iptables -A OUTPUT -d 10.233.6.1 -p tcp --dport 18091 -m comment --comment cg-poc6-v4 -j DROP
D1=$(probe_root "$V4URL"); D2=$(probe_nobody "$V4URL")
say "v4 DROP: root=$D1 nobody=$D2"
nsx iptables -I OUTPUT 1 -m owner --uid-owner 0 -m comment --comment cg-poc6-v4-exempt -j ACCEPT
D3=$(probe_root "$V4URL"); D4=$(probe_nobody "$V4URL")
say "v4 owner 豁免: root=$D3 nobody=$D4"
SWV6D=$( echo "$D3" | grep -q 'code=200' && echo "$D4" | grep -q 'code=000' && echo PASS || echo FAIL )
say ">>> V6-D v4/v6 等价性 => $SWV6D (v6 $SWV6C / v4 $SWV6D)"
nsx iptables -S OUTPUT | tee "$EVID/v6-iptables-v4.txt"

hr "V6-E 拆除"
nsx ip6tables -F OUTPUT; nsx iptables -F OUTPUT
kill "$(cat "$BASE/v6httpd.pid" 2>/dev/null)" 2>/dev/null
kill "$(cat "$BASE/v4httpd.pid" 2>/dev/null)" 2>/dev/null
sleep 0.5
say "ip6tables 残留: $(nsx ip6tables -S OUTPUT | tr '\n' ' ')"
say "iptables 残留: $(nsx iptables -S OUTPUT | tr '\n' ' ')"
guard "v6-done"
hr "V6 VERDICT"
say "A 无规则 v6 直通(泄漏路径) => $SWV6A"
say "B v6 DROP 生效             => $SWV6B"
say "C ip6tables owner 豁免     => $SWV6C"
say "D v4 同构对照             => $SWV6D"
