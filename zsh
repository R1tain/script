#!/usr/bin/env bash

# ============================================================
# Zsh Server Environment Manager
#
# Debian / Ubuntu
#
# Components:
#   - Zsh
#   - zsh-autosuggestions
#   - zsh-syntax-highlighting
#   - zsh-completions
#   - extract
#   - Starship
#
# No:
#   - Oh My Zsh
#   - Powerlevel10k
#
# Usage:
#   ./zsh-manager.sh
#
# ============================================================

set -Eeuo pipefail

readonly APP_NAME="Zsh Server Environment Manager"
readonly APP_VERSION="2.0.1"

readonly ZSHRC="${HOME}/.zshrc"
readonly ZSH_CONFIG_DIR="${HOME}/.config/zsh"
readonly ZSH_PLUGIN_DIR="${HOME}/.local/share/zsh/plugins"

readonly STARSHIP_CONFIG="${HOME}/.config/starship.toml"

readonly MANAGER_DIR="${HOME}/.local/share/zsh-manager"
readonly BACKUP_DIR="${MANAGER_DIR}/backups"
readonly STATE_FILE="${MANAGER_DIR}/state"

readonly MARK_BEGIN="# >>> zsh-manager >>>"
readonly MARK_END="# <<< zsh-manager <<<"

SUDO=""

# ============================================================
# Colors
# ============================================================

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    DIM='\033[2m'
    RESET='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    BOLD=''
    DIM=''
    RESET=''
fi

# ============================================================
# Output
# ============================================================

log() {
    printf '%b[INFO]%b %s\n' "${BLUE}" "${RESET}" "$*"
}

success() {
    printf '%b[ OK ]%b %s\n' "${GREEN}" "${RESET}" "$*"
}

warn() {
    printf '%b[WARN]%b %s\n' "${YELLOW}" "${RESET}" "$*"
}

error() {
    printf '%b[ERROR]%b %s\n' "${RED}" "${RESET}" "$*" >&2
}

# ============================================================
# Error handling
#
# NOTE: `return_to_menu` did not exist in the previous version,
# which meant any command failure under `set -e` would trigger
# a "command not found" error inside the trap itself. We just
# report the error here; each menu action already returns to
# main_menu naturally once the function exits.
# ============================================================

trap 'error "执行过程中发生错误，位于第 ${LINENO} 行。"' ERR

# ============================================================
# Privilege
# ============================================================

setup_sudo() {
    if [[ "${EUID}" -eq 0 ]]; then
        SUDO=""
        return
    fi

    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    else
        error "当前用户不是 root，且系统没有 sudo。"
        return 1
    fi
}

run_root() {
    if [[ -n "${SUDO}" ]]; then
        sudo "$@"
    else
        "$@"
    fi
}

# ============================================================
# OS
# ============================================================

detect_os() {
    [[ -r /etc/os-release ]] || {
        error "无法读取 /etc/os-release"
        return 1
    }

    # shellcheck disable=SC1091
    source /etc/os-release

    case "${ID:-}" in
        debian|ubuntu)
            ;;
        *)
            error "当前仅支持 Debian / Ubuntu。"
            error "检测到：${ID:-unknown}"
            return 1
            ;;
    esac
}

# ============================================================
# User / environment
# ============================================================

get_current_shell() {
    printf '%s' "${SHELL:-unknown}"
}

get_zsh_path() {
    command -v zsh 2>/dev/null || true
}

get_starship_path() {
    command -v starship 2>/dev/null || true
}

# ============================================================
# Directory
# ============================================================

create_directories() {
    mkdir -p \
        "${ZSH_CONFIG_DIR}" \
        "${ZSH_PLUGIN_DIR}" \
        "${BACKUP_DIR}" \
        "${MANAGER_DIR}" \
        "$(dirname "${STARSHIP_CONFIG}")"
}

# ============================================================
# Backup
# ============================================================

backup_file() {
    local file="$1"

    [[ -e "${file}" ]] || return 0

    create_directories

    local timestamp
    # Include nanoseconds so two backups in the same second never
    # collide/overwrite each other.
    timestamp="$(date '+%Y%m%d-%H%M%S-%N')"

    local base
    base="$(basename "${file}")"

    local backup
    backup="${BACKUP_DIR}/${base}.${timestamp}.bak"

    cp -a "${file}" "${backup}"

    success "已备份：${backup}"
}

# ============================================================
# APT
# ============================================================

apt_update() {
    log "更新 APT 软件索引..."

    run_root env DEBIAN_FRONTEND=noninteractive \
        apt-get update -y
}

apt_install() {
    run_root env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y --no-install-recommends "$@"
}

# ============================================================
# Zsh
# ============================================================

install_zsh() {
    if command -v zsh >/dev/null 2>&1; then
        success "Zsh 已安装：$(zsh --version)"
        return
    fi

    log "安装 Zsh..."

    apt_install zsh

    success "Zsh 安装完成"
}

