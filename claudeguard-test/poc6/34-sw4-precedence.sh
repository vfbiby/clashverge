#!/bin/bash
# SW4-A8 · 判决力测试: 当 ufw 策略与我们的豁免冲突时, 谁赢?
#   (a) iptables 专用链挂在 OUTPUT 首位 -> ACCEPT 是否终止整表遍历(可覆盖框架策略)
#   (b) 独立 nft 基链 ACCEPT -> 是否会被 ufw 同 hook 的 DROP 压过
set -u
. /root/claudeguard-poc6/common.sh

SHADOW=$BASE/ufw-shadow
SRVDIR=$BASE/testroot
URL=http://10.233.6.1:18080/

probe(){ nsx curl -sS -m 5 -o /dev/null -w 'code=%{http_code}' "$1" 2>/dev/null; echo " rc=$?"; }
sn(){ nsx setpriv --reuid=65534 --regid=65534 --clear-groups curl -sS -m 5 -o /dev/null -w 'code=%{http_code}' "$1" 2>/dev/null; echo " rc=$?"; }
eg(){ nsx curl -sS -m 6 -o /dev/null -w 'code=%{http_code}' https://example.org 2>/dev/null; echo " rc=$?"; }

hr "SW4-A8-0 准备: ufw 在 ns 内启用并设 default deny outgoing (与我们的豁免正面冲突)"
guard "sw4p-start"
rm -rf "$SHADOW"; cp -a /etc/ufw "$SHADOW"
mkdir -p "$SRVDIR"; echo "cg-poc6-ok" > "$SRVDIR/index.html"
( cd "$SRVDIR" && nohup python3 -m http.server 18080 --bind 10.233.6.1 >/dev/null 2>&1 & echo $! > "$BASE/httpd.pid" )
sleep 1
nsu ufw --force reset >/dev/null 2>&1
nsu ufw --force enable >/dev/null 2>&1
nsu ufw default deny outgoing >/dev/null 2>&1
nsu ufw reload >/dev/null 2>&1
say "ufw(ns): $(nsu ufw status verbose | tr '\n' ' ' | cut -c1-140)"
say "deny outgoing 生效? root->example.org: $(eg) (预期失败)"
say "deny outgoing 下 root->测试服务: $(probe $URL) (预期失败)"

hr "SW4-A8-1 (a) iptables 专用链置顶 + uid0 ACCEPT"
nsx "$BASE/cg-reassert.sh"
nsx iptables -S OUTPUT | head -3 | tee "$EVID/sw4p-order.txt"
say "root->测试服务: $(probe $URL)  (若 200 => 我们的 ACCEPT 终止了整表遍历)"
say "root->example.org: $(eg)"
say "nobody->测试服务: $(sn "$URL") (预期仍被拦)"

hr "SW4-A8-2 (b) 摘掉 iptables 钩子, 改用独立 nft 表 (同 hook, priority -10)"
nsx iptables -D OUTPUT -j CG-OUT
nsx nft add table inet cg
nsx nft 'add chain inet cg out { type filter hook output priority -10 ; policy accept ; }'
nsx nft add rule inet cg out meta skuid 0 accept
nsx nft add rule inet cg out ip daddr 10.233.6.1 tcp dport 18080 reject with tcp reset
nsx nft list table inet cg | tee "$EVID/sw4p-nft.txt"
say "nft 基链 accept 在 ufw DROP 之前命中: root->测试服务: $(probe $URL)"
say "root->example.org: $(eg) (若仍失败 => nft 的 accept 不终止同 hook 其他基链, ufw DROP 仍生效)"
say "nobody->测试服务: $(sn "$URL")"

hr "SW4-A8-3 恢复 ufw 默认(allow outgoing) 复核共存"
nsu ufw default allow outgoing >/dev/null 2>&1
nsu ufw reload >/dev/null 2>&1
say "allow outgoing 后 root->测试服务: $(probe $URL)  nobody: $(sn "$URL")  egress: $(eg)"
nsx "$BASE/cg-reassert.sh"
say "两条机制同时在场: root=$(probe $URL) nobody=$(sn "$URL")"

hr "SW4-A8-4 拆除"
nsu ufw --force disable >/dev/null 2>&1
nsu ufw --force reset >/dev/null 2>&1
nsx iptables -D OUTPUT -j CG-OUT 2>/dev/null
nsx iptables -F CG-OUT 2>/dev/null; nsx iptables -X CG-OUT 2>/dev/null
nsx nft delete table inet cg 2>/dev/null
kill "$(cat "$BASE/httpd.pid" 2>/dev/null)" 2>/dev/null
say "ns 残留: $(nsx iptables -S OUTPUT | tr '\n' ' ')"
say "host ufw: $(ufw status | head -1)"
( cd /etc/ufw && find . -type f -exec sha256sum {} \; | sort ) > "$EVID/sw4p-etcufw-after.txt"
diff "$EVID/sw4-etcufw-manifest-before.txt" "$EVID/sw4p-etcufw-after.txt" > "$EVID/sw4p-etcufw-diff.txt" 2>&1
say "宿主 /etc/ufw: $([ -s "$EVID/sw4p-etcufw-diff.txt" ] && echo CHANGED || echo UNCHANGED)"
guard "sw4p-done"
