#!/usr/bin/env bash
#================================================================
# network_optimize.sh  v2.10  (2025‑04‑18)
#================================================================
set -euo pipefail

###################### 可调默认 #################################
CONF_FILE="/etc/sysctl.d/99-vps-net.conf"
LOG_FILE="/var/log/vps-net-tune.log"
DEFAULT_QDISC="fq"                       # fq 或 cake
DEFAULT_BW=""
FILTER_EXCLUDE='^(lo$|docker|br-|veth|virbr|tap)'  # 排除接口
################################################################

# ---------- 彩色 ----------
use_c=false; [[ -t 1 && -z "${NO_COLOR:-}" ]] && use_c=true
c(){ $use_c && printf '\e[1;%sm' "$1" || true; }; clr(){ $use_c && printf '\e[0m' || true; }

# ---------- 日志 ----------
exec > >(tee -a "$LOG_FILE") 2>&1

# ---------- CLI ----------
DRY=false; NONINT=false; RESTORE=""; CPU_OVERRIDE=""; declare -A USER_SPEED
help(){ cat <<H
用法: sudo $0 [OPTIONS]
  --dry-run                  只打印不执行
  --non-interactive          探测失败直接退出
  --cpu=N                    手动指定用于调优的 CPU 数
  --speed=eth0=1000,...      覆盖接口速率 (Mb/s)
  --qdisc=fq  |  --qdisc=cake:30Mbit
  --restore=TIMESTAMP        还原旧备份
H
}
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) DRY=true ;;
    --non-interactive) NONINT=true ;;
    --cpu=*) CPU_OVERRIDE=${1#*=} ;;
    --speed=*) IFS=',' read -ra P <<< "${1#*=}"; for kv in "${P[@]}"; do
                 USER_SPEED["${kv%%=*}"]=${kv#*=}; done ;;
    --qdisc=*) arg=${1#*=}
               if [[ $arg == fq ]]; then DEFAULT_QDISC=fq
               elif [[ $arg =~ ^cake(:.*)?$ ]]; then DEFAULT_QDISC=cake; DEFAULT_BW=${arg#cake:}
                    [[ $DEFAULT_BW == "$arg" ]] && DEFAULT_BW=""; else
               echo "未知 qdisc"; exit 1; fi ;;
    --restore=*) RESTORE=${1#*=} ;;
    -h|--help) help; exit 0 ;;
    *) echo "未知参数 $1"; help; exit 1 ;;
  esac; shift; done

# ---------- 回滚 ----------
if [[ -n $RESTORE ]]; then
  bak="$CONF_FILE.$RESTORE.bak"
  [[ -f $bak ]] || { echo "无备份 $bak"; exit 1; }
  cp "$bak" "$CONF_FILE"
  echo "已还原 $bak"
  exit 0
fi
(( EUID==0 )) || { echo "请用 sudo"; exit 1; }

# ---------- 依赖 ----------
need=()
command -v ethtool >/dev/null 2>&1 || need+=(ethtool)
command -v tc      >/dev/null 2>&1 || need+=(iproute2 iproute)
if (( ${#need[@]} )); then
  echo -e "$(c 33)安装依赖: ${need[*]}$(clr)"
  . /etc/os-release
  case $ID in
    debian|ubuntu) apt-get update && apt-get -y install "${need[@]}" ;;
    rocky|centos|rhel|fedora) dnf -y install "${need[@]}" || yum -y install "${need[@]}" ;;
    arch) pacman -Sy --noconfirm "${need[@]}" ;;
    alpine) apk add --no-cache "${need[@]}" ;;
    *) echo "未知发行版, 请手动安装: ${need[*]}"; exit 1 ;;
  esac
fi

# ---------- 环境 ----------
VIRT=$(systemd-detect-virt || true)
IS_CT=false; [[ $VIRT =~ ^(lxc|openvz|docker|podman)$ ]] && IS_CT=true
KERN=$(uname -r | cut -d. -f1-2)
BBR_OK=$(awk 'BEGIN{s="'"$KERN"'"; split(s,a,"."); print (a[1]>4||a[1]==4&&a[2]>=9)?1:0}')

echo -e "$(c 34)=== VPS 网络优化 v2.10 开始 ===$(clr)"

