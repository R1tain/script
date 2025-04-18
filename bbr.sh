#!/usr/bin/env bash
#================================================================
# network_optimize.sh  v2.2  (2025‑04‑18)
#================================================================
set -euo pipefail

########################  用户可改默认  ##########################
CONF_FILE="/etc/sysctl.d/99-vps-net.conf"
LOG_FILE="/var/log/vps-net-tune.log"
DEFAULT_QDISC="fq"                 # fq 或 cake
DEFAULT_BW=""                      # cake 带宽
FILTER_EXCLUDE='^(lo$|docker|br-|veth|virbr|tap)'   # 跳过接口正则
#################################################################

# 彩色输出
USE_C=false; [[ -t 1 && -z "${NO_COLOR:-}" ]] && USE_C=true
c(){ $USE_C && printf '\e[1;%sm' "$1" || true; }
clr(){ $USE_C && printf '\e[0m' || true; }

# 日志
exec > >(tee -a "$LOG_FILE") 2>&1

#------------------- CLI -------------------
DRY=false; NONINT=false; RESTORE=""; declare -A USER_SPEED
help(){ cat <<H
用法: sudo $0 [OPTIONS]
  --dry-run                只打印不执行
  --non-interactive        不提示手输, 探测失败即退出
  --speed=eth0=1000,...    覆盖接口速率
  --qdisc=fq|cake:30Mbit   选择队列算法/带宽
  --restore=TIMESTAMP      还原备份
H
}
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) DRY=true ;;
    --non-interactive) NONINT=true ;;
    --speed=*)
        IFS=',' read -ra P <<< "${1#*=}"; for kv in "${P[@]}"; do
          USER_SPEED["${kv%%=*}"]=${kv#*=}; done ;;
    --qdisc=*) arg="${1#*=}"
        [[ $arg == fq ]] && DEFAULT_QDISC=fq || {
          [[ $arg =~ ^cake(:.*)?$ ]] || { echo "未知 qdisc"; exit 1; }
          DEFAULT_QDISC=cake; DEFAULT_BW="${arg#cake:}"
          [[ "$DEFAULT_BW" == "$arg" ]] && DEFAULT_BW=""; } ;;
    --restore=*) RESTORE="${1#*=}" ;;
    -h|--help) help; exit 0 ;;
    *) echo "未知参数 $1"; help; exit 1 ;;
  esac; shift; done

#------------------- 回滚 -------------------
if [[ -n $RESTORE ]]; then
  bak="$CONF_FILE.$RESTORE.bak"; [[ -f $bak ]] || { echo "无备份 $bak"; exit 1; }
  cp "$bak" "$CONF_FILE"; sysctl -p "$CONF_FILE"; echo "已还原 $bak"; exit 0
fi

(( EUID==0 )) || { echo "请用 sudo"; exit 1; }

#------------------- 依赖检查 -------------------
need_pkgs=()
command -v ethtool >/dev/null 2>&1 || need_pkgs+=(ethtool)
command -v tc      >/dev/null 2>&1 || need_pkgs+=(iproute2 iproute)
if (( ${#need_pkgs[@]} )); then
  OS=""
  [[ -f /etc/os-release ]] && OS=$(awk -F= '/^ID=/{print $2}' /etc/os-release | tr -d '"')
  echo -e "$(c 33)缺失依赖: ${need_pkgs[*]}$(clr)"
  case $OS in
    debian|ubuntu) apt-get update && apt-get -y install "${need_pkgs[@]}" ;;
    centos|rocky|fedora|rhel) dnf -y install "${need_pkgs[@]}" || yum -y install "${need_pkgs[@]}" ;;
    arch) pacman -Sy --noconfirm "${need_pkgs[@]}" ;;
    alpine) apk add --no-cache "${need_pkgs[@]}" ;;
    *) echo "未知发行版, 请自行安装: ${need_pkgs[*]}"; exit 1 ;;
  esac
fi

run(){ $DRY && echo "(dry) $*" || eval "$*"; }

#------------------- 环境 -------------------
VIRT=$(systemd-detect-virt || true)
IS_CT=false; [[ $VIRT =~ ^(lxc|openvz|docker|podman)$ ]] && IS_CT=true
KERN=$(uname -r | cut -d. -f1-2)
BBR_OK=$(awk 'BEGIN{s="'"$KERN"'";split(s,a,".");print (a[1]>4||a[1]==4&&a[2]>=9)?1:0}')

echo -e "$(c 34)=== VPS 网络优化 v2.2 开始 ===$(clr)"

#------------------- 资源 -------------------
mem_k=$(awk '/MemTotal/{print $2}' /proc/meminfo)
MEM_MB=$((mem_k/1024)); MEM_GB=$((mem_k/1024/1024))
CPU=$(nproc)
echo -e "内存 $(c 32)$MEM_MB MB$(clr)  CPU $(c 32)$CPU$(clr)"

#------------------- 网卡 -------------------
mapfile -t IFACES < <(ip -o link show up | awk -F': ' '$3~/ether/{print $2}' \
            | grep -Ev "$FILTER_EXCLUDE")
