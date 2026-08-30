#!/bin/sh

# Linux cleanup utility compatible with Bash 4+, Zsh 5+, and BusyBox ash.
# Supported distributions: Debian 11-14, Ubuntu 20.04-26.04,
# Alpine Linux, CentOS, and Oracle Linux.
# Run with either:
#   ./clear_history.sh [options]
#   sh   clear_history.sh [options]
#   bash clear_history.sh [options]
#   zsh  clear_history.sh [options]

set -u
if (set -o pipefail) 2>/dev/null; then
    set -o pipefail
fi

PROGRAM_NAME=${0##*/}
DRY_RUN=0
ASSUME_YES=0
KEEP_DAYS=7
CLEAN_HISTORY=1
CLEAN_LOGS=1
CLEAN_CACHE=1
CLEAN_TEMP=1
ALL_USERS=1

OS_ID=unknown
OS_VERSION=unknown
OS_LIKE=
OS_FAMILY=unknown
BEFORE_FREE_KB=0

CLEANED_FILES=0
COMPLETED_STEPS=0
FAILED_STEPS=0

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    COLOR_RED=$(printf '\033[0;31m')
    COLOR_GREEN=$(printf '\033[0;32m')
    COLOR_YELLOW=$(printf '\033[1;33m')
    COLOR_CYAN=$(printf '\033[0;36m')
    COLOR_RESET=$(printf '\033[0m')
else
    COLOR_RED=
    COLOR_GREEN=
    COLOR_YELLOW=
    COLOR_CYAN=
    COLOR_RESET=
fi

log_info() {
    printf '%s[INFO]%s %s\n' "$COLOR_GREEN" "$COLOR_RESET" "$*"
}

log_warn() {
    printf '%s[WARN]%s %s\n' "$COLOR_YELLOW" "$COLOR_RESET" "$*" >&2
}

log_error() {
    printf '%s[ERROR]%s %s\n' "$COLOR_RED" "$COLOR_RESET" "$*" >&2
}

log_dry_run() {
    printf '%s[DRY-RUN]%s %s\n' "$COLOR_CYAN" "$COLOR_RESET" "$*"
}

die() {
    log_error "$*"
    exit 1
}

usage() {
    printf '%s\n' "用法: $PROGRAM_NAME [选项]"
    printf '%s\n' ""
    printf '%s\n' "安全清理 Shell 历史、过期日志、软件包缓存和临时文件。"
    printf '%s\n' "支持 Debian 11-14、Ubuntu 20.04-26.04、Alpine、CentOS、Oracle Linux。"
    printf '%s\n' "可使用 Bash、Zsh；Alpine 默认 BusyBox ash 也可直接运行。"
    printf '%s\n' ""
    printf '%s\n' "选项:"
    printf '%s\n' "  -n, --dry-run            仅显示将执行的操作"
    printf '%s\n' "  -y, --yes                跳过交互确认"
    printf '%s\n' "      --keep-days N        Journal/兼容临时清理保留天数，默认 7"
    printf '%s\n' "      --current-user-only  只清理当前（或 sudo 发起者）用户的历史"
    printf '%s\n' "      --no-history         不清理 Shell 历史文件"
    printf '%s\n' "      --no-logs            不清理系统日志"
    printf '%s\n' "      --no-cache           不清理软件包缓存"
    printf '%s\n' "      --no-temp            不清理临时文件"
    printf '%s\n' "  -h, --help               显示帮助"
    printf '%s\n' ""
    printf '%s\n' "说明:"
    printf '%s\n' "  * 不会直接删除当前系统日志、audit、wtmp、btmp 或 lastlog。"
    printf '%s\n' "  * 非交互运行必须显式使用 --yes；建议先执行 --dry-run。"
}

trap 'exit 130' HUP INT TERM

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -n|--dry-run)
                DRY_RUN=1
                ;;
            -y|--yes)
                ASSUME_YES=1
                ;;
            --keep-days)
                [ "$#" -ge 2 ] || die "--keep-days 缺少参数"
                KEEP_DAYS=$2
                shift
                ;;
            --keep-days=*)
                KEEP_DAYS=${1#*=}
                ;;
            --current-user-only)
                ALL_USERS=0
                ;;
            --no-history)
                CLEAN_HISTORY=0
                ;;
            --no-logs)
                CLEAN_LOGS=0
                ;;
            --no-cache)
                CLEAN_CACHE=0
                ;;
            --no-temp)
                CLEAN_TEMP=0
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                [ "$#" -eq 0 ] || die "不支持位置参数: $*"
                break
                ;;
            *)
                die "未知选项: $1（使用 --help 查看帮助）"
                ;;
        esac
        shift
    done

    case "$KEEP_DAYS" in
        ''|*[!0-9]*)
            die "--keep-days 必须是非负整数"
            ;;
    esac

    if [ "$CLEAN_HISTORY" -eq 0 ] && [ "$CLEAN_LOGS" -eq 0 ] && \
       [ "$CLEAN_CACHE" -eq 0 ] && [ "$CLEAN_TEMP" -eq 0 ]; then
        die "没有启用任何清理项目"
    fi
}

