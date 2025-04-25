#!/bin/bash
# Stricter error handling
set -euo pipefail

# --------------------------------------
# 颜色与日志函数 (颜色已移除)
# --------------------------------------
log_info() {
    echo "[INFO] $1"
}
log_warn() {
    echo "[WARN] $1"
}
log_error() {
    echo "[ERROR] $1"
}

# --------------------------------------
# 全局路径 (Centralized paths)
# --------------------------------------
SS_CONFIG_DIR="/etc/shadowsocks"
SS_CONFIG_PATH="${SS_CONFIG_DIR}/config.json"
SS_INFO_PATH="${SS_CONFIG_DIR}/info.txt"
SS_SERVICE_PATH="/etc/systemd/system/shadowsocks.service"
SS_BIN_DIR="/usr/local/bin"
SS_SERVER_BIN="${SS_BIN_DIR}/ssserver"

# --------------------------------------
# 检查是否为 root
# --------------------------------------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本必须使用 root 用户运行！"
        exit 1
    fi
}

# --------------------------------------
# 获取公网 IP 地址（优先 IPv6）
# --------------------------------------
get_public_ip() {
    local ip=""
    if ! command -v curl &> /dev/null; then log_error "需要 'curl' 命令来获取 IP 地址。"; return 1; fi
    ip=$(curl -6 -s -m 10 https://api64.ipify.org || curl -4 -s -m 10 https://api64.ipify.org || curl -6 -s -m 10 https://ifconfig.co || curl -4 -s -m 10 https://ifconfig.co || curl -s -m 10 https://api.ip.sb/ip || curl -s -m 10 https://icanhazip.com || true)
    if [[ -z "$ip" ]]; then
        log_warn "无法获取公网 IP 地址，尝试获取内网 IP 地址..."
        ip=$(ip route get 1.1.1.1 | grep -oP 'src \K\S+' || hostname -I | awk '{print $1}' || true)
        if [[ -z "$ip" ]]; then log_error "无法获取任何 IP 地址。"; return 1; else log_warn "使用的是内网或本地 IP 地址: $ip"; fi
    fi
    ip=$(echo "$ip" | tr -d '[:space:]')
    if [[ "$ip" == *:* && "$ip" != \[* ]]; then ip="[$ip]"; fi
    echo "$ip"; return 0
}

# --------------------------------------
# 检查并安装必要工具
# --------------------------------------
check_tool() {
    local tools=("xz" "wget" "curl" "jq" "openssl" "ss") PM="" pkgs_to_install=() missing_tools=()
    if command -v apt &>/dev/null; then PM="apt"; elif command -v yum &>/dev/null; then PM="yum"; elif command -v dnf &>/dev/null; then PM="dnf"; else log_error "无法确定包管理器。请手动安装：${tools[*]}"; exit 1; fi
    log_info "检测到包管理器: $PM"
    log_info "检查所需工具: ${tools[*]}"
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
             missing_tools+=("$tool"); local pkg_name="$tool"
             case "$tool" in xz) [[ "$PM" == "apt" ]] && pkg_name="xz-utils" ;; ss) if [[ "$PM" == "apt" ]]; then pkg_name="iproute2"; elif [[ "$PM" == "yum" || "$PM" == "dnf" ]]; then pkg_name="iproute"; fi ;; esac
             if [[ ! " ${pkgs_to_install[@]} " =~ " ${pkg_name} " ]]; then pkgs_to_install+=("$pkg_name"); fi
        fi
    done
    if [ ${#pkgs_to_install[@]} -gt 0 ]; then
        log_warn "检测到以下工具命令缺失: ${missing_tools[*]}"; log_info "将尝试安装对应的包: ${pkgs_to_install[*]}"
        case "$PM" in
            apt) log_info "正在运行 apt update..."; apt update || log_warn "apt update 失败，继续尝试安装..."; if ! apt install -y "${pkgs_to_install[@]}"; then log_error "包安装失败: apt install -y ${pkgs_to_install[*]}"; exit 1; fi ;;
            yum | dnf) if ! $PM install -y "${pkgs_to_install[@]}"; then log_error "包安装失败: $PM install -y ${pkgs_to_install[*]}"; exit 1; fi ;;
        esac
        log_info "验证工具安装情况..."; local reinstall_check=0
        for tool in "${missing_tools[@]}"; do if ! command -v "$tool" &>/dev/null; then log_error "工具命令 '$tool' 在安装后仍然无法找到。"; reinstall_check=1; fi; done
        if [ $reinstall_check -eq 1 ]; then exit 1; fi; log_info "所有必需工具均已成功安装或验证。"
    else log_info "所有必需工具均已安装。"; fi
}

