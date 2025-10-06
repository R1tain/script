#!/bin/bash

# reality.sh - Sing-box Reality 安装/管理脚本 (nohup 版，完整)
# 版本: 1.5-nohup (2025-10-06)

# --- 初始检查 ---
if [ -z "$BASH_VERSION" ]; then
    echo "错误：请用 bash 运行此脚本"
    exit 1
fi
if [[ $EUID -ne 0 ]]; then
   echo -e "\033[31m错误：必须 root 权限运行！\033[0m"
   exit 1
fi

# --- 基础设置 ---
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; PLAIN="\033[0m"
SING_BOX_BIN="/usr/local/bin/sing-box"
CONFIG_DIR="/usr/local/etc/sing-box"
CONFIG_FILE="$CONFIG_DIR/config.json"
LOG_DIR="/var/log/sing-box"
LOG_FILE="$LOG_DIR/install.log"
PID_FILE="/var/run/sing-box.pid"

# --- 日志函数 ---
log() {
    local level="$1"; local msg="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $msg" | tee -a "$LOG_FILE"
}

# --- 进程管理 ---
start_singbox() {
    if [ -f "$PID_FILE" ] && kill -0 $(cat "$PID_FILE") 2>/dev/null; then
        log 警告 "sing-box 已经在运行 (PID: $(cat $PID_FILE))"
        return 0
    fi
    log 信息 "后台启动 sing-box..."
    nohup "$SING_BOX_BIN" run -c "$CONFIG_FILE" >> "$LOG_DIR/sing-box.out" 2>&1 &
    echo $! > "$PID_FILE"
    sleep 2
    check_status
}

stop_singbox() {
    if [ -f "$PID_FILE" ] && kill -0 $(cat "$PID_FILE") 2>/dev/null; then
        kill "$(cat "$PID_FILE")"
        rm -f "$PID_FILE"
        log 信息 "sing-box 已停止"
    else
        log 警告 "未找到 PID 文件，尝试强制结束进程..."
        pkill -f "$SING_BOX_BIN run -c $CONFIG_FILE" && log 信息 "已结束进程"
    fi
}

restart_singbox() { stop_singbox; sleep 1; start_singbox; }

check_status() {
    if pgrep -f "$SING_BOX_BIN run -c $CONFIG_FILE" >/dev/null; then
        log 信息 "sing-box 正在运行"
        return 0
    else
        log 错误 "sing-box 未运行"
        return 1
    fi
}

# --- 卸载 ---
uninstall() {
    log 信息 "卸载 sing-box..."
    stop_singbox
    rm -f "$SING_BOX_BIN"
    rm -rf "$CONFIG_DIR" "$LOG_DIR" "$PID_FILE"
    log 信息 "卸载完成"
}

# --- 安装 ---
install_singbox() {
    log 信息 "开始安装 sing-box..."
    mkdir -p "$CONFIG_DIR" "$LOG_DIR"

    # 选择端口
    read -p "请输入端口 [默认 443]: " port
    [ -z "$port" ] && port=443

    # 架构
    case $(uname -m) in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) log 错误 "不支持的架构: $(uname -m)"; return 1 ;;
    esac

    # 下载 sing-box
    latest=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep tag_name | sed -E 's/.*"([^"]+)".*/\1/')
    ver=${latest#v}
    url="https://github.com/SagerNet/sing-box/releases/download/${latest}/sing-box-${ver}-linux-${arch}.tar.gz"
    log 信息 "下载: $url"
    wget -qO /tmp/sing-box.tar.gz "$url" || { log 错误 "下载失败"; return 1; }
    tar -xzf /tmp/sing-box.tar.gz -C /tmp
    install -m 755 /tmp/sing-box-${ver}-linux-${arch}/sing-box "$SING_BOX_BIN"

    # 生成密钥
    keys=$("$SING_BOX_BIN" generate reality-keypair)
    private_key=$(echo "$keys" | awk '/PrivateKey/{print $2}')
    public_key=$(echo "$keys" | awk '/PublicKey/{print $2}')
    uuid=$("$SING_BOX_BIN" generate uuid)
    short_id=$(openssl rand -hex 8)
    sni="icloud-content.com"

    # 写配置
    cat > "$CONFIG_FILE" <<EOF
{
  "inbounds": [{
    "type": "vless",
    "listen": "::",
    "listen_port": $port,
    "users": [{"uuid": "$uuid","flow": "xtls-rprx-vision"}],
    "tls": {
      "enabled": true,
      "server_name": "$sni",
      "reality": {
        "enabled": true,
        "handshake": {"server": "$sni","server_port": 443},
        "private_key": "$private_key",
        "short_id": ["$short_id"]
      }
    }
  }],
  "outbounds": [{"type": "direct"}]
}
EOF

    log 信息 "配置已生成: $CONFIG_FILE"

    # 启动服务
    start_singbox

    # 输出分享链接
    ip=$(curl -s https://api.ipify.org || echo "YOUR_IP")
    vless="vless://${uuid}@${ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#Reality_${port}"
    echo -e "\n${GREEN}安装成功! VLESS 链接:${PLAIN}\n$vless\n"
}

# --- 菜单 ---
show_menu() {
    echo -e "
  ${GREEN}Sing-box Reality 管理脚本 (nohup 版)${PLAIN}
  ----------------------------------------
  1. 安装 Sing-box (Reality)
  2. 卸载 Sing-box
  ----------------------------------------
  3. 启动 Sing-box
  4. 停止 Sing-box
  5. 重启 Sing-box
  6. 查看运行状态
  ----------------------------------------
  0. 退出脚本
  ----------------------------------------"
    read -p "请输入选项 [0-6]: " num
    case "$num" in
        1) install_singbox ;;
        2) uninstall ;;
        3) start_singbox ;;
        4) stop_singbox ;;
        5) restart_singbox ;;
        6) check_status ;;
        0) exit 0 ;;
        *) log 错误 "无效选项" ;;
    esac
}

# --- 脚本入口 ---
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
log 信息 "--- 脚本启动 ---"

while true; do
    show_menu
    echo
    read -n 1 -s -r -p "按任意键返回主菜单..."
    echo
done