detect_os() {
    local ID
    local VERSION_ID
    local ID_LIKE

    ID=unknown
    VERSION_ID=unknown
    ID_LIKE=

    if [ -r /etc/os-release ]; then
        # /etc/os-release is a trusted system file and supports shell syntax.
        # shellcheck disable=SC1091
        . /etc/os-release
    fi

    OS_ID=${ID:-unknown}
    OS_VERSION=${VERSION_ID:-unknown}
    OS_LIKE=${ID_LIKE:-}

    case "$OS_ID" in
        debian|ubuntu)
            OS_FAMILY=debian
            ;;
        alpine)
            OS_FAMILY=alpine
            ;;
        centos|rhel|ol|oracle|oraclelinux)
            OS_FAMILY=rhel
            ;;
        *)
            case " $OS_LIKE " in
                *debian*) OS_FAMILY=debian ;;
                *rhel*|*fedora*) OS_FAMILY=rhel ;;
                *) OS_FAMILY=unknown ;;
            esac
            ;;
    esac

    log_info "系统: $OS_ID $OS_VERSION；发行版族: $OS_FAMILY${OS_LIKE:+（ID_LIKE: $OS_LIKE）}"
    if [ -n "${BASH_VERSION:-}" ]; then
        log_info "解释器: Bash ${BASH_VERSION%%(*}"
    elif [ -n "${ZSH_VERSION:-}" ]; then
        log_info "解释器: Zsh ${ZSH_VERSION:-unknown}"
    else
        log_info "解释器: POSIX sh / ash"
    fi

    if [ "$OS_FAMILY" = unknown ]; then
        log_warn "当前发行版不在验证列表中，将按已安装命令使用兼容路径"
    fi
}

available_kb() {
    df -Pk / 2>/dev/null | awk 'END {print $4 + 0}'
}

format_kb() {
    local size_kb
    local size_bytes

    size_kb=$1
    size_bytes=$((size_kb * 1024))

    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec-i --suffix=B "$size_bytes" 2>/dev/null || printf '%s KiB' "$size_kb"
    else
        printf '%s KiB' "$size_kb"
    fi
}

require_permissions() {
    local needs_root

    needs_root=0

    if [ "$CLEAN_LOGS" -eq 1 ] || [ "$CLEAN_CACHE" -eq 1 ] || [ "$CLEAN_TEMP" -eq 1 ]; then
        needs_root=1
    fi
    if [ "$CLEAN_HISTORY" -eq 1 ] && [ "$ALL_USERS" -eq 1 ]; then
        needs_root=1
    fi

    if [ "$needs_root" -eq 1 ] && [ "$(id -u)" -ne 0 ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            log_warn "当前不是 root；预览结果可能不完整"
        else
            die "这些清理项目需要 root 权限，请使用 sudo ./$PROGRAM_NAME 或 doas ./$PROGRAM_NAME"
        fi
    fi
}

confirm_run() {
    local answer

    if [ "$DRY_RUN" -eq 1 ] || [ "$ASSUME_YES" -eq 1 ]; then
        return 0
    fi
    if [ ! -t 0 ]; then
        die "非交互运行需要添加 --yes；可先用 --dry-run 预览"
    fi

    printf '%s' "将执行系统清理（Journal 保留 ${KEEP_DAYS} 天），继续？[y/N] "
    IFS= read -r answer || answer=
    case "$answer" in
        y|Y|yes|YES)
            ;;
        *)
            log_warn "操作已取消"
            exit 0
            ;;
    esac
}

