#!/bin/bash
# SW4-A6 (补充判别) · ufw 的 reload 与 disable/enable(完整重启) 对两条机制的不同后果
# 目的: 回答产品问题——跟随发行版框架时选 "iptables 专用链+看门重assert" 还是 "独立 nft 表"
set -u
. /root/claudeguard-poc6/common.sh

SHADOW=$BASE/ufw-shadow
SRVDIR=$BASE/testroot
URL=http://10.233.6.1:18080/

probe(){ local o r; o=$(nsx curl -sS -m 5 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null); r=$?; echo "code=${o:-000} rc=$r"; }
probe_nobody(){ local o r; o=$(nsx setpriv --reuid=65534 --regid=65534 --clear-groups curl -sS -m 5 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null); r=$?; echo "code=${o:-000} rc=$r"; }

hr "SW4-A6-0 准备"
guard "sw4r-start"
rm -rf "$SHADOW"; cp -a /etc/ufw "$SHADOW"
mkdir -p "$SRVDIR"; echo "cg-poc6-ok" > "$SRVDIR/index.html"
( cd "$SRVDIR" && nohup python3 -m http.server 18080 --bind 10.233.6.1 >/dev/null 2>&1 & echo $! > "$BASE/httpd.pid" )
sleep 1
nsu ufw --force reset >/dev/null 2>&1
nsu ufw --force enable >/dev/null 2>&1
say "ufw(ns)=$(nsu ufw status | head -1)  host=$(ufw status | head -1)"

hr "SW4-A6-1 装载两条机制"
nsx "$BASE/cg-reassert.sh"
nsx nft add table inet cg
nsx nft 'add chain inet cg out { type filter hook output priority -10 ; policy accept ; }'
nsx nft add rule inet cg out meta skuid 0 accept
nsx nft add rule inet cg out ip daddr 10.233.6.1 tcp dport 18080 reject with tcp reset
say "iptables: $(nsx iptables -S CG-OUT | tr '\n' ' ')"
say "nft: $(nsx nft list table inet cg | tr '\n' ' ' | cut -c1-160)"
say "语义: root=$(probe $URL) nobody=$(probe_nobody $URL)"
nsx iptables -D OUTPUT -j CG-OUT   # 先摘掉 iptables 钩子, 便于分别判定
say "已摘 iptables 钩子(仅留 nft 表), 语义: root=$(probe $URL) nobody=$(probe_nobody $URL)"

hr "SW4-A6-2 ufw --force disable (完整 stop: flush_builtins)"
nsu ufw --force disable 2>&1 | tee "$EVID/sw4r-disable.txt"
I1=$(nsx iptables -S CG-OUT 2>&1); R1=$?
N1=$(nsx nft list table inet cg 2>&1); S1=$?
say "disable 后: iptables CG-OUT rc=$R1 (链体/规则可能被 -F 保留? 见下)"
say "$I1"
say "disable 后: nft inet cg rc=$S1"
say "$N1" | head -6
say "disable 后语义(nft-only): root=$(probe $URL) nobody=$(probe_nobody $URL)"

hr "SW4-A6-3 ufw --force enable (完整 start: 重新装框架链)"
nsu ufw --force enable 2>&1 | tee "$EVID/sw4r-enable.txt"
H=$(nsx iptables -S OUTPUT | grep -c 'CG-OUT' || true); H2=$(nsx iptables -S CG-OUT >/dev/null 2>&1; echo $?)
N2=$(nsx nft list table inet cg 2>&1); S2=$?
say "enable 后: OUTPUT 中 CG-OUT 钩子数=$H ; CG-OUT 链查询 rc=$H2 ; nft inet cg rc=$S2"
say "enable 后 nft 表:"; say "$N2" | head -6
say "enable 后语义(nft-only): root=$(probe $URL) nobody=$(probe_nobody $URL)"
# 重断言后共存
nsx "$BASE/cg-reassert.sh"
say "重断言后: root=$(probe $URL) nobody=$(probe_nobody $URL)"

hr "SW4-A6-4 判定"
if [ "$H2" != "0" ]; then IT="WIPED"; else IT="SURVIVED"; fi
say "iptables 专用链在 ufw disable/enable(完整重启) 后 => $IT"
if [ "$S2" = "0" ]; then NT="SURVIVED"; else NT="WIPED"; fi
say "独立 nft 表在 ufw disable/enable 后 => $NT"
say "iptables 专用链在 ufw reload 后 => SURVIVED (见 30-sw4-run.txt A3)"

hr "SW4-A6-5 拆除"
nsu ufw --force disable >/dev/null 2>&1
nsu ufw --force reset >/dev/null 2>&1
nsx iptables -D OUTPUT -j CG-OUT 2>/dev/null
nsx iptables -F CG-OUT 2>/dev/null; nsx iptables -X CG-OUT 2>/dev/null
nsx nft delete table inet cg 2>/dev/null
kill "$(cat "$BASE/httpd.pid" 2>/dev/null)" 2>/dev/null
say "ns 残留: iptables=[$(nsx iptables -S OUTPUT | tr '\n' ' ')] nft_cg=[$(nsx nft list table inet cg 2>&1 | head -1)]"
say "host ufw: $(ufw status | head -1)"
( cd /etc/ufw && find . -type f -exec sha256sum {} \; | sort ) > "$EVID/sw4r-etcufw-manifest-after.txt"
diff "$EVID/sw4-etcufw-manifest-before.txt" "$EVID/sw4r-etcufw-manifest-after.txt" > "$EVID/sw4r-etcufw-diff.txt" 2>&1
say "宿主 /etc/ufw: $([ -s "$EVID/sw4r-etcufw-diff.txt" ] && echo CHANGED || echo UNCHANGED)"
guard "sw4r-done"
