#!/bin/bash

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

# 全局变量
SING_BOX_BIN="/usr/local/bin/sing-box"
CONFIG_DIR="/usr/local/etc/sing-box"
CONFIG_FILE="$CONFIG_DIR/config.json"
LOG_DIR="/var/log/sing-box"
LOG_FILE="/var/log/sing-box-install.log"
TMP_DIR=$(mktemp -d)

# 日志记录函数
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    case "$level" in
        INFO)  echo -e "${GREEN}$message${PLAIN}" ;;
        WARN)  echo -e "${YELLOW}$message${PLAIN}" ;;
        ERROR) echo -e "${RED}$message${PLAIN}" ;;
    esac
}

# 检查命令执行结果
check_result() {
    local ret=$1
    local message="$2"
    if [ $ret -ne 0 ]; then
        log ERROR "$message"
        return 1
    fi
    log INFO "$message"
    return 0
}

# 停止防火墙
stop_firewall() {
    log INFO "正在停止防火墙..."
    
    # 保存防火墙状态用于回滚
    local firewall_status=""
    if command -v firewalld &>/dev/null; then
        firewall_status=$(systemctl is-active firewalld)
        systemctl stop firewalld && systemctl disable firewalld
        check_result $? "已停止 firewalld" || return 1
    fi
    
    if command -v apt &>/dev/null; then
        if ! dpkg -l | grep -qw ufw; then
            log WARN "正在安装 ufw..."
            apt update && apt install -y ufw
            check_result $? "ufw 安装完成" || return 1
        fi
        ufw disable
        check_result $? "已停止 ufw" || return 1
    fi
    
    echo "$firewall_status" > /tmp/firewall_status
    return 0
}

# 恢复防火墙状态
restore_firewall() {
    log WARN "正在恢复防火墙状态..."
    if [ -f /tmp/firewall_status ]; then
        local status=$(cat /tmp/firewall_status)
        if [ "$status" = "active" ] && command -v firewalld &>/dev/null; then
            systemctl enable firewalld && systemctl start firewalld
            check_result $? "已恢复 firewalld" || return 1
        fi
        rm -f /tmp/firewall_status
    fi
    return 0
}

# 配置 SELinux
configure_selinux() {
    local port="$1"
    if ! command -v sestatus &>/dev/null; then
        log INFO "SELinux 未安装，跳过配置"
        return 0
    fi
    if sestatus | grep -q "SELinux status:.*enabled"; then
        log INFO "正在配置 SELinux..."
        semanage port -a -t http_port_t -p tcp "$port" 2>/dev/null || semanage port -m -t http_port_t -p tcp "$port"
        check_result $? "SELinux 端口配置完成" || return 1
        chcon -t bin_t "$SING_BOX_BIN"
        check_result $? "SELinux 文件上下文配置完成" || return 1
    fi
    return 0
}

# 安装基础软件包
install_base_packages() {
    local pkg_manager
    if command -v apt &>/dev/null; then
        pkg_manager="apt"
        apt update && apt install -y curl wget unzip tar openssl
    elif command -v apk &>/dev/null; then
        pkg_manager="apk"
        apk update && apk add curl wget unzip tar openssl bash
    elif command -v dnf &>/dev/null; then
        pkg_manager="dnf"
        dnf -y update && dnf -y install curl wget unzip tar openssl
    else
        log ERROR "不支持的系统！"
        exit 1
    fi
    check_result $? "$pkg_manager 基础软件包安装完成" || return 1
}

# 验证配置文件
validate_config() {
    log INFO "正在验证配置文件..."
    $SING_BOX_BIN check -c "$CONFIG_FILE"
    check_result $? "配置文件验证通过" || return 1
}

# 检查服务状态
check_status() {
    if command -v systemctl &>/dev/null; then
        systemctl is-active --quiet sing-box
        check_result $? "sing-box 服务已启动" || {
            log ERROR "服务启动失败，请检查日志："
            journalctl -u sing-box --no-pager -n 50
            return 1
        }
    else
        rc-service sing-box status &>/dev/null
        check_result $? "sing-box 服务已启动" || return 1
    fi
}

# 回滚安装
rollback_install() {
    log WARN "安装失败，正在回滚..."
    restore_firewall
    rm -f "$SING_BOX_BIN"
    rm -rf "$CONFIG_DIR" "$LOG_DIR"
    if command -v systemctl &>/dev/null; then
        systemctl stop sing-box 2>/dev/null
        rm -f /etc/systemd/system/sing-box.service
        systemctl daemon-reload
    else
        rc-service sing-box stop 2>/dev/null
        rm -f /etc/init.d/sing-box
    fi
    log INFO "回滚完成"
}