run_step() {
    local description

    description=$1
    shift

    if [ "$DRY_RUN" -eq 1 ]; then
        log_dry_run "$description: $*"
        return 0
    fi

    if "$@" >/dev/null 2>&1; then
        COMPLETED_STEPS=$((COMPLETED_STEPS + 1))
        log_info "$description"
        return 0
    fi

    FAILED_STEPS=$((FAILED_STEPS + 1))
    log_warn "$description 失败"
    return 1
}

truncate_history_file() {
    local history_path
    local account_name
    local link_count

    history_path=$1
    account_name=$2
    link_count=1

    [ -e "$history_path" ] || return 0
    if [ -L "$history_path" ]; then
        log_warn "跳过符号链接: $history_path"
        return 0
    fi
    [ -f "$history_path" ] || return 0
    [ -s "$history_path" ] || return 0

    if command -v stat >/dev/null 2>&1; then
        link_count=$(stat -c '%h' "$history_path" 2>/dev/null || printf '1')
        case "$link_count" in
            ''|*[!0-9]*) link_count=1 ;;
        esac
        if [ "$link_count" -gt 1 ]; then
            log_warn "跳过多硬链接文件: $history_path"
            return 0
        fi
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        log_dry_run "清空 $account_name 的 $history_path"
        return 0
    fi

    if command -v truncate >/dev/null 2>&1 && truncate -s 0 "$history_path" 2>/dev/null; then
        CLEANED_FILES=$((CLEANED_FILES + 1))
        log_info "已清空 $account_name 的 $history_path"
        return 0
    elif : > "$history_path" 2>/dev/null; then
        CLEANED_FILES=$((CLEANED_FILES + 1))
        log_info "已清空 $account_name 的 $history_path"
        return 0
    fi

    FAILED_STEPS=$((FAILED_STEPS + 1))
    log_warn "无法清空: $history_path"
    return 1
}

