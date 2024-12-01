#!/bin/bash

# 檢查是否以 root 權限運行
if [ "$(id -u)" != "0" ]; then
    echo "此腳本需要 root 權限運行"
    echo "請使用 sudo bash network_optimize.sh"
    exit 1
fi

echo "開始進行網絡優化配置..."

# 備份原有配置
cp /etc/sysctl.conf /etc/sysctl.conf.backup

# 創建新的 sysctl 配置
cat > /etc/sysctl.conf << EOF
# BBR 配置
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# 系統級別網絡優化
## 提高整體網絡性能
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 65535
net.core.rmem_default = 16777216
net.core.wmem_default = 16777216
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

## TCP 快速回收和重用
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_max_syn_backlog = 262144

## TCP 緩衝區調整
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_mem = 786432 1048576 1572864

## TCP 連接優化
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_mtu_probing = 1

## 防止 SYN 攻擊
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3

## IPv4 配置優化
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.ip_forward = 1
net.ipv4.route.gc_timeout = 100

## 網絡安全性設置
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0

## 系統內存使用優化
vm.swappiness = 10
vm.dirty_ratio = 60
vm.dirty_background_ratio = 30
EOF

# 應用新配置
sysctl -p

# 優化網絡接口設置
for interface in $(ls /sys/class/net/); do
    if [ "$interface" != "lo" ]; then
        # 設置網卡隊列長度
        ethtool -G $interface rx 4096 tx 4096 2>/dev/null || true
        # 開啟網卡多隊列支持
        ethtool -L $interface combined 8 2>/dev/null || true
        # 關閉網卡 TCP 分段
        ethtool -K $interface tso off gso off 2>/dev/null || true
        # 調整網卡中斷綁定 (需要 irqbalance 支持)
        systemctl start irqbalance 2>/dev/null || true
    fi
done

# 優化系統服務
if [ -f /etc/security/limits.conf ]; then
    # 增加系統文件描述符限制
    cat >> /etc/security/limits.conf << EOF
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
fi

# 檢查配置是否生效
echo "檢查 BBR 狀態..."
if lsmod | grep -q bbr && sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
    echo "BBR 已成功啟用"
else
    echo "BBR 啟用失敗"
fi

echo "網絡優化配置完成！"
echo "建議重啟系統以使所有更改生效"
echo "是否現在重啟系統？(y/n)"
read -r answer
if [ "$answer" = "y" ]; then
    reboot
fi
