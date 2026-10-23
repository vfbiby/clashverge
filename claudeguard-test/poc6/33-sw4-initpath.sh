#!/bin/bash
# SW4-A7 · 走发行版真正的框架路径: systemd ufw.service 的 ExecStart/ExecStop
#   ExecStart=/usr/lib/ufw/ufw-init start quiet ; ExecStop=/usr/lib/ufw/ufw-init stop
# 这一步才对应 "系统重启 / systemctl restart ufw / 包升级" 的实际行为
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
  printf 'CG-OUT链=%s 钩子=%s nft(inet_cg)=%s | iptables语义 root=%s nobody=%s\n' \
    "$ichain" "$ihook" "$ntab" "$(probe $URL)" "$(probe_nobody $URL)"
}

hr "SW4-A7-0 准备"
guard "sw4i-start"
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
say "初始: $(state)"

hr "SW4-A7-1 ufw-init stop (等价 systemctl stop ufw: flush_builtins)"
nsu /usr/lib/ufw/ufw-init stop 2>&1 | tee "$EVID/sw4i-stop.txt"
say "stop 后: $(state)"
nsx iptables -S OUTPUT | tee "$EVID/sw4i-iptables-after-stop.txt"

hr "SW4-A7-2 ufw-init start quiet (等价 systemctl start ufw)"
nsu /usr/lib/ufw/ufw-init start quiet 2>&1 | tee "$EVID/sw4i-start.txt"
say "start 后: $(state)"

hr "SW4-A7-3 重断言 + after.init 钩子 + 再现 stop/start"
nsx "$BASE/cg-reassert.sh"
cat > "$SHADOW/after.init" <<'EOF'
#!/bin/sh
case "$1" in
  start) /root/claudeguard-poc6/cg-reassert.sh ;;
  stop)  : ;;
esac
exit 0
EOF
chmod +x "$SHADOW/after.init"
nsu /usr/lib/ufw/ufw-init stop >/dev/null 2>&1
nsu /usr/lib/ufw/ufw-init start quiet >/dev/null 2>&1
say "stop/start(+after.init) 后: $(state)"
nsx iptables -S OUTPUT | tee "$EVID/sw4i-iptables-after-hook.txt"

hr "SW4-A7-4 判定"
say "(对照) ufw reload / --force disable / --force enable / --force reset: 均 SURVIVED —— 见 32-sw4-wipe-run.txt"
say "ufw-init stop(框架停机路径) 结果见 A7-1 行"
say "ufw-init start 结果见 A7-2 行"
say "after.init 重断言结果见 A7-3 行"

hr "SW4-A7-5 拆除"
nsu ufw --force disable >/dev/null 2>&1
nsu ufw --force reset >/dev/null 2>&1
nsx iptables -D OUTPUT -j CG-OUT 2>/dev/null
nsx iptables -F CG-OUT 2>/dev/null; nsx iptables -X CG-OUT 2>/dev/null
nsx nft delete table inet cg 2>/dev/null
kill "$(cat "$BASE/httpd.pid" 2>/dev/null)" 2>/dev/null
say "ns 残留 iptables: $(nsx iptables -S OUTPUT | tr '\n' ' ')"
say "host ufw: $(ufw status | head -1)"
( cd /etc/ufw && find . -type f -exec sha256sum {} \; | sort ) > "$EVID/sw4i-etcufw-after.txt"
diff "$EVID/sw4-etcufw-manifest-before.txt" "$EVID/sw4i-etcufw-after.txt" > "$EVID/sw4i-etcufw-diff.txt" 2>&1
say "宿主 /etc/ufw: $([ -s "$EVID/sw4i-etcufw-diff.txt" ] && echo CHANGED || echo UNCHANGED)"
guard "sw4i-done"
