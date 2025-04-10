#!/bin/bash
set -euo pipefail

# --------------------------------------
# 颜色与日志函数
# --------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

log_info() {
    echo -e "[${GREEN}INFO${PLAIN}] $1"
}
log_warn() {
    echo -e "[${YELLOW}WARN${PLAIN}] $1"
}
log_error() {
    echo -e "[${RED}ERROR${PLAIN}] $1"
}

# --------------------------------------
# 全局路径
# --------------------------------------
SS_CONFIG_PATH="/etc/shadowsocks/config.json"
STLS_CONFIG_PATH="/etc/systemd/system/shadow-tls.service"

# --------------------------------------
# 检查是否为 root
# --------------------------------------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "必须使用 root 用户运行此脚本！"
        exit 1
    fi
}

# --------------------------------------
# 获取公网 IP 地址（优先 IPv6）
# --------------------------------------
get_public_ip() {
    local ip=""
    ip=$(curl -6 -s -m 10 https://api64.ipify.org || \
         curl -s -m 10 https://api.ipify.org || \
         curl -s -m 10 https://api.ip.sb/ip || \
         curl -s -m 10 https://icanhazip.com || true)
    if [[ -z "$ip" ]]; then
        log_warn "无法获取公网 IP 地址，将使用内网 IP 地址"
        ip=$(hostname -I | awk '{print $1}')
    fi
    ip=$(echo "$ip" | tr -d '[:space:]')
    # 如果是 IPv6，就加上 []
    if [[ "$ip" == *:* ]]; then
        ip="[$ip]"
    fi
    echo "$ip"
}

# --------------------------------------
# 检查并安装必要工具
# --------------------------------------
check_tool() {
    local tools=("xz" "wget" "curl" "jq" "openssl")
    local PM=""
    local pkgs=()

    if command -v apt &>/dev/null; then
        PM="apt"
    elif command -v yum &>/dev/null; then
        PM="yum"
    elif command -v dnf &>/dev/null; then
        PM="dnf"
    else
        log_error "无法确定包管理器，请手动安装以下工具：${tools[*]}"
        exit 1
    fi

    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            log_warn "检测到 $tool 未安装，将进行安装"
            if [ "$PM" = "apt" ]; then
                if [ "$tool" = "xz" ]; then
                    pkgs+=("xz-utils")
                else
                    pkgs+=("$tool")
                fi
            else
                pkgs+=("$tool")
            fi
        else
            log_info "$tool 已安装"
        fi
    done

    if [ ${#pkgs[@]} -gt 0 ]; then
        log_warn "正在安装缺失工具：${pkgs[*]}"
        if [ "$PM" = "apt" ]; then
            apt update && apt install -y "${pkgs[@]}"
        else
            $PM install -y "${pkgs[@]}"
        fi
        log_info "所有工具安装成功"
    fi
}

# ============================
#  Shadowsocks 功能函数
# ============================

install_shadowsocks() {
    log_info "开始安装 Shadowsocks 服务..."
    check_tool

    local ARCH
    ARCH=$(uname -m)
    local ARCH_SUFFIX=""
    case "$ARCH" in
        x86_64)   ARCH_SUFFIX="x86_64-unknown-linux-gnu" ;;
        i686)     ARCH_SUFFIX="i686-unknown-linux-musl" ;;
        aarch64)  ARCH_SUFFIX="aarch64-unknown-linux-gnu" ;;
        armv7l)   ARCH_SUFFIX="armv7-unknown-linux-gnueabihf" ;;
        armv6l)   ARCH_SUFFIX="arm-unknown-linux-gnueabihf" ;;
        *)
            log_error "不支持的架构: $ARCH"
            exit 1
    esac

    log_info "获取 Shadowsocks 最新版本信息..."
    local api_response
    api_response=$(curl -s --header "User-Agent:Mozilla/5.0" https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest || true)
    if [ -z "$api_response" ]; then
        log_error "获取 GitHub Release 信息失败，请检查网络"
        exit 1
    fi

    local LATEST_TAG
    LATEST_TAG=$(echo "$api_response" | jq -r '.tag_name')
    if [ -z "$LATEST_TAG" ]; then
        log_error "无法获取 Shadowsocks 最新版本号"
        exit 1
    fi

    local LATEST_URL="https://github.com/shadowsocks/shadowsocks-rust/releases/download/$LATEST_TAG/shadowsocks-$LATEST_TAG.$ARCH_SUFFIX.tar.xz"
    log_warn "Shadowsocks 未安装或有更新，将下载安装: $LATEST_URL"

    log_info "正在下载 Shadowsocks..."
    curl -L -o "/tmp/ss-rust.tar.xz" "$LATEST_URL" || { log_error "下载 Shadowsocks 失败，请检查网络"; exit 1; }
    tar -Jxf /tmp/ss-rust.tar.xz -C /usr/local/bin/
    rm -f /tmp/ss-rust.tar.xz
    log_info "Shadowsocks 安装/更新完成"

    mkdir -p /etc/shadowsocks

    read -p "请输入 Shadowsocks 端口(1024-65535)，或按回车随机生成: " ss_port
    if [[ -z "$ss_port" || ! "$ss_port" =~ ^[0-9]+$ || "$ss_port" -lt 1024 || "$ss_port" -gt 65535 ]]; then
        log_warn "端口无效，使用随机端口"
        ss_port=$(shuf -i 1024-65535 -n 1)
    fi
    log_info "将使用端口：$ss_port"

    log_info "选择加密方法 [Enter=2]："
    echo "1) 2022-blake3-aes-128-gcm"
    echo "2) 2022-blake3-aes-256-gcm"
    echo "3) 2022-blake3-chacha20-poly1305"
    echo "4) aes-256-gcm"
    echo "5) aes-128-gcm"
    echo "6) chacha20-ietf-poly1305"
    echo "7) none"
    echo "8) aes-128-cfb"
    echo "9) aes-192-cfb"
    echo "10) aes-256-cfb"
    echo "11) aes-128-ctr"
    echo "12) aes-192-ctr"
    echo "13) aes-256-ctr"
    echo "14) camellia-128-cfb"
    echo "15) camellia-192-cfb"
    echo "16) camellia-256-cfb"
    echo "17) rc4-md5"
    echo "18) chacha20-ietf"

    read -p "输入数字: " enc_choice
    enc_choice=${enc_choice:-2}

    local method=""
    local ss_password=""
    case "$enc_choice" in
        1)
            method="2022-blake3-aes-128-gcm"
            ss_password=$(openssl rand -base64 16)
            ;;
        2)
            method="2022-blake3-aes-256-gcm"
            ss_password=$(openssl rand -base64 32)
            ;;
        3)
            method="2022-blake3-chacha20-poly1305"
            ss_password=$(openssl rand -base64 32)
            ;;
        *)
            # 对应普通加密方法
            case "$enc_choice" in
                4)  method="aes-256-gcm" ;;
                5)  method="aes-128-gcm" ;;
                6)  method="chacha20-ietf-poly1305" ;;
                7)  method="none" ;;
                8)  method="aes-128-cfb" ;;
                9)  method="aes-192-cfb" ;;
                10) method="aes-256-cfb" ;;
                11) method="aes-128-ctr" ;;
                12) method="aes-192-ctr" ;;
                13) method="aes-256-ctr" ;;
                14) method="camellia-128-cfb" ;;
                15) method="camellia-192-cfb" ;;
                16) method="camellia-256-cfb" ;;
                17) method="rc4-md5" ;;
                18) method="chacha20-ietf" ;;
                *)
                    method="2022-blake3-aes-256-gcm"
                    ss_password=$(openssl rand -base64 32)
                    log_warn "无效选择，使用默认 2022-blake3-aes-256-gcm"
                    ;;
            esac
            # 普通加密方法时可自定义密码
            read -p "请输入密码 (回车则默认yuju.love): " custom_pw
            if [[ -z "$custom_pw" ]]; then
                ss_password="yuju.love"
            else
                ss_password="$custom_pw"
            fi
            ;;
    esac

    read -p "输入节点名称 (回车默认为 Shadowsocks-$method): " node_name
    if [[ -z "$node_name" ]]; then
        node_name="Shadowsocks-$method"
    fi

    log_info "生成 Shadowsocks 配置..."
    cat <<EOF > "$SS_CONFIG_PATH"
{
    "server": "::",
    "server_port": $ss_port,
    "password": "$ss_password",
    "method": "$method",
    "fast_open": false,
    "mode": "tcp_and_udp"
}
EOF

    cat <<EOF > /etc/systemd/system/shadowsocks.service
