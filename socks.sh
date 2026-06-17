#!/bin/bash
# ============================================================
# SOCKS5 代理管理脚本 (基于 Dante - 源码编译)
# 功能: 安装 / 删除 / 启动 / 停止 / 重启 / 查看状态
# 安全: PAM认证 + 随机端口 + fail2ban + 专用nologin用户
# 网络: 安装时选择 IPv4 或 IPv6
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
BUILD_LOG="/tmp/dante_build.log"

# ────────────────────────────────────────────
# 工具函数
# ────────────────────────────────────────────
check_root() {
    [[ $EUID -ne 0 ]] && { echo -e "${RED}请用 root 权限运行${NC}"; exit 1; }
}

get_public_ipv4() {
    curl -4s --max-time 5 https://api.ipify.org 2>/dev/null \
    || curl -4s --max-time 5 https://ifconfig.me 2>/dev/null \
    || ip -4 route get 8.8.8.8 2>/dev/null | awk '{print $7; exit}'
}

get_public_ipv6() {
    curl -6s --max-time 5 https://api6.ipify.org 2>/dev/null \
    || ip -6 addr show scope global 2>/dev/null \
       | awk '/inet6/{print $2}' | cut -d/ -f1 | grep -v '^fd' | head -1
}

# IPv4: 复杂密码（大小写+数字+特殊字符，32位）
gen_password_complex() {
    tr -dc 'A-Za-z0-9!@#%^&*_+=' </dev/urandom | head -c 32
}

# IPv6: 纯字母数字密码，URI 安全（32位）
gen_password_safe() {
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32
}

# 随机端口 10000-65000，检测是否占用
gen_port() {
    while true; do
        PORT=$(shuf -i 10000-65000 -n 1)
        if ! ss -tlnp | grep -q ":${PORT} "; then
            echo "$PORT"
            return
        fi
    done
}

print_banner() {
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════╗"
    echo "║        SOCKS5 代理管理脚本                   ║"
    echo "║        Dante 源码编译 · IPv4/IPv6 · 安全加固 ║"
    echo "╚══════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ────────────────────────────────────────────
# 选择网络类型
# ────────────────────────────────────────────
choose_network() {
    echo -e "${CYAN}${BOLD}请选择网络类型:${NC}"
    echo "  1) IPv4  （密码含特殊字符，更复杂）"
    echo "  2) IPv6  （密码纯字母数字，URI兼容）"
    echo ""
    while true; do
        read -rp "请输入 [1/2]: " net_choice
        case $net_choice in
            1)
                NET_MODE="ipv4"
                echo -e "${GREEN}[✓] 已选择 IPv4 模式${NC}"
                break
                ;;
            2)
                NET_MODE="ipv6"
                echo -e "${GREEN}[✓] 已选择 IPv6 模式${NC}"
                break
                ;;
            *)
                echo -e "${RED}请输入 1 或 2${NC}"
                ;;
        esac
    done
}