# ============================================================
# Base dependencies
# ============================================================

install_dependencies() {
    log "安装基础依赖..."

    apt_install \
        ca-certificates \
        curl \
        git \
        unzip \
        gzip \
        bzip2 \
        xz-utils \
        tar \
        zstd

    success "基础依赖安装完成"
}

# ============================================================
# Archive tools
# ============================================================

install_archive_tools() {
    log "检查压缩格式支持..."

    if ! command -v 7z >/dev/null 2>&1 &&
       ! command -v 7zz >/dev/null 2>&1; then

        if apt-cache show 7zip >/dev/null 2>&1; then
            apt_install 7zip
        elif apt-cache show p7zip-full >/dev/null 2>&1; then
            apt_install p7zip-full
        else
            warn "系统仓库没有找到 7z 软件包。"
        fi
    fi

    if ! command -v unrar >/dev/null 2>&1; then
        if apt-cache show unrar-free >/dev/null 2>&1; then
            apt_install unrar-free
        else
            warn "系统仓库没有找到 unrar-free。"
        fi
    fi

    success "压缩格式支持检查完成"
}

# ============================================================
# Starship
# ============================================================

install_starship() {
    if command -v starship >/dev/null 2>&1; then
        success "Starship 已安装：$(starship --version | head -n1)"
        return
    fi

    log "安装 Starship..."

    curl \
        --fail \
        --silent \
        --show-error \
        --proto '=https' \
        --tlsv1.2 \
        https://starship.rs/install.sh \
        | sh -s -- -y

    command -v starship >/dev/null 2>&1 || {
        error "Starship 安装失败。"
        return 1
    }

    success "Starship 安装完成"
}

update_starship() {
    if ! command -v starship >/dev/null 2>&1; then
        install_starship
        return
    fi

    log "更新 Starship..."

    curl \
        --fail \
        --silent \
        --show-error \
        --proto '=https' \
        --tlsv1.2 \
        https://starship.rs/install.sh \
        | sh -s -- -y

    success "Starship 更新完成"
}

# ============================================================
# Plugin definitions
# ============================================================

plugin_url() {
    case "$1" in
        autosuggestions)
            printf '%s' \
                "https://github.com/zsh-users/zsh-autosuggestions.git"
            ;;
        syntax-highlighting)
            printf '%s' \
                "https://github.com/zsh-users/zsh-syntax-highlighting.git"
            ;;
        completions)
            printf '%s' \
                "https://github.com/zsh-users/zsh-completions.git"
            ;;
        *)
            return 1
            ;;
    esac
}

plugin_dir() {
    case "$1" in
        autosuggestions)
            printf '%s' \
                "${ZSH_PLUGIN_DIR}/zsh-autosuggestions"
            ;;
        syntax-highlighting)
            printf '%s' \
                "${ZSH_PLUGIN_DIR}/zsh-syntax-highlighting"
            ;;
        completions)
            printf '%s' \
                "${ZSH_PLUGIN_DIR}/zsh-completions"
            ;;
        *)
            return 1
            ;;
    esac
}

plugin_display_name() {
    case "$1" in
        autosuggestions)
            printf '%s' "zsh-autosuggestions"
            ;;
        syntax-highlighting)
            printf '%s' "zsh-syntax-highlighting"
            ;;
        completions)
            printf '%s' "zsh-completions"
            ;;
        *)
            printf '%s' "$1"
            ;;
    esac
}

# ============================================================
# Plugin operations
# ============================================================

install_plugin() {
    local name="$1"

    local url
    url="$(plugin_url "${name}")"

    local dir
    dir="$(plugin_dir "${name}")"

    if [[ -d "${dir}/.git" ]]; then
        success "$(plugin_display_name "${name}") 已安装"
        return
    fi

    log "安装 $(plugin_display_name "${name}")..."

    rm -rf "${dir}"

    git clone \
        --depth=1 \
        "${url}" \
        "${dir}"

    success "$(plugin_display_name "${name}") 安装完成"
}

remove_plugin() {
    local name="$1"

    local dir
    dir="$(plugin_dir "${name}")"

    if [[ ! -d "${dir}" ]]; then
        warn "$(plugin_display_name "${name}") 未安装"
        return
    fi

    rm -rf "${dir}"

    success "$(plugin_display_name "${name}") 已删除"
}

update_plugin() {
    local name="$1"

    local dir
    dir="$(plugin_dir "${name}")"

    if [[ ! -d "${dir}/.git" ]]; then
        warn "$(plugin_display_name "${name}") 未安装"
        return
    fi

    log "更新 $(plugin_display_name "${name}")..."

    git -C "${dir}" fetch --depth=1 origin

    local branch
    branch="$(git -C "${dir}" symbolic-ref --short HEAD 2>/dev/null || true)"

    if [[ -n "${branch}" ]]; then
        git -C "${dir}" reset --hard "origin/${branch}" >/dev/null 2>&1 \
            || git -C "${dir}" pull --ff-only
    else
        git -C "${dir}" pull --ff-only
    fi

    success "$(plugin_display_name "${name}") 更新完成"
}

