#!/usr/bin/env bash
#
# manage_swap.sh - Linux swap 交换文件管理脚本
#
# 功能:
#   1. 查看当前 swap 状态
#   2. 创建 swap (选择大小 + swappiness 调优 + 持久化, 兼容 btrfs)
#   3. 删除 swap (关闭 + 移除文件 + 清理 fstab + 可选清理 swappiness)
#   4. 调整 swappiness
#   5. 删除 swappiness 配置 (恢复默认)
#
# 兼容主流 Linux 发行版; 需 root 权限运行。
#

set -euo pipefail

SWAPFILE="/swapfile"
SYSCTL_CONF="/etc/sysctl.d/99-swappiness.conf"
DEFAULT_SWAPPINESS=60

# ---------- 工具函数 ----------
err()  { printf '错误: %s\n' "$*" >&2; }
info() { printf '%s\n' "$*"; }

# 读取输入, 处理 EOF (Ctrl-D)。返回非零表示读取失败。
ask() {
    local prompt="$1" __var="$2"
    if ! read -r -p "${prompt}" "${__var}"; then
        echo
        err "输入结束,已取消。"
        return 1
    fi
    return 0
}

confirm() {
    local prompt="$1" ans
    if ! read -r -p "${prompt} [y/N] " ans; then
        echo
        return 1
    fi
    case "${ans}" in
        [yY] | [yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------- 环境检查 ----------
if [[ "${EUID}" -ne 0 ]]; then
    err "请使用 root 权限运行此脚本 (sudo $0)"
    exit 1
fi

# 容器环境检测 (仅提示, 不强制退出)
in_container() {
    grep -qa 'container=' /proc/1/environ 2>/dev/null || [[ -f /.dockerenv ]]
}

# ---------- 查看状态 ----------
show_status() {
    info "==================== 当前 swap 状态 ===================="
    if swapon --show 2>/dev/null | grep -q '^'; then
        swapon --show
    else
        info "(当前没有启用任何 swap)"
    fi
    echo
    free -h
    echo
    info "当前 swappiness: $(cat /proc/sys/vm/swappiness)"
    if [[ -e "${SYSCTL_CONF}" ]]; then
        info "持久化配置: $(cat "${SYSCTL_CONF}")"
    else
        info "持久化配置: (无, 使用系统默认)"
    fi
    echo
}

# ---------- 调整 swappiness ----------
set_swappiness() {
    local value
    if [[ -e "${SYSCTL_CONF}" ]]; then
        info "检测到已有自定义配置: $(cat "${SYSCTL_CONF}")"
        info "继续操作将覆盖该值。"
    fi

    while true; do
        ask "请输入 swappiness 值 (0-100,建议:桌面 10,服务器 10-30,默认 60): " value || return 1
        if [[ "${value}" =~ ^[0-9]+$ ]] && [[ "${value}" -ge 0 ]] && [[ "${value}" -le 100 ]]; then
            break
        fi
        err "请输入 0 到 100 之间的整数。"
    done

    sysctl -w vm.swappiness="${value}" >/dev/null
    printf 'vm.swappiness=%s\n' "${value}" > "${SYSCTL_CONF}"
    info "✓ swappiness 已设置为 ${value} 并写入 ${SYSCTL_CONF} (开机生效)。"
}

# ---------- 删除/恢复 swappiness ----------
reset_swappiness() {
    if [[ ! -e "${SYSCTL_CONF}" ]]; then
        info "未找到自定义 swappiness 配置 (${SYSCTL_CONF}),当前值为 $(cat /proc/sys/vm/swappiness)。"
        return 0
    fi

    info "即将删除自定义配置 ${SYSCTL_CONF},并把 swappiness 恢复为系统默认 ${DEFAULT_SWAPPINESS}。"
    if ! confirm "确认继续?"; then
        info "已取消操作。"
        return 0
    fi

    rm -f "${SYSCTL_CONF}"
    sysctl -w vm.swappiness="${DEFAULT_SWAPPINESS}" >/dev/null
    info "✓ 已删除自定义配置,swappiness 恢复为 ${DEFAULT_SWAPPINESS} (当前: $(cat /proc/sys/vm/swappiness))。"
}

# 根据物理内存给出推荐 swap 大小 (GB)
recommend_size() {
    local mem_kb mem_gb rec
    mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    mem_gb=$(( (mem_kb + 1048575) / 1048576 ))   # 向上取整
    if   [[ "${mem_gb}" -le 2 ]]; then rec=$(( mem_gb * 2 ))
    elif [[ "${mem_gb}" -le 8 ]]; then rec="${mem_gb}"
    else rec=4
    fi
    printf '%s' "${rec}"
}

# ---------- 创建 swap ----------
create_swap() {
    local created=0
    cleanup_on_fail() {
        local rc=$?
        if [[ "${created}" -eq 1 && -e "${SWAPFILE}" ]]; then
            swapoff "${SWAPFILE}" 2>/dev/null || true
            rm -f "${SWAPFILE}"
            err "创建过程出错 (退出码 ${rc}),已清理残留文件 ${SWAPFILE}。"
        fi
        trap - RETURN
    }
    trap cleanup_on_fail RETURN

    if in_container; then
        err "检测到容器环境,通常无法在容器内创建 swap,需在宿主机配置。"
        if ! confirm "仍要尝试继续?"; then
            return 0
        fi
    fi

    info "==> 检测当前 swap 状态..."
    if swapon --show 2>/dev/null | grep -q '^'; then
        info "当前系统已存在 swap:"
        swapon --show
        echo
        if ! confirm "已存在 swap,是否仍要继续创建新的 swapfile?"; then
            info "已取消操作。"
            return 0
        fi
    else
        info "当前系统没有启用任何 swap。"
    fi

    if [[ -e "${SWAPFILE}" ]]; then
        err "${SWAPFILE} 已存在。请先用删除功能移除,或修改脚本中的 SWAPFILE 变量。"
        return 1
    fi

    # 选择大小 (给出基于内存的推荐值)
    local size_gb rec
    rec=$(recommend_size)
    while true; do
        ask "请输入要创建的 swap 大小 (GB,直接回车使用推荐值 ${rec}G): " size_gb || return 1
        size_gb="${size_gb:-${rec}}"
        if [[ "${size_gb}" =~ ^[1-9][0-9]*$ ]]; then
            break
        fi
        err "请输入一个有效的正整数。"
    done

    # 检查目标分区剩余空间 (基于 swapfile 实际所在目录)
    local target_dir avail_gb
    target_dir="$(dirname "${SWAPFILE}")"
    avail_gb=$(df -BG --output=avail "${target_dir}" | tail -n1 | tr -dc '0-9')
    if [[ "${size_gb}" -ge "${avail_gb}" ]]; then
        err "磁盘可用空间不足: 需要 ${size_gb}G,${target_dir} 可用 ${avail_gb}G。"
        return 1
    fi

    info "==> 将在 ${SWAPFILE} 创建 ${size_gb}G 的 swap 文件。"
    if ! confirm "确认继续?"; then
        info "已取消操作。"
        return 0
    fi

    # 标记进入"已创建文件"阶段, 失败时触发清理
    created=1

    # 检测文件系统类型, btrfs 需特殊处理 (关闭 COW)
    local fstype
    fstype=$(stat -f -c %T "${target_dir}")
    info "==> 目标文件系统: ${fstype}"

    if [[ "${fstype}" == "btrfs" ]]; then
        info "==> btrfs 专用方式创建 (关闭 COW)..."
        truncate -s 0 "${SWAPFILE}"
        chattr +C "${SWAPFILE}"
        dd if=/dev/zero of="${SWAPFILE}" bs=1M count=$((size_gb * 1024)) status=progress
    elif command -v fallocate >/dev/null 2>&1 && fallocate -l "${size_gb}G" "${SWAPFILE}" 2>/dev/null; then
        info "已使用 fallocate 创建。"
    else
        info "fallocate 不可用,改用 dd (可能较慢)..."
        dd if=/dev/zero of="${SWAPFILE}" bs=1M count=$((size_gb * 1024)) status=progress
    fi

    info "==> 设置权限 600..."
    chmod 600 "${SWAPFILE}"

    info "==> 格式化为 swap..."
    mkswap "${SWAPFILE}"

    info "==> 启用 swap..."
    swapon "${SWAPFILE}"

    # 持久化到 fstab
    if ! grep -qs "^${SWAPFILE} " /etc/fstab; then
        info "==> 写入 /etc/fstab 实现开机自动挂载..."
        cp /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
        printf '%s none swap sw 0 0\n' "${SWAPFILE}" >> /etc/fstab
    else
        info "/etc/fstab 中已存在该条目,跳过写入。"
    fi

    # 创建成功, 取消失败清理
    created=0

    # swappiness 调优
    echo
    if confirm "是否现在调整 swappiness?"; then
        set_swappiness || true
    fi

    # 检测结果
    echo
    info "==================== 配置结果检测 ===================="
    swapon --show
    echo
    free -h
    echo
    grep "${SWAPFILE}" /etc/fstab || err "未在 fstab 中找到条目!"
    echo
    if swapon --show | grep -q "${SWAPFILE}"; then
        info "✓ swap 创建并启用成功。"
    else
        err "swap 似乎未成功启用,请检查上面的输出。"
        return 1
    fi
}

# ---------- 删除 swap ----------
delete_swap() {
    if [[ ! -e "${SWAPFILE}" ]]; then
        err "${SWAPFILE} 不存在,无需删除。"
        if grep -qs "^${SWAPFILE} " /etc/fstab; then
            info "但 /etc/fstab 中存在残留条目,将一并清理。"
        else
            return 0
        fi
    fi

    info "即将执行以下操作 (不可逆):"
    info "  1. 关闭 ${SWAPFILE} (swapoff)"
    info "  2. 删除文件 ${SWAPFILE}"
    info "  3. 从 /etc/fstab 移除对应条目"
    echo
    if ! confirm "确认删除该 swapfile?"; then
        info "已取消操作。"
        return 0
    fi

    if swapon --show | grep -q "${SWAPFILE}"; then
        info "==> 关闭 swap..."
        swapoff "${SWAPFILE}"
    fi

    if [[ -e "${SWAPFILE}" ]]; then
        info "==> 删除文件 ${SWAPFILE}..."
        rm -f "${SWAPFILE}"
    fi

    if grep -qs "^${SWAPFILE} " /etc/fstab; then
        info "==> 清理 /etc/fstab 条目 (已备份)..."
        cp /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
        sed -i "\\#^${SWAPFILE} #d" /etc/fstab
    fi

    # 检测结果
    echo
    info "==================== 删除结果检测 ===================="
    if swapon --show | grep -q "${SWAPFILE}"; then
        err "swap 仍处于启用状态,删除失败!"
        return 1
    fi
    if [[ -e "${SWAPFILE}" ]]; then
        err "文件仍存在,删除失败!"
        return 1
    fi
    free -h
    echo

    # 询问是否一并清理 swappiness 配置
    if [[ -e "${SYSCTL_CONF}" ]]; then
        info "检测到自定义 swappiness 配置: $(cat "${SYSCTL_CONF}")"
        if confirm "是否一并删除该配置并恢复默认 ${DEFAULT_SWAPPINESS}?"; then
            reset_swappiness
        else
            info "保留 swappiness 配置。注意:已无 swap,该值不再有实际作用。"
        fi
        echo
    fi

    info "✓ swap 已删除。"
}

# ---------- 主菜单 ----------
main_menu() {
    while true; do
        echo
        info "============== Linux Swap 管理 =============="
        info "  1) 查看当前 swap 状态"
        info "  2) 创建 swap"
        info "  3) 删除 swap"
        info "  4) 调整 swappiness"
        info "  5) 删除 swappiness 配置 (恢复默认)"
        info "  0) 退出"
        info "============================================="
        if ! ask "请选择操作 [0-5]: " choice; then
            exit 0
        fi
        echo
        case "${choice}" in
            1) show_status     || true ;;
            2) create_swap     || true ;;
            3) delete_swap     || true ;;
            4) set_swappiness  || true ;;
            5) reset_swappiness || true ;;
            0)
                info "再见。"
                exit 0
                ;;
            *) err "无效选项,请重新输入。" ;;
        esac
    done
}

main_menu