clean_history_for_home() {
    local account_name
    local home_dir
    local history_name
    local history_names

    account_name=$1
    home_dir=$2

    case "$home_dir" in
        /*) ;;
        *) return 0 ;;
    esac
    [ "$home_dir" != "/" ] || return 0
    [ -d "$home_dir" ] || return 0

    history_names='.bash_history
.zsh_history
.ash_history
.ksh_history
.history'

    while IFS= read -r history_name; do
        [ -n "$history_name" ] || continue
        truncate_history_file "$home_dir/$history_name" "$account_name"
    done <<EOF
$history_names
EOF
}

current_account() {
    if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER:-}" != root ]; then
        printf '%s\n' "$SUDO_USER"
    elif [ -n "${DOAS_USER:-}" ] && [ "${DOAS_USER:-}" != root ]; then
        printf '%s\n' "$DOAS_USER"
    else
        id -un
    fi
}

clean_shell_histories() {
    local account_name
    local passwd_marker
    local uid
    local gid
    local gecos
    local home_dir
    local login_shell

    log_info "清理 Shell 历史文件..."

    if [ "$ALL_USERS" -eq 0 ]; then
        account_name=$(current_account)
        home_dir=
        if command -v getent >/dev/null 2>&1; then
            home_dir=$(getent passwd "$account_name" 2>/dev/null | awk -F: 'NR == 1 {print $6}')
        fi
        if [ -z "$home_dir" ] && [ -r /etc/passwd ]; then
            home_dir=$(awk -F: -v name="$account_name" '$1 == name {print $6; exit}' /etc/passwd)
        fi
        if [ -z "$home_dir" ] && [ "$account_name" = "$(id -un)" ]; then
            home_dir=${HOME:-}
        fi
        [ -n "$home_dir" ] || die "无法确定用户 $account_name 的主目录"
        clean_history_for_home "$account_name" "$home_dir"
        return 0
    fi

    [ -r /etc/passwd ] || die "无法读取本机用户账户列表"

    while IFS=: read -r account_name passwd_marker uid gid gecos home_dir login_shell; do
        [ -n "$account_name" ] || continue
        clean_history_for_home "$account_name" "$home_dir"
    done < /etc/passwd
}

clean_system_logs() {
    local journal_retention

    log_info "清理过期系统日志..."

    if command -v journalctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        if [ "$KEEP_DAYS" -eq 0 ]; then
            journal_retention=1s
        else
            journal_retention=${KEEP_DAYS}d
        fi

        if journalctl --help 2>/dev/null | grep -q -- '--rotate'; then
            run_step "已轮转 systemd journal" journalctl --rotate || true
        else
            log_info "当前 systemd 不支持 journalctl --rotate，跳过主动轮转"
        fi

        if journalctl --help 2>/dev/null | grep -q -- '--vacuum-time'; then
            run_step "已清理早于 $KEEP_DAYS 天的 journal" journalctl "--vacuum-time=$journal_retention" || true
        else
            log_warn "当前 systemd 不支持 journalctl --vacuum-time"
        fi
    elif [ "$OS_FAMILY" = alpine ]; then
        log_info "Alpine/OpenRC 默认不使用 systemd journal，跳过 journal 清理"
    else
        log_warn "未检测到活动的 systemd journal，跳过 journal 清理"
    fi

    if command -v logrotate >/dev/null 2>&1 && [ -r /etc/logrotate.conf ]; then
        run_step "已按系统策略处理传统日志" logrotate /etc/logrotate.conf || true
    else
        log_warn "未检测到 logrotate；不会直接截断活动日志"
    fi
}

clean_package_cache() {
    log_info "清理软件包缓存..."

    case "$OS_FAMILY" in
        debian)
            if command -v apt-get >/dev/null 2>&1; then
                run_step "已清理 APT 缓存" apt-get clean || true
            else
                FAILED_STEPS=$((FAILED_STEPS + 1))
                log_warn "Debian 系统未找到 apt-get"
            fi
            ;;
        alpine)
            if command -v apk >/dev/null 2>&1; then
                run_step "已清理 APK 缓存" apk cache clean || true
            else
                FAILED_STEPS=$((FAILED_STEPS + 1))
                log_warn "Alpine 系统未找到 apk"
            fi
            ;;
        rhel)
            if command -v dnf >/dev/null 2>&1; then
                run_step "已清理 DNF 缓存" dnf clean all || true
            elif command -v yum >/dev/null 2>&1; then
                run_step "已清理 YUM 缓存" yum clean all || true
            elif command -v microdnf >/dev/null 2>&1; then
                run_step "已清理 MicroDNF 缓存" microdnf clean all || true
            else
                FAILED_STEPS=$((FAILED_STEPS + 1))
                log_warn "RHEL 系统未找到 dnf、yum 或 microdnf"
            fi
            ;;
        *)
            if command -v apt-get >/dev/null 2>&1; then
                run_step "已清理 APT 缓存" apt-get clean || true
            elif command -v apk >/dev/null 2>&1; then
                run_step "已清理 APK 缓存" apk cache clean || true
            elif command -v dnf >/dev/null 2>&1; then
                run_step "已清理 DNF 缓存" dnf clean all || true
            elif command -v yum >/dev/null 2>&1; then
                run_step "已清理 YUM 缓存" yum clean all || true
            elif command -v microdnf >/dev/null 2>&1; then
                run_step "已清理 MicroDNF 缓存" microdnf clean all || true
            else
                log_warn "未检测到受支持的软件包管理器"
            fi
            ;;
    esac

    if [ "$OS_ID" = ubuntu ] && command -v snap >/dev/null 2>&1; then
        clean_disabled_snap_revisions
    fi
}

clean_disabled_snap_revisions() {
    local snap_list
    local snap_data
    local snap_name
    local revision

    if ! snap_list=$(LC_ALL=C snap list --all 2>/dev/null); then
        log_warn "无法读取 Snap revision 列表，跳过 Snap 清理"
        return 0
    fi
    snap_data=$(printf '%s\n' "$snap_list" | \
        awk 'NR > 1 && $NF == "disabled" {print $1, $3}')

    if [ -z "$snap_data" ]; then
        log_info "没有需要清理的旧 Snap revision"
        return 0
    fi

    while IFS=' ' read -r snap_name revision; do
        [ -n "$snap_name" ] || continue
        [ -n "$revision" ] || continue
        run_step "已删除 Snap $snap_name revision $revision" \
            snap remove "$snap_name" "--revision=$revision" || true
    done <<EOF
$snap_data
EOF
}

clean_temp_fallback() {
    local temp_dir
    local age_minutes

    temp_dir=$1

    [ -d "$temp_dir" ] || return 0
    if ! command -v find >/dev/null 2>&1; then
        log_warn "未找到 find，跳过 $temp_dir 的兼容临时文件清理"
        return 0
    fi
    age_minutes=$((KEEP_DAYS * 1440))

    if [ "$DRY_RUN" -eq 1 ]; then
        log_dry_run "删除 $temp_dir 中超过 $KEEP_DAYS 天的普通文件、符号链接和空目录"
        return 0
    fi

    if find "$temp_dir" -xdev -depth -mindepth 1 \
        \( -type f -o -type l \) -mmin "+$age_minutes" -delete 2>/dev/null && \
       find "$temp_dir" -xdev -depth -mindepth 1 \
        -type d -empty -mmin "+$age_minutes" -delete 2>/dev/null; then
        COMPLETED_STEPS=$((COMPLETED_STEPS + 1))
        log_info "已清理 $temp_dir 中的过期项目"
    else
        FAILED_STEPS=$((FAILED_STEPS + 1))
        log_warn "清理 $temp_dir 时有部分项目失败"
    fi
}

clean_temporary_files() {
    log_info "清理临时文件..."

    if command -v systemd-tmpfiles >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        run_step "已按系统 tmpfiles 策略清理临时文件" systemd-tmpfiles --clean || true
    else
        clean_temp_fallback /tmp
        clean_temp_fallback /var/tmp
    fi
}

print_summary() {
    local after_free_kb
    local freed_kb

    after_free_kb=$(available_kb)
    case "$after_free_kb" in
        ''|*[!0-9]*) after_free_kb=0 ;;
    esac

    freed_kb=$((after_free_kb - BEFORE_FREE_KB))
    if [ "$freed_kb" -lt 0 ]; then
        freed_kb=0
    fi

    printf '\n'
    log_info "完成步骤: $COMPLETED_STEPS；清空历史文件: $CLEANED_FILES；失败: $FAILED_STEPS"
    if [ "$DRY_RUN" -eq 0 ]; then
        log_info "根文件系统可用空间约增加: $(format_kb "$freed_kb")"
    else
        log_info "预览完成，未修改任何文件"
    fi

    if [ "$CLEAN_HISTORY" -eq 1 ]; then
        log_warn "已打开的交互式 Shell 仍持有内存历史，退出时可能重新写回。"
        printf '%s\n' "  Bash 当前会话可执行: history -c && history -w"
        printf '%s\n' "  Zsh  当前会话可执行: fc -p /dev/null; : >! \"\$HISTFILE\""
    fi
}

main() {
    local start_time
    local end_time

    parse_args "$@"
    detect_os
    require_permissions
    confirm_run

    BEFORE_FREE_KB=$(available_kb)
    case "$BEFORE_FREE_KB" in
        ''|*[!0-9]*) BEFORE_FREE_KB=0 ;;
    esac
    start_time=$(date +%s)

    [ "$CLEAN_HISTORY" -eq 0 ] || clean_shell_histories
    [ "$CLEAN_LOGS" -eq 0 ] || clean_system_logs
    [ "$CLEAN_CACHE" -eq 0 ] || clean_package_cache
    [ "$CLEAN_TEMP" -eq 0 ] || clean_temporary_files

    end_time=$(date +%s)
    print_summary
    log_info "总耗时: $((end_time - start_time)) 秒"

    [ "$FAILED_STEPS" -eq 0 ]
}

main "$@"
