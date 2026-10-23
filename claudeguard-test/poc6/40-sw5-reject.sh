#!/bin/bash
# SW5-B' · 真网络面: REJECT tcp-reset vs DROP 对"已建连接"的作用 (netns 内经 host NAT 出公网)
set -u
. /root/claudeguard-poc6/common.sh
clear_cg(){ nsx iptables -F OUTPUT; }
show_out(){ nsx iptables -S OUTPUT; }
res(){ getent ahostsv4 "$1" | awk '{print $1}' | sort -u | head -1; }

hr "SW5-0 准备"
guard "sw5-start"
# 清掉上一阶段在 ns 里留下的 ufw 框架空链(仅本 ns)
nsx iptables -F; nsx iptables -X 2>/dev/null
say "ns OUTPUT 初始: $(show_out | tr '\n' ' ')"
IP_EX=$(res example.org); IP_OVH=$(res proof.ovh.net)
say "example.org=$IP_EX  proof.ovh.net=$IP_OVH (host 解析, 只读)"
NSDIR=$BASE/sw5; mkdir -p "$NSDIR"
C0=$(nsx curl -sS -m 15 -o /dev/null -w '%{http_code}' --resolve "example.org:443:$IP_EX" https://example.org/ 2>/dev/null)
C0b=$(nsx curl -sS -m 20 -o /dev/null -w '%{http_code}' --resolve "proof.ovh.net:443:$IP_OVH" https://proof.ovh.net/files/1Mb.dat 2>/dev/null)
say "baseline: example.org=${C0:-ERR} proof.ovh.net/1Mb.dat=${C0b:-ERR}"
[ "$C0" = "200" ] || { say "FAIL: 出网基线不成立"; exit 1; }

hr "SW5-A REJECT --reject-with tcp-reset vs 已建 keepalive 连接 (发包含 0.2s 节拍)"
rm -f "$NSDIR/probeA.txt"
nsx python3 "$BASE/probe-keepalive.py" "$IP_EX" 443 "$NSDIR/probeA.txt" 0.2 >"$NSDIR/probeA.err" 2>&1 &
PP=$!
for i in $(seq 1 50); do grep -q CONNECTED "$NSDIR/probeA.txt" 2>/dev/null && break; sleep 0.1; done
sleep 2
say "插入前末态: $(tail -1 "$NSDIR/probeA.txt")"
T0=$(nowms)
nsx iptables -I OUTPUT 1 -d "$IP_EX" -p tcp --dport 443 -m comment --comment cg-poc6-sw5-reject -j REJECT --reject-with tcp-reset
ERR=timeout
for i in $(seq 1 500); do
  grep -q '^ERROR' "$NSDIR/probeA.txt" 2>/dev/null && { ERR=hit; break; }
  sleep 0.02
done
DELA=$(( $(nowms) - T0 ))
say "REJECT: 插入->客户端报错 = ${DELA}ms"
tail -6 "$NSDIR/probeA.txt" | tee "$NSDIR/probeA.evidence.txt"
wait $PP 2>/dev/null
SW5A=$( [ "$ERR" = hit ] && echo PASS || echo FAIL )
say ">>> SW5-A REJECT 秒断已建连接 => $SW5A"

hr "SW5-B REJECT vs 已建慢速下载流 (proof.ovh.net/1Mb.dat, --limit-rate 20k)"
rm -f "$NSDIR/curlB.out"
nsx curl -sS -m 90 --limit-rate 20k -o /dev/null --resolve "proof.ovh.net:443:$IP_OVH" \
  -w 'code=%{http_code} time=%{time_total} size=%{size_download}\n' https://proof.ovh.net/files/1Mb.dat >"$NSDIR/curlB.out" 2>"$NSDIR/curlB.err" &
CP=$!
sleep 5
T0=$(nowms)
nsx iptables -I OUTPUT 1 -d "$IP_OVH" -p tcp --dport 443 -m comment --comment cg-poc6-sw5-reject2 -j REJECT --reject-with tcp-reset
wait $CP
say "REJECT 流中途: 插入->结束 $(($(nowms)-T0))ms | $(cat "$NSDIR/curlB.out") | $(tail -1 "$NSDIR/curlB.err")"
clear_cg

hr "SW5-C 对照 DROP vs 已建慢速下载流"
rm -f "$NSDIR/curlC.out"
nsx curl -sS -m 30 --limit-rate 20k -o /dev/null --resolve "proof.ovh.net:443:$IP_OVH" \
  -w 'code=%{http_code} time=%{time_total} size=%{size_download}\n' https://proof.ovh.net/files/1Mb.dat >"$NSDIR/curlC.out" 2>"$NSDIR/curlC.err" &
CP=$!
sleep 5
T0=$(nowms)
nsx iptables -I OUTPUT 1 -d "$IP_OVH" -p tcp --dport 443 -m comment --comment cg-poc6-sw5-drop -j DROP
wait $CP
say "DROP 流中途: 插入->结束 $(($(nowms)-T0))ms | $(cat "$NSDIR/curlC.out") | $(tail -1 "$NSDIR/curlC.err")"
clear_cg

hr "SW5-D 对照 DROP vs 已建 keepalive 连接 (应悬挂, 不 RST)"
rm -f "$NSDIR/probeD.txt"
nsx python3 "$BASE/probe-keepalive.py" "$IP_EX" 443 "$NSDIR/probeD.txt" 0.2 >"$NSDIR/probeD.err" 2>&1 &
PP=$!
for i in $(seq 1 50); do grep -q CONNECTED "$NSDIR/probeD.txt" 2>/dev/null && break; sleep 0.1; done
sleep 1
T0=$(nowms)
nsx iptables -I OUTPUT 1 -d "$IP_EX" -p tcp --dport 443 -m comment --comment cg-poc6-sw5-drop2 -j DROP
sleep 15
RST=$(grep -c 'ConnectionResetError' "$NSDIR/probeD.txt" || true)
HANG=$(grep -c '^HANG' "$NSDIR/probeD.txt" || true)
ALIVE=$(grep -c '^ALIVE' "$NSDIR/probeD.txt" || true)
kill $PP 2>/dev/null; wait $PP 2>/dev/null
say "DROP 15s: ALIVE=$ALIVE HANG=$HANG RST=$RST (RST=0 且 HANG>0 => 悬挂未秒断)"
tail -4 "$NSDIR/probeD.txt" | tee "$NSDIR/probeD.evidence.txt"
SW5D=$( [ "$RST" = "0" ] && [ "$HANG" -gt 0 ] && echo PASS || echo FAIL )
say ">>> SW5-D DROP 悬挂形态 => $SW5D"
clear_cg

hr "SW5-E 新连接失败形态"
nsx iptables -I OUTPUT 1 -d "$IP_EX" -p tcp --dport 443 -m comment --comment cg-poc6-sw5-drop3 -j DROP
D1=$(nsx curl -sS -m 8 -o /dev/null -w '%{http_code}|%{time_total}' --resolve "example.org:443:$IP_EX" https://example.org/ 2>/dev/null); R1=$?
say "DROP 态新连接: ${D1:-000} rc=$R1"
clear_cg
nsx iptables -I OUTPUT 1 -d "$IP_EX" -p tcp --dport 443 -m comment --comment cg-poc6-sw5-reject3 -j REJECT --reject-with tcp-reset
D2=$(nsx curl -sS -m 8 -o /dev/null -w '%{http_code}|%{time_total}' --resolve "example.org:443:$IP_EX" https://example.org/ 2>/dev/null); R2=$?
say "REJECT 态新连接: ${D2:-000} rc=$R2"
clear_cg
C1=$(nsx curl -sS -m 15 -o /dev/null -w '%{http_code}' --resolve "example.org:443:$IP_EX" https://example.org/ 2>/dev/null)
say "清规则后新连接: ${C1:-ERR}"
SW5E=$( [ "$C1" = "200" ] && echo PASS || echo FAIL )
say ">>> SW5-E 清规则复通 => $SW5E"

hr "SW5 残留"
show_out | tee "$NSDIR/sw5-output-final.txt"
guard "sw5-done"
hr "SW5 VERDICT"
say "A REJECT vs 已建连接(秒断)   => $SW5A (${DELA}ms)"
say "D DROP   vs 已建连接(悬挂)   => $SW5D"
say "E 清规则复通                 => $SW5E"