[Unit]
Description=Shadowsocks Rust
After=network.target

[Service]
ExecStart=/usr/local/bin/ssserver -c /etc/shadowsocks/config.json
Restart=on-abort

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl start shadowsocks
    systemctl enable shadowsocks &>/dev/null || true

    if systemctl is-active shadowsocks &>/dev/null; then
        log_info "Shadowsocks 已启动！"
    else
        log_error "Shadowsocks 启动失败，请检查"
    fi

    # 输出节点信息
    local public_ip base64_pass
    public_ip=$(get_public_ip)
    base64_pass=$(echo -n "$method:$ss_password" | base64 | tr -d '\n')
    log_info "Shadowsocks 节点: ss://${base64_pass}@${public_ip}:${ss_port}#$node_name"

    mkdir -p /etc/shadowsocks
    cat <<EOF > /etc/shadowsocks/info.txt
端口: $ss_port
密码: $ss_password
加密方法: $method
节点名称: $node_name
链接: ss://${base64_pass}@${public_ip}:${ss_port}#$node_name
EOF

    log_info "安装完成，/etc/shadowsocks/info.txt 中有详细配置信息"
}

check_shadowsocks_status() {
    if ! command -v ssserver &>/dev/null; then
        log_error "Shadowsocks 未安装"
        return 1
    fi
    echo "Shadowsocks 版本: $(ssserver --version)"
    echo "服务状态: $(systemctl is-active shadowsocks)"
}

