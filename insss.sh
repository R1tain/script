#!/bin/bash
set -euo pipefail

# ============================================================
# Shadowsocks Rust 一键安装脚本
# SS2022 + IPv6，支持安装与卸载
# x86_64 使用 musl 静态链接包
# ============================================================

set +H

INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/shadowsocks-rust"
CONFIG_FILE="${CONFIG_DIR}/config.json"
SERVICE_FILE="/etc/systemd/system/ssserver.service"
TMP_DIR=""
KEEP_CONFIG=0
UNINSTALL_YES=0
OLD_PORT=""

cleanup() {
    if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "[!] 请使用 root 运行此脚本"
        exit 1
    fi
}

check_unit_conflict() {
    if [ -f "$SERVICE_FILE" ]; then
        if grep -Fq '# Managed by insss.sh' "$SERVICE_FILE" || grep -Eq '^ExecStart=.*(/usr/local/bin/ssserver)([[:space:]]|$)' "$SERVICE_FILE"; then
            echo "[+] 发现已有旧服务配置，本次安装将进行更新覆盖"
        else
            echo "[!] 检测到非本脚本管理的 ssserver.service，避免误覆盖第三方服务，安装中止"
            exit 2
        fi
    fi
}

parse_uninstall_args() {
    local menu_confirmed="$1"
    shift
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -y|--yes|-f|--force) UNINSTALL_YES=1 ;;
            --keep-config) KEEP_CONFIG=1 ;;
            *) echo "[!] 未知卸载参数: $1"; exit 1 ;;
        esac
        shift
    done
    if [ ! -t 0 ] && [ "$UNINSTALL_YES" -ne 1 ] && [ "$menu_confirmed" -ne 1 ]; then
        echo "[!] 非交互模式下卸载必须指定 -y 或 -f 参数"
        exit 1
    fi
}

check_installed_status() {
    if [ -f "$CONFIG_FILE" ] && command -v jq >/dev/null 2>&1; then
        OLD_PORT="$(jq -r '.server_port // empty' "$CONFIG_FILE" 2>/dev/null || true)"
    fi
    if [ ! -e "$SERVICE_FILE" ] && [ ! -e "${INSTALL_DIR}/ssserver" ] && [ ! -e "${INSTALL_DIR}/ssservice" ] && [ ! -e "$CONFIG_DIR" ] && ! pgrep -x ssserver >/dev/null 2>&1 && ! find "$INSTALL_DIR" -maxdepth 1 -type f -name 'ssserver.bak.*' -print -quit | grep -q . && ! find "$INSTALL_DIR" -maxdepth 1 -type f -name 'ssservice.bak.*' -print -quit | grep -q .; then
        echo "系统中未检测到 shadowsocks-rust 相关组件，无需卸载"
        exit 0
    fi
}

show_uninstall_plan() {
    echo
    echo "即将删除/清理的资源清单："
    echo "  - 服务: ${SERVICE_FILE}（仅归属本脚本时删除）"
    echo "  - 二进制: ${INSTALL_DIR}/ssserver、${INSTALL_DIR}/ssservice 及 .bak 备份"
    if [ "$KEEP_CONFIG" -eq 1 ]; then
        echo "  - 配置: 保留 ${CONFIG_DIR}"
    else
        echo "  - 配置: 删除 ${CONFIG_DIR}"
    fi
}

stop_and_kill_service() {
    systemctl stop ssserver || true
    if pgrep -x ssserver >/dev/null 2>&1; then
        pkill -x ssserver || true
        sleep 2
    fi
    if pgrep -x ssserver >/dev/null 2>&1; then
        echo "[!] 无法终止 ssserver 运行中进程，卸载中止"
        exit 2
    fi
}

cleanup_systemd_unit() {
    if [ -f "$SERVICE_FILE" ]; then
        systemctl disable ssserver || true
        if grep -Fq '# Managed by insss.sh' "$SERVICE_FILE" || grep -Eq '^ExecStart=.*(/usr/local/bin/ssserver)([[:space:]]|$)' "$SERVICE_FILE"; then
            rm -f "$SERVICE_FILE"
        else
            echo "[!] ${SERVICE_FILE} 属于第三方配置，已跳过删除"
        fi
    fi
    systemctl daemon-reload
    systemctl reset-failed ssserver 2>/dev/null || true
}

cleanup_files() {
    rm -f "${INSTALL_DIR}/ssserver" "${INSTALL_DIR}/ssservice"
    find "$INSTALL_DIR" -maxdepth 1 -type f \( -name 'ssserver.bak.*' -o -name 'ssservice.bak.*' \) -delete
    if [ "$KEEP_CONFIG" -eq 0 ]; then
        rm -rf "$CONFIG_DIR"
    else
        echo "[KEEP] 配置目录已保留: ${CONFIG_DIR}"
    fi
}

