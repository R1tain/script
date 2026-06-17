#!/bin/bash
# ============================================================
# SOCKS5 代理管理脚本 (基于 Dante - 源码编译)
# 功能: 安装 / 删除 / 启动 / 停止 / 重启 / 查看状态
# 安全: PAM认证 + 随机端口 + fail2ban + 专用nologin用户
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

DANTE_VER="1.4.3"
DANTE_DIR="/opt/dante"
CONFIG_FILE="/etc/danted.conf"
SERVICE_FILE="/etc/systemd/system/danted.service"
LOG_FILE="/var/log/danted.log"
CRED_FILE="/root/.socks5_credentials"
SOCKS_USER="socks5usr"

# ────────────────────────────────────────────
# 工具函数
# ────────────────────────────────────────────
check_root() {
    [[ $EUID -ne 0 ]] && { echo -e "${RED}请用 root 权限运行${NC}"; exit 1; }
}

get_public_ip() {
    curl -s --max-time 5 https://api.ipify.org 2>/dev/null \
    || curl -s --max-time 5 https://ifconfig.me 2>/dev/null \
    || ip route get 8.8.8.8 2>/dev/null | awk '{print $7; exit}' \
    || hostname -I | awk '{print $1}'
}

gen_password() {
    tr -dc 'A-Za-z0-9!@#%^&*_+=' </dev/urandom | head -c 32
}

# 生成随机端口: 10000-65000 范围，避开常用端口
gen_port() {
    while true; do
        PORT=$(shuf -i 10000-65000 -n 1)
        # 检查端口是否已被占用
        if ! ss -tlnp | grep -q ":${PORT} "; then
            echo "$PORT"
            return
        fi
    done
}

