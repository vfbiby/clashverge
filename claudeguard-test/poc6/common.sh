#!/bin/bash
# PoC-6 共用: 生产栈护身符 + 日志 + 命名空间助手
set -u
BASE=/root/claudeguard-poc6
EVID=$BASE/evidence
mkdir -p "$EVID"
PROD_SVCS="mtcopy-gateway mtcopy-platform nginx"

ts(){ date '+%F %T'; }
hr(){ printf '\n========== %s ==========\n' "$*"; }
say(){ printf '%s\n' "$*"; }
# Ubuntu 26.04 是 uutils coreutils: %3N 不支持(会输出纳秒), 统一用 ns 折算 ms
nowms(){ echo $(( $(date +%s%N) / 1000000 )); }
pcount(){ pgrep -fc "$1" 2>/dev/null || true; }

# 生产栈护身符: 三服务 active + 本机 80 端口 200。任何一次不满足 -> 立即中止(exit 90)
guard(){
  local tag="$1" ok=1 a st="" code
  for s in $PROD_SVCS; do
    a=$(systemctl is-active "$s" 2>/dev/null)
    st="$st$s=$a "
    [ "$a" = "active" ] || ok=0
  done
  code=$(curl -m 3 -s -o /dev/null -w '%{http_code}' http://127.0.0.1/ 2>/dev/null)
  [ "$code" = "200" ] || ok=0
  printf '[GUARD %s] %shttp=%s -> %s\n' "$tag" "$st" "${code:-ERR}" "$([ $ok = 1 ] && echo OK || echo VIOLATION)" | tee -a "$EVID/guard.txt"
  if [ "$ok" != 1 ]; then
    printf '[GUARD %s] PRODUCTION VIOLATION -> abort\n' "$tag" | tee -a "$EVID/guard.txt"
    exit 90
  fi
}

# ns 内执行
nsx(){ ip netns exec cgpoc "$@"; }

# ns 内执行、且 /etc/ufw 被私有副本覆盖(安全: 绝不改宿主 /etc/ufw)
nsu(){
  ip netns exec cgpoc unshare -m --propagation private /bin/sh -c \
    'mount --bind /root/claudeguard-poc6/ufw-shadow /etc/ufw && exec "$@"' sh "$@"
}

# 裸 curl(无代理环境变量), $1=timeout $2=url  -> http_code
bare(){ env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
  curl -sS -m "$1" -o /dev/null -w '%{http_code}' "$2" 2>/dev/null; }

# 以 uid 65534(nobody) 发起的 ns 内 curl, 输出 "code exit"
as_nobody(){
  nsx setpriv --reuid=65534 --regid=65534 --clear-groups \
    env -u http_proxy -u https_proxy -u all_proxy curl -sS -m "$1" -o /dev/null -w '%{http_code}' "$2" 2>/dev/null
  echo " $?"
}
