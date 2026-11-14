#!/usr/bin/env bash
# ==============================================================================
# ll.sh — 设置/安装 ll 别名与分组展示函数 (Grouped Directory Listing)
#
# 参考本机 Zsh 的 ll 格式，将目录内容按类别分组高亮展示：
#   -- Hidden Files --  (隐藏文件)
#   -- Hidden Dirs --   (隐藏目录)
#   -- Files --         (普通文件)
#   -- Dirs --          (普通目录)
#
# 使用方式:
#   1. 安装到当前用户或系统配置:
#      bash ll.sh               # 自动检测并写入 ~/.zshrc 和 ~/.bashrc (root 则同步写入系统级)
#      bash ll.sh --system      # 强制写入系统级 /etc/profile.d/ll.sh
#      bash ll.sh --uninstall   # 卸载已安装的配置
#      bash ll.sh --test        # 仅测试当前目录展示效果
#
#   2. 直接在当前终端临时生效:
#      source ll.sh
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. 核心定义：ll 函数与环境配置（Bash & Zsh 通用）
# ------------------------------------------------------------------------------

export LS_COLORS="di=38;5;141:ln=38;5;176:or=1;38;5;203:mi=1;38;5;203:ex=38;5;221:fi=38;5;252:*.tar=38;5;203:*.tgz=38;5;203:*.gz=38;5;203:*.bz2=38;5;203:*.xz=38;5;203:*.zst=38;5;203:*.zip=38;5;203:*.7z=38;5;203:*.rar=38;5;203:*.deb=38;5;203:*.rpm=38;5;203"
alias ls='ls --color=auto'
unalias ll 2>/dev/null || true

