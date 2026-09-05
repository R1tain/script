#!/bin/bash
# reality-warp.sh - 新建一个独立的 "Reality (走 WARP 出口)" 服务
#
# 与 reality.sh 装的原始 Reality 服务完全隔离、互不影响：
#   - 独立端口 / 独立 UUID / 独立密钥
#   - 独立 systemd 服务: sing-box-warp
#   - 独立配置文件: /usr/local/etc/sing-box-warp/config.json
#   - 出站不是 direct，而是打到 MicroWARP 提供的本地 SOCKS5 (127.0.0.1:1080)
#     MicroWARP: https://github.com/ccbkkb/MicroWARP (Cloudflare WARP 出口)
#
# 架构:
#   客户端 --Reality(新端口)--> sing-box-warp(vless-in) --socks--> 127.0.0.1:1080(MicroWARP) --> WARP 出口
#   原有的 reality.sh 服务 (另一个端口) 保持原样，直连出站，不受任何影响。
#
# 用法: bash reality-warp.sh

if [ -z "$BASH_VERSION" ]; then
    echo "错误：请使用 bash 运行此脚本（bash reality-warp.sh）"
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo -e "\033[31m错误：此脚本必须以 root 权限运行！\033[0m"
    exit 1
fi

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

# --- sing-box 二进制 (与 reality.sh 共用同一份，没有则自己下载) ---
SING_BOX_BIN="/usr/local/bin/sing-box"

# --- 新服务：独立配置/独立 systemd 单元，不碰原有 reality.sh 的任何文件 ---
CONFIG_DIR="/usr/local/etc/sing-box-warp"
CONFIG_FILE="$CONFIG_DIR/config.json"
SERVICE_NAME="sing-box-warp"
SERVICE_LOG="/root/sing-box-warp.log"

# --- MicroWARP (SOCKS5 出口容器) ---
WARP_DIR="/usr/local/etc/microwarp"
WARP_COMPOSE_FILE="$WARP_DIR/docker-compose.yml"
WARP_CONTAINER="microwarp"

LOG_DIR="/var/log/sing-box-warp"
LOG_FILE="/var/log/sing-box-warp-install.log"
TMP_DIR=""
COMPOSE_CMD="docker compose"

log() {
    local level="$1" message="$2" ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] [$level] $message" >> "$LOG_FILE"
    case "$level" in
        信息|INFO) echo -e "${GREEN}[$ts] [信息] $message${PLAIN}" ;;
        警告|WARN) echo -e "${YELLOW}[$ts] [警告] $message${PLAIN}" ;;
        错误|ERROR) echo -e "${RED}[$ts] [错误] $message${PLAIN}" ;;
        *) echo -e "[$ts] [$level] $message" ;;
    esac
}

check_result() {
    local name="$1"
    if [ $? -ne 0 ]; then log 错误 "$name 失败。"; return 1; fi
    return 0
}

sanitize_var() {
    echo "$1" | tr -d '\n\r"' | tr -dc 'A-Za-z0-9-._:'
}

# --- 防火墙: 只放行端口，绝不整体关闭防火墙 ---
open_firewall_port() {
    local port="$1" proto="${2:-tcp}"
    [[ -z "$port" ]] && return 0
    if command -v ufw &>/dev/null; then
        if [[ "$(ufw status | head -n1)" == "Status: active" ]]; then
            log 信息 "ufw 放行端口 ${port}/${proto} ..."
            ufw allow "${port}/${proto}" >/dev/null 2>&1
        fi
    fi
    if command -v firewall-cmd &>/dev/null; then
        if [ "$(systemctl is-active firewalld 2>/dev/null)" = "active" ]; then
            log 信息 "firewalld 放行端口 ${port}/${proto} ..."
            firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null 2>&1
            firewall-cmd --reload >/dev/null 2>&1
        fi
    fi
    return 0
}

