#!/bin/bash
# ClaudeGuard 守护安装器（root）——用 launchd 托管，避免 do shell script 杀后台子进程
set -u
DIR=/tmp/claudeguard
PLIST=/Library/LaunchDaemons/com.claudeguard.guardd.plist
LABEL=com.claudeguard.guardd
SCRIPT="$(cd "$(dirname "$0")" && pwd)/guardd.sh"

mkdir -p "$DIR"; chmod 777 "$DIR" 2>/dev/null
chmod 755 "$SCRIPT"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$SCRIPT</string>
    <string>run</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$DIR/guardd.out</string>
  <key>StandardErrorPath</key><string>$DIR/guardd.err</string>
</dict>
</plist>
EOF
chown root:wheel "$PLIST"; chmod 644 "$PLIST"

launchctl bootout "system/$LABEL" >/dev/null 2>&1
launchctl bootstrap system "$PLIST" 2>&1
launchctl enable "system/$LABEL" >/dev/null 2>&1
sleep 1
if launchctl print "system/$LABEL" >/dev/null 2>&1; then
  echo "installed"
else
  echo "install-failed"
  tail -5 "$DIR/guardd.err" 2>/dev/null
fi