ll() {
    local dir="${1:-.}"

    # 多参数、选项参数或非目录时降级为普通 ls -lAh
    if [ "$#" -gt 1 ] || [ ! -d "$dir" ]; then
        command ls -lAh --color=auto "$@"
        return
    fi

    (
        cd -- "$dir" || return 1
        shopt -s nullglob 2>/dev/null || true
        setopt null_glob 2>/dev/null || true

        local -a hidden_files=() hidden_dirs=() normal_files=() normal_dirs=()
        local f

        for f in .*; do
            [ -e "$f" ] || [ -L "$f" ] || continue
            [ "$f" = "." ] || [ "$f" = ".." ] && continue
            if [ -d "$f" ]; then
                hidden_dirs+=("$f")
            else
                hidden_files+=("$f")
            fi
        done

        for f in *; do
            [ -e "$f" ] || [ -L "$f" ] || continue
            if [ -d "$f" ]; then
                normal_dirs+=("$f")
            else
                normal_files+=("$f")
            fi
        done

        local grey=$'\033[49m\033[38;5;244m'
        local reset=$'\033[0m'

        if [ ${#hidden_files[@]} -gt 0 ]; then
            printf "%b-- Hidden Files --%b\n" "$grey" "$reset"
            command ls -lhd --color=auto -- "${hidden_files[@]}"
        fi

        if [ ${#hidden_dirs[@]} -gt 0 ]; then
            printf "%b-- Hidden Dirs --%b\n" "$grey" "$reset"
            command ls -lhd --color=auto -- "${hidden_dirs[@]}"
        fi

        if [ ${#normal_files[@]} -gt 0 ]; then
            printf "%b-- Files --%b\n" "$grey" "$reset"
            command ls -lhd --color=auto -- "${normal_files[@]}"
        fi

        if [ ${#normal_dirs[@]} -gt 0 ]; then
            printf "%b-- Dirs --%b\n" "$grey" "$reset"
            command ls -lhd --color=auto -- "${normal_dirs[@]}"
        fi
    )
}

# ------------------------------------------------------------------------------
# 2. 判断是否是通过 source 载入当前 Shell
# ------------------------------------------------------------------------------

_is_sourced() {
    if [ -n "${ZSH_VERSION:-}" ]; then
        case "$ZSH_EVAL_CONTEXT" in *:file*) return 0;; *) return 1;; esac
    elif [ -n "${BASH_VERSION:-}" ]; then
        [ "${BASH_SOURCE[0]}" != "$0" ] && [ -n "${BASH_SOURCE[0]}" ] && return 0 || return 1
    else
        return 1
    fi
}

if _is_sourced; then
    return 0 2>/dev/null || exit 0
fi

# ------------------------------------------------------------------------------
# 3. 安装与管理逻辑 (当作为独立脚本执行时)
# ------------------------------------------------------------------------------

set -euo pipefail

# 颜色与输出辅助
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    COLOR_RED=$'\033[0;31m'
    COLOR_GREEN=$'\033[0;32m'
    COLOR_YELLOW=$'\033[1;33m'
    COLOR_CYAN=$'\033[0;36m'
    COLOR_RESET=$'\033[0m'
else
    COLOR_RED=""
    COLOR_GREEN=""
    COLOR_YELLOW=""
    COLOR_CYAN=""
    COLOR_RESET=""
fi

log() { printf "%b[INFO]%b %s\n" "${COLOR_CYAN}" "${COLOR_RESET}" "$*"; }
success() { printf "%b[OK]%b %s\n" "${COLOR_GREEN}" "${COLOR_RESET}" "$*"; }
warn() { printf "%b[WARN]%b %s\n" "${COLOR_YELLOW}" "${COLOR_RESET}" "$*"; }
error() { printf "%b[ERROR]%b %s\n" "${COLOR_RED}" "${COLOR_RESET}" "$*" >&2; }

MARK_BEGIN="# >>> ll-alias >>>"
MARK_END="# <<< ll-alias <<<"

emit_block() {
    cat <<'EOF'
# >>> ll-alias >>>
# ============================================================
# ll - grouped directory listing
# Order: hidden files -> hidden dirs -> files -> dirs
# Reference: Local machine zsh ll format
# ============================================================

alias ls='ls --color=auto'
unalias ll 2>/dev/null || true

export LS_COLORS="di=38;5;141:ln=38;5;176:or=1;38;5;203:mi=1;38;5;203:ex=38;5;221:fi=38;5;252:*.tar=38;5;203:*.tgz=38;5;203:*.gz=38;5;203:*.bz2=38;5;203:*.xz=38;5;203:*.zst=38;5;203:*.zip=38;5;203:*.7z=38;5;203:*.rar=38;5;203:*.deb=38;5;203:*.rpm=38;5;203"

ll() {
    local dir="${1:-.}"

    if [ "$#" -gt 1 ] || [ ! -d "$dir" ]; then
        command ls -lAh --color=auto "$@"
        return
    fi

    (
        cd -- "$dir" || return 1
        shopt -s nullglob 2>/dev/null || true
        setopt null_glob 2>/dev/null || true

        local -a hidden_files=() hidden_dirs=() normal_files=() normal_dirs=()
        local f

        for f in .*; do
            [ -e "$f" ] || [ -L "$f" ] || continue
            [ "$f" = "." ] || [ "$f" = ".." ] && continue
            if [ -d "$f" ]; then
                hidden_dirs+=("$f")
            else
                hidden_files+=("$f")
            fi
        done

        for f in *; do
            [ -e "$f" ] || [ -L "$f" ] || continue
            if [ -d "$f" ]; then
                normal_dirs+=("$f")
            else
                normal_files+=("$f")
            fi
        done

        local grey=$'\033[49m\033[38;5;244m'
        local reset=$'\033[0m'

        if [ ${#hidden_files[@]} -gt 0 ]; then
            printf "%b-- Hidden Files --%b\n" "$grey" "$reset"
            command ls -lhd --color=auto -- "${hidden_files[@]}"
        fi

        if [ ${#hidden_dirs[@]} -gt 0 ]; then
            printf "%b-- Hidden Dirs --%b\n" "$grey" "$reset"
            command ls -lhd --color=auto -- "${hidden_dirs[@]}"
        fi

        if [ ${#normal_files[@]} -gt 0 ]; then
            printf "%b-- Files --%b\n" "$grey" "$reset"
            command ls -lhd --color=auto -- "${normal_files[@]}"
        fi

        if [ ${#normal_dirs[@]} -gt 0 ]; then
            printf "%b-- Dirs --%b\n" "$grey" "$reset"
            command ls -lhd --color=auto -- "${normal_dirs[@]}"
        fi
    )
}
# <<< ll-alias <<<
EOF
}

strip_block() {
    local file="$1"
    [ -f "$file" ] || return 0
    sed -i "/^# >>> ll-alias >>>\$/,/^# <<< ll-alias <<<\$/d" "$file"
}

upsert_file() {
    local target="$1"
    local dir
    dir="$(dirname "$target")"
    [ -d "$dir" ] || mkdir -p "$dir"
    [ -f "$target" ] || touch "$target"

    strip_block "$target"

    # 若末尾无换行则追加换行
    if [ -s "$target" ] && [ "$(tail -c 1 "$target" 2>/dev/null || true)" != "" ]; then
        echo "" >> "$target"
    fi

    emit_block >> "$target"
    success "已配置: $target"
}

remove_file_block() {
    local target="$1"
    if [ -f "$target" ]; then
        if grep -q "^# >>> ll-alias >>>\$" "$target" 2>/dev/null; then
            strip_block "$target"
            success "已移除配置: $target"
        fi
    fi
}

do_install() {
    local system_wide="${1:-0}"
    log "开始设置 ll 别名与格式配置..."

    local user_home="${HOME:-/root}"
    local targets=()

    # 1. 用户级配置
    if [ -f "${user_home}/.zshrc" ] || command -v zsh >/dev/null 2>&1; then
        targets+=("${user_home}/.zshrc")
    fi
    if [ -f "${user_home}/.bashrc" ] || command -v bash >/dev/null 2>&1; then
        targets+=("${user_home}/.bashrc")
    fi

    for t in "${targets[@]}"; do
        upsert_file "$t"
    done

    # 2. 系统级配置 (root 或指定 --system)
    if [ "$system_wide" -eq 1 ] || [ "${EUID:-$(id -u)}" -eq 0 ]; then
        if [ -d "/etc/profile.d" ]; then
            upsert_file "/etc/profile.d/ll.sh"
            chmod 644 "/etc/profile.d/ll.sh" 2>/dev/null || true
        fi
    fi

    printf '\n'
    success "ll 别名配置完成！"
    log "提示：新开终端或执行以下命令即可立即生效："
    if [ -n "${ZSH_VERSION:-}" ] || [ "${SHELL##*/}" = "zsh" ]; then
        printf "  source ~/.zshrc\n"
    else
        printf "  source ~/.bashrc\n"
    fi
}

do_uninstall() {
    log "正在卸载 ll 别名配置..."
    local user_home="${HOME:-/root}"
    remove_file_block "${user_home}/.zshrc"
    remove_file_block "${user_home}/.bashrc"
    remove_file_block "/etc/profile.d/ll.sh"
    success "卸载完成。"
}

show_help() {
    cat <<EOF
用法: ${0##*/} [选项]

选项:
  -i, --install      设置并安装 ll 别名到 ~/.zshrc, ~/.bashrc 与 /etc/profile.d (默认)
  -s, --system       仅写入系统全局配置 (/etc/profile.d/ll.sh)
  -u, --uninstall    从所有配置文件中移除已安装的 ll 配置
  -t, --test [目录]  测试运行 ll 分组格式 (默认当前目录)
  -h, --help         显示帮助信息

说明:
  也可以通过 source 命令直接在当前终端临时生效：
    source ${0##*/}
EOF
}

# 命令行解析
ACTION="install"
TARGET_DIR="."
SYSTEM_ONLY=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        -i|--install)
            ACTION="install"
            shift
            ;;
        -s|--system)
            ACTION="install"
            SYSTEM_ONLY=1
            shift
            ;;
        -u|--uninstall)
            ACTION="uninstall"
            shift
            ;;
        -t|--test)
            ACTION="test"
            if [ "$#" -gt 1 ] && [[ "$2" != -* ]]; then
                TARGET_DIR="$2"
                shift
            fi
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            error "未知参数: $1"
            show_help
            exit 1
            ;;
    esac
done

case "$ACTION" in
    install)
        do_install "$SYSTEM_ONLY"
        ;;
    uninstall)
        do_uninstall
        ;;
    test)
        log "测试目录: $TARGET_DIR"
        ll "$TARGET_DIR"
        ;;
esac