# ============================
#  Shadowsocks 功能函数
# ============================
install_shadowsocks() {
    log_info "开始安装 Shadowsocks 服务..."
    check_root; check_tool
    if command -v "$SS_SERVER_BIN" &>/dev/null && [ -f "$SS_CONFIG_PATH" ]; then
        log_warn "Shadowsocks 似乎已安装 ($SS_SERVER_BIN 存在且 $SS_CONFIG_PATH 存在)。"
        read -p "是否要覆盖安装? (y/n): " overwrite_confirm
        if [[ ! "$overwrite_confirm" =~ ^[Yy]$ ]]; then log_info "取消安装。"; return; else log_warn "将进行覆盖安装..."; if systemctl is-active --quiet shadowsocks; then log_info "正在停止现有 Shadowsocks 服务..."; systemctl stop shadowsocks || true; fi; fi
    fi

    local ARCH ARCH_SUFFIX api_url api_response LATEST_TAG download_url temp_archive
    ARCH=$(uname -m)
    case "$ARCH" in x86_64) ARCH_SUFFIX="x86_64-unknown-linux-gnu" ;; i686) ARCH_SUFFIX="i686-unknown-linux-musl" ;; aarch64) ARCH_SUFFIX="aarch64-unknown-linux-gnu" ;; armv7l) ARCH_SUFFIX="armv7-unknown-linux-gnueabihf" ;; armv6l) ARCH_SUFFIX="arm-unknown-linux-gnueabihf" ;; *) log_error "不支持的系统架构: $ARCH"; exit 1 ;; esac
    log_info "检测到系统架构: $ARCH ($ARCH_SUFFIX)"

    log_info "获取 Shadowsocks-rust 最新版本信息..."
    api_url="https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest"
    api_response=$(curl -s -m 15 -H "Accept: application/vnd.github.v3+json" "$api_url")
    if ! echo "$api_response" | jq -e '.tag_name' > /dev/null 2>&1; then log_error "从 GitHub API 获取 Release 信息失败。"; exit 1; fi
    LATEST_TAG=$(echo "$api_response" | jq -r '.tag_name'); if [ -z "$LATEST_TAG" ] || [ "$LATEST_TAG" == "null" ]; then log_error "无法从 GitHub API 响应中解析最新版本号。"; exit 1; fi
    log_info "检测到最新版本: $LATEST_TAG"

    download_url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/$LATEST_TAG/shadowsocks-$LATEST_TAG.$ARCH_SUFFIX.tar.xz"
    temp_archive="/tmp/ss-rust-${LATEST_TAG}.tar.xz"
    log_info "准备下载 Shadowsocks: $download_url"
    log_info "正在下载 Shadowsocks 到 $temp_archive ..."
    # Clean up any potential leftover archive first
    rm -f "$temp_archive"
    if ! curl -L -f -o "$temp_archive" "$download_url" --connect-timeout 15 --retry 3; then log_error "下载 Shadowsocks 失败。错误代码: $?"; rm -f "$temp_archive" &> /dev/null || true; exit 1; fi
    log_info "下载完成。"

    log_info "正在解压 Shadowsocks 到 $SS_BIN_DIR ..."
    mkdir -p "$SS_BIN_DIR"
    # Extract files, overwrite existing ones (-C target_dir)
    # Add explicit error checking for tar command itself
    # REMOVED --strip-components=1 because archive has files at root
    if ! tar -Jxf "$temp_archive" -C "$SS_BIN_DIR"; then
        log_error "解压 Shadowsocks 失败 (tar 命令返回错误)。"
        # Keep the archive for manual inspection on explicit tar failure
        log_error "压缩包保留在 $temp_archive 供手动检查。"
        log_error "请尝试手动运行: sudo tar -xJvf $temp_archive -C /usr/local/bin"
        exit 1
    fi
    # ** DO NOT remove archive here yet **

    # --- Verification Step ---
    # Check if the main binary exists after extraction
    if [ ! -f "${SS_SERVER_BIN}" ]; then
        log_error "解压后验证失败：${SS_SERVER_BIN} 文件未找到！"
        log_error "可能原因：下载的压缩包不完整、/tmp 或 /usr/local/bin 空间不足或权限问题、tar 命令未能正确解压。"
        # Keep the archive for manual inspection
        log_error "压缩包保留在 $temp_archive 供手动检查。"
        log_error "请尝试手动运行: sudo tar -xJvf $temp_archive -C /usr/local/bin" # Removed --strip-components=1 from error msg too
        exit 1
    fi
    # --- End of verification if block ---

    log_info "解压完成并验证文件存在。"

    # Clean up archive ONLY after successful extraction and verification
    rm -f "$temp_archive"
    log_info "临时压缩包 $temp_archive 已删除。"

    # Ensure main binaries have execute permissions (Simplified error handling)
    log_info "设置可执行权限..."
    chmod +x "${SS_BIN_DIR}/ssserver" "${SS_BIN_DIR}/sslocal" "${SS_BIN_DIR}/ssurl" "${SS_BIN_DIR}/ssmanager" || log_warn "chmod 命令失败 (可能需要手动设置)"
    # --- End of chmod section ---

    log_info "Shadowsocks 二进制文件准备就绪。"
    log_info "显示已安装版本："
    "${SS_SERVER_BIN}" --version

    # --- Continue with config generation, service setup etc. ---
    mkdir -p "$SS_CONFIG_DIR" || { log_error "无法创建配置目录 $SS_CONFIG_DIR"; exit 1; }
    local ss_port=""
    while true; do
        local random_port=$(shuf -i 20000-65000 -n 1)
        read -p "请输入 Shadowsocks 端口 (1024-65535) [建议: $random_port]: " ss_port_input; ss_port_input=${ss_port_input:-$random_port}
        if [[ "$ss_port_input" =~ ^[0-9]+$ && "$ss_port_input" -ge 1024 && "$ss_port_input" -le 65535 ]]; then if ss -tuln | grep -q ":$ss_port_input\s"; then log_warn "端口 $ss_port_input 似乎已被监听。"; else ss_port=$ss_port_input; log_info "将使用端口: $ss_port"; break; fi; else log_warn "端口 '$ss_port_input' 无效。"; fi
    done
    log_info "选择加密方法 [推荐使用 2022 系列，默认: 2]:"; echo "  1) 2022-blake3-aes-128-gcm"; echo "  2) 2022-blake3-aes-256-gcm (默认推荐)"; echo "  3) 2022-blake3-chacha20-poly1305"; echo "  4) aes-256-gcm"; echo "  5) aes-128-gcm"; echo "  6) chacha20-ietf-poly1305"; echo "  7) aes-256-cfb"; echo "  8) aes-128-cfb"; echo "  9) chacha20-ietf"; echo " 10) none (极不推荐)";
    local enc_choice method="" ss_password="" key_len=32; read -p "输入数字选择加密方式 [1-10]: " enc_choice; enc_choice=${enc_choice:-2}
    case "$enc_choice" in 1) method="2022-blake3-aes-128-gcm";key_len=16;; 2) method="2022-blake3-aes-256-gcm";key_len=32;; 3) method="2022-blake3-chacha20-poly1305";key_len=32;; 4) method="aes-256-gcm";; 5) method="aes-128-gcm";; 6) method="chacha20-ietf-poly1305";; 7) method="aes-256-cfb";; 8) method="aes-128-cfb";; 9) method="chacha20-ietf";; 10) method="none";log_warn "警告: 选择 'none' 加密不安全！";; *) log_warn "无效选择，使用默认: 2022-blake3-aes-256-gcm";method="2022-blake3-aes-256-gcm";key_len=32;; esac
    if [[ "$method" =~ ^2022- ]]; then ss_password=$(openssl rand -base64 $key_len); log_info "使用方法: $method, 已自动生成密码。"; else read -p "请输入密码 (留空随机): " custom_pw; if [[ -z "$custom_pw" ]]; then ss_password=$(openssl rand -base64 16); log_info "未输入密码，已随机生成。"; else ss_password="$custom_pw"; fi; log_info "使用方法: $method"; fi
    local default_node_name="SS-$(echo "$method" | cut -d'-' -f1,2)-$(hostname -s)"; read -p "输入节点名称 (默认 '$default_node_name'): " node_name; node_name=${node_name:-$default_node_name}; log_info "节点名称: $node_name"

    log_info "生成 Shadowsocks JSON 配置文件..."
    if command -v jq &>/dev/null; then
        jq -n --arg srv "::" --argjson port "$ss_port" --arg pass "$ss_password" --arg meth "$method" --argjson fo false --arg mode "tcp_and_udp" '{server: $srv, server_port: $port, password: $pass, method: $meth, fast_open: $fo, mode: $mode}'>"$SS_CONFIG_PATH"; log_info "使用 jq 生成配置文件。"
    else
        log_warn "jq 未找到，使用 cat EOF 生成配置文件。"
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
    fi
    log_info "配置文件写入: $SS_CONFIG_PATH"

    log_info "生成 Systemd 服务文件..."
    cat << EOF > "$SS_SERVICE_PATH"
