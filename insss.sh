#!/bin/bash
set -euo pipefail

# ============================================================
# Shadowsocks Rust 一键安装脚本
#
# 支持：
#   Debian 12 / 13
#   Ubuntu 22.04 / 24.04 / 26.04
#
# 架构：
#   x86_64
#
# 协议：
#   Shadowsocks 2022
#
# 加密：
#   AES-128 / AES-256 可选
#
# 网络：
#   IPv6
#   TCP + UDP
#
# 端口：
#   50000 - 60000
#   排除包含数字 4 的端口
#
# 防火墙：
#   不安装 / 不配置 UFW
# ============================================================

set +H

INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/shadowsocks-rust"
CONFIG_FILE="${CONFIG_DIR}/config.json"
SERVICE_FILE="/etc/systemd/system/ssserver.service"

TMP_DIR=""

cleanup() {
    if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
}

trap cleanup EXIT

echo
echo "================================================"
echo " Shadowsocks Rust 一键安装"
echo " SS2022 + IPv6"
echo "================================================"
echo

# ============================================================
# 1. Root
# ============================================================

if [ "$EUID" -ne 0 ]; then
    echo "[!] 请使用 root 运行此脚本"
    exit 1
fi

# ============================================================
# 2. 检查系统
# ============================================================

if [ ! -f /etc/os-release ]; then
    echo "[!] 无法检测操作系统"
    exit 1
fi

source /etc/os-release

echo "[+] 操作系统:"
echo "    ${PRETTY_NAME:-unknown}"

case "${ID:-}" in
    debian)
        echo "[+] Debian 系统"
        ;;
    ubuntu)
        echo "[+] Ubuntu 系统"
        ;;
    *)
        echo
        echo "[!] 当前系统不是 Debian / Ubuntu"
        echo "[!] ID=${ID:-unknown}"
        exit 1
        ;;
esac

# ============================================================
# 3. 检查 CPU 架构
# ============================================================

ARCH="$(uname -m)"

if [ "$ARCH" != "x86_64" ]; then
    echo
    echo "[!] 当前 CPU 架构: ${ARCH}"
    echo "[!] 此脚本只支持 x86_64"
    exit 1
fi

echo "[+] CPU 架构: ${ARCH}"

# ============================================================
# 4. 选择 AES-128 / AES-256
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

    read -rp "请输入 [1-2]: " METHOD_CHOICE

    case "$METHOD_CHOICE" in

        1)
            METHOD="2022-blake3-aes-128-gcm"
            break
            ;;

        2)
            METHOD="2022-blake3-aes-256-gcm"
            break
            ;;

        *)
            echo "[!] 无效选择，请输入 1 或 2"
            ;;

    esac

done

echo
echo "[+] 加密方式:"
echo "    ${METHOD}"

# ============================================================
# 5. 安装依赖
# ============================================================

echo
echo "[+] 安装必要依赖..."

export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get install -y \
    ca-certificates \
    curl \
    wget \
    jq \
    tar \
    xz-utils \
    coreutils \
    iproute2

# ============================================================
# 6. 获取 Shadowsocks Rust 最新正式版本
# ============================================================

echo
echo "[+] 获取 Shadowsocks Rust 最新正式版本..."

API_URL="https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest"

RELEASE_JSON="$(
    curl -fsSL \
        -H "Accept: application/vnd.github+json" \
        "$API_URL"
)"

VERSION="$(
    echo "$RELEASE_JSON" \
    | jq -r '.tag_name'
)"

if [ -z "$VERSION" ] || [ "$VERSION" = "null" ]; then
    echo "[!] 获取 Shadowsocks Rust 版本失败"
    exit 1
fi

case "$VERSION" in
    v*)
        ;;
    *)
        echo "[!] GitHub 返回的版本号异常:"
        echo "    ${VERSION}"
        exit 1
        ;;
esac

VERSION_NUMBER="${VERSION#v}"

echo "[+] Shadowsocks Rust:"
echo "    ${VERSION}"

# ============================================================
# 7. 构造下载地址
# ============================================================

FILE_NAME="shadowsocks-v${VERSION_NUMBER}.x86_64-unknown-linux-gnu.tar.xz"

DOWNLOAD_URL="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${VERSION}/${FILE_NAME}"

echo
echo "[+] 下载文件:"
echo "    ${FILE_NAME}"

echo
echo "[+] 下载地址:"
echo "    ${DOWNLOAD_URL}"

# ============================================================
# 8. 创建临时目录
# ============================================================

TMP_DIR="$(mktemp -d)"

ARCHIVE="${TMP_DIR}/${FILE_NAME}"
EXTRACT_DIR="${TMP_DIR}/extract"

mkdir -p "$EXTRACT_DIR"

# ============================================================
# 9. 下载 Shadowsocks Rust
# ============================================================

echo
echo "[+] 开始下载..."

if ! wget \
    --https-only \
    --timeout=30 \
    --tries=3 \
    -O "$ARCHIVE" \
    "$DOWNLOAD_URL"; then

    echo
    echo "[!] Shadowsocks Rust 下载失败"
    echo
    echo "可能原因："
    echo "  1. GitHub 最新版本暂时没有 x86_64 glibc 包"
    echo "  2. GitHub 网络连接失败"
    echo "  3. Release 文件名发生变化"
    echo
    exit 1
fi

if [ ! -s "$ARCHIVE" ]; then
    echo "[!] 下载文件为空"
    exit 1
fi

# ============================================================
# 10. 解压
# ============================================================

echo
echo "[+] 解压 Shadowsocks Rust..."