verify_and_report() {
    if ! pgrep -x ssserver >/dev/null 2>&1; then echo "[OK] 进程已完全停止"; else echo "[!] 仍有 ssserver 进程"; exit 2; fi
    if [ -z "$OLD_PORT" ] || ! ss -lnt 2>/dev/null | grep -Eq "[:.]${OLD_PORT}[[:space:]]"; then echo "[OK] 端口监听已释放"; else echo "[!] 端口 ${OLD_PORT} 仍在监听"; fi
    if [ ! -e "${INSTALL_DIR}/ssserver" ]; then echo "[OK] 二进制文件已清理"; else echo "[!] ssserver 二进制仍存在"; fi
    if ! systemctl cat ssserver >/dev/null 2>&1; then echo "[OK] systemd 服务已注销"; else echo "[!] systemd 服务仍可查询（可能为第三方 unit）"; fi
    if [ "$KEEP_CONFIG" -eq 1 ]; then echo "[KEEP] 配置目录已保留: ${CONFIG_DIR}"; elif [ ! -e "$CONFIG_DIR" ]; then echo "[OK] 配置目录 ${CONFIG_DIR} 已移除"; else echo "[!] 配置目录仍存在"; fi
    echo "Shadowsocks-rust 卸载完成"
}

uninstall_main() {
    local menu_confirmed=0
    if [ "${1:-}" = "--menu-confirmed" ]; then
        menu_confirmed=1
        shift
    fi
    parse_uninstall_args "$menu_confirmed" "$@"
    check_installed_status
    if [ "$UNINSTALL_YES" -eq 0 ]; then
        show_uninstall_plan
        local answer
        read -r -p "确认卸载 shadowsocks-rust 及相关组件吗? [y/N]: " answer || exit 1
        case "$answer" in y|Y) ;; *) echo "操作取消"; exit 1 ;; esac
    else
        show_uninstall_plan
    fi
    echo
    echo "[+] 停止 Shadowsocks 服务..."
    stop_and_kill_service
    echo "[+] 清理 systemd 服务..."
    cleanup_systemd_unit
    echo "[+] 清理文件..."
    cleanup_files
    echo "[+] 卸载后检查..."
    verify_and_report
}