print_banner() {
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════╗"
    echo "║        SOCKS5 代理管理脚本               ║"
    echo "║        基于 Dante (源码编译) + 安全加固  ║"
    echo "╚══════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ────────────────────────────────────────────
# 编译安装 Dante
# ────────────────────────────────────────────
compile_dante() {
    echo -e "${YELLOW}[*] 安装编译依赖...${NC}"
    if command -v apt-get &>/dev/null; then
        apt-get update -qq
        apt-get install -y gcc make wget curl libwrap0-dev libpam0g-dev \
                           libssl-dev fail2ban ufw 2>/dev/null
    elif command -v yum &>/dev/null; then
        yum install -y gcc make wget curl tcp_wrappers-devel pam-devel \
                       openssl-devel fail2ban firewalld 2>/dev/null
    else
        echo -e "${RED}不支持的系统${NC}"; exit 1
    fi

    echo -e "${YELLOW}[*] 下载 Dante ${DANTE_VER} 源码...${NC}"
    cd /tmp || exit 1
    rm -rf dante-*

    wget -q --show-progress \
         "https://www.inet.no/dante/files/dante-${DANTE_VER}.tar.gz" \
         -O dante.tar.gz 2>/dev/null

    # 备用版本回退
    if [[ ! -f dante.tar.gz ]] || [[ $(stat -c%s dante.tar.gz 2>/dev/null || echo 0) -lt 10000 ]]; then
        echo -e "${YELLOW}[!] 尝试备用版本 1.4.2...${NC}"
        wget -q "https://www.inet.no/dante/files/dante-1.4.2.tar.gz" \
             -O dante.tar.gz 2>/dev/null
        DANTE_VER="1.4.2"
    fi

    if [[ ! -f dante.tar.gz ]] || [[ $(stat -c%s dante.tar.gz 2>/dev/null || echo 0) -lt 10000 ]]; then
        echo -e "${RED}下载失败！请检查网络连接${NC}"; exit 1
    fi

    echo -e "${YELLOW}[*] 解压源码...${NC}"
    tar -xzf dante.tar.gz
    cd dante-* || { echo -e "${RED}解压失败${NC}"; exit 1; }

    echo -e "${YELLOW}[*] 编译中（约1-3分钟）...${NC}"
    ./configure \
        --prefix="$DANTE_DIR" \
        --sysconfdir=/etc \
        --disable-client \
        --without-gssapi \
        --without-krb5 \
        --without-upnp \
        2>/dev/null

    make -j"$(nproc)" 2>/dev/null
    make install 2>/dev/null

    if [[ ! -f "$DANTE_DIR/sbin/sockd" ]]; then
        echo -e "${RED}编译失败！请确认 gcc/make 已安装${NC}"; exit 1
    fi

    ln -sf "$DANTE_DIR/sbin/sockd" /usr/local/sbin/sockd
    cd / && rm -rf /tmp/dante*
    echo -e "${GREEN}[✓] Dante ${DANTE_VER} 编译安装完成${NC}"
}

# ────────────────────────────────────────────
# 主安装流程
# ────────────────────────────────────────────
install_socks5() {
    check_root
    print_banner
    echo -e "${GREEN}[*] 开始安装 SOCKS5 代理服务（Dante 源码编译版）...${NC}"

    # 编译 Dante
    if [[ -f "$DANTE_DIR/sbin/sockd" ]]; then
        echo -e "${YELLOW}[!] Dante 已编译存在，跳过编译步骤${NC}"
    else
        compile_dante
    fi

    # 获取网卡名
    IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
    [[ -z "$IFACE" ]] && IFACE=$(ip link show | awk -F': ' '/^[0-9]+: [^lo]/{print $2; exit}')
    echo -e "${GREEN}[✓] 检测到网卡: ${IFACE}${NC}"

    # 生成随机端口
    SOCKS_PORT=$(gen_port)
    echo -e "${GREEN}[✓] 随机端口: ${SOCKS_PORT}${NC}"

    # 创建专用系统用户
    if id "$SOCKS_USER" &>/dev/null; then
        echo -e "${YELLOW}[!] 用户 $SOCKS_USER 已存在，更新密码${NC}"
    else
        useradd -r -s /sbin/nologin -M -d /nonexistent "$SOCKS_USER"
        echo -e "${GREEN}[✓] 已创建系统用户: $SOCKS_USER${NC}"
    fi

    # 生成强密码（PAM认证，密码不写入任何配置文件）
    SOCKS_PASS=$(gen_password)
    echo "$SOCKS_USER:$SOCKS_PASS" | chpasswd
    echo -e "${GREEN}[✓] 已设置强密码（32位，PAM系统认证）${NC}"

    # 写入 Dante 配置
    cat > "$CONFIG_FILE" << EOF
# Dante SOCKS5 配置 - 安全加固版
logoutput: $LOG_FILE

internal: 0.0.0.0 port = $SOCKS_PORT
external: $IFACE

socksmethod: username
clientmethod: none

user.privileged: root
user.unprivileged: nobody

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error
}

socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    socksmethod: username
    log: error connect disconnect
}

socks block {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error
}
EOF
    chmod 600 "$CONFIG_FILE"

    # 创建 systemd 服务
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Dante SOCKS5 Proxy Server
After=network.target

[Service]
Type=forking
PIDFile=/run/danted.pid
ExecStart=$DANTE_DIR/sbin/sockd -D -f $CONFIG_FILE -p /run/danted.pid
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
NoNewPrivileges=true
ProtectSystem=full
ReadWritePaths=/var/log /run

[Install]
WantedBy=multi-user.target
EOF

    touch "$LOG_FILE"
    chmod 640 "$LOG_FILE"

    # 配置 fail2ban 防爆破
    mkdir -p /etc/fail2ban/jail.d /etc/fail2ban/filter.d

    cat > /etc/fail2ban/jail.d/danted.conf << EOF
[danted]
enabled  = true
port     = $SOCKS_PORT
protocol = tcp
filter   = danted
logpath  = $LOG_FILE
maxretry = 5
findtime = 300
bantime  = 3600
EOF

    cat > /etc/fail2ban/filter.d/danted.conf << EOF
[Definition]
failregex = danted\[.*\]:.*\bfailed\b.*from <HOST>
            danted\[.*\]:.*authentication.*failed.*<HOST>
