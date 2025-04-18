#!/bin/bash
#---------------------------------------------------------------
# network_optimize.sh —— 针对 VPS/独服自动优化网络内核参数
# 2025‑04‑18  Europe/London
#---------------------------------------------------------------

#--------------- 可选：关闭颜色输出 -----------------------------
USE_COLOR=true
c_bold_blue="\e[1;34m"
c_bold_yellow="\e[1;33m"
c_bold_green="\e[1;32m"
c_reset="\e[0m"
color() { $USE_COLOR && printf "%b" "$1" || printf "%s" ""; }

#--------------- 1. 必须 root -----------------------------------
(( EUID == 0 )) || { echo "请用 sudo bash $0"; exit 1; }

echo -e "$(color $c_bold_blue)=== 开始进行网络优化配置 ===$(color $c_reset)"

#===============================================================
# 2. 探测 VPS 资源
#===============================================================
detect() {
    echo -e "$(color $c_bold_blue)-- 探测系统资源和网卡信息 --$(color $c_reset)"

    # 内存
    mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    MEM_MB=$(( mem_kb / 1024 ))
    MEM_GB=$(( mem_kb / 1024 / 1024 ))   # 整数
    if [ "$MEM_GB" -ge 1 ]; then
        echo -e "检测到内存：$(color $c_bold_green)${MEM_GB} GB$(color $c_reset)"
    else
        echo -e "检测到内存：$(color $c_bold_green)${MEM_MB} MB$(color $c_reset)"
    fi

    # CPU
    CPU_CORES=$(nproc)
    echo -e "检测到 CPU 核心：$(color $c_bold_green)${CPU_CORES}$(color $c_reset)"

    # 网卡 + 速率
    DEFAULT_IFACES=($(ls /sys/class/net | grep -v '^lo$'))
    declare -gA IFACE_SPEED
    for iface in "${DEFAULT_IFACES[@]}"; do
        # 方法 1: /sys/class/net/$iface/speed
        if [ -r "/sys/class/net/$iface/speed" ]; then
            speed=$(cat "/sys/class/net/$iface/speed" 2>/dev/null)
        fi
        # 方法 2: ethtool
        if ! [[ "$speed" =~ ^[0-9]+$ ]] || [ "$speed" -le 0 ]; then
            speed_raw=$(ethtool "$iface" 2>/dev/null | awk -F': ' '/Speed/ {print $2}')
            [[ $speed_raw =~ ^[0-9]+ ]] && speed=${speed_raw//Mb\/s/}
        fi
        # 方法 3: 交互式
        while ! [[ "$speed" =~ ^[0-9]+$ ]] || [ "$speed" -le 0 ]; do
            read -rp "⚠️  无法自动获取 $iface 速率，请输入该接口速率 (Mb/s，如 1000): " speed
        done
        IFACE_SPEED["$iface"]=$speed
        echo -e "网卡 $iface 速率：$(color $c_bold_green)${speed} Mb/s$(color $c_reset)"
    done
}

#===============================================================
# 3. 计算最优参数
#===============================================================
compute_params() {
    echo -e "$(color $c_bold_blue)-- 计算网络参数 --$(color $c_reset)"

    # TCP 缓冲上下限
    if [ "$MEM_GB" -ge 8 ]; then
        SB_MAX=16777216; SB_DEFAULT=8388608
    elif [ "$MEM_GB" -ge 2 ]; then
        SB_MAX=8388608; SB_DEFAULT=4194304
    else
        SB_MAX=2097152; SB_DEFAULT=1048576
    fi
    echo -e "TCP 缓冲区上限: $(color $c_bold_yellow)$SB_MAX$(color $c_reset), 默认: $(color $c_bold_yellow)$SB_DEFAULT$(color $c_reset)"

    # backlog
    NETDEV_BACKLOG=$(( CPU_CORES * 32768 ))
    echo -e "net.core.netdev_max_backlog: $(color $c_bold_yellow)$NETDEV_BACKLOG$(color $c_reset)"
}

#===============================================================
# 4. 生成 & 应用 sysctl
#===============================================================
apply_sysctl() {
    cat > /etc/sysctl.d/99-vps-net.conf << EOF
# BBR/TCP qdisc
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 系统级别网络优化
net.core.netdev_max_backlog = $NETDEV_BACKLOG
net.core.somaxconn = 65535

net.core.rmem_default = $SB_DEFAULT
net.core.wmem_default = $SB_DEFAULT
net.core.rmem_max = $SB_MAX
net.core.wmem_max = $SB_MAX

net.ipv4.tcp_rmem = 4096 87380 $SB_MAX
net.ipv4.tcp_wmem = 4096 65536 $SB_MAX
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
EOF

    sysctl --system >/dev/null

    echo -e "$(color $c_bold_blue)-- 已写入 /etc/sysctl.d/99-vps-net.conf，关键参数如下 --$(color $c_reset)"
    for p in net.core.netdev_max_backlog net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem; do
        v=$(sysctl -n "$p")
        echo -e "  $(color $c_bold_yellow)$p = $v$(color $c_reset)"
    done
}

#===============================================================
# 5. 网卡队列 & offload
#===============================================================
optimize_ifaces() {
    echo -e "$(color $c_bold_blue)-- 优化网卡设置 --$(color $c_reset)"
    for iface in "${DEFAULT_IFACES[@]}"; do
        speed=${IFACE_SPEED[$iface]}
        if [ "$speed" -ge 1000 ]; then
            ethtool -G "$iface" rx 4096 tx 4096 2>/dev/null || true
        else
            ethtool -G "$iface" rx 1024 tx 1024 2>/dev/null || true
        fi
        ethtool -K "$iface" tso off gso off gro off 2>/dev/null || true
        echo -e "$iface 队列长度与 offload 已调整"
    done
    systemctl enable --now irqbalance 2>/dev/null || true
    echo -e "$(color $c_bold_green)irqbalance 已启用$(color $c_reset)"
}

#===============================================================
# 6. 主流程
#===============================================================
detect
compute_params
apply_sysctl
optimize_ifaces

echo -e "$(color $c_bold_blue)=== 网络优化配置完成！建议重启系统以完全生效。===${c_reset}"