# ────────────────────────────────────────────
# 编译安装 Dante
# ────────────────────────────────────────────
compile_dante() {
    echo -e "${YELLOW}[*] 安装编译依赖...${NC}"
    if command -v apt-get &>/dev/null; then
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            gcc make wget curl \
            libwrap0-dev libpam0g-dev libssl-dev \
            fail2ban ufw 2>/dev/null
    elif command -v yum &>/dev/null; then
        yum install -y gcc make wget curl \
            tcp_wrappers-devel pam-devel openssl-devel \
            fail2ban firewalld 2>/dev/null
    else
        echo -e "${RED}不支持的系统${NC}"; exit 1
    fi

    # 验证编译工具
    for tool in gcc make; do
        if ! command -v $tool &>/dev/null; then
            echo -e "${RED}缺少 $tool，请手动执行: apt install $tool${NC}"
            exit 1
        fi
    done
    echo -e "${GREEN}[✓] 编译工具就绪: gcc $(gcc --version | head -1 | awk '{print $NF}')${NC}"

    echo -e "${YELLOW}[*] 下载 Dante 源码...${NC}"
    cd /tmp || exit 1
    rm -rf dante-* dante.tar.gz

    for VER in "1.4.3" "1.4.2"; do
        wget -q --show-progress \
             "https://www.inet.no/dante/files/dante-${VER}.tar.gz" \
             -O dante.tar.gz 2>/dev/null
        FILE_SIZE=$(stat -c%s dante.tar.gz 2>/dev/null || echo 0)
        if [[ $FILE_SIZE -gt 50000 ]]; then
            DANTE_VER="$VER"
            echo -e "${GREEN}[✓] 下载成功: dante-${VER}.tar.gz${NC}"
            break
        fi
        echo -e "${YELLOW}[!] 版本 ${VER} 下载失败，尝试下一个...${NC}"
        rm -f dante.tar.gz
    done

    if [[ ! -f dante.tar.gz ]] || [[ $(stat -c%s dante.tar.gz 2>/dev/null || echo 0) -lt 50000 ]]; then
        echo -e "${RED}下载失败，请检查网络连接${NC}"; exit 1
    fi

    echo -e "${YELLOW}[*] 解压源码...${NC}"
    tar -xzf dante.tar.gz || { echo -e "${RED}解压失败${NC}"; exit 1; }
    cd dante-${DANTE_VER} 2>/dev/null || cd dante-* || { echo -e "${RED}找不到源码目录${NC}"; exit 1; }

    echo -e "${YELLOW}[*] 运行 configure...${NC}"
    ./configure \
        --prefix="$DANTE_DIR" \
        --sysconfdir=/etc \
        --disable-client \
        --without-gssapi \
        --without-krb5 \
        --without-upnp \
        > "$BUILD_LOG" 2>&1

    if [[ $? -ne 0 ]]; then
        echo -e "${RED}configure 失败！详细错误:${NC}"
        tail -30 "$BUILD_LOG"
        exit 1
    fi
    echo -e "${GREEN}[✓] configure 完成${NC}"

    echo -e "${YELLOW}[*] 编译中（约1-3分钟）...${NC}"
    make -j"$(nproc)" >> "$BUILD_LOG" 2>&1
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}make 失败！详细错误:${NC}"
        tail -30 "$BUILD_LOG"
        exit 1
    fi

    make install >> "$BUILD_LOG" 2>&1
    if [[ $? -ne 0 ]] || [[ ! -f "$DANTE_DIR/sbin/sockd" ]]; then
        echo -e "${RED}make install 失败！详细错误:${NC}"
        tail -20 "$BUILD_LOG"
        exit 1
    fi

    ln -sf "$DANTE_DIR/sbin/sockd" /usr/local/sbin/sockd
    cd / && rm -rf /tmp/dante* "$BUILD_LOG"
    echo -e "${GREEN}[✓] Dante ${DANTE_VER} 编译安装完成${NC}"
}

# ────────────────────────────────────────────
# 写入 Dante 配置
# ────────────────────────────────────────────
write_config() {
    local port="$1"
    local iface="$2"
    local mode="$3"   # ipv4 | ipv6

    if [[ "$mode" == "ipv6" ]]; then
        INTERNAL_LINE="internal: :: port = ${port}"
    else
        INTERNAL_LINE="internal: 0.0.0.0 port = ${port}"
    fi

    cat > "$CONFIG_FILE" << EOF
# Dante SOCKS5 配置 - 安全加固版
logoutput: $LOG_FILE

${INTERNAL_LINE}
external: ${iface}

socksmethod: username
clientmethod: none

user.privileged: root
user.unprivileged: nobody

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error
}

client pass {
    from: ::/0 to: ::/0
    log: error
}

socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    socksmethod: username
    log: error connect disconnect
}

socks pass {
    from: ::/0 to: ::/0
    socksmethod: username
    log: error connect disconnect
}