install_main() {
    echo
    echo "================================================"
    echo " Shadowsocks Rust 一键安装"
    echo " SS2022 + IPv6"
    echo "================================================"
    echo
    # ============================================================
    # 1. 检查系统与服务覆盖风险
    # ============================================================
    if [ ! -f /etc/os-release ]; then echo "[!] 无法检测操作系统"; exit 1; fi
    # shellcheck disable=SC1091
    source /etc/os-release
    echo "[+] 操作系统: ${PRETTY_NAME:-unknown}"
    case "${ID:-}" in debian|ubuntu) ;; *) echo "[!] 当前系统不是 Debian / Ubuntu (ID=${ID:-unknown})"; exit 1 ;; esac
    ARCH="$(uname -m)"
    if [ "$ARCH" != "x86_64" ]; then echo "[!] 此脚本只支持 x86_64，当前为 ${ARCH}"; exit 1; fi
    echo "[+] CPU 架构: ${ARCH}"
    check_unit_conflict

    # ============================================================
    # 2. 选择 AES-128 / AES-256
    # ============================================================
    echo
    echo "================================================"
    echo " 请选择 SS2022 加密方式"
    echo "================================================"
    echo
    echo "  1) 2022-blake3-aes-128-gcm"
    echo "  2) 2022-blake3-aes-256-gcm"
    echo
    while true; do
        read -r -p "请输入 [1-2]: " METHOD_CHOICE || exit 1
        case "$METHOD_CHOICE" in
            1) METHOD="2022-blake3-aes-128-gcm"; break ;;
            2) METHOD="2022-blake3-aes-256-gcm"; break ;;
            *) echo "[!] 无效选择，请输入 1 或 2" ;;
        esac
    done
    echo
    echo "[+] 加密方式: ${METHOD}"

    # ============================================================
    # 3. 安装依赖
    # ============================================================
    echo
    echo "[+] 安装必要依赖..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl wget jq tar xz-utils coreutils iproute2

    # ============================================================
    # 4. 获取最新 Tag 与下载校验
    # ============================================================
    echo
    echo "[+] 获取 Shadowsocks Rust 最新正式版本..."
    EFFECTIVE_URL=""
    if ! EFFECTIVE_URL="$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/shadowsocks/shadowsocks-rust/releases/latest)"; then
        echo "[!] 无法获取 shadowsocks-rust 最新版本 Tag，请检查网络连接"; exit 3
    fi
    VERSION="${EFFECTIVE_URL##*/}"
    if [[ ! "$VERSION" =~ ^v[0-9].* ]]; then echo "[!] 无法获取 shadowsocks-rust 最新版本 Tag，请检查网络连接"; exit 3; fi
    echo "[+] Shadowsocks Rust: ${VERSION}"
    FILE_NAME="shadowsocks-${VERSION}.x86_64-unknown-linux-musl.tar.xz"
    DOWNLOAD_URL="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${VERSION}/${FILE_NAME}"
    TMP_DIR="$(mktemp -d)"
    ARCHIVE="${TMP_DIR}/${FILE_NAME}"
    CHECKSUM_FILE="${ARCHIVE}.sha256"
    EXTRACT_DIR="${TMP_DIR}/extract"
    mkdir -p "$EXTRACT_DIR"
    echo "[+] 下载文件与 SHA256 校验文件..."
    if ! curl -fL --retry 3 --connect-timeout 30 -o "$ARCHIVE" "$DOWNLOAD_URL" || ! curl -fL --retry 3 --connect-timeout 30 -o "$CHECKSUM_FILE" "${DOWNLOAD_URL}.sha256"; then
        echo "[!] Shadowsocks Rust 下载失败"; exit 3
    fi
    if [ ! -s "$ARCHIVE" ] || [ ! -s "$CHECKSUM_FILE" ]; then echo "[!] 下载文件为空"; exit 3; fi
    EXPECTED_HASH="$(awk 'NF {print $1; exit}' "$CHECKSUM_FILE" | tr 'A-F' 'a-f')"
    ACTUAL_HASH="$(sha256sum "$ARCHIVE" | awk '{print $1}' | tr 'A-F' 'a-f')"
    if [[ ! "$EXPECTED_HASH" =~ ^[0-9a-f]{64}$ ]] || [ "$EXPECTED_HASH" != "$ACTUAL_HASH" ]; then
        echo "[!] SHA256 校验失败，文件可能损坏或被篡改"; exit 3
    fi
    echo "[+] SHA256 校验通过"

    # ============================================================
    # 5. 解压、冒烟验证与原子安装
    # ============================================================
    echo
    echo "[+] 解压 Shadowsocks Rust..."
    if ! tar -xJf "$ARCHIVE" -C "$EXTRACT_DIR"; then echo "[!] 安装包解压失败"; exit 3; fi
    if [ ! -f "${EXTRACT_DIR}/ssserver" ]; then echo "[!] 下载包中没有找到 ssserver"; exit 3; fi
    if ! "${EXTRACT_DIR}/ssserver" --version >/dev/null 2>&1; then echo "[!] ssserver 冒烟验证失败"; exit 3; fi
    if [ ! -f "${EXTRACT_DIR}/ssservice" ]; then echo "[!] 下载包中没有找到 ssservice，无法生成密钥"; exit 3; fi
    for binary in ssserver ssservice; do
        if [ -e "${INSTALL_DIR}/${binary}" ]; then
            BACKUP="${INSTALL_DIR}/${binary}.bak.$(date +%Y%m%d-%H%M%S)_$$"
            cp -a "${INSTALL_DIR}/${binary}" "$BACKUP"
            echo "[+] 已备份旧版 ${binary}: ${BACKUP}"
        fi
    done
    install -m 0755 "${EXTRACT_DIR}/ssserver" "${INSTALL_DIR}/ssserver.new.$$"
    mv -f "${INSTALL_DIR}/ssserver.new.$$" "${INSTALL_DIR}/ssserver"
    if [ -f "${EXTRACT_DIR}/ssservice" ]; then
        install -m 0755 "${EXTRACT_DIR}/ssservice" "${INSTALL_DIR}/ssservice.new.$$"
        mv -f "${INSTALL_DIR}/ssservice.new.$$" "${INSTALL_DIR}/ssservice"
    fi
    echo "[+] Shadowsocks Rust 二进制安装完成"

    # ============================================================
    # 6. 检测公网 IPv6 与可用端口
    # ============================================================
    echo
    echo "[+] 检测公网 IPv6..."
    IPV6_OUTPUT="$(ip -6 addr show scope global)"
    IPV6="$(printf '%s\n' "$IPV6_OUTPUT" | awk '/inet6[[:space:]]/ {split($2,a,"/"); if (a[1] ~ /^[23][0-9a-fA-F]/) {print a[1]; exit}}')"
    if [ -z "$IPV6" ]; then echo "[!] 未检测到有效的 2xxx/3xxx 公网 IPv6 地址，安装中止"; exit 4; fi
    echo "[+] IPv6: ${IPV6}"
    echo
    echo "[+] 生成随机端口..."
    PORT=""
    for ((attempt=1; attempt<=30; attempt++)); do
        candidate="$(shuf -i 50000-60000 -n 1)"
        [[ "$candidate" == *4* ]] && continue
        if ! ss -lntu | awk -v p="$candidate" '$5 ~ (":" p "$" ) {found=1} END {exit !found}'; then PORT="$candidate"; break; fi
    done
    if [ -z "$PORT" ]; then echo "[!] 30 次尝试后仍未找到未占用端口"; exit 4; fi
    echo "[+] Server Port: ${PORT}"

    # ============================================================
    # 7. 配置、服务与启动验证
    # ============================================================
    mkdir -p "$CONFIG_DIR"
    if [ -f "$CONFIG_FILE" ]; then
        BACKUP_FILE="${CONFIG_FILE}.bak.$(date +%Y%m%d-%H%M%S)_$$"
        echo "[+] 检测到旧配置，备份到: ${BACKUP_FILE}"
        cp -a "$CONFIG_FILE" "$BACKUP_FILE"
    fi
    echo
    echo "[+] 生成 SS2022 密钥..."
    PASSWORD="$("${INSTALL_DIR}/ssservice" genkey -m "${METHOD}" | tail -n 1 | tr -d '\r\n')"
    if [ -z "$PASSWORD" ]; then echo "[!] SS2022 密钥生成失败"; exit 1; fi
    echo "[+] SS2022 Key: ${PASSWORD}"
    echo "[+] 创建配置..."
    cat > "$CONFIG_FILE" <<EOF
{
    "server": "::",
    "server_port": ${PORT},
    "password": "${PASSWORD}",
    "method": "${METHOD}",
    "timeout": 300,
    "mode": "tcp_and_udp"
}
EOF
    chmod 600 "$CONFIG_FILE"
    if ! jq . "$CONFIG_FILE" >/dev/null; then echo "[!] config.json 语法校验失败"; exit 4; fi
    echo "[+] 创建 systemd 服务..."
    cat > "$SERVICE_FILE" <<EOF
