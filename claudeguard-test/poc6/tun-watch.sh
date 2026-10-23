#!/bin/bash
WLOG=/root/claudeguard-poc6/evidence/tun-watch.txt
STOPFILE=/root/claudeguard-poc6/stop.tun
CTRL=127.0.0.1:9095
MIXED=http://127.0.0.1:7892
INTERVAL=15; FAILN=2; OKN=2
now(){ date '+%F %T'; }
gnow(){ curl -s -m 3 "$CTRL/proxies/$1" 2>/dev/null | grep -o '"now":"[^"]*"' | cut -d'"' -f4; }
gset(){ curl -s -m 3 -X PUT "$CTRL/proxies/$1" -d "{\"name\":\"$2\"}" -o /dev/null; }
probe(){ curl -x "$MIXED" -m 8 -sS -o /dev/null -w '%{http_code}' https://example.org 2>/dev/null; }
WF=0; WO=0; WI=0
while :; do
  [ -f "$STOPFILE" ] && { echo "STOP $(now)" >> "$WLOG"; exit 0; }
  CODE=$(probe); NOW=$(gnow ClaudeExit)
  if [ "$WI" = 0 ]; then
    if [ "$CODE" = "200" ]; then WO=$((WO+1)); WF=0; else WF=$((WF+1)); WO=0; fi
    if [ "$WF" -ge "$FAILN" ]; then
      echo "INJECT-REJECT $(now) probe=$CODE claude_exit=$NOW" >> "$WLOG"
      gset ClaudeExit REJECT; WI=1
    fi
  else
    if [ "$CODE" = "200" ]; then WO=$((WO+1)); else WO=0; fi
    if [ "$WO" -ge "$OKN" ]; then
      echo "RELEASE $(now) probe=$CODE claude_exit=$NOW" >> "$WLOG"
      gset ClaudeExit DIRECT; WI=0
    fi
  fi
  echo "WATCH $(now) probe=$CODE claude_exit=$(gnow ClaudeExit) injected=$WI" >> "$WLOG"
  sleep "$INTERVAL"
done
