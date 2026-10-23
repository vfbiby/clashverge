#!/bin/bash
# SW4' · ufw 共存实验 (全部在 netns cgpoc 内; /etc/ufw 用私有副本 bind-mount, 宿主文件零改动)
set -u
. /root/claudeguard-poc6/common.sh

SHADOW=$BASE/ufw-shadow
SRVDIR=$BASE/testroot
URL=http://10.233.6.1:18080/
NSURL=http://10.233.6.2:18081/

probe(){ local o r t; o=$(nsx curl -sS -m 5 -o /dev/null -w '%{http_code}|%{time_total}' "$1" 2>/dev/null); r=$?; echo "$o rc=$r"; }
probe_nobody(){ local o r t; o=$(nsx setpriv --reuid=65534 --regid=65534 --clear-groups curl -sS -m 5 -o /dev/null -w '%{http_code}|%{time_total}' "$1" 2>/dev/null); r=$?; echo "$o rc=$r"; }

hr "SW4-0 准备"
guard "sw4-start"
rm -rf "$SHADOW"; cp -a /etc/ufw "$SHADOW"
( cd /etc/ufw && find . -type f -exec sha256sum {} \; | sort ) > "$EVID/sw4-etcufw-manifest-before.txt"
say "shadow copy: $(du -sh "$SHADOW" | cut -f1), files=$(find "$SHADOW" -type f | wc -l)"

mkdir -p "$SRVDIR"; echo "cg-poc6-ok" > "$SRVDIR/index.html"
( cd "$SRVDIR" && nohup python3 -m http.server 18080 --bind 10.233.6.1 >"$EVID/sw4-httpd.log" 2>&1 & echo $! > "$BASE/httpd.pid" )
sleep 1
say "baseline(root / nobody) via CG-untouched path: root=$(probe $URL) nobody=$(probe_nobody $URL)"

hr "SW4-A1 netns 内 ufw enable (shadow /etc/ufw)"
nsu ufw --force reset >/dev/null 2>&1
nsu ufw --force enable 2>&1 | tee "$EVID/sw4-ufw-enable.txt"
say "--- ns ufw status ---"; nsu ufw status verbose 2>&1 | tee -a "$EVID/sw4-ufw-status.txt"
say "--- host ufw status (必须仍 inactive) ---"; ufw status | tee "$EVID/sw4-host-ufw-status.txt"
say "--- ns iptables 链全景 ---"; nsx iptables -S | tee "$EVID/sw4-iptables-after-enable.txt"

hr "SW4-A2 挂我们的 iptables 专用链 CG-OUT (首匹配豁免 uid0 + 封禁样本)"
cat > "$BASE/cg-reassert.sh" <<'EOF'
#!/bin/bash
# claudeguard 规则重断言(可在 ufw 的 after.init 里被调用)
iptables -N CG-OUT 2>/dev/null
iptables -F CG-OUT
iptables -A CG-OUT -m owner --uid-owner 0 -j ACCEPT
iptables -A CG-OUT -d 10.233.6.1 -p tcp --dport 18080 -j REJECT --reject-with tcp-reset
iptables -C OUTPUT -j CG-OUT 2>/dev/null || iptables -I OUTPUT 1 -j CG-OUT
EOF
chmod +x "$BASE/cg-reassert.sh"
nsx "$BASE/cg-reassert.sh"
nsx iptables -S CG-OUT | tee "$EVID/sw4-cg-out.txt"
nsx iptables -S OUTPUT | tee -a "$EVID/sw4-cg-out.txt"
R=$(probe $URL); N=$(probe_nobody $URL)
say "semantics: root(exempt)=$R   nobody(ban sample)=$N"
[ "${N%%|*}" = "000" ] && SW4A2=PASS || SW4A2=FAIL
say ">>> SW4-A2 封禁语义生效 => $SW4A2"

hr "SW4-A3 ufw reload 是否冲掉我们的 iptables 专用链?"
nsu ufw reload 2>&1 | tee "$EVID/sw4-ufw-reload.txt"
CH=$(nsx iptables -S CG-OUT 2>&1); RC=$?
say "CG-OUT 存在? rc=$RC  (rc!=0 表示链已消失)"
say "$CH"
nsx iptables -S OUTPUT | tee "$EVID/sw4-iptables-after-reload.txt"
R=$(probe $URL); N=$(probe_nobody $URL)
say "reload 后语义: root=$R nobody=$N  (nobody 若变 200 = 封禁被框架冲掉)"
if echo "$CH" | grep -q "CG-OUT" && [ "${N%%|*}" = "000" ]; then SW4A3=SURVIVED; else SW4A3=WIPED; fi
say ">>> SW4-A3 裸 iptables 专用链在 ufw reload 后的存活 => $SW4A3"

hr "SW4-A4 用 ufw 官方 after.init 钩子重断言"
cat > "$SHADOW/after.init" <<'EOF'
#!/bin/sh
case "$1" in
  start) /root/claudeguard-poc6/cg-reassert.sh ;;
  stop)  : ;;
esac
exit 0
EOF
chmod +x "$SHADOW/after.init"
nsu ufw reload 2>&1 | tee "$EVID/sw4-ufw-reload-hook.txt"
CH=$(nsx iptables -S CG-OUT 2>&1)
say "after.init 钩子后 CG-OUT: $(echo "$CH" | head -2 | tr '\n' ' ')"
R=$(probe $URL); N=$(probe_nobody $URL)
say "语义: root=$R nobody=$N"
if echo "$CH" | grep -q "CG-OUT" && [ "${N%%|*}" = "000" ]; then SW4A4=PASS; else SW4A4=FAIL; fi
say ">>> SW4-A4 after.init 钩子重断言 => $SW4A4"