install_all_plugins() {
    install_plugin autosuggestions
    install_plugin syntax-highlighting
    install_plugin completions
}

update_all_plugins() {
    update_plugin autosuggestions
    update_plugin syntax-highlighting
    update_plugin completions
}

# ============================================================
# Extract
# ============================================================

write_extract_function() {
    mkdir -p "${ZSH_CONFIG_DIR}"

    cat > "${ZSH_CONFIG_DIR}/extract.zsh" <<'EOF'
# ============================================================
# Universal archive extraction
# ============================================================

extract() {
    if [[ $# -ne 1 ]]; then
        print "用法：extract <压缩文件>"
        return 2
    fi

    local archive="$1"

    if [[ ! -f "$archive" ]]; then
        print "extract: 文件不存在：$archive"
        return 1
    fi

    case "$archive" in

        *.tar.gz|*.tgz)
            command tar -xzf "$archive"
            ;;

        *.tar.bz2|*.tbz|*.tbz2)
            command tar -xjf "$archive"
            ;;

        *.tar.xz|*.txz)
            command tar -xJf "$archive"
            ;;

        *.tar.zst|*.tzst)
            command tar --zstd -xf "$archive"
            ;;

        *.tar)
            command tar -xf "$archive"
            ;;

        *.zip)
            command unzip "$archive"
            ;;

        *.7z)
            if command -v 7z >/dev/null 2>&1; then
                command 7z x "$archive"
            elif command -v 7zz >/dev/null 2>&1; then
                command 7zz x "$archive"
            else
                print "extract: 未安装 7z / 7zz"
                return 1
            fi
            ;;

        *.rar)
            if command -v unrar >/dev/null 2>&1; then
                command unrar x "$archive"
            elif command -v 7z >/dev/null 2>&1; then
                command 7z x "$archive"
            elif command -v 7zz >/dev/null 2>&1; then
                command 7zz x "$archive"
            else
                print "extract: 未安装 unrar / 7z / 7zz"
                return 1
            fi
            ;;

        *.gz)
            command gunzip "$archive"
            ;;

        *.bz2)
            command bunzip2 "$archive"
            ;;

        *.xz)
            command unxz "$archive"
            ;;

        *.zst)
            command unzstd "$archive"
            ;;

        *)
            print "extract: 不支持的压缩格式：$archive"
            return 1
            ;;

    esac
}
EOF

    success "extract 配置完成"
}

# ============================================================
# ll (colored, grouped listing; colors follow tmux config)
# ============================================================

