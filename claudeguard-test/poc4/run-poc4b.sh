#!/bin/bash
# =========================================================================
# PoC-4 补跑脚本 (run-1 的 SW1 反序判别有缺陷: 反序 DROP 只钉 1 个 IP,
# 而豁免 curl 走容器 DNS 视图解析到 172.66.157.237 未被钉 => 被误判 "未被拦").
# 本脚本: ① 快照重存(修正 0 字节快照); ② 反序判别用全 BLOCK_V4 集合重测;
#         ③ 复盘规范链; ④ 立即回滚到基线(钩子+链全清)。
# =========================================================================
set -u
cd /opt/poc4
OUT=/out
LOG="$OUT/log_b.txt"
hr(){ printf '\n========== %s ==========\n' "$*"; }
pass(){ printf '>>> PASS: %s\n' "$*"; }
fail(){ printf '>>> FAIL: %s\n' "$*"; }
note(){ printf '>>> INFO: %s\n' "$*"; }
ts(){ date '+%F %T'; }
exec > >(tee "$LOG") 2>&1

hr "RAN-B SW1 反序重测 (全 IP 钉死)"
echo "时间: $(ts)"
# 快照重存 + 有效性校验 (run-1 快照 0 字节事故)
iptables-save > /tmp/base.rules; ip6tables-save > /tmp/base6.rules
echo "快照字节数: $(wc -c < /tmp/base.rules) / $(wc -c < /tmp/base6.rules)  (必须 >0)"
[ "$(wc -c < /tmp/base.rules)" -gt 0 ] || { fail "快照仍为 0 字节, 中止(基线状态: $(iptables -S | tr '\n' '|'))"; exit 1; }
iptables -N MONETAFW 2>/dev/null; ip6tables -N MONETAFW 2>/dev/null
iptables -I OUTPUT 1 -j MONETAFW; ip6tables -I OUTPUT 1 -j MONETAFW
B4="104.20.23.154 104.20.26.136 160.79.104.10 172.66.147.243 172.66.157.237"

# 反序链: 全 IP DROP 在前, owner ACCEPT 在后 (首匹配 => 豁免应该也被咬)
iptables -F MONETAFW
for IP in $B4; do iptables -A MONETAFW -m tcp -p tcp -m multiport --dports 80,443 -d "$IP" -j DROP; done
iptables -A MONETAFW -m owner --uid-owner 5011 -m tcp -p tcp -m multiport --dports 80,443 -j ACCEPT
echo "反序链: $(iptables -S MONETAFW | tr '\n' '|')"
SC4=$(sudo -u monetafw env -u http_proxy -u https_proxy -u all_proxy HTTP_PROXY= HTTPS_PROXY= \
  /usr/bin/curl -m 6 -sS -o /dev/null -w '%{http_code} time=%{time_total}' "https://example.org" 2>/dev/null); RC4=$?
SCV=$(env -u http_proxy -u https_proxy -u all_proxy HTTP_PROXY= HTTPS_PROXY= \
  curl -m 6 -sS -o /dev/null -w '%{http_code} time=%{time_total}' "https://example.org" 2>/dev/null); RCV=$?
echo "反序: exempt(uid=5011) => '$SC4' exit=$RC4   victim(root) => '$SCV' exit=$RCV"
case "$SC4" in 200*) fail "SW1 反序(全 IP): 豁免还通?? 真语义不符"; ;; *) pass "SW1 反序(全 IP): 豁免 '$SC4' 也被拦 — iptables 首匹配胜出 = 与 macOS pf 后匹配语义相反, 完整实证";; esac

hr "RAN-B 规范链复盘 (豁免重排最前)"
iptables -F MONETAFW
iptables -A MONETAFW -m owner --uid-owner 5011 -m tcp -p tcp -m multiport --dports 80,443 -j ACCEPT
for IP in $B4; do iptables -A MONETAFW -m tcp -p tcp -m multiport --dports 80,443 -d "$IP" -j DROP; done
SC5=$(sudo -u monetafw env -u http_proxy -u https_proxy -u all_proxy HTTP_PROXY= HTTPS_PROXY= \
  /usr/bin/curl -m 8 -sS -o /dev/null -w '%{http_code}' "https://example.org" 2>/dev/null)
[ "$SC5" = "200" ] && pass "SW1 规范链复盘: 豁免 => 200" || fail "SW1 规范链复盘: '$SC5'"
SCV2=$(env -u http_proxy -u https_proxy -u all_proxy HTTP_PROXY= HTTPS_PROXY= \
  curl -m 6 -sS -o /dev/null -w '%{http_code}' "https://example.org" 2>/dev/null)
[ "$SCV2" = "200" ] && fail "规范链下 victim 竟通?!" || pass "规范链: victim(root) '$SCV2' (still被拦)"
echo "reverse_full=$SC4 victim_reverse=$SCV canonical_recheck=$SC5 victim_canonical=$SCV2" > "$OUT/sw1_b.txt"

hr "RAN-B 回滚到基线"
iptables -D OUTPUT 1 2>/dev/null; ip6tables -D OUTPUT 1 2>/dev/null
iptables -F MONETAFW 2>/dev/null; ip6tables -F MONETAFW 2>/dev/null
iptables -X MONETAFW 2>/dev/null; ip6tables -X MONETAFW 2>/dev/null
iptables-restore < /tmp/base.rules; ip6tables-restore < /tmp/base6.rules
echo "收尾全景:"; iptables -S | sed 's/^/  /'; ip6tables -S | sed 's/^/  /'
R=$(iptables -S | grep -c MONETAFW || true)
[ "$R" = "0" ] && pass "MONETAFW 零残留" || fail "MONETAFW 残留 $R"
R1=$(env -u http_proxy -u https_proxy -u all_proxy HTTP_PROXY= HTTPS_PROXY= \
  curl -m 8 -sS -o /dev/null -w '%{http_code}' "https://example.org" 2>/dev/null)
[ "$R1" = "200" ] && pass "网络验1 直连 example.org => 200" || fail "网络验1 => $R1"
note "补跑完成 $(ts)"