[Unit]
Description=Shadowsocks-Rust Server Service
Documentation=https://github.com/shadowsocks/shadowsocks-rust
After=network.target network-online.target
Wants=network-online.target
[Service]
Type=simple
User=root
Group=root
LimitNOFILE=51200
ExecStart=${SS_SERVER_BIN} -c ${SS_CONFIG_PATH}
Restart=on-failure
RestartSec=5s
[Install]
WantedBy=multi-user.target
EOF
    log_info "服务文件写入: $SS_SERVICE_PATH"

    log_info "重载 Systemd 并启动/启用服务..."; systemctl daemon-reload; if ! systemctl start shadowsocks; then log_error "启动服务失败。"; log_info "查日志: journalctl -u shadowsocks -n 50"; exit 1; fi; if ! systemctl enable shadowsocks &>/dev/null; then log_warn "无法启用服务"; fi; sleep 1; if systemctl is-active --quiet shadowsocks; then log_info "服务已成功启动并启用(若enable成功)。"; else log_error "服务启动后未能保持活动。查日志: journalctl -u shadowsocks -n 50"; exit 1; fi
    local public_ip base64_pass ss_url encoded_node_name; public_ip=$(get_public_ip); if [ $? -ne 0 ] || [ -z "$public_ip" ]; then log_error "无法获取公网IP。"; public_ip="<服务器IP>"; fi
    if [ -n "$method" ]&&[ "$method"!="null" ]&&[ -n "$ss_password" ]&&[ "$ss_password"!="null" ]; then base64_pass=$(echo -n "$method:$ss_password"|base64|tr -d '\n'); if command -v jq &>/dev/null; then encoded_node_name=$(jq -sRr @uri <<<"$node_name"); else encoded_node_name=$(echo -n "$node_name"|hexdump -v -e '/1 "%_p"'|sed 's/%/%%/g;s/_/%/g'); log_warn "jq未找到，URL编码可能不准"; fi; ss_url="ss://${base64_pass}@${public_ip}:${ss_port}#${encoded_node_name}"; log_info "--- Shadowsocks 配置信息 ---"; echo "服务器: $public_ip"; echo "端口: $ss_port"; echo "密码: $ss_password"; echo "方法: $method"; echo "名称: $node_name"; log_info "---------------------------"; echo "SS 链接: $ss_url"; if command -v qrencode &>/dev/null; then echo "二维码:"; qrencode -t ANSIUTF8 "$ss_url"; fi; log_info "---------------------------";
        cat << EOF > "$SS_INFO_PATH"