write_ll_function() {
    mkdir -p "${ZSH_CONFIG_DIR}"

    cat > "${ZSH_CONFIG_DIR}/ll.zsh" <<'EOF'
# ============================================================
# ll - grouped directory listing
# Order: hidden files -> hidden dirs -> files -> dirs
# 配色参考 tmux：cyan(活动边框) green(状态栏)
#               yellow(消息) blue(display-panes)
# ============================================================

alias ls='ls --color=auto'

# 条目本身的颜色：目录 bold cyan / 链接 yellow / 可执行 green
export LS_COLORS="di=1;36:ln=0;33:ex=0;32:or=1;31:*.tar=0;35:*.gz=0;35:*.zip=0;35:*.xz=0;35:*.zst=0;35:*.7z=0;35:*.rar=0;35"

ll() {
    emulate -L zsh
    setopt local_options null_glob

    local dir="${1:-.}"

    if [[ ! -d "$dir" ]]; then
        command ls -lAh --color=auto -- "$dir"
        return
    fi

    (
        cd -- "$dir" || return 1

        local -a hidden_dirs normal_dirs hidden_files normal_files
        hidden_dirs=(.*(N/))
        normal_dirs=(*(N/))
        hidden_files=(.*(N^/))
        normal_files=(*(N^/))

        local blue=$'\033[1;34m' cyan=$'\033[1;36m'
        local yellow=$'\033[1;33m' green=$'\033[1;32m'
        local reset=$'\033[0m'

        if (( ${#hidden_files} )); then
            print "${yellow}-- Hidden Files --${reset}"
            command ls -lhd --color=auto -- "${hidden_files[@]}"
        fi

        if (( ${#hidden_dirs} )); then
            print "${blue}-- Hidden Dirs --${reset}"
            command ls -lhd --color=auto -- "${hidden_dirs[@]}"
        fi

        if (( ${#normal_files} )); then
            print "${green}-- Files --${reset}"
            command ls -lhd --color=auto -- "${normal_files[@]}"
        fi

        if (( ${#normal_dirs} )); then
            print "${cyan}-- Dirs --${reset}"
            command ls -lhd --color=auto -- "${normal_dirs[@]}"
        fi
    )
}
EOF

    success "ll 配置完成"
}

# ============================================================
# Starship fixed configuration
# ============================================================

write_starship_config() {
    mkdir -p "$(dirname "${STARSHIP_CONFIG}")"

    cat > "${STARSHIP_CONFIG}" <<'EOF'
# ============================================================
# Starship
# Managed by zsh-manager
# ============================================================

add_newline = false

format = """
$hostname\
$username\
$directory\
$git_branch\
$git_status\
$cmd_duration
$character"""

[username]
show_always = true
format = "[$user]($style)@"
style_user = "bold"

[hostname]
ssh_only = false
format = "[$hostname]($style) "
style = "bold"

[directory]
format = "[$path]($style)"
style = "bold cyan"
truncation_length = 3
truncate_to_repo = false

[git_branch]
format = " [$branch]($style)"
style = "bold purple"

[git_status]
format = " [$all_status$ahead_behind]($style)"
style = "bold red"

[cmd_duration]
min_time = 2000
format = " [$duration]($style)"
style = "bold yellow"

[character]
success_symbol = "❯"
error_symbol = "❯"
vimcmd_symbol = "❮"
EOF

    chmod 0644 "${STARSHIP_CONFIG}"

    success "Starship 固定配置已写入"
}

# ============================================================
# Zsh configuration
# ============================================================

write_zshrc() {
    create_directories

    if [[ -f "${ZSHRC}" ]]; then
        backup_file "${ZSHRC}"
    fi

    local tmp
    tmp="$(mktemp)"

    if [[ -f "${ZSHRC}" ]]; then
        awk \
            -v begin="${MARK_BEGIN}" \
            -v end="${MARK_END}" '
            $0 == begin { skip=1; next }
            $0 == end   { skip=0; next }
            !skip { print }
        ' "${ZSHRC}" > "${tmp}"
    else
        : > "${tmp}"
    fi

    cat >> "${tmp}" <<EOF

${MARK_BEGIN}

# ============================================================
# Zsh Server Environment
# Managed by zsh-manager
# ============================================================

export STARSHIP_CONFIG="${STARSHIP_CONFIG}"

# ------------------------------------------------------------
# History
# ------------------------------------------------------------

HISTFILE="\${HOME}/.zsh_history"
HISTSIZE=100000
SAVEHIST=100000

setopt APPEND_HISTORY
setopt SHARE_HISTORY
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_REDUCE_BLANKS
setopt HIST_VERIFY

# ------------------------------------------------------------
# Navigation
# ------------------------------------------------------------

setopt AUTO_CD
setopt AUTO_PUSHD
setopt PUSHD_IGNORE_DUPS

# ------------------------------------------------------------
# Completion
# ------------------------------------------------------------

# zsh-completions must be added before compinit.
if [[ -d "${ZSH_PLUGIN_DIR}/zsh-completions/src" ]]; then
    fpath=("${ZSH_PLUGIN_DIR}/zsh-completions/src" \$fpath)
fi

autoload -Uz compinit

# Only rebuild the completion cache once every 24h instead of on
# every shell start; falls back to a full compinit the first time
# or if the dump file is missing/stale.
_zcompdump="\${ZDOTDIR:-\${HOME}}/.zcompdump"
if [[ -n "\${_zcompdump}"(#qN.mh+24) ]]; then
    compinit
else
    compinit -C
fi
unset _zcompdump

# ------------------------------------------------------------
# Autosuggestions
# ------------------------------------------------------------

if [[ -f "${ZSH_PLUGIN_DIR}/zsh-autosuggestions/zsh-autosuggestions.zsh" ]]; then
    source "${ZSH_PLUGIN_DIR}/zsh-autosuggestions/zsh-autosuggestions.zsh"
fi

# ------------------------------------------------------------
# Syntax highlighting
# Must be loaded near the end.
# ------------------------------------------------------------

if [[ -f "${ZSH_PLUGIN_DIR}/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" ]]; then
    source "${ZSH_PLUGIN_DIR}/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
fi

# ------------------------------------------------------------
# extract
# ------------------------------------------------------------

if [[ -f "${ZSH_CONFIG_DIR}/extract.zsh" ]]; then
    source "${ZSH_CONFIG_DIR}/extract.zsh"
fi

# ------------------------------------------------------------
# ll
# ------------------------------------------------------------

if [[ -f "${ZSH_CONFIG_DIR}/ll.zsh" ]]; then
    source "${ZSH_CONFIG_DIR}/ll.zsh"
fi

# ------------------------------------------------------------
# Starship
# ------------------------------------------------------------

if command -v starship >/dev/null 2>&1; then
    eval "\$(starship init zsh)"
fi

${MARK_END}
EOF

    mv "${tmp}" "${ZSHRC}"

    chmod 0644 "${ZSHRC}"

    success ".zshrc 配置完成"
}

# ============================================================
# State
# ============================================================

save_state() {
    mkdir -p "${MANAGER_DIR}"

    cat > "${STATE_FILE}" <<EOF
VERSION=${APP_VERSION}
INSTALLED_AT=$(date '+%Y-%m-%d %H:%M:%S')
ZSHRC=${ZSHRC}
STARSHIP_CONFIG=${STARSHIP_CONFIG}
PLUGIN_DIR=${ZSH_PLUGIN_DIR}
EOF
}

# ============================================================
# Full installation
# ============================================================

install_environment() {
    clear

    print_header "安装 / 初始化 Zsh 环境"

    detect_os
    setup_sudo
    create_directories

    printf '\n'

    log "开始安装..."

    apt_update

    install_dependencies
    install_zsh
    install_archive_tools
    install_starship

    install_all_plugins

    write_extract_function
    write_ll_function
    write_starship_config
    write_zshrc

    save_state

    printf '\n'
    success "Zsh 环境安装完成"

    printf '\n'
    printf '%b当前默认 Shell：%b%s%b\n' \
        "${BOLD}" "${CYAN}" "$(get_current_shell)" "${RESET}"

    printf '\n'
    printf '%b是否现在将默认 Shell 切换为 Zsh？%b\n' \
        "${YELLOW}" "${RESET}"

    printf '  1) 是\n'
    printf '  2) 否\n'

    read -r -p "请选择 [1-2]: " choice

    case "${choice}" in
        1)
            set_default_shell
            ;;
        2)
            warn "保持当前默认 Shell 不变"
            ;;
        *)
            warn "输入无效，保持当前默认 Shell 不变"
            ;;
    esac

    printf '\n'
    success "安装流程完成"

    printf '\n'
    printf '%b安装完成%b\n\n' "${BOLD}" "${RESET}"
    printf '  1) 立即进入 Zsh\n'
    printf '  2) 返回管理菜单\n'

    printf '\n'
    read -r -p "请选择 [1-2]: " enter_choice

    if [[ "${enter_choice}" == "1" ]]; then
        exec zsh
    fi
}

# ============================================================
# Default shell
# ============================================================

set_default_shell() {
    command -v zsh >/dev/null 2>&1 || {
        error "Zsh 尚未安装。"
        return 1
    }

    local zsh_path
    zsh_path="$(command -v zsh)"

    if [[ "${SHELL:-}" == "${zsh_path}" ]]; then
        success "当前默认 Shell 已经是 Zsh"
        return
    fi

    if ! grep -qxF "${zsh_path}" /etc/shells 2>/dev/null; then
        run_root sh -c "echo '${zsh_path}' >> /etc/shells"
    fi

    if command -v chsh >/dev/null 2>&1; then
        chsh -s "${zsh_path}"
    else
        run_root usermod -s "${zsh_path}" "${USER}"
    fi

    success "默认 Shell 已切换为 Zsh"
    warn "重新 SSH 登录后完全生效。"
}

# ============================================================
# Restore Bash
# ============================================================

restore_bash_shell() {
    local bash_path

    bash_path="$(command -v bash 2>/dev/null || true)"

    if [[ -z "${bash_path}" ]]; then
        error "找不到 Bash。"
        return 1
    fi

    if [[ "${SHELL:-}" == "${bash_path}" ]]; then
        success "当前默认 Shell 已经是 Bash"
        return
    fi

    if ! grep -qxF "${bash_path}" /etc/shells 2>/dev/null; then
        run_root sh -c "echo '${bash_path}' >> /etc/shells"
    fi

    if command -v chsh >/dev/null 2>&1; then
        chsh -s "${bash_path}"
    else
        run_root usermod -s "${bash_path}" "${USER}"
    fi

    success "默认 Shell 已恢复为 Bash"
    warn "重新 SSH 登录后完全生效。"
}

# ============================================================
# Repair
# ============================================================

repair_environment() {
    clear

    print_header "修复 / 重建配置"

    setup_sudo
    create_directories

    # Refresh APT indexes first so install_archive_tools' `apt-cache
    # show` checks (7zip / unrar-free) don't silently fail on a stale
    # or empty package cache.
    apt_update

    log "检查 Zsh..."
    install_zsh

    log "检查压缩工具..."
    install_archive_tools

    log "检查 Starship..."
    install_starship

    log "检查插件..."
    install_all_plugins

    log "重建 extract..."
    write_extract_function
    write_ll_function

    log "重建 Starship 配置..."
    write_starship_config

    log "重建 .zshrc..."
    write_zshrc

    save_state

    printf '\n'
    success "配置修复完成"

    pause
}

# ============================================================
# Update
# ============================================================

update_environment() {
    clear

    print_header "更新全部组件"

    setup_sudo

    if ! command -v zsh >/dev/null 2>&1; then
        warn "Zsh 未安装。"
        pause
        return
    fi

    update_starship

    update_all_plugins

    write_extract_function
    write_ll_function
    write_starship_config
    write_zshrc

    save_state

    printf '\n'
    success "全部组件更新完成"

    pause
}

# ============================================================
# Plugin status
# ============================================================

plugin_status() {
    printf '\n'
    printf '%b插件状态%b\n' "${BOLD}" "${RESET}"
    printf '%b----------------------------------------%b\n' \
        "${DIM}" "${RESET}"

    local name
    local dir

    for name in autosuggestions syntax-highlighting completions; do
        dir="$(plugin_dir "${name}")"

        if [[ -d "${dir}/.git" ]]; then
            printf '  %-28s %b已安装%b\n' \
                "$(plugin_display_name "${name}")" \
                "${GREEN}" \
                "${RESET}"
        else
            printf '  %-28s %b未安装%b\n' \
                "$(plugin_display_name "${name}")" \
                "${YELLOW}" \
                "${RESET}"
        fi
    done

    printf '\n'
}

# ============================================================
# Plugin menu
# ============================================================

plugin_menu() {
    while true; do
        clear

        print_header "插件管理"

        plugin_status

        printf '%b请选择操作：%b\n\n' \
            "${BOLD}" "${RESET}"

        printf '  1) 安装全部插件\n'
        printf '  2) 更新全部插件\n'
        printf '  3) 安装指定插件\n'
        printf '  4) 删除指定插件\n'
        printf '  5) 查看插件状态\n'
        printf '  6) 返回主菜单\n'

        printf '\n'

        read -r -p "请选择 [1-6]: " choice

        case "${choice}" in
            1)
                install_all_plugins
                write_zshrc
                pause
                ;;
            2)
                update_all_plugins
                pause
                ;;
            3)
                select_plugin_install
                ;;
            4)
                select_plugin_remove
                ;;
            5)
                pause
                ;;
            6)
                return
                ;;
            *)
                warn "无效选择"
                sleep 1
                ;;
        esac
    done
}

# ============================================================
# Select plugin install
# ============================================================

select_plugin_install() {
    clear

    print_header "安装插件"

    printf '  1) zsh-autosuggestions\n'
    printf '  2) zsh-syntax-highlighting\n'
    printf '  3) zsh-completions\n'
    printf '  4) 全部\n'
    printf '  5) 返回\n'

    printf '\n'

    read -r -p "请选择 [1-5]: " choice

    case "${choice}" in
        1)
            install_plugin autosuggestions
            write_zshrc
            pause
            ;;
        2)
            install_plugin syntax-highlighting
            write_zshrc
            pause
            ;;
        3)
            install_plugin completions
            write_zshrc
            pause
            ;;
        4)
            install_all_plugins
            write_zshrc
            pause
            ;;
        5)
            return
            ;;
        *)
            warn "无效选择"
            sleep 1
            ;;
    esac
}

