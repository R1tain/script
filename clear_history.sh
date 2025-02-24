#!/bin/sh

# 通用Linux系统历史记录清理脚本
# 支持: Ubuntu, Debian, CentOS, Rocky, AlmaLinux, Fedora, openSUSE, Arch, RHEL, SUSE, Alpine

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 统计变量初始化
cleaned_logs=0
cleaned_size=0

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 进度显示函数
show_progress() {
    echo -n "正在清理 $1 "
    while [ -d /proc/$! ]; do
        echo -n "."
        sleep 1
    done
    echo " 完成"
}

# 确保以root权限运行
if [ "$(id -u)" != "0" ]; then
   log_error "此脚本需要root权限运行"
   log_info "请使用: sudo sh clear_history.sh"
   exit 1
fi

# 检测系统类型
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
        OS_LIKE=$ID_LIKE
    else
        OS="unknown"
    fi

    log_info "系统信息检测:"
    log_info "> 发行版: $OS"
    log_info "> 版本号: $VERSION"
    [ -n "$OS_LIKE" ] && log_info "> 系统类型: $OS_LIKE"
}

# 通用清理函数
clean_common() {
    log_info "执行通用清理..."

    # 记录清理前的磁盘使用情况
    before_space=$(df -h / | awk 'NR==2 {print $4}')
    log_info "清理前可用空间: $before_space"

    # 清理用户历史
    log_info "清理用户历史记录..."
    for user_home in /home/*; do
        if [ -d "$user_home" ]; then
            user=$(basename "$user_home")
            for hist_file in ".bash_history" ".zsh_history" ".ash_history" ".ksh_history" ".tcsh_history"; do
                if [ -f "$user_home/$hist_file" ]; then
                    cat /dev/null > "$user_home/$hist_file"
                    log_info "> 已清理 $user 的 $hist_file"
                    cleaned_logs=$((cleaned_logs + 1))
                fi
            done
        fi
    done

    # 清理root历史
    for hist_file in "/root/.bash_history" "/root/.zsh_history" "/root/.ash_history" "/root/.ksh_history" "/root/.tcsh_history"; do
        if [ -f "$hist_file" ]; then
            cat /dev/null > "$hist_file"
            log_info "> 已清理 root 的 $(basename "$hist_file")"
            cleaned_logs=$((cleaned_logs + 1))
        fi
    done

    # 清理系统日志
    log_info "清理系统日志..."
    common_logs=(
        "/var/log/syslog"
        "/var/log/messages"
        "/var/log/auth.log"
        "/var/log/kern.log"
        "/var/log/dmesg"
        "/var/log/daemon.log"
        "/var/log/debug"
        "/var/log/faillog"
        "/var/log/wtmp"
        "/var/log/btmp"
        "/var/log/lastlog"
        "/var/log/secure"
        "/var/log/maillog"
        "/var/log/boot.log"
        "/var/log/cron"
        "/var/log/spooler"
        "/var/log/audit/audit.log"
    )

    for log in "${common_logs[@]}"; do
        if [ -f "$log" ]; then
            cat /dev/null > "$log"
            log_info "> 已清理 $log"
            cleaned_logs=$((cleaned_logs + 1))
        fi
    done

    # 清理轮转的日志文件
    echo -n "清理轮转日志文件 "
    find /var/log -type f -name "*.gz" -delete 2>/dev/null &
    show_progress "轮转日志"
    find /var/log -type f -name "*.1" -delete 2>/dev/null
    find /var/log -type f -name "*.old" -delete 2>/dev/null
    find /var/log -type f -name "*.log.*" -delete 2>/dev/null

    # 清理临时文件
    log_info "清理临时文件..."
    rm -rf /tmp/* /var/tmp/* 2>/dev/null
}

# Alpine Linux 特定清理
clean_alpine() {
    log_info "执行Alpine系统清理..."
    
    # 清理apk缓存
    if command -v apk >/dev/null 2>&1; then
        echo -n "清理APK缓存 "
        apk cache clean >/dev/null 2>&1 &
        show_progress "APK"
        log_info "> 已清理APK缓存"
    fi

    # 清理Alpine特定日志
    alpine_logs=(
        "/var/log/messages"
        "/var/log/syslog"
        "/var/log/dmesg"
        "/var/log/wtmp"
        "/var/log/lastlog"
        "/var/log/faillog"
    )

    for log in "${alpine_logs[@]}"; do
        if [ -f "$log" ]; then
            cat /dev/null > "$log"
            log_info "> 已清理 $log"
            cleaned_logs=$((cleaned_logs + 1))
        fi
    done

    # 清理OpenRC服务日志
    if [ -d "/var/log/service" ]; then
        rm -rf /var/log/service/* 2>/dev/null
        log_info "> 已清理服务日志"
    fi
}

# Debian/Ubuntu特定清理
clean_debian() {
    log_info "执行Debian系清理..."
    
    # 清理apt缓存
    if command -v apt-get >/dev/null 2>&1; then
        echo -n "清理APT缓存 "
        apt-get clean -y >/dev/null 2>&1 &
        show_progress "APT"
        apt-get autoclean -y >/dev/null 2>&1
        log_info "> 已清理APT缓存"
    fi

    # Ubuntu特有的snap清理
    if [ "$OS" = "ubuntu" ] && command -v snap >/dev/null 2>&1; then
        log_info "清理Snap缓存..."
        snap list --all | awk '/disabled/{print $1, $3}' |
            while read snapname revision; do
                snap remove "$snapname" --revision="$revision" >/dev/null 2>&1
            done
        log_info "> 已清理Snap缓存"
    fi

    # 清理journal日志
    if [ -d "/var/log/journal" ]; then
        rm -rf /var/log/journal/* 2>/dev/null
        log_info "> 已清理systemd journal日志"
    fi

    debian_logs=(
        "/var/log/unattended-upgrades"
        "/var/log/apt"
        "/var/cache/apt/archives"
        "/var/cache/debconf"
    )

    for dir in "${debian_logs[@]}"; do
        if [ -d "$dir" ]; then
            rm -rf "${dir:?}"/* 2>/dev/null
            log_info "> 已清理 $dir"
        fi
    done
}

# RHEL系特定清理
clean_rhel() {
    log_info "执行RHEL系清理..."
    
    # 清理yum/dnf缓存
    if command -v dnf >/dev/null 2>&1; then
        echo -n "清理DNF缓存 "
        dnf clean all >/dev/null 2>&1 &
        show_progress "DNF"
        log_info "> 已清理DNF缓存"
    elif command -v yum >/dev/null 2>&1; then
        echo -n "清理YUM缓存 "
        yum clean all >/dev/null 2>&1 &
        show_progress "YUM"
        log_info "> 已清理YUM缓存"
    fi
}

# SUSE特定清理
clean_suse() {
    log_info "执行SUSE系清理..."
    
    # 清理zypper缓存
    if command -v zypper >/dev/null 2>&1; then
        echo -n "清理Zypper缓存 "
        zypper clean >/dev/null 2>&1 &
        show_progress "Zypper"
        log_info "> 已清理Zypper缓存"
    fi
}

# Arch特定清理
clean_arch() {
    log_info "执行Arch系清理..."
    
    # 清理pacman缓存
    if command -v pacman >/dev/null 2>&1; then
        echo -n "清理Pacman缓存 "
        pacman -Scc --noconfirm >/dev/null 2>&1 &
        show_progress "Pacman"
        log_info "> 已清理Pacman缓存"
    fi
}

# 重启服务
restart_services() {
    log_info "重启相关服务..."
    
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet rsyslog; then
            systemctl restart rsyslog 2>/dev/null
            log_info "> 已重启rsyslog服务"
        fi
        if systemctl is-active --quiet systemd-journald; then
            systemctl restart systemd-journald 2>/dev/null
            log_info "> 已重启systemd-journald服务"
        fi
    elif [ -x /sbin/openrc ]; then
        if rc-service --list | grep -q "syslog"; then
            rc-service syslog restart >/dev/null 2>&1
            log_info "> 已重启syslog服务"
        fi
    fi
}

# 打印清理统计
print_summary() {
    after_space=$(df -h / | awk 'NR==2 {print $4}')
    log_info "清理统计："
    log_info "> 清理的日志文件数: $cleaned_logs"
    log_info "> 清理前可用空间: $before_space"
    log_info "> 清理后可用空间: $after_space"
}

# 主程序
main() {
    log_info "开始系统清理..."
    
    # 记录开始时间
    start_time=$(date +%s)
    
    # 检测系统类型
    detect_os

    # 执行通用清理
    clean_common

    # 根据系统类型执行特定清理
    case $OS in
        "alpine")
            clean_alpine
            ;;
        "ubuntu"|"debian")
            clean_debian
            ;;
        "centos"|"rhel"|"rocky"|"almalinux"|"fedora")
            clean_rhel
            ;;
        "opensuse-leap"|"sles"|"opensuse-tumbleweed")
            clean_suse
            ;;
        "arch"|"manjaro")
            clean_arch
            ;;
        *)
            case $OS_LIKE in
                *"debian"*)
                    clean_debian
                    ;;
                *"rhel"*|*"fedora"*)
                    clean_rhel
                    ;;
                *"suse"*)
                    clean_suse
                    ;;
                *)
                    log_warn "未能精确识别系统类型，仅执行通用清理"
                    ;;
            esac
            ;;
    esac

    # 重启服务
    restart_services

    # 清理当前shell历史
    if [ -n "$BASH" ]; then
        history -c
        history -w
    elif [ -n "$ZSH_VERSION" ]; then
        history -p
        fc -R
    else
        # For ash shell (BusyBox)
        unset HISTFILE
        printf '' > ~/.ash_history 2>/dev/null
    fi

    # 计算执行时间
    end_time=$(date +%s)
    duration=$((end_time - start_time))

    # 打印统计信息
    print_summary
    
    log_info "系统清理完成！总耗时: ${duration}秒"
    echo
    log_info "清理完成！如果发现某些日志文件空间未释放，可能需要重启相关服务或系统。"
}

# 执行主程序
main

exit 0