服务器地址: $public_ip
端口: $ss_port
密码: $ss_password
加密方法: $method
节点名称: $node_name
链接: $ss_url
EOF
        log_info "配置信息保存到: $SS_INFO_PATH"; else log_error "无法生成链接，缺少信息。"; fi; log_info "Shadowsocks 安装完成。"
}

check_shadowsocks_status() { log_info "检查 Shadowsocks 服务状态..."; if ! command -v "$SS_SERVER_BIN" &>/dev/null; then log_error "$SS_SERVER_BIN 命令未找到"; return 1; fi; local ver; ver=$("$SS_SERVER_BIN" --version 2>/dev/null || echo "无法获取版本"); log_info "版本: $ver"; if [ ! -f "$SS_SERVICE_PATH" ]; then log_warn "未找到 $SS_SERVICE_PATH"; return 1; fi; log_info "检查 systemd 服务..."; if systemctl is-active --quiet shadowsocks; then log_info "状态: 运行中"; systemctl status shadowsocks --no-pager -n 5 || true; elif systemctl is-failed --quiet shadowsocks; then log_error "状态: 失败"; log_info "查日志: journalctl -u shadowsocks -n 50"; elif systemctl is-inactive --quiet shadowsocks; then log_info "状态: 未运行"; else local state=$(systemctl show -p SubState --value shadowsocks 2>/dev/null||echo "未知"); log_info "状态: $state"; fi; }
check_shadowsocks_config() { log_info "检查 Shadowsocks 配置文件..."; local found=0; if [ -f "$SS_INFO_PATH" ]; then log_info "--- 保存的信息 ($SS_INFO_PATH) ---"; cat "$SS_INFO_PATH"; echo "---"; found=1; else log_warn "未找到 $SS_INFO_PATH"; fi; if [ -f "$SS_CONFIG_PATH" ]; then log_info "--- JSON 配置 ($SS_CONFIG_PATH) ---"; if command -v jq &>/dev/null; then if jq '.' "$SS_CONFIG_PATH"; then log_info "(JSON有效)"; else log_error "(JSON无效!)"; cat "$SS_CONFIG_PATH"; fi; else log_info "(jq未装)"; cat "$SS_CONFIG_PATH"; fi; echo "---"; found=1; else log_error "未找到 $SS_CONFIG_PATH"; fi; if [ $found -eq 0 ]; then log_error "未找到任何配置文件。"; fi; }
modify_shadowsocks_config() { log_warn "修改配置功能开发中。"; log_info "请手动编辑 $SS_CONFIG_PATH"; log_info "修改后使用 '重启' 应用。"; log_info "建议也更新 $SS_INFO_PATH"; }
start_shadowsocks() { log_info "启动服务..."; if [ ! -f "$SS_SERVICE_PATH" ]; then log_error "未找到 $SS_SERVICE_PATH"; return 1; fi; if systemctl is-active --quiet shadowsocks; then log_warn "服务已运行。"; return 0; fi; if ! systemctl start shadowsocks; then log_error "启动失败。"; log_info "查日志: journalctl -u shadowsocks -n 50"; return 1; fi; sleep 1; if systemctl is-active --quiet shadowsocks; then log_info "服务已启动。"; return 0; else log_error "服务未能保持活动。"; log_info "查日志: journalctl -u shadowsocks -n 50"; return 1; fi; }
stop_shadowsocks() { log_info "停止服务..."; if [ ! -f "$SS_SERVICE_PATH" ]; then log_warn "未找到 $SS_SERVICE_PATH"; return 1; fi; if ! systemctl is-active --quiet shadowsocks; then log_warn "服务未运行。"; return 0; fi; if ! systemctl stop shadowsocks; then log_error "停止失败。"; return 1; fi; sleep 1; if ! systemctl is-active --quiet shadowsocks; then log_info "服务已停止。"; return 0; else log_error "停止后服务仍活动？"; return 1; fi; }
restart_shadowsocks() { log_info "重启服务..."; if [ ! -f "$SS_SERVICE_PATH" ]; then log_error "未找到 $SS_SERVICE_PATH"; return 1; fi; if ! systemctl restart shadowsocks; then log_error "重启失败。"; log_info "查日志: journalctl -u shadowsocks -n 50"; return 1; fi; sleep 1; if systemctl is-active --quiet shadowsocks; then log_info "服务已重启。"; return 0; else log_error "服务未能进入活动。"; log_info "查日志: journalctl -u shadowsocks -n 50"; return 1; fi; }
uninstall_shadowsocks() { log_warn "警告：此操作将卸载服务并删除文件！"; read -p "确定卸载? (y/n): " confirm; if [[ ! "$confirm" =~ ^[Yy]$ ]]; then log_info "取消。"; return; fi; log_info "停止/禁用服务..."; if [ -f "$SS_SERVICE_PATH" ]; then systemctl stop shadowsocks || true; systemctl disable shadowsocks || true; else log_warn "未找到 $SS_SERVICE_PATH"; fi; log_info "删除服务文件..."; if [ -f "$SS_SERVICE_PATH" ]; then rm -f "$SS_SERVICE_PATH"; log_info "重载 systemd..."; systemctl daemon-reload || log_warn "daemon-reload失败"; fi; log_info "删除配置目录..."; rm -rf "$SS_CONFIG_DIR"; log_info "删除执行文件..."; rm -f "${SS_BIN_DIR}/ssserver" "${SS_BIN_DIR}/sslocal" "${SS_BIN_DIR}/ssurl" "${SS_BIN_DIR}/ssmanager" "${SS_BIN_DIR}/ssservice"; log_info "Shadowsocks 已卸载。"; log_warn "依赖项可能需手动卸载。"; } # Added ssservice to removal list
ss_links() { log_info "获取分享链接..."; local ss_url=""; if [ -f "$SS_INFO_PATH" ]; then ss_url=$(grep "^链接:" "$SS_INFO_PATH" | head -n 1 | sed -e 's/^链接: //'); if [ -n "$ss_url" ]; then log_info "从 $SS_INFO_PATH 读取:"; echo "$ss_url"; if command -v qrencode &>/dev/null; then echo "二维码:"; qrencode -t ANSIUTF8 "$ss_url"; fi; return 0; else log_warn " $SS_INFO_PATH 无有效链接。"; fi; else log_warn "未找到 $SS_INFO_PATH"; fi; if [ ! -f "$SS_CONFIG_PATH" ]; then log_error "$SS_CONFIG_PATH 不存在。"; return 1; fi; if ! command -v jq &>/dev/null; then log_error "需 'jq' 从JSON生成链接。"; return 1; fi; local ss_port ss_pass method ip b64 enc_name final; ss_port=$(jq -r '.server_port' "$SS_CONFIG_PATH"); ss_pass=$(jq -r '.password' "$SS_CONFIG_PATH"); method=$(jq -r '.method' "$SS_CONFIG_PATH"); if [ -z "$ss_port" ]||[ "$ss_port"=="null" ]||[ -z "$ss_pass" ]||[ "$ss_pass"=="null" ]||[ -z "$method" ]||[ "$method"=="null" ]; then log_error "$SS_CONFIG_PATH 信息不全。"; return 1; fi; ip=$(get_public_ip); if [ $? -ne 0 ]||[ -z "$ip" ]; then log_error "无法获取公网IP。"; ip="<服务器IP>"; fi; local node="SS-Generated-$(hostname -s)"; log_warn "使用默认节点名 '$node'"; b64=$(echo -n "$method:$ss_pass"|base64|tr -d '\n'); enc_name=$(jq -sRr @uri <<<"$node"); final="ss://${b64}@${ip}:${ss_port}#${enc_name}"; log_info "据 $SS_CONFIG_PATH 生成:"; echo "$final"; if command -v qrencode &>/dev/null; then echo "二维码:"; qrencode -t ANSIUTF8 "$final"; fi; return 0; }
uninstall_script_and_shadowsocks() { check_root; log_warn "此操作将卸载并删除此脚本！"; read -p "确定继续? (y/n): " confirm; if [[ ! "$confirm" =~ ^[Yy]$ ]]; then log_info "取消。"; return; fi; uninstall_shadowsocks; local script="$0"; log_warn "删除脚本 (${script})..."; if rm -f "$script"; then log_info "脚本已删除。"; log_info "再见！"; exit 0; else log_error "删除脚本失败: $script"; exit 1; fi; }
ss_submenu() { while true; do clear; echo "=== Shadowsocks 服务管理 ==="; echo "  1) 查看状态"; echo "  2) 查看配置/链接"; echo "  3) 启动服务"; echo "  4) 停止服务"; echo "  5) 重启服务"; echo "  6) 修改配置(开发中)"; echo "  ---"; echo "  7) 重装/更新"; echo "  8) 卸载服务(仅服务)"; echo "  ---"; echo "  0) 返回主菜单"; echo "==========================="; read -p "选项 [0-8]: " choice; echo ""; case $choice in 1) check_shadowsocks_status;; 2) check_shadowsocks_config; ss_links;; 3) start_shadowsocks;; 4) stop_shadowsocks;; 5) restart_shadowsocks;; 6) modify_shadowsocks_config;; 7) log_info "选择重装/更新..."; install_shadowsocks;; 8) log_info "选择卸载服务..."; uninstall_shadowsocks;; 0) return;; *) echo "[ERROR] 无效选项 '$choice'";; esac; if [[ "$choice" != "0" ]]; then echo ""; read -n 1 -s -r -p "按任意键返回..."; fi; done; }
main_menu() { while true; do clear; local status="未知"; if command -v systemctl &>/dev/null && [ -f "$SS_SERVICE_PATH" ]; then if systemctl is-active --quiet shadowsocks; then status="运行中"; elif systemctl is-failed --quiet shadowsocks; then status="失败"; else status="停止"; fi; elif [ -f "$SS_CONFIG_PATH" ]; then status="已安装(状态未知)"; else status="未安装"; fi; echo "================================"; echo "   Shadowsocks-Rust 管理脚本"; echo "   当前状态: ${status}"; echo "================================"; echo "  安装 / 管理:"; echo "  1) 安装 Shadowsocks (或更新/覆盖安装)"; echo "  2) 服务管理 (启/停/状态/配置)"; echo ""; echo "  常用操作:"; echo "  3) 显示 配置/链接/二维码"; echo ""; echo "  卸载:"; echo "  9) 完全卸载及脚本 (危险)"; echo ""; echo "  退出:"; echo "  0) 退出脚本"; echo "================================"; read -p "选项 [0-3, 9]: " choice; echo ""; case $choice in 1) install_shadowsocks;; 2) ss_submenu;; 3) check_shadowsocks_config; ss_links;; 9) uninstall_script_and_shadowsocks;; 0) echo "退出。"; exit 0;; *) echo "[ERROR] 无效选项 '$choice'";; esac; if [[ "$choice" != "0" ]]; then echo ""; read -n 1 -s -r -p "按任意键返回..."; fi; done; }

# ---------------------------
#  脚本入口
# ---------------------------
check_root
main_menu