# ============================================================
# Select plugin remove
# ============================================================

select_plugin_remove() {
    clear

    print_header "删除插件"

    printf '  1) zsh-autosuggestions\n'
    printf '  2) zsh-syntax-highlighting\n'
    printf '  3) zsh-completions\n'
    printf '  4) 返回\n'

    printf '\n'

    read -r -p "请选择 [1-4]: " choice

    case "${choice}" in
        1)
            remove_plugin autosuggestions
            write_zshrc
            pause
            ;;
        2)
            remove_plugin syntax-highlighting
            write_zshrc
            pause
            ;;
        3)
            remove_plugin completions
            write_zshrc
            pause
            ;;
        4)
            return
            ;;
        *)
            warn "无效选择"
            sleep 1
            ;;
    esac
}

# ============================================================
# Status
# ============================================================

show_status() {
    clear

    print_header "系统状态"

    detect_os || true

    printf '\n'

    printf '  %-18s %s\n' "用户" "${USER}"
    printf '  %-18s %s\n' "HOME" "${HOME}"
    printf '  %-18s %s\n' "当前 Shell" "$(get_current_shell)"

    printf '\n'

    if command -v zsh >/dev/null 2>&1; then
        printf '  %-18s %b%s%b\n' \
            "Zsh" \
            "${GREEN}" \
            "$(zsh --version)" \
            "${RESET}"
    else
        printf '  %-18s %b未安装%b\n' \
            "Zsh" \
            "${RED}" \
            "${RESET}"
    fi

    if command -v starship >/dev/null 2>&1; then
        printf '  %-18s %b%s%b\n' \
            "Starship" \
            "${GREEN}" \
            "$(starship --version | head -n1)" \
            "${RESET}"
    else
        printf '  %-18s %b未安装%b\n' \
            "Starship" \
            "${RED}" \
            "${RESET}"
    fi

    if command -v tmux >/dev/null 2>&1; then
        printf '  %-18s %b已安装%b\n' \
            "tmux" \
            "${GREEN}" \
            "${RESET}"
    else
        printf '  %-18s %b未安装%b\n' \
            "tmux" \
            "${YELLOW}" \
            "${RESET}"
    fi

    printf '\n'

    if [[ -f "${ZSHRC}" ]]; then
        printf '  %-18s %bOK%b\n' \
            ".zshrc" \
            "${GREEN}" \
            "${RESET}"
    else
        printf '  %-18s %b不存在%b\n' \
            ".zshrc" \
            "${YELLOW}" \
            "${RESET}"
    fi

    if [[ -f "${STARSHIP_CONFIG}" ]]; then
        printf '  %-18s %bOK%b\n' \
            "Starship 配置" \
            "${GREEN}" \
            "${RESET}"
    else
        printf '  %-18s %b不存在%b\n' \
            "Starship 配置" \
            "${YELLOW}" \
            "${RESET}"
    fi

    if [[ -f "${ZSH_CONFIG_DIR}/extract.zsh" ]]; then
        printf '  %-18s %bOK%b\n' \
            "extract" \
            "${GREEN}" \
            "${RESET}"
    else
        printf '  %-18s %b不存在%b\n' \
            "extract" \
            "${YELLOW}" \
            "${RESET}"
    fi

    printf '\n'

    plugin_status

    pause
}