hr "SW4-A5 独立 nft 原生表 (inet cg) 过一遍 ufw reload"
nsx nft add table inet cg
nsx nft 'add chain inet cg out { type filter hook output priority -10 ; policy accept ; }'
nsx nft add rule inet cg out meta skuid 0 accept
nsx nft add rule inet cg out ip daddr 10.233.6.1 tcp dport 18080 reject with tcp reset
nsx nft list table inet cg | tee "$EVID/sw4-nft-table.txt"
# 屏蔽 iptables 链, 单独观察 nft 表语义
nsx iptables -D OUTPUT -j CG-OUT 2>/dev/null
R=$(probe $URL); N=$(probe_nobody $URL)
say "nft-only 语义: root=$R nobody=$N"
nsu ufw reload 2>&1 | tee "$EVID/sw4-ufw-reload-nft.txt"
NT=$(nsx nft list table inet cg 2>&1); RC=$?
say "reload 后 inet cg 表: rc=$RC"
say "$NT" | head -12
R=$(probe $URL); N=$(probe_nobody $URL)
say "reload 后 nft-only 语义: root=$R nobody=$N"
if [ "$RC" = "0" ] && [ "${N%%|*}" = "000" ]; then SW4A5=SURVIVED; else SW4A5=WIPED; fi
say ">>> SW4-A5 独立 nft 表在 ufw reload 后的存活 => $SW4A5"

hr "SW4-B 共存下封禁/放行语义 + ufw 自身功能验证"
# ufw 自身 INPUT 策略: ns 内起监听, host 侧应被拒
( nsx nohup python3 -m http.server 18081 --bind 10.233.6.2 >"$EVID/sw4-nshttpd.log" 2>&1 & echo $! > "$BASE/nshttpd.pid" )
sleep 1
HB=$(curl -sS -m 4 -o /dev/null -w '%{http_code}' "$NSURL" 2>/dev/null); HR=$?
say "host -> ns 监听(ufw default deny incoming): code=${HB:-000} rc=$HR (预期失败)"
UFW_IN=$([ -z "${HB:-}" ] && echo BLOCKED || { [ "$HB" = "200" ] && echo ALLOWED || echo BLOCKED; })
say "ufw INPUT 策略生效 => $UFW_IN"
guard "sw4-mid"
# 恢复我们的链(与 nft 表共存), 复核两条机制的语义
nsx "$BASE/cg-reassert.sh"
R=$(probe $URL); N=$(probe_nobody $URL)
say "共存(iptables链+nft表+ufw) 语义: root=$R nobody=$N"
if [ "${N%%|*}" = "000" ] && [ "${R%%|*}" = "200" ]; then SW4B=PASS; else SW4B=FAIL; fi
say ">>> SW4-B 共存封禁语义 => $SW4B"

# 出网面(经 host NAT)复核: 白名单外仍可出网, 被封目标不可达
E=$(nsx curl -sS -m 10 -o /dev/null -w '%{http_code}' https://example.org 2>/dev/null)
say "共存态 ns -> https://example.org = ${E:-ERR}"
[ "$E" = "200" ] && SW4BE=PASS || SW4BE=FAIL
say ">>> SW4-B2 共存态出网 => $SW4BE"

hr "SW4-C 拆除"
nsu ufw --force disable 2>&1 | tee "$EVID/sw4-ufw-disable.txt"
nsu ufw --force reset >/dev/null 2>&1
nsx iptables -D OUTPUT -j CG-OUT 2>/dev/null
nsx iptables -F CG-OUT 2>/dev/null; nsx iptables -X CG-OUT 2>/dev/null
nsx nft delete table inet cg 2>/dev/null
kill "$(cat "$BASE/nshttpd.pid" 2>/dev/null)" 2>/dev/null
kill "$(cat "$BASE/httpd.pid" 2>/dev/null)" 2>/dev/null
sleep 1
say "--- ns 残留 (应为纯默认策略) ---"; nsx iptables -S | tee "$EVID/sw4-iptables-residue.txt"
say "--- ns nft 残留 ---"; nsx nft list ruleset | tee "$EVID/sw4-nft-residue.txt"
say "--- host ufw status (必须 inactive) ---"; ufw status | tee "$EVID/sw4-host-ufw-status-final.txt"
( cd /etc/ufw && find . -type f -exec sha256sum {} \; | sort ) > "$EVID/sw4-etcufw-manifest-after.txt"
diff "$EVID/sw4-etcufw-manifest-before.txt" "$EVID/sw4-etcufw-manifest-after.txt" > "$EVID/sw4-etcufw-diff.txt" 2>&1
say "宿主 /etc/ufw 是否被改动: $([ -s "$EVID/sw4-etcufw-diff.txt" ] && echo CHANGED || echo UNCHANGED)"
guard "sw4-done"

hr "SW4 VERDICT"
say "A2 专用链封禁语义            => $SW4A2"
say "A3 裸 iptables 链过 ufw reload => $SW4A3"
say "A4 after.init 钩子重断言      => $SW4A4"
say "A5 独立 nft 表过 ufw reload    => $SW4A5"
say "B  共存封禁语义               => $SW4B"
say "B2 共存出网                   => $SW4BE"
say "C  宿主 /etc/ufw 改动          => $([ -s "$EVID/sw4-etcufw-diff.txt" ] && echo CHANGED || echo UNCHANGED)"