ignoreregex =
EOF

    # 防火墙放行随机端口
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw allow "$SOCKS_PORT"/tcp &>/dev/null
        echo -e "${GREEN}[✓] UFW 已放行端口 $SOCKS_PORT${NC}"
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-port="$SOCKS_PORT"/tcp &>/dev/null
        firewall-cmd --reload &>/dev/null
        echo -e "${GREEN}[✓] firewalld 已放行端口 $SOCKS_PORT${NC}"
    fi

    # 启动服务
    systemctl daemon-reload
    systemctl enable danted &>/dev/null
    systemctl restart danted

    sleep 2
    if systemctl is-active --quiet danted; then
        echo -e "${GREEN}[✓] Dante 服务启动成功${NC}"
    else
        echo -e "${RED}[!] 服务启动异常，查看日志:${NC}"
        journalctl -u danted -n 20 --no-pager
        exit 1
    fi

    systemctl enable fail2ban &>/dev/null
    systemctl restart fail2ban &>/dev/null

    # 保存凭据（仅 root 可读）
    PUBLIC_IP=$(get_public_ip)
    cat > "$CRED_FILE" << EOF
IP=$PUBLIC_IP
PORT=$SOCKS_PORT
USER=$SOCKS_USER
PASS=$SOCKS_PASS
EOF
    chmod 600 "$CRED_FILE"

    # ── 输出代理信息 ──
    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║         ✅  SOCKS5 安装成功！以下为代理信息             ║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}┌─────────────── 📋 代理配置（一键复制）────────────────┐${NC}"
    printf "  %-10s : ${YELLOW}%s${NC}\n" "服务器IP"  "$PUBLIC_IP"
    printf "  %-10s : ${YELLOW}%s${NC}\n" "端口"      "$SOCKS_PORT"
    printf "  %-10s : ${YELLOW}%s${NC}\n" "用户名"    "$SOCKS_USER"
    printf "  %-10s : ${YELLOW}%s${NC}\n" "密码"      "$SOCKS_PASS"
    printf "  %-10s : ${YELLOW}%s${NC}\n" "协议"      "SOCKS5"
    echo -e "${CYAN}└────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "${CYAN}┌─────────────── 🔗 URI 格式 ───────────────────────────┐${NC}"
    echo -e "  ${YELLOW}socks5://${SOCKS_USER}:${SOCKS_PASS}@${PUBLIC_IP}:${SOCKS_PORT}${NC}"
    echo -e "${CYAN}└────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "${CYAN}┌─────────────── 🧪 curl 验证命令 ──────────────────────┐${NC}"
    echo -e "  ${YELLOW}curl -x socks5h://${SOCKS_USER}:${SOCKS_PASS}@${PUBLIC_IP}:${SOCKS_PORT} https://api.ipify.org${NC}"
    echo -e "${CYAN}└────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "${BLUE}🔒 已启用安全措施:${NC}"
    echo -e "  ✔ 随机端口 ${SOCKS_PORT}（10000-65000 范围，规避端口扫描）"
    echo -e "  ✔ PAM 系统级认证（密码不写入任何配置文件）"
    echo -e "  ✔ 32位随机强密码（大小写+数字+特殊字符）"
    echo -e "  ✔ 专用 nologin 系统用户（无法 SSH 登录）"
    echo -e "  ✔ fail2ban：5次失败封锁 IP 1小时"
    echo -e "  ✔ systemd NoNewPrivileges 沙箱隔离"
    echo -e "  ✔ 凭据文件 chmod 600，仅 root 可读"
    echo -e "  ✔ 凭据已保存至 ${YELLOW}${CRED_FILE}${NC}"
    echo ""
}

# ────────────────────────────────────────────
# 删除
# ────────────────────────────────────────────
remove_socks5() {
    check_root
    echo -e "${RED}[!] 将彻底删除 SOCKS5 服务，是否继续? (y/N): ${NC}"
    read -r confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { echo "已取消"; return; }

    # 获取当前端口用于防火墙清理
    OLD_PORT=""
    [[ -f "$CRED_FILE" ]] && OLD_PORT=$(grep '^PORT=' "$CRED_FILE" | cut -d= -f2)

    systemctl stop danted &>/dev/null
    systemctl disable danted &>/dev/null
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload

    rm -rf "$DANTE_DIR"
    rm -f /usr/local/sbin/sockd
    rm -f "$CONFIG_FILE" "$CRED_FILE" "$LOG_FILE"
    rm -f /etc/fail2ban/jail.d/danted.conf /etc/fail2ban/filter.d/danted.conf

    userdel "$SOCKS_USER" &>/dev/null
    systemctl restart fail2ban &>/dev/null

    # 关闭防火墙端口
    if [[ -n "$OLD_PORT" ]]; then
        ufw delete allow "$OLD_PORT"/tcp &>/dev/null
        firewall-cmd --permanent --remove-port="$OLD_PORT"/tcp &>/dev/null
        firewall-cmd --reload &>/dev/null
    fi

    echo -e "${GREEN}✅ SOCKS5 服务已完全删除${NC}"
}