# ---------- 资源 ----------
mem_k=$(awk '/MemTotal/{print $2}' /proc/meminfo)
MEM_MB=$((mem_k/1024)); MEM_GB=$((mem_k/1024/1024))
CPU_QUOTA=$(nproc)
CPU_TOTAL=$(grep -c '^processor' /proc/cpuinfo)
[[ -n $CPU_OVERRIDE ]] && CPU_QUOTA=$CPU_OVERRIDE
echo -e "内存 $(c 32)$MEM_MB MB$(clr)  CPU(quota) $(c 32)$CPU_QUOTA$(clr)  vCPU(total) $CPU_TOTAL"

# ---------- 网卡 ----------
mapfile -t IFACES < <(
    ip -o -br link show up \
    | awk '{print $1}' \
    | sed 's/@.*//' \
    | grep -Ev "$FILTER_EXCLUDE"
)
[[ ${#IFACES[@]} -eq 0 ]] && { echo "无可调优网卡"; exit 0; }

declare -A SPEED
for ifc in "${IFACES[@]}"; do
  sp="${USER_SPEED[$ifc]:-}"
  if [[ -z $sp ]]; then
    val=$(cat "/sys/class/net/$ifc/speed" 2>/dev/null || echo "")
    [[ $val =~ ^[0-9]+$ ]] && sp=$val
  fi
  if [[ -z $sp ]]; then
    raw=$( { ethtool "$ifc" 2>/dev/null || true; } | awk -F': ' '/Speed/{print $2}')
    [[ $raw =~ ^[0-9]+ ]] && sp=${raw//Mb\/s/}
  fi
  if [[ -z $sp ]]; then
    r1=$(grep "$ifc" /proc/net/dev | awk '{printf("%d",$2+$10)}')
    sleep 1
    r2=$(grep "$ifc" /proc/net/dev | awk '{printf("%d",$2+$10)}')
    delta=$(( r2 - r1 )); mbps=$(( delta*8/1024/1024 ))
    (( mbps>9000 )) && sp=10000
    (( mbps>900 && mbps<=9000 )) && sp=1000
    (( mbps>90  && mbps<=900 )) && sp=100
  fi
  if [[ -z $sp ]]; then
    $NONINT && { echo "$ifc 速率未知"; exit 1; }
    read -rp "输入 $ifc 速率(Mb/s): " sp
  fi
  SPEED[$ifc]=$sp
  echo -e "  $ifc: $(c 32)$sp Mb/s$(clr)"
done

# ---------- 内核参数 & 备份 ----------
if   (( MEM_GB>=8 )); then S_MAX=16777216; S_DEF=8388608
elif (( MEM_GB>=2 )); then S_MAX=8388608;  S_DEF=4194304
else                       S_MAX=2097152;  S_DEF=1048576; fi
BACKLOG=$((CPU_QUOTA*32768)); (( BACKLOG<4096 )) && BACKLOG=4096
echo -e "缓冲上限 $(c 33)$S_MAX$(clr) backlog $(c 33)$BACKLOG$(clr)"

ts=$(date +%s)
[[ -f $CONF_FILE ]] && cp "$CONF_FILE" "$CONF_FILE.$ts.bak"

# ---------- 生成持久配置 ----------
cat > "$CONF_FILE" <<EOF
# generated $(date)
net.core.default_qdisc = $DEFAULT_QDISC
net.ipv4.tcp_congestion_control = $([[ $BBR_OK == 1 ]] && echo bbr || echo cubic)
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
net.ipv4.tcp_retries1 = 3
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

# ---------- 应用 sysctl ----------
declare -A SYSCTL_SETTINGS=(
  [net.core.default_qdisc]="$DEFAULT_QDISC"
  [net.ipv4.tcp_congestion_control]="$([[ $BBR_OK == 1 ]] && echo bbr || echo cubic)"
  [net.core.netdev_max_backlog]="$BACKLOG"
  [net.core.somaxconn]="65535"
  [net.core.rmem_default]="$S_DEF"
  [net.core.wmem_default]="$S_DEF"
  [net.core.rmem_max]="$S_MAX"
  [net.core.wmem_max]="$S_MAX"
  [net.ipv4.tcp_rmem]="4096 87380 $S_MAX"
  [net.ipv4.tcp_wmem]="4096 65536 $S_MAX"
  [net.ipv4.udp_rmem_min]="8192"
  [net.ipv4.udp_wmem_min]="8192"
  [net.ipv4.tcp_tw_reuse]="1"
  [net.ipv4.tcp_fin_timeout]="15"
  [net.ipv4.tcp_max_tw_buckets]="2000000"
  [net.ipv4.tcp_max_syn_backlog]="262144"
  [net.ipv4.tcp_moderate_rcvbuf]="1"
  [net.ipv4.tcp_mem]="786432 1048576 1572864"
  [net.ipv4.tcp_slow_start_after_idle]="0"
  [net.ipv4.tcp_fastopen]="3"
  [net.ipv4.tcp_window_scaling]="1"
  [net.ipv4.tcp_mtu_probing]="1"
  [net.ipv4.tcp_syncookies]="1"
  [net.ipv4.tcp_retries1]="3"
  [net.ipv4.tcp_synack_retries]="3"
  [net.ipv4.ip_local_port_range]="1024 65535"
  [net.ipv4.ip_forward]="1"
  [net.ipv4.route.gc_timeout]="100"
)
for key in "${!SYSCTL_SETTINGS[@]}"; do
  file="/proc/sys/${key//./\/}"
  if [[ -w $file ]]; then
    if ! $DRY; then
      sysctl -w "$key=${SYSCTL_SETTINGS[$key]}" >/dev/null 2>&1
    else
      echo "(dry) sysctl -w $key=${SYSCTL_SETTINGS[$key]}"
    fi
  fi
done

# ---------- H/W 调优 ----------
read_max(){ ethtool -g "$1" 2>/dev/null | awk '
/RX:/ && $2~/^[0-9]+$/ {rx=$2}
/TX:/ && $2~/^[0-9]+$/ {tx=$2}
END{printf "%s %s",rx,tx}' ; }

if ! $IS_CT; then
  for ifc in "${!SPEED[@]}"; do
    sp=${SPEED[$ifc]}
    read rx_max tx_max <<<"$(read_max "$ifc")"
    [[ -z $rx_max ]] && rx_max=256; [[ -z $tx_max ]] && tx_max=$rx_max
    (( sp>=1000 )) && want=4096 || want=1024
    (( want>rx_max )) && want=$rx_max
    $DRY && echo "(dry) ethtool -G $ifc rx $want tx $want" \
         || ethtool -G "$ifc" rx $want tx $want
    $DRY && echo "(dry) ethtool -K $ifc tso off gso off gro off" \
         || ethtool -K "$ifc" tso off gso off gro off

    if (( CPU_QUOTA > 1 )); then
      mask=$(printf '0x%x\n' $(( (1<<CPU_QUOTA)-1 )))
      for q in /sys/class/net/$ifc/queues/rx-*; do
        [[ -w $q/rps_cpus ]] && { echo $mask > "$q/rps_cpus" 2>/dev/null || true; }
      done
      for q in /sys/class/net/$ifc/queues/tx-*; do
        [[ -w $q/xps_cpus ]] && { echo $mask > "$q/xps_cpus" 2>/dev/null || true; }
      done
      # 容错写入 rps_sock_flow_entries
      if [[ -w /proc/sys/net/core/rps_sock_flow_entries ]]; then
        if ! $DRY; then
          echo 32768 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true
        else
          echo "(dry) echo 32768 > /proc/sys/net/core/rps_sock_flow_entries"
        fi
      fi
    fi
  done

  if command -v irqbalance >/dev/null 2>&1 && (( CPU_TOTAL > 1 )); then
    $DRY && echo "(dry) systemctl enable --now irqbalance" \
         || systemctl enable --now irqbalance
  fi
fi

# ---------- Qdisc ----------
for ifc in "${!SPEED[@]}"; do
  $DRY && echo "(dry) tc qdisc del dev $ifc root" \
       || tc qdisc del dev "$ifc" root >/dev/null 2>&1 || true
  if [[ $DEFAULT_QDISC == fq ]]; then
    $DRY && echo "(dry) tc qdisc add dev $ifc root fq" \
         || tc qdisc add dev "$ifc" root fq
  else
    if [[ -n $DEFAULT_BW ]]; then
      $DRY && echo "(dry) tc qdisc add dev $ifc root cake bandwidth $DEFAULT_BW" \
           || tc qdisc add dev "$ifc" root cake bandwidth "$DEFAULT_BW"
    else
      $DRY && echo "(dry) tc qdisc add dev $ifc root cake" \
           || tc qdisc add dev "$ifc" root cake
    fi
  fi
done

echo -e "$(c 34)=== 优化完成 $($DRY && echo DRY‑RUN || echo LIVE)! 建议重启 ===$(clr)"