tar -xJf "$ARCHIVE" -C "$EXTRACT_DIR"

# ============================================================
# 11. 检查 ssserver
# ============================================================

if [ ! -f "${EXTRACT_DIR}/ssserver" ]; then

    echo
    echo "[!] 下载包中没有找到 ssserver"
    echo
    echo "当前文件："

    find "$EXTRACT_DIR" -maxdepth 2 -type f -print

    exit 1
fi

# ============================================================
# 12. 安装程序
# ============================================================

echo
echo "[+] 安装 Shadowsocks Rust..."

install -m 0755 \
    "${EXTRACT_DIR}/ssserver" \
    "${INSTALL_DIR}/ssserver"

if [ -f "${EXTRACT_DIR}/ssservice" ]; then

    install -m 0755 \
        "${EXTRACT_DIR}/ssservice" \
        "${INSTALL_DIR}/ssservice"

fi

echo
echo "[+] 安装完成"

ssserver --version || true

# ============================================================
# 13. 检查 ssservice
# ============================================================

if [ ! -x "${INSTALL_DIR}/ssservice" ]; then

    echo
    echo "[!] ssservice 不存在"
    echo "[!] 无法自动生成 SS2022 密钥"

    exit 1
fi

# ============================================================
# 14. 检测公网 IPv6
# ============================================================

echo
echo "[+] 检测公网 IPv6..."

IPV6="$(
    ip -6 addr show scope global \
    | awk '/inet6/ {print $2}' \
    | cut -d/ -f1 \
    | grep -v '^fe80:' \
    | head -n 1
)"

if [ -z "$IPV6" ]; then

    echo
    echo "[!] 没有检测到公网 IPv6"
    echo
    echo "当前 IPv6 地址："

    ip -6 addr

    echo

    exit 1
fi

echo "[+] IPv6:"
echo "    ${IPV6}"

# ============================================================
# 15. 随机端口
#
# 50000 - 60000
# 且端口不能包含数字 4
# ============================================================

echo
echo "[+] 生成随机端口..."

while true; do

    PORT="$(shuf -i 50000-60000 -n 1)"

    if [[ "$PORT" != *4* ]]; then
        break
    fi

done

echo "[+] Server Port:"
echo "    ${PORT}"

# ============================================================
# 16. 创建配置目录
# ============================================================

mkdir -p "$CONFIG_DIR"

# ============================================================
# 17. 备份旧配置
# ============================================================

if [ -f "$CONFIG_FILE" ]; then

    BACKUP_FILE="${CONFIG_FILE}.bak.$(date +%Y%m%d-%H%M%S)"

    echo
    echo "[+] 检测到旧配置"

    echo "[+] 备份到:"
    echo "    ${BACKUP_FILE}"

    cp -a "$CONFIG_FILE" "$BACKUP_FILE"

fi

# ============================================================
# 18. 生成 SS2022 密钥
# ============================================================

echo
echo "[+] 生成 SS2022 密钥..."

PASSWORD="$(
    "${INSTALL_DIR}/ssservice" \
        genkey \
        -m "${METHOD}" \
        | tail -n 1 \
        | tr -d '\r\n'
)"

if [ -z "$PASSWORD" ]; then

    echo
    echo "[!] SS2022 密钥生成失败"

    exit 1
fi

echo
echo "[+] SS2022 Key:"
echo "    ${PASSWORD}"

# ============================================================
# 19. 创建 Shadowsocks 配置
# ============================================================

echo
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

# ============================================================
# 20. 创建 systemd 服务
# ============================================================

echo
echo "[+] 创建 systemd 服务..."

cat > "$SERVICE_FILE" <<EOF
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

# ============================================================
# 21. 启动服务
# ============================================================

echo
echo "[+] 启动 Shadowsocks..."

systemctl daemon-reload

systemctl enable ssserver

systemctl restart ssserver

sleep 2

# ============================================================
# 22. 检查服务
# ============================================================

if ! systemctl is-active --quiet ssserver; then

    echo
    echo "[!] Shadowsocks 启动失败"
    echo

    echo "服务状态:"
    systemctl status ssserver --no-pager -l || true

    echo
    echo "最近日志:"
    journalctl -u ssserver -n 50 --no-pager || true

    exit 1
fi

echo "[+] Shadowsocks 服务运行正常"

# ============================================================
# 23. 检查监听
# ============================================================

echo
echo "[+] 检查监听端口..."

ss -lntup | grep ":${PORT}" || true

# ============================================================
# 24. 最终输出
# ============================================================

echo
echo
echo "================================================"
echo " Shadowsocks Rust 安装完成"
echo "================================================"
echo
echo "Server:"
echo "${IPV6}"
echo
echo "Port:"
echo "${PORT}"
echo
echo "Method:"
echo "${METHOD}"
echo
echo "Password:"
echo "${PASSWORD}"
echo
echo "------------------------------------------------"
echo "配置文件:"
echo "${CONFIG_FILE}"
echo
echo "服务状态:"
echo "systemctl status ssserver"
echo
echo "重启服务:"
echo "systemctl restart ssserver"
echo
echo "停止服务:"
echo "systemctl stop ssserver"
echo
echo "查看日志:"
echo "journalctl -u ssserver -f"
echo
echo "================================================"
echo
echo "注意："
echo "本脚本不会安装或配置 UFW。"
echo
echo "如果云服务器有安全组/网络防火墙，"
echo "请放行以下端口："
echo
echo "TCP ${PORT}"
echo "UDP ${PORT}"
echo
echo "================================================"
echo