[[ ${#IFACES[@]} -eq 0 ]] && { echo "无需调优网卡"; exit 0; }

declare -A SPEED
for ifc in "${IFACES[@]}"; do
  sp="${USER_SPEED[$ifc]:-}"
  [[ -z $sp && -r /sys/class/net/$ifc/speed ]] && sp=$(cat /sys/class/net/$ifc/speed)
  if [[ -z $sp || $sp -le 0 ]]; then
    raw=$( { ethtool $ifc 2>/dev/null || true; } | awk -F': ' '/Speed/{print $2}')
    [[ $raw =~ ^[0-9]+ ]] && sp=${raw//Mb\/s/}
  fi
  # 无 /sys & ethtool → 吞吐估算
  if [[ -z $sp || $sp -le 0 ]]; then
    r1=$(grep "$ifc" /proc/net/dev | awk '{printf("%d\n",$2+$10)}')
    sleep 1
    r2=$(grep "$ifc" /proc/net/dev | awk '{printf("%d\n",$2+$10)}')
    delta=$(( r2-r1 )); mbps=$(( delta*8/1024/1024 ))
    (( mbps>9000 )) && sp=10000
    (( mbps>900 && mbps<=9000 )) && sp=1000
    (( mbps>90  && mbps<=900 )) && sp=100
  fi
  [[ -z $sp || $sp -le 0 ]] && {
      $NONINT && { echo "$ifc 速率未知"; exit 1; }
      read -rp "输入 $ifc 速率(Mb/s): " sp; }
  SPEED[$ifc]=$sp
  echo -e "  $ifc: $(c 32)$sp Mb/s$(clr)"
done

#------------------- 参数 -------------------
if   (( MEM_GB>=8 )); then S_MAX=16777216; S_DEF=8388608
elif (( MEM_GB>=2 )); then S_MAX=8388608;  S_DEF=4194304
else                       S_MAX=2097152;  S_DEF=1048576; fi
BACKLOG=$((CPU*32768))
echo -e "缓冲上限 $(c 33)$S_MAX$(clr) backlog $(c 33)$BACKLOG$(clr)"

ts=$(date +%s); [[ -f $CONF_FILE ]] && cp "$CONF_FILE" "$CONF_FILE.$ts.bak"

sysctl_gen(){ cat <<EOF
# generated $(date)
net.core.default_qdisc = $DEFAULT_QDISC
net.ipv4.tcp_congestion_control = $( ((BBR_OK)) && echo bbr || echo cubic )
net.core.netdev_max_backlog = $BACKLOG
net.core.somaxconn = 65535
net.core.rmem_default = $S_DEF
net.core.wmem_default = $S_DEF
net.core.rmem_max = $S_MAX
net.core.wmem_max = $S_MAX
net.ipv4.tcp_rmem = 4096 87380 $S_MAX
net.ipv4.tcp_wmem = 4096 65536 $S_MAX
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_max_syn_backlog = 262144
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_mem = 786432 1048576 1572864
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.ip_forward = 1
net.ipv4.route.gc_timeout = 100
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
vm.swappiness = 10
vm.dirty_ratio = 60
vm.dirty_background_ratio = 30
$( [[ -d /proc/sys/net/netfilter ]] && echo "net.netfilter.nf_conntrack_max = $((MEM_MB*64))" )
EOF
}

run "sysctl_gen > $CONF_FILE"
run "sysctl -p $CONF_FILE"

#------------------- H/W 调优 -------------------
if ! $IS_CT; then
  for ifc in "${!SPEED[@]}"; do
    sp=${SPEED[$ifc]}
    (( sp>=1000 )) && run ethtool -G $ifc rx 4096 tx 4096 || run ethtool -G $ifc rx 1024 tx 1024
    run ethtool -K $ifc tso off gso off gro off
    mask=$(printf '0x%x\n' $(( (1<<CPU)-1 )))
    for q in /sys/class/net/$ifc/queues/rx-*; do echo $mask > "$q/rps_cpus" || true; done
    for q in /sys/class/net/$ifc/queues/tx-*; do echo $mask > "$q/xps_cpus" || true; done
    echo 32768 > /proc/sys/net/core/rps_sock_flow_entries
  done
  
  if command -v irqbalance >/dev/null 2>&1 && [[ $CPU -gt 1 ]]; then
    run systemctl enable --now irqbalance
  fi

  run "cat > /etc/udev/rules.d/99-vps-net.rules <<'U'
SUBSYSTEM==\"net\", ACTION==\"add\", PROGRAM=\"/usr/sbin/ethtool -K %k tso off gso off gro off\"
U"
fi

#------------------- Qdisc -------------------
for ifc in "${!SPEED[@]}"; do
  run tc qdisc del dev $ifc root || true
  if [[ $DEFAULT_QDISC == fq ]]; then
      run tc qdisc add dev $ifc root fq
  else
      [[ -n $DEFAULT_BW ]] && run tc qdisc add dev $ifc root cake bandwidth $DEFAULT_BW \
                           || run tc qdisc add dev $ifc root cake
  fi
done

echo -e "$(c 34)=== 优化完成 $($DRY && echo DRY‑RUN || echo LIVE)! 建议重启 ===$(clr)"
