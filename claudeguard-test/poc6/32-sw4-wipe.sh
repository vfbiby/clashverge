#!/bin/bash
# SW4-A6(修正版) · 逐步判定矩阵: reload / disable / enable / reset 对 iptables 专用链与独立 nft 表的影响
set -u
. /root/claudeguard-poc6/common.sh

SHADOW=$BASE/ufw-shadow
SRVDIR=$BASE/testroot
URL=http://10.233.6.1:18080/

probe(){ local o r; o=$(nsx curl -sS -m 5 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null); r=$?; echo "code=${o:-000} rc=$r"; }
probe_nobody(){ local o r; o=$(nsx setpriv --reuid=65534 --regid=65534 --clear-groups curl -sS -m 5 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null); r=$?; echo "code=${o:-000} rc=$r"; }

state(){
  local ihook ichain ntab
  ihook=$(nsx iptables -S OUTPUT 2>/dev/null | grep -c -- '-j CG-OUT' || true)
  nsx iptables -S CG-OUT >/dev/null 2>&1 && ichain=YES || ichain=NO
  nsx nft list table inet cg >/dev/null 2>&1 && ntab=YES || ntab=NO
  printf 'CG-OUT链=%s 钩子=%s nft(inet cg)=%s | iptables语义 root=%s nobody=%s\n' \
    "$ichain" "$ihook" "$ntab" "$(probe $URL)" "$(probe_nobody $URL)"
}

hr "SW4-A6-0 准备"
guard "sw4w-start"
rm -rf "$SHADOW"; cp -a /etc/ufw "$SHADOW"
mkdir -p "$SRVDIR"; echo "cg-poc6-ok" > "$SRVDIR/index.html"
( cd "$SRVDIR" && nohup python3 -m http.server 18080 --bind 10.233.6.1 >/dev/null 2>&1 & echo $! > "$BASE/httpd.pid" )
sleep 1
nsu ufw --force reset >/dev/null 2>&1
nsu ufw --force enable >/dev/null 2>&1
nsx "$BASE/cg-reassert.sh"
nsx nft add table inet cg
nsx nft 'add chain inet cg out { type filter hook output priority -10 ; policy accept ; }'
nsx nft add rule inet cg out meta skuid 0 accept
nsx nft add rule inet cg out ip daddr 10.233.6.1 tcp dport 18080 reject with tcp reset
say "初始(ufw=$(nsu ufw status | head -1)): $(state)"

hr "SW4-A6-1 ufw reload"
nsu ufw reload >/dev/null 2>&1
say "reload 后: $(state)"

hr "SW4-A6-2 ufw --force disable"
nsu ufw --force disable >/dev/null 2>&1
say "disable 后: $(state)"

hr "SW4-A6-3 ufw --force enable"
nsu ufw --force enable >/dev/null 2>&1
say "enable 后: $(state)"

hr "SW4-A6-4 ufw --force reset (最激进: 重建规则集)"
nsu ufw --force reset >/dev/null 2>&1
say "reset 后: $(state)"

hr "SW4-A6-5 after.init 钩子能否在 enable 时自动重断言"
cat > "$SHADOW/after.init" <<'EOF'
#!/bin/sh
case "$1" in
  start) /root/claudeguard-poc6/cg-reassert.sh ;;
  stop)  : ;;
esac
exit 0
EOF
chmod +x "$SHADOW/after.init"
nsu ufw --force enable >/dev/null 2>&1
say "enable(+after.init) 后: $(state)"

hr "SW4-A6-6 判定矩阵"
cat > "$EVID/sw4-wipe-matrix.txt" <<'EOF'
动作                      | CG-OUT 链 | 钩子 | 独立 nft 表 | 语义
--------------------------+-----------+------+-------------+------
初始                      | 见上逐行记录
ufw reload                | 记录于 30-sw4-run.txt A3
ufw disable               | 见本次输出
ufw enable                | 见本次输出
ufw reset                 | 见本次输出
ufw enable + after.init   | 见本次输出
EOF
say "矩阵原始输出见上; 汇总表另写 REPORT.md"

hr "SW4-A6-7 拆除"
nsu ufw --force disable >/dev/null 2>&1
nsu ufw --force reset >/dev/null 2>&1
nsx iptables -D OUTPUT -j CG-OUT 2>/dev/null
nsx iptables -F CG-OUT 2>/dev/null; nsx iptables -X CG-OUT 2>/dev/null
nsx nft delete table inet cg 2>/dev/null
kill "$(cat "$BASE/httpd.pid" 2>/dev/null)" 2>/dev/null
say "ns 残留 iptables: $(nsx iptables -S OUTPUT | tr '\n' ' ')"
say "host ufw: $(ufw status | head -1)"
( cd /etc/ufw && find . -type f -exec sha256sum {} \; | sort ) > "$EVID/sw4w-etcufw-after.txt"
diff "$EVID/sw4-etcufw-manifest-before.txt" "$EVID/sw4w-etcufw-after.txt" > "$EVID/sw4w-etcufw-diff.txt" 2>&1
say "宿主 /etc/ufw: $([ -s "$EVID/sw4w-etcufw-diff.txt" ] && echo CHANGED || echo UNCHANGED)"
guard "sw4w-done"