# ────────────────────────────────────────────
# 查看状态
# ────────────────────────────────────────────
show_status() {
    check_root
    echo -e "${CYAN}${BOLD}═══ 服务状态 ═══${NC}"
    systemctl status danted --no-pager -l 2>/dev/null \
        || echo -e "${RED}服务未安装或未运行${NC}"

    echo ""
    echo -e "${CYAN}${BOLD}═══ 端口监听 ═══${NC}"
    if [[ -f "$CRED_FILE" ]]; then
        CUR_PORT=$(grep '^PORT=' "$CRED_FILE" | cut -d= -f2)
        ss -tlnp | grep ":${CUR_PORT}" \
            || echo -e "${RED}端口 ${CUR_PORT} 未监听${NC}"
    else
        ss -tlnp | grep sockd || echo -e "${RED}未检测到 sockd 监听${NC}"
    fi

    if [[ -f "$CRED_FILE" ]]; then
        source "$CRED_FILE"
        echo ""
        echo -e "${CYAN}${BOLD}═══ 当前代理信息 ═══${NC}"
        printf "  %-10s : ${YELLOW}%s${NC}\n" "服务器IP" "$IP"
        printf "  %-10s : ${YELLOW}%s${NC}\n" "端口"     "$PORT"
        printf "  %-10s : ${YELLOW}%s${NC}\n" "用户名"   "$USER"
        printf "  %-10s : ${YELLOW}%s${NC}\n" "密码"     "$PASS"
        echo ""
        echo -e "${CYAN}${BOLD}═══ 一键复制 ═══${NC}"
        echo -e "  ${YELLOW}socks5://${USER}:${PASS}@${IP}:${PORT}${NC}"
        echo ""
        echo -e "${CYAN}${BOLD}═══ curl 验证 ═══${NC}"
        echo -e "  ${YELLOW}curl -x socks5h://${USER}:${PASS}@${IP}:${PORT} https://api.ipify.org${NC}"
    fi
}

# ────────────────────────────────────────────
# 主菜单
# ────────────────────────────────────────────
main_menu() {
    print_banner
    echo -e "${BOLD}请选择操作:${NC}"
    echo "  1) 安装 SOCKS5（源码编译 Dante，随机端口）"
    echo "  2) 删除 SOCKS5"
    echo "  3) 启动服务"
    echo "  4) 停止服务"
    echo "  5) 重启服务"
    echo "  6) 查看状态 + 代理信息"
    echo "  0) 退出"
    echo ""
    read -rp "请输入选项 [0-6]: " choice
    case $choice in
        1) install_socks5 ;;
        2) remove_socks5 ;;
        3) check_root; systemctl start danted   && echo -e "${GREEN}✅ 已启动${NC}" ;;
        4) check_root; systemctl stop danted    && echo -e "${YELLOW}⏹ 已停止${NC}" ;;
        5) check_root; systemctl restart danted && echo -e "${GREEN}✅ 已重启${NC}" ;;
        6) show_status ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${NC}" ;;
    esac
}

# ────────────────────────────────────────────
# 命令行参数
# ────────────────────────────────────────────
case "${1:-menu}" in
    install)  install_socks5 ;;
    remove)   remove_socks5 ;;
    start)    check_root; systemctl start danted ;;
    stop)     check_root; systemctl stop danted ;;
    restart)  check_root; systemctl restart danted ;;
    status)   show_status ;;
    menu|"")  main_menu ;;
    *) echo "用法: $0 {install|remove|start|stop|restart|status|menu}"; exit 1 ;;
esac
