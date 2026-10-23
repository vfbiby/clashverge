#!/bin/bash
# claudeguard 规则重断言(可在 ufw 的 after.init 里被调用)
iptables -N CG-OUT 2>/dev/null
iptables -F CG-OUT
iptables -A CG-OUT -m owner --uid-owner 0 -j ACCEPT
iptables -A CG-OUT -d 10.233.6.1 -p tcp --dport 18080 -j REJECT --reject-with tcp-reset
iptables -C OUTPUT -j CG-OUT 2>/dev/null || iptables -I OUTPUT 1 -j CG-OUT