check_shadowsocks_config() {
    if [ -f /etc/shadowsocks/info.txt ]; then
        cat /etc/shadowsocks/info.txt
    else
        log_warn "未找到 /etc/shadowsocks/info.txt"
    fi
}

modify_shadowsocks_config() {
    if ! command -v ssserver &>/dev/null; then
        log_error "Shadowsocks 未安装"
        return 1
    fi
    if [ ! -f "$SS_CONFIG_PATH" ]; then
        log_error "未找到 Shadowsocks 配置文件 $SS_CONFIG_PATH"
        return 1
    fi
    # 此处省略：可以参考你之前的脚本，对端口、加密方式、密码进行修改
    log_warn "此函数可自行实现修改并重启 Shadowsocks"
}

start_shadowsocks() {
    systemctl start shadowsocks
    if systemctl is-active shadowsocks &>/dev/null; then
        log_info "Shadowsocks 已启动"
    else
        log_error "启动 Shadowsocks 失败"
    fi
}

stop_shadowsocks() {
    if systemctl is-active shadowsocks &>/dev/null; then
        systemctl stop shadowsocks
        log_info "已停止 Shadowsocks"
    else
        log_warn "Shadowsocks 未运行"
    fi
}

restart_shadowsocks() {
    systemctl restart shadowsocks
    if systemctl is-active shadowsocks &>/dev/null; then
        log_info "Shadowsocks 已重启"
    else
        log_error "重启 Shadowsocks 失败"
    fi
}

uninstall_shadowsocks() {
    log_warn "警告：此操作将卸载 Shadowsocks"
    read -p "是否继续 (y/n): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "取消卸载"
        return
    fi
    systemctl stop shadowsocks || true
    systemctl disable shadowsocks || true
    rm -f /etc/systemd/system/shadowsocks.service
    systemctl daemon-reload
    rm -rf /etc/shadowsocks
    rm -f /usr/local/bin/ssserver
    rm -f /usr/local/bin/sslocal
    rm -f /usr/local/bin/ssurl
    rm -f /usr/local/bin/ssmanager
    log_info "Shadowsocks 已卸载"
}

# ============================
#  ShadowTLS 功能函数
# ============================

install_shadowtls() {
    log_info "开始安装 ShadowTLS..."
    # 类似 install_shadowsocks 的流程
    # 省略
    log_warn "此函数请自行填充，需要时参考之前脚本"
}

check_shadowtls_status() {
    # 类似 check_shadowsocks_status
    log_warn "此函数请自行填充"
}

check_shadowtls_config() {
    log_warn "自行查看 /etc/shadowtls/info.txt"
}

modify_shadowtls_config() {
    log_warn "自行修改后 systemctl restart shadow-tls"
}

shadowtls_control() {
    local action=$1
    case $action in
        start)
            systemctl start shadow-tls
            ;;
        stop)
            systemctl stop shadow-tls
            ;;
        restart)
            systemctl restart shadow-tls
            ;;
    esac
}

uninstall_shadowtls() {
    log_warn "此操作将卸载 ShadowTLS"
    read -p "是否继续 (y/n): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "取消卸载"
        return
    fi
    if systemctl list-units --all | grep -q "shadow-tls.service"; then
        systemctl stop shadow-tls || true
        systemctl disable shadow-tls || true
    fi
    rm -f /usr/bin/shadow-tls
    rm -f /etc/systemd/system/shadow-tls.service
    systemctl daemon-reload
    rm -rf /etc/shadowtls
    log_info "ShadowTLS 已卸载"
}

# ============================
#  其余功能函数
# ============================