# ============================================================
# Uninstall
# ============================================================

uninstall_environment() {
    clear

    print_header "卸载 Zsh 环境"

    printf '%b注意：%b\n\n' "${YELLOW}" "${RESET}"

    printf '  将删除：\n'
    printf '    - zsh-manager 配置\n'
    printf '    - 三个 Zsh 插件\n'
    printf '    - extract 配置\n'
    printf '    - Starship 固定配置\n'
    printf '\n'

    printf '  将保留：\n'
    printf '    - Zsh 软件包\n'
    printf '    - Starship 软件包\n'
    printf '    - Bash 软件包\n'
    printf '\n'

    printf '%b你的 .zshrc 会先自动备份。%b\n\n' \
        "${CYAN}" "${RESET}"

    read -r -p "确定继续卸载吗？输入 YES 确认： " confirm

    if [[ "${confirm}" != "YES" ]]; then
        warn "已取消卸载"
        pause
        return
    fi

    if [[ -f "${ZSHRC}" ]]; then
        backup_file "${ZSHRC}"
    fi

    if [[ -f "${STARSHIP_CONFIG}" ]]; then
        backup_file "${STARSHIP_CONFIG}"
    fi

    # Remove managed section from .zshrc
    if [[ -f "${ZSHRC}" ]]; then
        local tmp
        tmp="$(mktemp)"

        awk \
            -v begin="${MARK_BEGIN}" \
            -v end="${MARK_END}" '
            $0 == begin { skip=1; next }
            $0 == end   { skip=0; next }
            !skip { print }
        ' "${ZSHRC}" > "${tmp}"

        mv "${tmp}" "${ZSHRC}"
    fi

    rm -rf "${ZSH_CONFIG_DIR}"
    rm -rf "${ZSH_PLUGIN_DIR}"

    if [[ -f "${STARSHIP_CONFIG}" ]] &&
       grep -q "Managed by zsh-manager" "${STARSHIP_CONFIG}" 2>/dev/null; then
        rm -f "${STARSHIP_CONFIG}"
    fi

    rm -rf "${MANAGER_DIR}"

    printf '\n'
    success "Zsh-manager 配置已卸载"

    printf '\n'
    read -r -p "是否把默认 Shell 恢复为 Bash？[y/N]: " restore

    case "${restore}" in
        y|Y|yes|YES)
            restore_bash_shell
            ;;
        *)
            warn "保持当前默认 Shell 不变"
            ;;
    esac

    pause
}