close_firewall_port() {
    local port="$1" proto="${2:-tcp}"
    [[ -z "$port" ]] && return 0
    if command -v ufw &>/dev/null; then
        [[ "$(ufw status | head -n1)" == "Status: active" ]] && ufw delete allow "${port}/${proto}" >/dev/null 2>&1
    fi
    if command -v firewall-cmd &>/dev/null; then
        if [ "$(systemctl is-active firewalld 2>/dev/null)" = "active" ]; then
            firewall-cmd --permanent --remove-port="${port}/${proto}" >/dev/null 2>&1
            firewall-cmd --reload >/dev/null 2>&1
        fi
    fi
    return 0
}

# --- 依赖 ---
install_base_packages() {
    local pkgs="curl wget tar openssl coreutils iproute2"
    if command -v apt &>/dev/null; then apt update -y && apt install -y $pkgs
    elif command -v apk &>/dev/null; then apk update && apk add $pkgs bash
    elif command -v dnf &>/dev/null; then dnf install -y $pkgs
    elif command -v yum &>/dev/null; then yum install -y $pkgs
    else log 错误 "未检测到支持的包管理器，请手动安装: $pkgs"; return 1
    fi
}

check_dependencies() {
    local deps=( "curl" "wget" "tar" "openssl" "install" "grep" "awk" "sed" "ss" )
    local missing=()
    for cmd in "${deps[@]}"; do command -v "$cmd" &>/dev/null || missing+=("$cmd"); done
    if [ ${#missing[@]} -ne 0 ]; then
        log 警告 "缺少依赖: ${missing[*]}，尝试自动安装..."
        install_base_packages || { log 错误 "依赖安装失败"; return 1; }
    fi
    return 0
}

ensure_sing_box_installed() {
    if command -v "$SING_BOX_BIN" &>/dev/null; then
        log 信息 "复用已存在的 sing-box 二进制: $SING_BOX_BIN"
        return 0
    fi
    log 信息 "未检测到 sing-box，开始下载..."
    local arch=""
    case $(uname -m) in
        x86_64 | amd64) arch="amd64" ;;
        aarch64 | arm64) arch="arm64" ;;
        *) log 错误 "不支持的系统架构: $(uname -m)"; return 1 ;;
    esac
    cd "$TMP_DIR" || return 1
    local api="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
    local tag
    tag=$(curl -s -H "User-Agent: reality-warp-script" --retry 3 --retry-delay 2 "$api" | grep -o '"tag_name":"[^"]*"' | head -1 | cut -d'"' -f4)
    [[ -z "$tag" ]] && { log 错误 "无法获取 sing-box 最新版本号。"; return 1; }
    local version=${tag#v}
    local url="https://github.com/SagerNet/sing-box/releases/download/${tag}/sing-box-${version}-linux-${arch}.tar.gz"
    wget --tries=3 --waitretry=3 -O sing-box.tar.gz "$url"
    check_result "下载 sing-box" || return 1
    tar -xzf sing-box.tar.gz --strip-components=1 "sing-box-${version}-linux-${arch}/sing-box"
    check_result "解压 sing-box" || return 1
    install -m 755 sing-box "$SING_BOX_BIN"
    check_result "安装 sing-box 二进制" || return 1
}

ensure_docker_installed() {
    if command -v docker &>/dev/null; then
        log 信息 "检测到 Docker: $(docker --version)"
    else
        log 信息 "未检测到 Docker，正在安装..."
        curl -fsSL https://get.docker.com | sh
        check_result "安装 Docker" || return 1
        systemctl enable docker 2>/dev/null
        systemctl start docker 2>/dev/null
    fi
    if docker compose version &>/dev/null; then
        COMPOSE_CMD="docker compose"
    elif command -v docker-compose &>/dev/null; then
        COMPOSE_CMD="docker-compose"
    else
        log 信息 "安装 docker compose 插件..."
        if command -v apt &>/dev/null; then apt install -y docker-compose-plugin
        elif command -v dnf &>/dev/null; then dnf install -y docker-compose-plugin
        elif command -v yum &>/dev/null; then yum install -y docker-compose-plugin
        elif command -v apk &>/dev/null; then apk add docker-cli-compose
        fi
        docker compose version &>/dev/null && COMPOSE_CMD="docker compose" || {
            log 错误 "docker compose 安装失败，请手动安装后重试。"; return 1;
        }
    fi
    return 0
}