socks block {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error
}
EOF
    chmod 600 "$CONFIG_FILE"
}

# ────────────────────────────────────────────
# 主安装流程
# ────────────────────────────────────────────
install_socks5() {
    check_root
    print_banner

    # 选择网络类型
    choose_network
    echo ""
    echo -e "${GREEN}[*] 开始安装 SOCKS5 代理服务（Dante 源码编译）...${NC}"

    # 编译 Dante
    if [[ -f "$DANTE_DIR/sbin/sockd" ]]; then
        echo -e "${YELLOW}[!] Dante 已编译存在，跳过编译步骤${NC}"
    else
        compile_dante
    fi

    # 获取网卡名（IPv4 或 IPv6 路由）
    if [[ "$NET_MODE" == "ipv6" ]]; then
        IFACE=$(ip -6 route get 2001:4860:4860::8888 2>/dev/null \
                | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
    else
        IFACE=$(ip route get 8.8.8.8 2>/dev/null \
                | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
    fi
    [[ -z "$IFACE" ]] && IFACE=$(ip link show \
                                  | awk -F': ' '/^[0-9]+: [^lo]/{print $2; exit}')
    echo -e "${GREEN}[✓] 检测到网卡: ${IFACE}${NC}"

    # 生成随机端口
    SOCKS_PORT=$(gen_port)
    echo -e "${GREEN}[✓] 随机端口: ${SOCKS_PORT}${NC}"

    # 创建专用系统用户
    if ! id "$SOCKS_USER" &>/dev/null; then
        useradd -r -s /sbin/nologin -M -d /nonexistent "$SOCKS_USER"
        echo -e "${GREEN}[✓] 已创建系统用户: $SOCKS_USER${NC}"
    fi

    # 按网络类型生成密码
    if [[ "$NET_MODE" == "ipv4" ]]; then
        SOCKS_PASS=$(gen_password_complex)
        echo -e "${GREEN}[✓] IPv4 模式：32位复杂密码（含特殊字符）${NC}"
    else
        SOCKS_PASS=$(gen_password_safe)
        echo -e "${GREEN}[✓] IPv6 模式：32位纯字母数字密码（URI兼容）${NC}"
    fi

    echo "$SOCKS_USER:$SOCKS_PASS" | chpasswd
    echo -e "${GREEN}[✓] PAM 密码设置完成${NC}"

    # 写入 Dante 配置
    write_config "$SOCKS_PORT" "$IFACE" "$NET_MODE"
    echo -e "${GREEN}[✓] 配置写入完成${NC}"

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

    # 配置 fail2ban
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

    # 防火墙放行
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
    if ! systemctl is-active --quiet danted; then
        echo -e "${RED}[!] 服务启动失败，查看详情:${NC}"
        journalctl -u danted -n 30 --no-pager
        echo -e "${RED}配置文件:${NC}"
        cat "$CONFIG_FILE"
        exit 1
    fi
    echo -e "${GREEN}[✓] Dante 服务启动成功${NC}"

    systemctl enable fail2ban &>/dev/null
    systemctl restart fail2ban &>/dev/null

    # 获取公网 IP
    if [[ "$NET_MODE" == "ipv6" ]]; then
        PUBLIC_IP=$(get_public_ipv6)
        IP_LABEL="IPv6地址"
        # IPv6 URI 需要方括号
        URI_HOST="[${PUBLIC_IP}]"
    else
        PUBLIC_IP=$(get_public_ipv4)
        IP_LABEL="IPv4地址"
        URI_HOST="${PUBLIC_IP}"
    fi

    # 保存凭据
    cat > "$CRED_FILE" << EOF
MODE=$NET_MODE
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
    printf "  %-12s : ${YELLOW}%s${NC}\n" "$IP_LABEL"  "$PUBLIC_IP"
    printf "  %-12s : ${YELLOW}%s${NC}\n" "端口"       "$SOCKS_PORT"
    printf "  %-12s : ${YELLOW}%s${NC}\n" "用户名"     "$SOCKS_USER"
    printf "  %-12s : ${YELLOW}%s${NC}\n" "密码"       "$SOCKS_PASS"
    printf "  %-12s : ${YELLOW}%s${NC}\n" "协议"       "SOCKS5"
    echo -e "${CYAN}└────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "${CYAN}┌─────────────── 🔗 URI 格式（一键复制）───────────────┐${NC}"
    echo -e "  ${YELLOW}socks5://${SOCKS_USER}:${SOCKS_PASS}@${URI_HOST}:${SOCKS_PORT}${NC}"
    echo -e "${CYAN}└────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "${CYAN}┌─────────────── 🧪 curl 验证命令 ──────────────────────┐${NC}"
    if [[ "$NET_MODE" == "ipv6" ]]; then
        echo -e "  ${YELLOW}curl -x socks5h://${SOCKS_USER}:${SOCKS_PASS}@${URI_HOST}:${SOCKS_PORT} https://api6.ipify.org${NC}"
    else
        echo -e "  ${YELLOW}curl -x socks5h://${SOCKS_USER}:${SOCKS_PASS}@${PUBLIC_IP}:${SOCKS_PORT} https://api.ipify.org${NC}"
    fi
    echo -e "${CYAN}└────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "${BLUE}🔒 已启用安全措施:${NC}"
    echo -e "  ✔ 网络模式: ${NET_MODE^^}"
    if [[ "$NET_MODE" == "ipv4" ]]; then
        echo -e "  ✔ 32位复杂密码（含特殊字符，高强度）"
    else
        echo -e "  ✔ 32位纯字母数字密码（IPv6 URI 完全兼容）"
    fi
    echo -e "  ✔ 随机端口 ${SOCKS_PORT}（10000-65000，规避端口扫描）"
    echo -e "  ✔ PAM 系统级认证（密码不写入任何配置文件）"
    echo -e "  ✔ 专用 nologin 用户（无法 SSH 登录）"
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
        # IPv6 URI 需要方括号
        if [[ "$MODE" == "ipv6" ]]; then
            URI_HOST="[${IP}]"
            IP_LABEL="IPv6地址"
        else
            URI_HOST="${IP}"
            IP_LABEL="IPv4地址"
        fi
        echo ""
        echo -e "${CYAN}${BOLD}═══ 当前代理信息 ═══${NC}"
        printf "  %-12s : ${YELLOW}%s${NC}\n" "$IP_LABEL" "$IP"
        printf "  %-12s : ${YELLOW}%s${NC}\n" "端口"      "$PORT"
        printf "  %-12s : ${YELLOW}%s${NC}\n" "用户名"    "$USER"
        printf "  %-12s : ${YELLOW}%s${NC}\n" "密码"      "$PASS"
        echo ""
        echo -e "${CYAN}${BOLD}═══ URI 一键复制 ═══${NC}"
        echo -e "  ${YELLOW}socks5://${USER}:${PASS}@${URI_HOST}:${PORT}${NC}"
        echo ""
        echo -e "${CYAN}${BOLD}═══ curl 验证 ═══${NC}"
        if [[ "$MODE" == "ipv6" ]]; then
            echo -e "  ${YELLOW}curl -x socks5h://${USER}:${PASS}@${URI_HOST}:${PORT} https://api6.ipify.org${NC}"
        else
            echo -e "  ${YELLOW}curl -x socks5h://${USER}:${PASS}@${URI_HOST}:${PORT} https://api.ipify.org${NC}"
        fi
    fi
}

# ────────────────────────────────────────────
# 主菜单
# ────────────────────────────────────────────
main_menu() {
    print_banner
    echo -e "${BOLD}请选择操作:${NC}"
    echo "  1) 安装 SOCKS5（选择 IPv4/IPv6）"
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