# ============================================================
# Test Zsh configuration
# ============================================================

test_configuration() {
    clear

    print_header "测试 Zsh 配置"

    if ! command -v zsh >/dev/null 2>&1; then
        error "Zsh 未安装"
        pause
        return
    fi

    log "检查 .zshrc..."

    if zsh -n "${ZSHRC}" 2>/dev/null; then
        success ".zshrc 语法检查通过"
    else
        error ".zshrc 存在语法错误"
    fi

    log "检查 Starship..."

    if command -v starship >/dev/null 2>&1; then
        if starship --version >/dev/null 2>&1; then
            success "Starship 工作正常"
        else
            error "Starship 检查失败"
        fi
    else
        error "Starship 未安装"
    fi

    log "检查插件..."

    local name
    for name in autosuggestions syntax-highlighting completions; do
        if [[ -d "$(plugin_dir "${name}")" ]]; then
            success "$(plugin_display_name "${name}")"
        else
            warn "$(plugin_display_name "${name}") 未安装"
        fi
    done

    printf '\n'
    printf '%b当前可以执行：%b\n\n' "${BOLD}" "${RESET}"
    printf '  exec zsh\n'

    pause
}

# ============================================================
# Header
# ============================================================

print_header() {
    local title="$1"

    printf '\n'
    printf '%b============================================================%b\n' \
        "${CYAN}" "${RESET}"

    printf '%b        %s%b\n' \
        "${BOLD}" "${title}" "${RESET}"

    printf '%b============================================================%b\n' \
        "${CYAN}" "${RESET}"

    printf '\n'
}