# 安装 sing-box
install_sing_box() {
    log INFO "开始安装 sing-box..."
    
    # 停止防火墙
    stop_firewall || { rollback_install; exit 1; }
    
    # 获取端口
    local port
    while true; do
        read -p "请输入连接端口 (1-65535): " port
        if [[ ! $port =~ ^[0-9]+$ ]]; then
            log ERROR "请输入有效的数字！"
            continue
        elif [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            log ERROR "端口范围无效，请输入 1-65535 之间的数字！"
            continue
        elif [ "$port" -lt 1024 ] && [ "$port" -ne 443 ]; then
            log WARN "使用 1024 以下的端口可能需要 root 权限"
        fi
        if netstat -tuln 2>/dev/null | grep -q ":$port " || ss -tuln 2>/dev/null | grep -q ":$port "; then
            log ERROR "端口 $port 已被使用，请选择其他端口！"
            continue
        fi
        break
    done

    # 检查架构
    local arch
    case $(uname -m) in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        *) log ERROR "不支持的系统架构！"; exit 1 ;;
    esac

    # 安装依赖
    install_base_packages || { rollback_install; exit 1; }

    # 下载最新版本
    cd "$TMP_DIR" || { log ERROR "无法进入临时目录"; rollback_install; exit 1; }
    local version=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | awk -F'"' '/tag_name/{print $4}')
    if [[ -z "$version" ]]; then
        log ERROR "无法获取版本信息！"
        rollback_install
        exit 1
    fi

    local download_url="https://github.com/SagerNet/sing-box/releases/download/${version}/sing-box-${version#v}-linux-${arch}.tar.gz"
    log INFO "下载地址: $download_url"
    wget -q --show-progress "$download_url" || { log ERROR "下载失败！"; rollback_install; exit 1; }

    tar -xf "sing-box-${version#v}-linux-${arch}.tar.gz" || { log ERROR "解压失败！"; rollback_install; exit 1; }
    cd "sing-box-${version#v}-linux-${arch}" || { log ERROR "进入解压目录失败！"; rollback_install; exit 1; }

    # 安装文件
    install -m 755 sing-box "$SING_BOX_BIN" || { log ERROR "安装 sing-box 失败！"; rollback_install; exit 1; }
    mkdir -p "$CONFIG_DIR" "$LOG_DIR"

    # 生成密钥对
    local keys=$($SING_BOX_BIN generate reality-keypair)
    local private_key=$(echo "$keys" | awk -F " " '{print $2}')
    local public_key=$(echo "$keys" | awk -F " " '{print $4}')

    # 生成 UUID 和短 ID
    local uuid=$($SING_BOX_BIN generate uuid)
    local short_id=$(openssl rand -hex 8)

    # 创建服务文件
    if command -v systemctl &>/dev/null; then
        cat > /etc/systemd/system/sing-box.service << EOF
[Unit]
Description=sing-box Service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
ExecStart=$SING_BOX_BIN run -c $CONFIG_FILE
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    else
        cat > /etc/init.d/sing-box << EOF
#!/sbin/openrc-run

name="sing-box"
description="Sing-box Service"
command="$SING_BOX_BIN"
command_args="run -c $CONFIG_FILE"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"

