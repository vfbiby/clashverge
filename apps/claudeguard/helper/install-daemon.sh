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

# 引擎作为独立 launchd job（RunAtLoad 由 guardd 在武装时 bootstrap）
ENGINE_PLIST=/Library/LaunchDaemons/com.claudeguard.engine.plist
ENGINE_BIN="/Applications/Clash Verge.app/Contents/MacOS/verge-mihomo"
cat > "$ENGINE_PLIST" <<EPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.claudeguard.engine</string>
  <key>ProgramArguments</key>
  <array>
    <string>$ENGINE_BIN</string>
    <string>-d</string><string>$DIR/engine</string>
    <string>-f</string><string>$DIR/engine/config.yaml</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$DIR/engine.log</string>
  <key>StandardErrorPath</key><string>$DIR/engine.log</string>
</dict>
</plist>
EPLIST
chown root:wheel "$ENGINE_PLIST"; chmod 644 "$ENGINE_PLIST"

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
