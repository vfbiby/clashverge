#!/bin/bash
# SW3 · systemd 看门自愈 (host systemd, 瞬时 unit 落 /run/systemd/system = tmpfs, 重启不残留)
set -u
. /root/claudeguard-poc6/common.sh

UNIT=claudeguard-watch-test
UDIR=/run/systemd/system
STOPFILE=$BASE/stop.guard
STUB=$BASE/watch-stub.sh

# $1=extra [Service] 指令
write_unit(){
  cat > "$UDIR/$UNIT.service" <<EOF
[Unit]
Description=claudeguard PoC-6 watchdog restart test (transient)
After=network.target

[Service]
Type=simple
ExecStart=$STUB
Restart=always
RestartSec=2
KillSignal=SIGTERM
TimeoutStopSec=5
$1

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

hr "SW3-0 准备"
guard "sw3-start"
systemctl is-active systemd-journald >/dev/null || { say "FAIL: journald 不在"; exit 1; }
ls -ld /run/systemd/system | tee "$EVID/sw3-unitdir.txt"

cat > "$STUB" <<'EOF'
#!/bin/bash
# claudeguard 看门桩: 探活循环 + 停机文件形态 (真实看门机的骨架)
STOPFILE=/root/claudeguard-poc6/stop.guard
while :; do
  if [ -f "$STOPFILE" ]; then
    echo "STOPFILE seen, clean exit 0 ($(date '+%F %T'))"
    exit 0
  fi
  echo "watchdog heartbeat pid=$$ $(date '+%F %T')"
  sleep 1
done
EOF
chmod +x "$STUB"
rm -f "$STOPFILE"
write_unit ""
say "--- unit ---"; systemctl cat "$UNIT" | sed 's/^/  /'

hr "SW3-A kill -9 -> 自动重启 (Restart=always / RestartSec=2)"
systemctl start "$UNIT"
sleep 3
P0=$(systemctl show -p MainPID --value "$UNIT")
N0=$(systemctl show -p NRestarts --value "$UNIT")
A0=$(systemctl is-active "$UNIT")
say "initial: active=$A0 MainPID=$P0 NRestarts=$N0"
[ "$A0" = "active" ] || { say "FAIL: unit 未启动"; exit 1; }

T0=$(nowms)
kill -9 "$P0"
P1=$P0; N1=$N0; EL=timeout
for i in $(seq 1 100); do
  A=$(systemctl is-active "$UNIT" 2>/dev/null)
  P1=$(systemctl show -p MainPID --value "$UNIT")
  N1=$(systemctl show -p NRestarts --value "$UNIT")
  if [ "$A" = "active" ] && [ -n "$P1" ] && [ "$P1" != "0" ] && [ "$P1" != "$P0" ] && [ "${N1:-0}" -gt "${N0:-0}" ]; then
    EL=$(( $(nowms) - T0 ))
    break
  fi
  sleep 0.1
done
say "after kill -9: active=$A MainPID=$P1 NRestarts=$N1 elapsed=${EL}ms"
journalctl -u "$UNIT" --no-pager --since "-2min" | tail -25 | tee "$EVID/sw3-journal.txt"

if [ "$A" = "active" ] && [ "$P1" != "$P0" ] && [ "${N1:-0}" -gt "${N0:-0}" ] && [ "$EL" != "timeout" ] && [ "$EL" -le 5000 ]; then
  SW3A=PASS; say ">>> SW3-A PASS: kill -9 后 ${EL}ms 自愈 (NRestarts $N0->$N1)"
else
  SW3A=FAIL; say ">>> SW3-A FAIL: active=$A pid=$P0->$P1 NRestarts=$N0->$N1 elapsed=$EL"
fi
guard "sw3-after-restart"

hr "SW3-B systemctl stop -> 不再拉起"
systemctl stop "$UNIT"
sleep 6
A2=$(systemctl is-active "$UNIT")
PROC=$(pcount "$STUB")
say "after stop(+6s): active=$A2 stub_procs=${PROC} (NRestarts 在 stop 后被 systemd 清零, 不作判据)"
if [ "$A2" = "inactive" ] && [ "$PROC" = "0" ]; then
  SW3B=PASS; say ">>> SW3-B PASS: stop 后 6s 无重启, 无残留进程"
else
  SW3B=FAIL; say ">>> SW3-B FAIL: active=$A2 procs=$PROC"
fi

hr "SW3-C 停机文件语义: Restart=always 下 exit 0 会不会被拉起?"
systemctl reset-failed "$UNIT" 2>/dev/null; rm -f "$STOPFILE"
systemctl start "$UNIT"; sleep 2
NC=$(systemctl show -p NRestarts --value "$UNIT")
say "C1 initial: active=$(systemctl is-active "$UNIT") NRestarts=$NC"
touch "$STOPFILE"; sleep 6
A1=$(systemctl is-active "$UNIT"); N1C=$(systemctl show -p NRestarts --value "$UNIT"); P1C=$(pcount "$STUB")
say "C1 (Restart=always, 无 RestartPreventExitStatus): active=$A1 procs=$P1C NRestarts=$NC->$N1C"
if [ "$A1" != "inactive" ] || [ "$P1C" != "0" ]; then
  C1_VERDICT="会拉起(停机文件单独无效)"; SW3C1=EXPECTED
else
  C1_VERDICT="未被拉起"; SW3C1=UNEXPECTED
fi
say ">>> C1 结论: $C1_VERDICT"

systemctl stop "$UNIT" 2>/dev/null; systemctl reset-failed "$UNIT" 2>/dev/null
write_unit "RestartPreventExitStatus=0"
systemctl cat "$UNIT" | grep -n RestartPreventExitStatus | sed 's/^/  /'
rm -f "$STOPFILE"; systemctl start "$UNIT"; sleep 2
NB=$(systemctl show -p NRestarts --value "$UNIT")
say "C2 initial: active=$(systemctl is-active "$UNIT") NRestarts=$NB"
touch "$STOPFILE"; sleep 6
A3=$(systemctl is-active "$UNIT"); N3=$(systemctl show -p NRestarts --value "$UNIT"); P2C=$(pcount "$STUB")
say "C2 (+RestartPreventExitStatus=0): active=$A3 procs=$P2C NRestarts=$NB->$N3"
if [ "$A3" = "inactive" ] && [ "$P2C" = "0" ] && [ "${N3:-0}" = "${NB:-0}" ]; then
  SW3C=PASS; say ">>> SW3-C PASS: exit 0 不被拉起, 停机文件语义成立"
else
  SW3C=FAIL; say ">>> SW3-C FAIL: active=$A3 procs=$P2C NRestarts=$NB->$N3"
fi
rm -f "$STOPFILE"

hr "SW3-D 拆除 unit"
systemctl stop "$UNIT" 2>/dev/null
systemctl disable "$UNIT" 2>/dev/null
rm -f "$UDIR/$UNIT.service"
systemctl daemon-reload
systemctl reset-failed "$UNIT" 2>/dev/null
sleep 1
systemctl cat "$UNIT" >/dev/null 2>&1 && { say "FAIL: unit 仍可见"; SW3D=FAIL; } || { SW3D=PASS; say ">>> SW3-D PASS: unit 已从 systemd 视图移除"; }
ls -l "$UDIR/$UNIT.service" 2>&1 | sed 's/^/  /'
say "残留进程: $(pcount "$STUB")"
guard "sw3-done"

hr "SW3 VERDICT"
say "SW3-A kill -9 自愈(<=5s)     => $SW3A"
say "SW3-B stop 后不拉起           => $SW3B"
say "SW3-C1 停机文件单独(always)   => $SW3C1 ($C1_VERDICT)"
say "SW3-C 停机文件+PreventExit0  => $SW3C"
say "SW3-D unit 移除零残留         => $SW3D"