depend() {
    need net
}
EOF
        chmod +x /etc/init.d/sing-box
    fi

    # 创建配置文件
    cat > "$CONFIG_FILE" << EOF
{
    "log": {
        "level": "error",
        "timestamp": true
    },
    "inbounds": [
        {
            "type": "vless",
            "tag": "vless-in",
            "listen": "::",
            "listen_port": ${port},
            "users": [
                {
                    "name": "default",
                    "uuid": "${uuid}",
                    "flow": "xtls-rprx-vision"
                }
            ],
            "tls": {
                "enabled": true,
                "server_name": "gateway.icloud.com",
                "reality": {
                    "enabled": true,
                    "handshake": {
                        "server": "gateway.icloud.com",
                        "server_port": 443
                    },
                    "private_key": "${private_key}",
                    "short_id": [
                        "${short_id}"
                    ]
                }
            }
        }
    ],
    "outbounds": [
        {
            "type": "direct",
            "tag": "direct"
        }
    ]
}
EOF

    # 设置配置文件权限
    chmod 600 "$CONFIG_FILE"
    log INFO "配置文件权限已设置为 600"

    # 验证配置文件
    validate_config || { rollback_install; exit 1; }

    # 配置 SELinux
    configure_selinux "$port" || { rollback_install; exit 1; }

    # 启动服务
    if command -v systemctl &>/dev/null; then
        systemctl daemon-reload
        systemctl enable sing-box && systemctl start sing-box
    else
        rc-update add sing-box default
        rc-service sing-box start
    fi

    # 检查服务状态
    check_status || { rollback_install; exit 1; }

    # 获取服务器 IP
    local ip=$(curl -s4m8 ip.sb || curl -s6m8 ip.sb)

    # 生成分享链接
    local vless_link
    if [[ $ip =~ ":" ]]; then
        vless_link="vless://${uuid}@[${ip}]:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=gateway.icloud.com&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#Sing-Box-Reality"
    else
        vless_link="vless://${uuid}@${ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=gateway.icloud.com&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#Sing-Box-Reality"
    fi

    log INFO "安装完成！"
    log INFO "端口: $port"
    log INFO "UUID: $uuid"
    log INFO "Public Key: $public_key"
    log INFO "Short ID: $short_id"
    log INFO "分享链接: $vless_link"
}

# 更新密钥
update_keys() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log ERROR "配置文件不存在！"
        return 1
    fi

    log INFO "正在生成新的密钥对..."
    local keys=$($SING_BOX_BIN generate reality-keypair)
    local private_key=$(echo "$keys" | awk -F " " '{print $2}')
    local public_key=$(echo "$keys" | awk -F " " '{print $4}')

    # 备份配置
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"

    # 更新配置
    sed -i "s/\"private_key\": \"[^\"]*\"/\"private_key\": \"$private_key\"/" "$CONFIG_FILE"
    check_result $? "密钥更新完成" || {
        mv "${CONFIG_FILE}.bak" "$CONFIG_FILE"
        log ERROR "密钥更新失败，已恢复原配置"
        return 1
    }

    # 验证新配置
    validate_config || {
        mv "${CONFIG_FILE}.bak" "$CONFIG_FILE"
        log ERROR "新配置文件无效，已恢复原配置"
        return 1
    }

    # 重启服务
    if command -v systemctl &>/dev/null; then
        systemctl restart sing-box
    else
        rc-service sing-box restart
    fi
    check_status || {
        mv "${CONFIG_FILE}.bak" "$CONFIG_FILE"
        log ERROR "服务重启失败，已恢复原配置"
        return 1
    }

    log INFO "密钥更新成功！"
    log INFO "新的 Public Key: $public_key"
}

# 卸载
uninstall() {
    log INFO "正在卸载 sing-box..."
    
    # 停止服务
    if command -v systemctl &>/dev/null; then
        systemctl stop sing-box 2>/dev/null
        systemctl disable sing-box 2>/dev/null
        rm -f /etc/systemd/system/sing-box.service
        systemctl daemon-reload
    else
        rc-service sing-box stop 2>/dev/null
        rc-update del sing-box default 2>/dev/null
        rm -f /etc/init.d/sing-box
    fi

    # 清理文件
    rm -f "$SING_BOX_BIN"
    rm -rf "$CONFIG_DIR" "$LOG_DIR"
    log INFO "卸载完成！"
}

# 显示菜单
show_menu() {
    echo -e "
  ${GREEN}Sing-box Reality 管理脚本${PLAIN}
  ${GREEN}1.${PLAIN} 安装
  ${GREEN}2.${PLAIN} 更新密钥
  ${GREEN}3.${PLAIN} 卸载
  ${GREEN}0.${PLAIN} 退出
  "
    read -p "请输入选择 [0-3]: " num
    case "$num" in
        1) install_sing_box ;;
        2) update_keys ;;
        3) uninstall ;;
        0) exit 0 ;;
        *) log ERROR "请输入正确的选项 [0-3]" ;;
    esac
}

# 检查 root 权限
[[ $EUID -ne 0 ]] && { log ERROR "请以 root 身份运行！"; exit 1; }

# 检查 curl
if ! command -v curl &>/dev/null; then
    log WARN "curl 未安装，正在安装..."
    install_base_packages || exit 1


# 清理临时文件
cleanup() {
    [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
    rm -f /tmp/firewall_status
}
trap cleanup EXIT

# 创建日志文件
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

show_menu
