#!/bin/sh
# clear-disk.sh
# 清理 systemd-journal 日志 + 永久限制最大占用为 100MB
#
# 兼容: Ubuntu / Debian / CentOS / RHEL / Rocky / AlmaLinux / Fedora / Arch / openSUSE
#       (任何以 systemd 为 init、且支持 journald.conf.d drop-in 的发行版)
# 不兼容: Alpine(OpenRC) / Devuan / CentOS 6 等非 systemd 系统

set -e

LIMIT="100M"
DROPIN_DIR="/etc/systemd/journald.conf.d"
DROPIN_FILE="${DROPIN_DIR}/00-size-limit.conf"

line() { printf '%s\n' "------------------------------------------------------------"; }

get_usage() {
    journalctl --disk-usage 2>/dev/null | sed -n 's/.*take up \([^ ]*\) .*/\1/p'
}

line
echo "systemd-journal 清理与限额脚本"
line

# 0. 基本检查
if ! command -v journalctl >/dev/null 2>&1; then
    echo "[错误] 未找到 journalctl，当前系统不是 systemd 系统，脚本不支持。" >&2
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "[错误] 请使用 root 权限运行 (例如: sudo sh $0)" >&2
    exit 1
fi

BEFORE=$(get_usage)
echo "[1/3] 清理前占用: ${BEFORE:-未知}"
echo

echo "[2/3] 正在清理 journal 日志（保留至 ${LIMIT} 以内）..."
journalctl --vacuum-size="${LIMIT}" 2>&1 | sed 's/^/    /'
echo
line

echo "[3/3] 写入永久限额配置..."
mkdir -p "${DROPIN_DIR}"

cat > "${DROPIN_FILE}" <<EOF
# 由 clear-disk.sh 自动生成，请勿手动修改
[Journal]
SystemMaxUse=${LIMIT}
EOF

echo "    配置文件: ${DROPIN_FILE}"
echo "    内容:"
sed 's/^/        /' "${DROPIN_FILE}"
echo
echo "    重启 systemd-journald 使配置生效..."
systemctl restart systemd-journald
echo

AFTER=$(get_usage)

line
echo "结果汇总"
line
printf "  %-10s %s\n" "清理前:" "${BEFORE:-未知}"
printf "  %-10s %s\n" "清理后:" "${AFTER:-未知}"
printf "  %-10s %s\n" "永久限额:" "${LIMIT}（已生效）"
printf "  %-10s %s\n" "配置文件:" "${DROPIN_FILE}"
line
echo "完成。"