# ============================================================
# Main menu
# ============================================================

main_menu() {
    while true; do
        clear

        print_header "${APP_NAME} v${APP_VERSION}"

        printf '  用户：       %b%s%b\n' \
            "${CYAN}" "${USER}" "${RESET}"

        printf '  当前 Shell： %b%s%b\n' \
            "${CYAN}" "$(get_current_shell)" "${RESET}"

        if command -v zsh >/dev/null 2>&1; then
            printf '  Zsh：        %b已安装%b\n' \
                "${GREEN}" "${RESET}"
        else
            printf '  Zsh：        %b未安装%b\n' \
                "${YELLOW}" "${RESET}"
        fi

        if command -v starship >/dev/null 2>&1; then
            printf '  Starship：   %b已安装%b\n' \
                "${GREEN}" "${RESET}"
        else
            printf '  Starship：   %b未安装%b\n' \
                "${YELLOW}" "${RESET}"
        fi

        local plugin_count=0

        [[ -d "$(plugin_dir autosuggestions)" ]] && ((plugin_count+=1))
        [[ -d "$(plugin_dir syntax-highlighting)" ]] && ((plugin_count+=1))
        [[ -d "$(plugin_dir completions)" ]] && ((plugin_count+=1))

        printf '  插件：       %b%s/3%b\n' \
            "${GREEN}" "${plugin_count}" "${RESET}"

        if command -v tmux >/dev/null 2>&1; then
            printf '  tmux：        %b已安装%b\n' \
                "${GREEN}" "${RESET}"
        else
            printf '  tmux：        %b未安装%b\n' \
                "${YELLOW}" "${RESET}"
        fi

        printf '\n'
        printf '%b------------------------------------------------------------%b\n' \
            "${DIM}" "${RESET}"

        printf '\n'

        printf '  %b1%b) 安装 / 初始化 Zsh 环境\n' "${BOLD}" "${RESET}"
        printf '  %b2%b) 设置 Zsh 为默认 Shell\n' "${BOLD}" "${RESET}"
        printf '  %b3%b) 恢复 Bash 为默认 Shell\n' "${BOLD}" "${RESET}"
        printf '\n'

        printf '  %b4%b) 更新全部组件\n' "${BOLD}" "${RESET}"
        printf '  %b5%b) 修复 / 重建配置\n' "${BOLD}" "${RESET}"
        printf '  %b6%b) 插件管理\n' "${BOLD}" "${RESET}"
        printf '\n'

        printf '  %b7%b) 测试 Zsh 配置\n' "${BOLD}" "${RESET}"
        printf '  %b8%b) 查看当前状态\n' "${BOLD}" "${RESET}"
        printf '\n'

        printf '  %b9%b) 卸载 Zsh 环境\n' "${BOLD}" "${RESET}"
        printf '  %b0%b) 退出\n' "${BOLD}" "${RESET}"

        printf '\n'
        printf '%b------------------------------------------------------------%b\n' \
            "${DIM}" "${RESET}"

        printf '\n'

        read -r -p "请选择 [0-9]: " choice

        case "${choice}" in
            1)
                install_environment
                ;;
            2)
                clear
                print_header "设置 Zsh 为默认 Shell"
                setup_sudo
                set_default_shell
                pause
                ;;
            3)
                clear
                print_header "恢复 Bash 为默认 Shell"
                setup_sudo
                restore_bash_shell
                pause
                ;;
            4)
                update_environment
                ;;
            5)
                repair_environment
                ;;
            6)
                plugin_menu
                ;;
            7)
                test_configuration
                ;;
            8)
                show_status
                ;;
            9)
                uninstall_environment
                ;;
            0)
                clear
                printf '\n'
                success "退出"
                printf '\n'
                exit 0
                ;;
            *)
                warn "无效选择，请输入 0-9"
                sleep 1
                ;;
        esac
    done
}

# ============================================================
# Pause
# ============================================================

pause() {
    printf '\n'
    read -r -p "按 Enter 返回菜单..." _
}

# ============================================================
# Main
# ============================================================

main() {
    detect_os || exit 1
    setup_sudo || exit 1
    create_directories

    main_menu
}

main "$@"
