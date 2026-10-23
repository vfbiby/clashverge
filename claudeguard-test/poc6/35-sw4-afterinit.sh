#!/bin/bash
# SW4-A9 · 验证 ufw 官方钩子 after.init 是否真的被框架路径调用 (start/stop), 用临时 netns, 不涉宿主机
set -u
. /root/claudeguard-poc6/common.sh

SH=$BASE/ufw-shadow2
MARK=$EVID/afterinit-calls.txt

hr "SW4-A9 准备"
guard "sw4a9-start"
ip netns add cgtmp
ip netns exec cgtmp ip link set lo up
rm -rf "$SH"; cp -a /etc/ufw "$SH"
sed -i 's/^ENABLED=.*/ENABLED=yes/' "$SH/ufw.conf"
grep -n '^ENABLED' "$SH/ufw.conf" | sed 's/^/  /'
cat > "$SH/after.init" <<'EOF'
#!/bin/sh
echo "after.init $1 $(date '+%F %T')" >> /root/claudeguard-poc6/evidence/afterinit-calls.txt
exit 0
EOF
chmod +x "$SH/after.init"
rm -f "$MARK"

hr "SW4-A9 框架路径 start/stop"
ip netns exec cgtmp unshare -m --propagation private /bin/sh -c \
  'mount --bind /root/claudeguard-poc6/ufw-shadow2 /etc/ufw && /usr/lib/ufw/ufw-init start quiet; echo "start rc=$?"' 2>&1 | tee "$EVID/sw4a9-start.txt"
ip netns exec cgtmp unshare -m --propagation private /bin/sh -c \
  'mount --bind /root/claudeguard-poc6/ufw-shadow2 /etc/ufw && /usr/lib/ufw/ufw-init stop; echo "stop rc=$?"' 2>&1 | tee "$EVID/sw4a9-stop.txt"
say "--- after.init 调用记录 ---"
cat "$MARK" 2>/dev/null || say "(无记录)"
C=$(grep -c 'after.init' "$MARK" 2>/dev/null || echo 0)
say "调用次数=$C (start 一次 + stop 一次 应为 2)"
[ "$C" -ge 2 ] && SW4A9=PASS || SW4A9=FAIL
say ">>> SW4-A9 after.init 钩子在框架路径被调用 => $SW4A9"

hr "SW4-A9 拆除"
ip netns delete cgtmp
rm -rf "$SH"
sleep 0.5
say "netns: [$(ip netns list | tr '\n' ' ')]  ufw: $(ufw status | head -1)"
guard "sw4a9-done"