ss_links() {
    # 输出 Shadowsocks 节点链接
    if [ ! -f "$SS_CONFIG_PATH" ]; then
        log_error "Shadowsocks 未安装或者配置不存在"
        return 1
    fi
    local ss_port ss_pass method node_name ip base64_pw final_url
    ss_port=$(jq -r '.server_port' "$SS_CONFIG_PATH")
    ss_pass=$(jq -r '.password' "$SS_CONFIG_PATH")
    method=$(jq -r '.method' "$SS_CONFIG_PATH")
    node_name=$(grep "节点名称:" /etc/shadowsocks/info.txt | cut -d ' ' -f 2- || echo "Shadowsocks-$method")
    ip=$(get_public_ip)
    base64_pw=$(echo -n "$method:$ss_pass" | base64 | tr -d '\n')
    final_url="ss://${base64_pw}@${ip}:${ss_port}#$node_name"
    echo -e "${GREEN}Shadowsocks 节点链接:${PLAIN}\n${BLUE}$final_url${PLAIN}"
}

install_all() {
    check_root
    install_shadowsocks
    install_shadowtls
    # 可以在安装完后自动输出链接
    ss_links
    read -n 1 -s -r -p "按任意键继续..."
}

uninstall_all() {
    check_root
    uninstall_shadowsocks
    uninstall_shadowtls
    log_warn "正在删除脚本本身..."
    rm -f "$0"
    log_info "所有组件及脚本已卸载！"
    exit 0
}

# ---------------------------
# 子菜单
# ---------------------------
ss_submenu() {
    while true; do
        clear
        echo -e "${BLUE}=== Shadowsocks 服务管理 ===${PLAIN}"
        echo "  1) 安装 Shadowsocks"
        echo "  2) 查看 Shadowsocks 状态"
        echo "  3) 查看 Shadowsocks 配置"
        echo "  4) 修改 Shadowsocks 配置"
        echo "  5) 启动 Shadowsocks"
        echo "  6) 停止 Shadowsocks"
        echo "  7) 重启 Shadowsocks"
        echo "  9) 卸载 Shadowsocks"
        echo "  0) 返回主菜单"
        read -p "选项: " choice
        case $choice in
            1) install_shadowsocks ;;
            2) check_shadowsocks_status ;;
            3) check_shadowsocks_config ;;
            4) modify_shadowsocks_config ;;
            5) start_shadowsocks ;;
            6) stop_shadowsocks ;;
            7) restart_shadowsocks ;;
            9) uninstall_shadowsocks ;;
            0) return ;;
            *) echo -e "${RED}无效选项${PLAIN}" ;;
        esac
        read -n 1 -s -r -p "按任意键返回..."
    done
}

stls_submenu() {
    while true; do
        clear
        echo -e "${BLUE}=== ShadowTLS 服务管理 ===${PLAIN}"
        echo "  1) 安装 ShadowTLS"
        echo "  2) 查看 ShadowTLS 状态"
        echo "  3) 查看 ShadowTLS 配置"
        echo "  4) 修改 ShadowTLS 配置"
        echo "  5) 启动 ShadowTLS"
        echo "  6) 停止 ShadowTLS"
        echo "  7) 重启 ShadowTLS"
        echo "  9) 卸载 ShadowTLS"
        echo "  0) 返回主菜单"
        read -p "选项: " choice
        case $choice in
            1) install_shadowtls ;;
            2) check_shadowtls_status ;;
            3) check_shadowtls_config ;;
            4) modify_shadowtls_config ;;
            5) shadowtls_control start ;;
            6) shadowtls_control stop ;;
            7) shadowtls_control restart ;;
            9) uninstall_shadowtls ;;
            0) return ;;
            *) echo -e "${RED}无效选项${PLAIN}" ;;
        esac
        read -n 1 -s -r -p "按任意键返回..."
    done
}

# ---------------------------
# 主菜单
# ---------------------------
main_menu() {
    while true; do
        clear
        echo -e "${BLUE}================================${PLAIN}"
        echo "          Shadowsocks 管理脚本"
        echo -e "${BLUE}================================${PLAIN}"
        echo "  1) Shadowsocks 管理"
        echo "  2) ShadowTLS 管理"
        echo "  3) 安装 Shadowsocks ShadowTLS"
        echo "  4) 输出当前节点链接"
        echo "  9) 完全卸载"
        echo "  0) 退出脚本"
        echo -e "${BLUE}================================${PLAIN}"
        read -p "请输入选项: " main_choice
        case $main_choice in
            1) ss_submenu ;;
            2) stls_submenu ;;
            3) install_all ;;
            4) ss_links ;;
            9) uninstall_all ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选项${PLAIN}" ;;
        esac
    done
}

# ---------------------------
#  脚本入口
# ---------------------------
check_root
main_menu