get_public_ip() {
    local svcs=( "https://api.ipify.org" "https://icanhazip.com" "https://ipinfo.io/ip" "https://ifconfig.me/ip" "https://checkip.amazonaws.com" )
    local ip
    for s in "${svcs[@]}"; do
        ip=$(curl -s --max-time 8 -4 "$s")
        if [[ -n "$ip" ]] && ! [[ "$ip" == *\<* || "$ip" == *" "* ]]; then
            echo "$ip"; return 0
        fi
    done
    return 1
}

# --- MicroWARP 容器 (SOCKS5 出口, 供新 Reality 服务出站使用) ---
warp_port_from_compose() {
    # 注意: 不能直接对整段 "127.0.0.1:1080:1080" 做 grep -oE '[0-9]+' | head -1，
    # 那样会先匹配到 IP 里的 "127"，取到错误的端口号。必须用捕获组精确提取端口。
    [ -f "$WARP_COMPOSE_FILE" ] || return 0
    grep -oE '"127\.0\.0\.1:[0-9]+:[0-9]+"' "$WARP_COMPOSE_FILE" | head -1 | sed -E 's/.*:([0-9]+):[0-9]+"/\1/'
}

ensure_microwarp_running() {
    if [ -f "$WARP_COMPOSE_FILE" ] && docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${WARP_CONTAINER}$"; then
        log 信息 "MicroWARP 容器已在运行，端口: $(warp_port_from_compose)"
        return 0
    fi

    ensure_docker_installed || return 1

    log 信息 "未检测到运行中的 MicroWARP，开始安装..."
    local bind_port="1080"
    echo -e "${YELLOW}MicroWARP 本地 SOCKS5 端口 [默认 1080，仅监听 127.0.0.1]:${PLAIN}"
    read -r ip
    [[ -n "$ip" ]] && bind_port="$ip"

    local socks_user="" socks_pass=""
    echo -e "${YELLOW}是否为 MicroWARP 的 SOCKS5 设置账号密码? (默认无密码) (y/N):${PLAIN}"
    read -r set_auth
    if [[ "$set_auth" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}用户名:${PLAIN}"
        read -r socks_user
        echo -e "${YELLOW}密码:${PLAIN}"
        read -r socks_pass
    fi

    local endpoint_ip=""
    echo -e "${YELLOW}是否启用端口跳跃 (机房 UDP 2408 被限速时用 4500)? (y/N):${PLAIN}"
    read -r use_hop
    [[ "$use_hop" =~ ^[Yy]$ ]] && endpoint_ip="162.159.192.1:4500"

    mkdir -p "$WARP_DIR"
    {
        echo "services:"
        echo "  microwarp:"
        echo "    image: ghcr.io/ccbkkb/microwarp:latest"
        echo "    container_name: $WARP_CONTAINER"
        echo "    restart: always"
        echo "    ports:"
        echo "      - \"127.0.0.1:${bind_port}:${bind_port}\""
        echo "    cap_add:"
        echo "      - NET_ADMIN"
        echo "      - SYS_MODULE"
        echo "    sysctls:"
        echo "      - net.ipv4.conf.all.src_valid_mark=1"
        echo "    environment:"
        echo "      - BIND_ADDR=0.0.0.0"
        echo "      - BIND_PORT=${bind_port}"
        echo "      - ALLOW_NO_AUTH=1"
        [[ -n "$socks_user" ]] && echo "      - SOCKS_USER=${socks_user}"
        [[ -n "$socks_pass" ]] && echo "      - SOCKS_PASS=${socks_pass}"
        [[ -n "$endpoint_ip" ]] && echo "      - ENDPOINT_IP=${endpoint_ip}"
        echo "    volumes:"
        echo "      - warp-data:/etc/wireguard"
        echo
        echo "volumes:"
        echo "  warp-data:"
    } > "$WARP_COMPOSE_FILE"

    (cd "$WARP_DIR" && $COMPOSE_CMD up -d)
    check_result "启动 MicroWARP 容器" || return 1

    log 信息 "等待 MicroWARP 就绪 (最多 20 秒)..."
    local i
    for i in $(seq 1 20); do
        ss -tuln | grep -q ":${bind_port} " && break
        sleep 1
    done
    log 信息 "MicroWARP 已就绪，本地 SOCKS5: 127.0.0.1:${bind_port}"
    return 0
}

# --- 新建 "Reality 走 WARP 出口" 服务 ---
install_reality_warp() {
    if [ -f "$CONFIG_FILE" ]; then
        log 警告 "检测到本服务已安装 ($CONFIG_FILE 已存在)。"
        echo -e "${YELLOW}是否覆盖重新安装? (y/N):${PLAIN}"
        read -r ov
        [[ ! "$ov" =~ ^[Yy]$ ]] && { log 信息 "已取消。"; return 0; }
        uninstall_reality_warp keep_warp
    fi

    check_dependencies || return 1
    ensure_sing_box_installed || return 1
    ensure_microwarp_running || return 1
    local warp_port
    warp_port=$(warp_port_from_compose)
    if ! [[ "$warp_port" =~ ^[0-9]+$ ]]; then
        log 警告 "未能从 $WARP_COMPOSE_FILE 解析出端口，回退使用默认值 1080。"
        warp_port=1080
    fi

    # 安装前先探测一下 MicroWARP 的 SOCKS5 端口是否真的能连上，避免把错误端口写进新配置
    if ! (exec 3<>"/dev/tcp/127.0.0.1/${warp_port}") 2>/dev/null; then
        log 错误 "无法连接 127.0.0.1:${warp_port} (MicroWARP)，请先用选项 8 检查容器状态/日志再重试。"
        return 1
    fi
    exec 3<&- 3>&- 2>/dev/null
    log 信息 "已确认 MicroWARP 的 SOCKS5 端口 127.0.0.1:${warp_port} 可连接。"

    # 1. 新端口 (必须与原有 reality.sh 服务的端口不同)
    local port=""
    while true; do
        echo -e "${YELLOW}请输入本服务(WARP 出口)的 Reality 连接端口 (需与原 Reality 服务不同):${PLAIN}"
        read -r port
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
            if ss -tuln | grep -q ":$port "; then
                log 错误 "端口 $port 已被占用，请换一个。"
            else
                break
            fi
        else
            log 错误 "端口无效，请输入 1-65535 之间的数字。"
        fi
    done

    # 2. 密钥 / UUID / short_id
    log 信息 "生成 Reality 密钥对..."
    local keys
    keys=$("$SING_BOX_BIN" generate reality-keypair 2>&1)
    check_result "生成密钥对" || return 1
    local private_key public_key
    private_key=$(sanitize_var "$(echo "$keys" | grep 'PrivateKey' | awk '{print $2}')")
    public_key=$(sanitize_var "$(echo "$keys" | grep 'PublicKey' | awk '{print $2}')")
    [[ -z "$private_key" || -z "$public_key" ]] && { log 错误 "提取密钥失败"; return 1; }

    local uuid short_id
    uuid=$("$SING_BOX_BIN" generate uuid)
    short_id=$(openssl rand -hex 8)

    # 3. SNI
    local dest_server="icloud-content.com"
    echo -e "${YELLOW}目标服务器域名 (SNI) [默认: $dest_server]:${PLAIN}"
    read -r input_sni
    if [[ -n "$input_sni" ]]; then
        local s
        s=$(echo "$input_sni" | tr -dc 'A-Za-z0-9-.' | head -c 253)
        [[ -n "$s" ]] && dest_server="$s"
    fi

    # 4. 写配置：inbound 与原版一致，outbound 换成指向 MicroWARP 的 socks
    mkdir -p "$CONFIG_DIR" "$LOG_DIR"
    cat > "$CONFIG_FILE" << EOF
{
  "log": {
    "level": "info",
    "disabled": false,
    "output": "$SERVICE_LOG",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": $port,
      "users": [
        { "uuid": "$uuid", "flow": "xtls-rprx-vision" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$dest_server",
        "reality": {
          "enabled": true,
          "handshake": { "server": "$dest_server", "server_port": 443 },
          "private_key": "$private_key",
          "short_id": ["$short_id"]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "socks",
      "tag": "warp-out",
      "server": "127.0.0.1",
      "server_port": $warp_port,
      "version": "5"
    },
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "rules": [
      { "network": ["tcp", "udp"], "outbound": "warp-out" }
    ],
    "auto_detect_interface": true,
    "default_mark": 0,
    "default_domain_resolver": "cloudflare"
  },
  "dns": {
    "servers": [
      { "tag": "google-dns", "type": "udp", "server": "8.8.8.8" },
      { "tag": "cloudflare", "type": "udp", "server": "1.1.1.1" }
    ],
    "final": "cloudflare"
  }
}
EOF
    check_result "写入配置文件" || return 1
    chmod 600 "$CONFIG_FILE"

    local out
    out=$("$SING_BOX_BIN" check -c "$CONFIG_FILE" 2>&1)
    if [ $? -ne 0 ]; then
        log 错误 "配置校验失败:\n$out"
        rm -rf "$CONFIG_DIR"
        return 1
    fi
    log 信息 "配置校验通过。"

    # 5. systemd / OpenRC 服务
    if command -v systemctl &>/dev/null; then
        cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=Sing-box Reality Service (WARP egress)
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target docker.service

[Service]
User=root
Group=root
WorkingDirectory=$CONFIG_DIR
ExecStart=$SING_BOX_BIN run -c $CONFIG_FILE
Restart=on-failure
RestartSec=10s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable "$SERVICE_NAME"
        systemctl restart "$SERVICE_NAME"
        check_result "启用并启动 ${SERVICE_NAME}" || { uninstall_reality_warp keep_warp; return 1; }
    elif command -v rc-service &>/dev/null; then
        cat > "/etc/init.d/${SERVICE_NAME}" << EOF
#!/sbin/openrc-run
name="${SERVICE_NAME}"
description="Sing-box Reality Service (WARP egress)"
supervisor=supervise-daemon
command="$SING_BOX_BIN"
command_args="run -c $CONFIG_FILE"
command_user="root"
output_log="$LOG_DIR/${SERVICE_NAME}.log"
error_log="$LOG_DIR/${SERVICE_NAME}.err"
pidfile="/run/\${RC_SVCNAME}.pid"
depend() { need net; after firewall docker; }
EOF
        chmod +x "/etc/init.d/${SERVICE_NAME}"
        rc-update add "$SERVICE_NAME" default
        rc-service "$SERVICE_NAME" restart
        check_result "启用并启动 ${SERVICE_NAME}" || { uninstall_reality_warp keep_warp; return 1; }
    else
        log 警告 "未找到 systemd 或 OpenRC，请手动运行: $SING_BOX_BIN run -c $CONFIG_FILE"
    fi

    sleep 3
    check_service_status || { uninstall_reality_warp keep_warp; return 1; }

    open_firewall_port "$port" "tcp"

    # 6. 输出分享链接
    local ip
    ip=$(get_public_ip)
    echo
    log 信息 "${GREEN}安装成功！新的 Reality (WARP 出口) 服务已启动，与原 Reality 服务互不影响。${PLAIN}"
    log 信息 "端口 : $port"
    log 信息 "UUID : $uuid"
    log 信息 "公钥 : $public_key"
    log 信息 "ShortID : $short_id"
    log 信息 "SNI : $dest_server"
    log 信息 "出站 : 经本机 SOCKS5 127.0.0.1:${warp_port} (MicroWARP) -> Cloudflare WARP"
    if [[ -n "$ip" ]]; then
        local link
        link=$(printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#Reality_WARP_%s' \
            "$uuid" "$ip" "$port" "$dest_server" "$public_key" "$short_id" "$port")
        log 信息 "${GREEN}分享链接:${PLAIN}"
        echo "$link"
    else
        log 警告 "未能自动获取公网 IP，请手动拼接分享链接。"
    fi
    return 0
}

# --- 删除新服务 ---
# 参数 keep_warp: 传入时跳过 “是否顺带删除 MicroWARP” 的询问（内部失败回滚时使用，不动 MicroWARP）
uninstall_reality_warp() {
    local mode="$1"
    log 信息 "开始卸载 Reality (WARP 出口) 服务..."

    local existing_port=""
    [ -f "$CONFIG_FILE" ] && existing_port=$(grep -oE '"listen_port"[[:space:]]*:[[:space:]]*[0-9]+' "$CONFIG_FILE" | grep -oE '[0-9]+' | head -1)

    if command -v systemctl &>/dev/null; then
        systemctl stop "$SERVICE_NAME" 2>/dev/null
        systemctl disable "$SERVICE_NAME" 2>/dev/null
        [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ] && rm -f "/etc/systemd/system/${SERVICE_NAME}.service" && systemctl daemon-reload
    elif command -v rc-service &>/dev/null; then
        rc-service "$SERVICE_NAME" stop 2>/dev/null
        rc-update del "$SERVICE_NAME" default 2>/dev/null
        rm -f "/etc/init.d/${SERVICE_NAME}"
    fi

    rm -rf "$CONFIG_DIR" "$LOG_DIR"
    rm -f "$SERVICE_LOG"
    [[ -n "$existing_port" ]] && close_firewall_port "$existing_port" "tcp"

    log 信息 "本服务(端口 ${existing_port:-未知}) 已卸载。原有 reality.sh 服务未受任何影响。"

    if [[ "$mode" != "keep_warp" ]]; then
        if [ -f "$WARP_COMPOSE_FILE" ] && command -v docker &>/dev/null; then
            echo -e "${YELLOW}是否同时停止/删除 MicroWARP 容器? (若还有其他服务在用，请选 N) (y/N):${PLAIN}"
            read -r rm_warp
            if [[ "$rm_warp" =~ ^[Yy]$ ]]; then
                echo -e "${YELLOW}是否同时删除 WARP 账号数据卷 warp-data (删除后下次重新注册账号)? (y/N):${PLAIN}"
                read -r rmvol
                if [[ "$rmvol" =~ ^[Yy]$ ]]; then
                    (cd "$WARP_DIR" && $COMPOSE_CMD down -v)
                else
                    (cd "$WARP_DIR" && $COMPOSE_CMD down)
                fi
                rm -rf "$WARP_DIR"
                log 信息 "MicroWARP 容器已移除。"
            fi
        fi
    fi

    log 信息 "${GREEN}卸载完成。${PLAIN}"
    return 0
}

check_service_status() {
    log 信息 "正在检查 ${SERVICE_NAME} 服务状态..."
    if command -v systemctl &>/dev/null; then
        if systemctl is-active --quiet "$SERVICE_NAME"; then
            log 信息 "${SERVICE_NAME} 正在运行。"; return 0
        else
            log 错误 "${SERVICE_NAME} 未运行。最近日志:"
            journalctl -u "$SERVICE_NAME" --no-pager -n 20
            return 1
        fi
    elif command -v rc-service &>/dev/null; then
        if rc-service "$SERVICE_NAME" status | grep -q -E 'status: started|status: starting'; then
            log 信息 "${SERVICE_NAME} 正在运行。"; return 0
        else
            log 错误 "${SERVICE_NAME} 未运行。"
            [ -f "$SERVICE_LOG" ] && tail -n 20 "$SERVICE_LOG"
            return 1
        fi
    else
        pgrep -f "$SING_BOX_BIN run -c $CONFIG_FILE" >/dev/null && return 0 || return 1
    fi
}

# --- 主菜单 ---
show_menu() {
    echo -e "
  ${GREEN}Reality (WARP 出口) 独立服务 管理脚本${PLAIN}
  (与 reality.sh 装的原 Reality 服务并存，互不影响)
  ----------------------------------------
  ${GREEN}1.${PLAIN} 新建 / 安装 (Reality + MicroWARP 出口)
  ${GREEN}2.${PLAIN} 删除 / 卸载 本服务
  ----------------------------------------
  ${GREEN}3.${PLAIN} 启动服务
  ${GREEN}4.${PLAIN} 停止服务
  ${GREEN}5.${PLAIN} 重启服务
  ${GREEN}6.${PLAIN} 查看服务状态
  ${GREEN}7.${PLAIN} 查看配置文件
  ${GREEN}8.${PLAIN} 查看 MicroWARP 容器状态/日志
  ----------------------------------------
  ${GREEN}0.${PLAIN} 退出脚本
  ----------------------------------------"
    echo -e "${YELLOW}请输入选项 [0-8]:${PLAIN}"
    read -r num
    case "$num" in
        1) install_reality_warp ;;
        2)
            echo -e "${YELLOW}确认删除本服务(新建的 WARP 出口 Reality)? 不会影响原有 Reality 服务 (y/N):${PLAIN}"
            read -r c
            [[ "$c" =~ ^[Yy]$ ]] && uninstall_reality_warp || log 信息 "已取消。"
            ;;
        3)
            if command -v systemctl &>/dev/null; then systemctl start "$SERVICE_NAME"; check_result "启动服务";
            elif command -v rc-service &>/dev/null; then rc-service "$SERVICE_NAME" start; check_result "启动服务";
            else log 错误 "未知服务管理器"; fi
            check_service_status ;;
        4)
            if command -v systemctl &>/dev/null; then systemctl stop "$SERVICE_NAME"; check_result "停止服务";
            elif command -v rc-service &>/dev/null; then rc-service "$SERVICE_NAME" stop; check_result "停止服务";
            else log 错误 "未知服务管理器"; fi ;;
        5)
            if command -v systemctl &>/dev/null; then systemctl restart "$SERVICE_NAME"; check_result "重启服务";
            elif command -v rc-service &>/dev/null; then rc-service "$SERVICE_NAME" restart; check_result "重启服务";
            else log 错误 "未知服务管理器"; fi
            sleep 2; check_service_status ;;
        6) check_service_status ;;
        7)
            if [ -f "$CONFIG_FILE" ]; then cat "$CONFIG_FILE"; else log 错误 "配置文件未找到！"; fi ;;
        8)
            if command -v docker &>/dev/null; then
                docker ps --filter "name=$WARP_CONTAINER" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
                echo; docker logs --tail 30 "$WARP_CONTAINER" 2>&1
            else
                log 错误 "未安装 Docker。"
            fi ;;
        0) exit 0 ;;
        *) log 错误 "无效选项: $num" ;;
    esac
}

# --- 入口 ---
cleanup_and_init() {
    TMP_DIR=$(mktemp -d -t singbox-warp-XXXXXX) || { echo "无法创建临时目录"; exit 1; }
    trap 'rm -rf "$TMP_DIR"' EXIT SIGINT SIGTERM
}
cleanup_and_init

mkdir -p "$LOG_DIR" 2>/dev/null
touch "$LOG_FILE" 2>/dev/null || log() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $2"; }

check_dependencies || exit 1

while true; do
    show_menu
    echo
    echo -e "${GREEN}按任意键返回主菜单...${PLAIN}"
    read -n 1 -s -r
    echo
done