# Managed by insss.sh
[Unit]
Description=Shadowsocks Rust Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/ssserver -c ${CONFIG_FILE}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$SERVICE_FILE"
    echo "[+] 启动 Shadowsocks..."
    systemctl daemon-reload
    systemctl enable ssserver
    systemctl restart ssserver
    sleep 2
    if ! systemctl is-active --quiet ssserver; then
        echo "[!] Shadowsocks 启动失败"
        systemctl status ssserver --no-pager -l || true
        journalctl -u ssserver -n 50 --no-pager || true
        exit 1
    fi
    echo "[+] Shadowsocks 服务运行正常"
    echo
    echo "[+] 检查监听端口..."
    ss -lntup | grep ":${PORT}" || true
    echo
    echo "================================================"
    echo " Shadowsocks Rust 安装完成"
    echo "================================================"
    echo "Server: ${IPV6}"
    echo "Port: ${PORT}"
    echo "Method: ${METHOD}"
    echo "Password: ${PASSWORD}"
    echo "配置文件: ${CONFIG_FILE}"
    echo "服务状态: systemctl status ssserver"
    echo "重启服务: systemctl restart ssserver"
    echo "停止服务: systemctl stop ssserver"
    echo "查看日志: journalctl -u ssserver -f"
    echo "注意：本脚本不会安装或配置 UFW。请在安全组放行 TCP/UDP ${PORT}。"
}

if [ "$#" -eq 0 ]; then
    check_root
    if [ -e "$SERVICE_FILE" ] || [ -e "${INSTALL_DIR}/ssserver" ]; then
        echo
        echo "================================================"
        echo " 检测到已安装 Shadowsocks Rust"
        echo "================================================"
        echo "  1) 覆盖安装 / 更新"
        echo "  2) 卸载"
        echo "  3) 退出"
        while true; do
            read -r -p "请输入 [1-3]: " MENU_CHOICE || exit 1
            case "$MENU_CHOICE" in
                1) break ;;
                2) uninstall_main --menu-confirmed; exit 0 ;;
                3) exit 0 ;;
                *) echo "[!] 无效选择，请输入 1、2 或 3" ;;
            esac
        done
    fi
    install_main
    exit 0
fi

case "$1" in
    install)
        if [ "$#" -gt 1 ]; then echo "[!] install 不接受额外参数"; exit 1; fi
        check_root
        install_main
        ;;
    uninstall)
        check_root
        shift
        uninstall_main "$@"
        ;;
    *) echo "用法: $0 [install | uninstall [-y|--yes|-f|--force] [--keep-config]]"; exit 1 ;;
esac
