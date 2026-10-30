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
# Keep the adjacent config/ directory with this script.
#
# ============================================================

set -Eeuo pipefail

readonly APP_NAME="Zsh Server Environment Manager"
readonly APP_VERSION="2.0.1"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${SCRIPT_DIR}/config/theme/eyerelax.sh"

readonly ZSHRC="${HOME}/.zshrc"
readonly ZSH_CONFIG_DIR="${HOME}/.config/zsh"
readonly ZSH_PLUGIN_DIR="${HOME}/.local/share/zsh/plugins"

readonly STARSHIP_CONFIG="${HOME}/.config/starship.toml"

readonly MANAGER_DIR="${HOME}/.local/share/zsh-manager"
readonly BACKUP_DIR="${HOME}/.zsh-manager-backups-$(date +%Y%m%d%H%M%S)"
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
        if ! sudo "$@"; then
            warn "命令执行失败：$*"
            return 1
        fi
    else
        if ! "$@"; then
            warn "命令执行失败：$*"
            return 1
        fi
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

    mkdir -p "${BACKUP_DIR}"

    local timestamp
    # Include nanoseconds so two backups in the same second never
    # collide/overwrite each other.
    timestamp="$(date '+%Y%m%d-%H%M%S-%N')"

    local base
    base="$(basename "${file}")"

    local backup
    backup="${BACKUP_DIR}/${base}.${timestamp}.bak"

    if ! cp -a "${file}" "${backup}"; then
        warn "备份失败：${file}"
        return 1
    fi

    success "已备份：${backup}"
}

# ============================================================
# APT
# ============================================================

apt_update() {
    log "更新 APT 软件索引..."

    if ! run_root env DEBIAN_FRONTEND=noninteractive apt-get update -y; then
        warn "APT 索引更新失败"
        return 1
    fi
}

apt_install() {
    if ! run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"; then
        warn "APT 软件包安装失败：$*"
        return 1
    fi
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

    apt_install zsh || return 1

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
        zstd || return 1

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
            apt_install 7zip || return 1
        elif apt-cache show p7zip-full >/dev/null 2>&1; then
            apt_install p7zip-full || return 1
        else
            warn "系统仓库没有找到 7z 软件包。"
        fi
    fi

    if ! command -v unrar >/dev/null 2>&1; then
        if apt-cache show unrar-free >/dev/null 2>&1; then
            apt_install unrar-free || return 1
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
    install_starship_binary
}

update_starship() {
    install_starship_binary
}

install_starship_binary() {
    local machine asset tmp archive checksum_url checksum_file extracted target
    machine="$(uname -m)"
    case "${machine}" in
        x86_64|amd64) asset="x86_64-unknown-linux-musl" ;;
        aarch64|arm64) asset="aarch64-unknown-linux-musl" ;;
        *) error "不支持的 Starship 架构：${machine}"; return 1 ;;
    esac
    tmp="$(mktemp -d)" || { warn "无法创建 Starship 临时目录"; return 1; }
    archive="starship-${asset}.tar.gz"
    checksum_file="${tmp}/${archive}.sha256"
    if ! curl --location --connect-timeout 10 --retry 2 --fail --silent --show-error \
        --proto '=https' --tlsv1.2 -o "${tmp}/${archive}" \
        "https://github.com/starship/starship/releases/latest/download/${archive}"; then
        rm -rf "${tmp}"; warn "Starship 下载失败"; return 1
    fi
    if [ ! -s "${tmp}/${archive}" ]; then
        rm -rf "${tmp}"; warn "Starship 下载失败"; return 1
    fi
    checksum_url="https://github.com/starship/starship/releases/latest/download/${archive}.sha256"
    local verified=0
    if curl --location --connect-timeout 10 --retry 2 --fail --silent --show-error \
        --proto '=https' --tlsv1.2 -o "${checksum_file}" "${checksum_url}"; then
        local expected actual
        expected="$(awk 'NR==1{print $1}' "${checksum_file}" | tr 'A-F' 'a-f')"
        actual="$(sha256sum "${tmp}/${archive}" | awk '{print $1}')"
        if [[ ! "${expected}" =~ ^[0-9a-f]{64}$ ]] || [ "${expected}" != "${actual}" ]; then
            rm -rf "${tmp}"; error "Starship SHA256 校验失败"; return 1
        fi
        verified=1
    fi
    if ! tar -xzf "${tmp}/${archive}" -C "${tmp}"; then
        rm -rf "${tmp}"; warn "Starship 归档解压失败"; return 1
    fi
    extracted="${tmp}/starship"
    if [[ ! -x "${extracted}" ]] || ! "${extracted}" --version >/dev/null 2>&1; then
        rm -rf "${tmp}"; error "Starship 二进制探活失败"; return 1
    fi
    target="${HOME}/.local/bin/starship"
    if ! mkdir -p "${HOME}/.local/bin" || ! install -m 0755 "${extracted}" "${target}"; then
        rm -rf "${tmp}"; warn "Starship 安装失败：${target}"; return 1
    fi
    rm -rf "${tmp}"
    [[ "${verified}" -eq 1 ]] || warn "无法获取 SHA256 校验和，已启用二进制可执行探活兜底"
    success "Starship 已安装：${target}"
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

    if ! git clone --depth=1 "${url}" "${dir}"; then
        warn "插件下载失败：$(plugin_display_name "${name}")"
        return 1
    fi

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

    if ! git -C "${dir}" fetch --depth=1 origin; then
        warn "插件更新失败：$(plugin_display_name "${name}")"
        return 1
    fi

    local branch
    branch="$(git -C "${dir}" symbolic-ref --short HEAD 2>/dev/null || true)"

    if [[ -n "${branch}" ]]; then
        if ! git -C "${dir}" reset --hard "origin/${branch}" >/dev/null 2>&1; then
            if ! git -C "${dir}" pull --ff-only; then
                warn "插件更新失败：$(plugin_display_name "${name}")"
                return 1
            fi
        fi
    else
        if ! git -C "${dir}" pull --ff-only; then
            warn "插件更新失败：$(plugin_display_name "${name}")"
            return 1
        fi
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


hex_to_256() {
    local hex="${1#\#}"
    local red=$((16#${hex:0:2})) green=$((16#${hex:2:2})) blue=$((16#${hex:4:2}))
    awk -v red="${red}" -v green="${green}" -v blue="${blue}" '
        BEGIN {
            levels[0]=0; levels[1]=95; levels[2]=135
            levels[3]=175; levels[4]=215; levels[5]=255
            best_distance=1e30
            for (i=16; i<=231; i++) {
                offset=i-16
                r=levels[int(offset/36)]
                g=levels[int(offset/6)%6]
                b=levels[offset%6]
                distance=(red-r)^2+(green-g)^2+(blue-b)^2
                if (distance<best_distance) { best_distance=distance; best=i }
            }
            for (i=232; i<=255; i++) {
                gray=8+10*(i-232)
                distance=(red-gray)^2+(green-gray)^2+(blue-gray)^2
                if (distance<best_distance) { best_distance=distance; best=i }
            }
            printf "%d", best
        }
    '
}

render_theme_template() {
    local source_file="$1" output_file="$2"
    sed \
        -e "s/@TEXT@/colour$(hex_to_256 "${THEME_TEXT}")/g" \
        -e "s/@TEXT_BRIGHT@/colour$(hex_to_256 "${THEME_TEXT_BRIGHT}")/g" \
        -e "s/@MUTED@/colour$(hex_to_256 "${THEME_MUTED}")/g" \
        -e "s/@COMMAND@/colour$(hex_to_256 "${THEME_COMMAND}")/g" \
        -e "s/@VALID_COMMAND@/colour$(hex_to_256 "${THEME_VALID_COMMAND}")/g" \
        -e "s/@ERROR@/colour$(hex_to_256 "${THEME_ERROR}")/g" \
        -e "s/@BUILTIN@/colour$(hex_to_256 "${THEME_BUILTIN}")/g" \
        -e "s/@FUNCTION@/colour$(hex_to_256 "${THEME_FUNCTION}")/g" \
        -e "s/@OPTION@/colour$(hex_to_256 "${THEME_OPTION}")/g" \
        -e "s/@QUOTED@/colour$(hex_to_256 "${THEME_QUOTED}")/g" \
        -e "s/@LINK@/colour$(hex_to_256 "${THEME_LINK}")/g" \
        -e "s/@DIRECTORY@/colour$(hex_to_256 "${THEME_DIRECTORY}")/g" \
        -e "s/@EXECUTABLE@/colour$(hex_to_256 "${THEME_EXECUTABLE}")/g" \
        -e "s/@SUGGESTION@/colour$(hex_to_256 "${THEME_SUGGESTION}")/g" \
        -e "s/@GIT@/colour$(hex_to_256 "${THEME_GIT}")/g" \
        -e "s/@DURATION@/colour$(hex_to_256 "${THEME_DURATION}")/g" \
        -e "s/@PROMPT@/colour$(hex_to_256 "${THEME_PROMPT}")/g" \
        -e "s/@USERNAME_256@/$(hex_to_256 "${THEME_USERNAME}")/g" \
        -e "s/@HOSTNAME_256@/$(hex_to_256 "${THEME_HOSTNAME}")/g" \
        -e "s/@DIRECTORY_256@/$(hex_to_256 "${THEME_DIRECTORY}")/g" \
        -e "s/@LINK_256@/$(hex_to_256 "${THEME_LINK}")/g" \
        -e "s/@ERROR_256@/$(hex_to_256 "${THEME_ERROR}")/g" \
        -e "s/@EXECUTABLE_256@/$(hex_to_256 "${THEME_EXECUTABLE}")/g" \
        -e "s/@FILE_256@/$(hex_to_256 "${THEME_FILE}")/g" \
        -e "s/@ARCHIVE_256@/$(hex_to_256 "${THEME_ARCHIVE}")/g" \
        -e "s/@MUTED_256@/$(hex_to_256 "${THEME_MUTED}")/g" \
        -e "s/@BUILTIN_256@/$(hex_to_256 "${THEME_BUILTIN}")/g" \
        -e "s/@GIT_256@/$(hex_to_256 "${THEME_GIT}")/g" \
        -e "s/@FUNCTION_256@/$(hex_to_256 "${THEME_FUNCTION}")/g" \
        -e "s/@OPTION_256@/$(hex_to_256 "${THEME_OPTION}")/g" \
        "${source_file}" > "${output_file}"
}

write_zsh_environment() {
    local module rendered
    local -a modules=(environment core keybindings completion plugins shell-tools prompt)
    mkdir -p "${ZSH_CONFIG_DIR}"
    for module in "${modules[@]}"; do
        rendered="$(mktemp)" || return 1
        if ! render_theme_template "${SCRIPT_DIR}/config/zsh/${module}.zsh" "${rendered}"; then
            rm -f "${rendered}"
            return 1
        fi
        if [[ -f "${ZSH_CONFIG_DIR}/${module}.zsh" ]] && ! cmp -s "${ZSH_CONFIG_DIR}/${module}.zsh" "${rendered}"; then
            backup_file "${ZSH_CONFIG_DIR}/${module}.zsh" || { rm -f "${rendered}"; return 1; }
        fi
        install -m 0644 "${rendered}" "${ZSH_CONFIG_DIR}/${module}.zsh" || { rm -f "${rendered}"; return 1; }
        rm -f "${rendered}"
    done
    success "Zsh 环境模块已写入"
}

update_config_file() {
    local source_file="$1" target_file="$2" rendered choice
    rendered="$(mktemp)" || return 1
    if ! render_theme_template "${source_file}" "${rendered}"; then rm -f "${rendered}"; return 1; fi
    if [[ -f "${target_file}" ]] && cmp -s "${target_file}" "${rendered}"; then
        rm -f "${rendered}"
        return 0
    fi
    if [[ -f "${target_file}" ]]; then
        choice=""
        read -r -p "检测到配置已有修改，是否更新？[y/N] (默认 N 保留): " choice || true
        if [[ "${choice}" != [yY] ]]; then
            rm -f "${rendered}"
            warn "保留用户配置：${target_file}"
            return 0
        fi
        backup_file "${target_file}" || { rm -f "${rendered}"; return 1; }
    fi
    mkdir -p "$(dirname "${target_file}")"
    install -m 0644 "${rendered}" "${target_file}"
    rm -f "${rendered}"
}

# ============================================================
# Extract
# ============================================================

write_extract_function() {
    mkdir -p "${ZSH_CONFIG_DIR}"
    if [[ -f "${ZSH_CONFIG_DIR}/extract.zsh" ]] && ! cmp -s "${SCRIPT_DIR}/config/zsh/extract.zsh" "${ZSH_CONFIG_DIR}/extract.zsh"; then
        backup_file "${ZSH_CONFIG_DIR}/extract.zsh" || return 1
    fi
    install -m 0644 "${SCRIPT_DIR}/config/zsh/extract.zsh" "${ZSH_CONFIG_DIR}/extract.zsh"
    success "extract 配置完成"
}

# ============================================================
# ll (colored, grouped listing; colors follow tmux config)
# ============================================================

write_ll_function() {
    mkdir -p "${ZSH_CONFIG_DIR}"
    local rendered
    rendered="$(mktemp)" || return 1
    render_theme_template "${SCRIPT_DIR}/config/zsh/ll.zsh" "${rendered}" || { rm -f "${rendered}"; return 1; }
    if [[ -f "${ZSH_CONFIG_DIR}/ll.zsh" ]] && ! cmp -s "${ZSH_CONFIG_DIR}/ll.zsh" "${rendered}"; then
        backup_file "${ZSH_CONFIG_DIR}/ll.zsh" || { rm -f "${rendered}"; return 1; }
    fi
    install -m 0644 "${rendered}" "${ZSH_CONFIG_DIR}/ll.zsh"
    rm -f "${rendered}"
    success "ll 配置完成"
}

# ============================================================
# Starship fixed configuration
# ============================================================

write_starship_config() {
    local output="${1:-${STARSHIP_CONFIG}}"
    local template choice
    local is_real_config=false
    [[ "${output}" == "${STARSHIP_CONFIG}" ]] && is_real_config=true
    template="$(mktemp)" || { warn "无法创建 Starship 模板临时文件"; return 1; }
    render_theme_template "${SCRIPT_DIR}/config/starship/starship.toml" "${template}" || { rm -f "${template}"; return 1; }

    if [[ "${is_real_config}" == true && -f "${output}" ]] && ! cmp -s "${output}" "${template}"; then
        choice=""
        read -r -p "检测到 starship.toml 已有修改,是否覆盖?[y/N](默认 N 保留): " choice || true
        if [[ "${choice}" != [yY] ]]; then
            rm -f "${template}"
            warn "保留用户配置：${output}"
            return 0
        fi
        backup_file "${output}" || { rm -f "${template}"; return 1; }
    fi

    mkdir -p "$(dirname "${output}")" || { rm -f "${template}"; return 1; }
    if ! install -m 0644 "${template}" "${output}"; then
        rm -f "${template}"
        return 1
    fi
    rm -f "${template}"
    success "Starship 固定配置已写入"
}

# ============================================================
# Zsh configuration
# ============================================================

write_zshrc() {
    local output="${1:-${ZSHRC}}"
    create_directories
    if [[ -f "${output}" && "${output}" == "${ZSHRC}" ]]; then backup_file "${output}"; fi

    local tmp orig_mode=""
    [[ -f "${output}" ]] && orig_mode="$(stat -c '%a' "${output}" 2>/dev/null || true)"
    tmp="$(mktemp)" || return 1
    trap 'rm -f "${tmp}"' EXIT INT TERM
    if [[ -f "${output}" ]]; then
        awk -v begin="${MARK_BEGIN}" -v end="${MARK_END}" '
            $0 == begin { skip=1; next }
            $0 == end   { skip=0; next }
            !skip { print }
        ' "${output}" > "${tmp}"
    else
        : > "${tmp}"
    fi

    cat >> "${tmp}" <<EOF

${MARK_BEGIN}
# Managed by zsh-manager; configuration lives in ~/.config/zsh/environment.zsh.
source "\${HOME}/.config/zsh/environment.zsh"
${MARK_END}
EOF
    mv "${tmp}" "${output}"
    if [[ -n "${orig_mode}" ]]; then chmod "${orig_mode}" "${output}"; else chmod 0644 "${output}"; fi
    trap - EXIT INT TERM
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

    detect_os || return 1
    setup_sudo || return 1
    create_directories

    printf '\n'

    log "开始安装..."

    apt_update || return 1

    install_dependencies || return 1
    install_zsh || return 1
    install_archive_tools || return 1
    install_starship || return 1

    install_all_plugins || return 1

    write_extract_function
    write_ll_function
    write_zsh_environment
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

    read -r -p "请选择 [1-2]: " choice || true

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
    read -r -p "请选择 [1-2]: " enter_choice || true

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

    local TARGET_USER current_shell
    TARGET_USER="${SUDO_USER:-$(id -un)}"
    if command -v getent >/dev/null 2>&1; then
        current_shell="$(getent passwd "${TARGET_USER}" | cut -d: -f7 || true)"
    else
        current_shell="$(awk -F: -v u="${TARGET_USER}" '$1==u {print $7}' /etc/passwd)"
    fi
    if [[ "${current_shell}" == "${zsh_path}" ]]; then
        success "当前默认 Shell 已经是 Zsh"
        return
    fi

    if ! grep -Fxq "${zsh_path}" /etc/shells 2>/dev/null; then
        if ! run_root sh -c 'printf "%s\\n" "$1" >> /etc/shells' sh "${zsh_path}"; then
            warn "无法将 Zsh 路径加入 /etc/shells"
            return 1
        fi
    fi

    if ! run_root chsh -s "${zsh_path}" "${TARGET_USER}"; then
        warn "Shell 切换失败，请手动执行：chsh -s ${zsh_path} ${TARGET_USER}"
        return 1
    fi

    success "默认 Shell 已切换为 Zsh"
    warn "重新 SSH 登录后完全生效。"
}

# ============================================================
# Restore Bash
# ============================================================

restore_bash_shell() {
    local bash_path TARGET_USER current_shell

    bash_path="$(command -v bash 2>/dev/null || true)"

    if [[ -z "${bash_path}" ]]; then
        error "找不到 Bash。"
        return 1
    fi

    TARGET_USER="${SUDO_USER:-$(id -un)}"
    if command -v getent >/dev/null 2>&1; then
        current_shell="$(getent passwd "${TARGET_USER}" | cut -d: -f7 || true)"
    else
        current_shell="$(awk -F: -v u="${TARGET_USER}" '$1==u {print $7}' /etc/passwd)"
    fi
    if [[ "${current_shell}" == "${bash_path}" ]]; then
        success "当前默认 Shell 已经是 Bash"
        return
    fi

    if ! grep -Fxq "${bash_path}" /etc/shells 2>/dev/null; then
        if ! run_root sh -c 'printf "%s\\n" "$1" >> /etc/shells' sh "${bash_path}"; then
            warn "无法将 Bash 路径加入 /etc/shells"
            return 1
        fi
    fi

    if ! run_root chsh -s "${bash_path}" "${TARGET_USER}"; then
        warn "Shell 恢复失败，请手动执行：chsh -s ${bash_path} ${TARGET_USER}"
        return 1
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

    setup_sudo || return 1
    create_directories

    # Refresh APT indexes first so install_archive_tools' `apt-cache
    # show` checks (7zip / unrar-free) don't silently fail on a stale
    # or empty package cache.
    apt_update || return 1

    log "检查 Zsh..."
    install_zsh || return 1

    log "检查压缩工具..."
    install_archive_tools || return 1

    log "检查 Starship..."
    install_starship || return 1

    log "检查插件..."
    install_all_plugins || return 1

    log "重建 extract..."
    write_extract_function
    write_ll_function
    write_zsh_environment

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

    update_starship || warn "Starship 更新未完成"
    update_all_plugins || warn "部分插件更新未完成"
    update_config_file "${SCRIPT_DIR}/config/zsh/extract.zsh" "${ZSH_CONFIG_DIR}/extract.zsh" || return 1
    update_config_file "${SCRIPT_DIR}/config/zsh/ll.zsh" "${ZSH_CONFIG_DIR}/ll.zsh" || return 1
    local module
    for module in environment core keybindings completion plugins shell-tools prompt; do
        update_config_file "${SCRIPT_DIR}/config/zsh/${module}.zsh" "${ZSH_CONFIG_DIR}/${module}.zsh" || return 1
    done

    local tmp starship_template zshrc_template current_block new_block choice
    tmp="$(mktemp -d)" || { warn "无法创建配置对比目录"; return 1; }
    starship_template="${tmp}/starship.toml"
    zshrc_template="${tmp}/zshrc"
    write_starship_config "${starship_template}"
    if [[ -f "${STARSHIP_CONFIG}" ]] && ! cmp -s "${STARSHIP_CONFIG}" "${starship_template}"; then
        read -r -p "检测到配置文件已有修改，是否使用新模板覆盖？[y/N] (默认: N 保留): " choice || true
        if [[ "${choice}" == [yY] ]]; then
            backup_file "${STARSHIP_CONFIG}" || { rm -rf "${tmp}"; return 1; }
            cp "${starship_template}" "${STARSHIP_CONFIG}" || { rm -rf "${tmp}"; return 1; }
        fi
    fi

    write_zshrc "${zshrc_template}"
    if [[ -f "${ZSHRC}" ]] && grep -Fxq "${MARK_BEGIN}" "${ZSHRC}" && grep -Fxq "${MARK_END}" "${ZSHRC}"; then
        current_block="${tmp}/current-block"
        new_block="${tmp}/new-block"
        awk -v begin="${MARK_BEGIN}" -v end="${MARK_END}" '$0==begin {copy=1} copy {print} $0==end {copy=0}' "${ZSHRC}" > "${current_block}"
        awk -v begin="${MARK_BEGIN}" -v end="${MARK_END}" '$0==begin {copy=1} copy {print} $0==end {copy=0}' "${zshrc_template}" > "${new_block}"
        if ! cmp -s "${current_block}" "${new_block}"; then
            read -r -p "检测到配置文件已有修改，是否使用新模板覆盖？[y/N] (默认: N 保留): " choice || true
            if [[ "${choice}" == [yY] ]]; then
                backup_file "${ZSHRC}" || { rm -rf "${tmp}"; return 1; }
                awk -v begin="${MARK_BEGIN}" -v end="${MARK_END}" -v replacement="${new_block}" '
                    $0==begin { while ((getline line < replacement)>0) print line; close(replacement); skip=1; next }
                    $0==end { skip=0; next }
                    !skip { print }
                ' "${ZSHRC}" > "${tmp}/updated-zshrc" || { rm -rf "${tmp}"; return 1; }
                mv "${tmp}/updated-zshrc" "${ZSHRC}" || { rm -rf "${tmp}"; return 1; }
            fi
        fi
    else
        warn "未找到托管标记块，跳过对 .zshrc 的修改"
    fi
    rm -rf "${tmp}"

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

        read -r -p "请选择 [1-6]: " choice || true

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

    read -r -p "请选择 [1-5]: " choice || true

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

    read -r -p "请选择 [1-4]: " choice || true

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
    local config_name local_file

    printf '%b注意：%b\n\n' "${YELLOW}" "${RESET}"

    printf '  将删除：\n'
    printf '    - zsh-manager 配置\n'
    printf '    - 三个 Zsh 插件\n'
    printf '    - Zsh 配置模块（含 extract / ll）\n'
    printf '    - Starship 固定配置\n'
    printf '\n'

    printf '  将保留：\n'
    printf '    - Zsh 软件包\n'
    printf '    - Starship 软件包\n'
    printf '    - Bash 软件包\n'
    printf '\n'

    printf '%b你的 .zshrc 会先自动备份。%b\n\n' \
        "${CYAN}" "${RESET}"

    read -r -p "确定继续卸载吗？输入 YES 确认： " confirm || true

    if [[ "${confirm}" != "YES" ]]; then
        warn "已取消卸载"
        pause
        return
    fi

    mkdir -p "${BACKUP_DIR}"
    if [[ -f "${ZSHRC}" ]]; then backup_file "${ZSHRC}" || return 1; fi
    for config_name in extract ll environment core keybindings completion plugins shell-tools prompt; do
        local_file="${ZSH_CONFIG_DIR}/${config_name}.zsh"
        if [[ -f "${local_file}" ]]; then backup_file "${local_file}" || return 1; fi
    done

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

    for config_name in extract ll environment core keybindings completion plugins shell-tools prompt; do
        rm -f "${ZSH_CONFIG_DIR}/${config_name}.zsh"
    done
    rmdir "${ZSH_CONFIG_DIR}" 2>/dev/null || true

    local plugin_name
    for plugin_name in zsh-autosuggestions zsh-syntax-highlighting zsh-completions; do
        rm -rf "${ZSH_PLUGIN_DIR:?}/${plugin_name}"
    done

    if [[ -f "${STARSHIP_CONFIG}" ]] &&
       grep -q "Managed by zsh-manager" "${STARSHIP_CONFIG}" 2>/dev/null; then
        backup_file "${STARSHIP_CONFIG}" || return 1
        rm -f "${STARSHIP_CONFIG}"
    fi

    rmdir "${ZSH_PLUGIN_DIR}" 2>/dev/null || true
    rmdir "$(dirname "${STARSHIP_CONFIG}")" 2>/dev/null || true
    rm -rf "${MANAGER_DIR}"
    success "备份路径：${BACKUP_DIR}"

    printf '\n'
    success "Zsh-manager 配置已卸载"

    printf '\n'
    read -r -p "是否把默认 Shell 恢复为 Bash？[y/N]: " restore || true

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

        read -r -p "请选择 [0-9]: " choice || true
        [[ -n "${choice}" ]] || continue

        case "${choice}" in
            1)
                install_environment || warn "环境安装未全部成功"
                ;;
            2)
                clear
                print_header "设置 Zsh 为默认 Shell"
                setup_sudo
                set_default_shell || warn "默认 Shell 设置失败"
                pause
                ;;
            3)
                clear
                print_header "恢复 Bash 为默认 Shell"
                setup_sudo
                restore_bash_shell || warn "默认 Shell 恢复失败"
                pause
                ;;
            4)
                update_environment || warn "环境更新未全部成功"
                ;;
            5)
                repair_environment || warn "环境修复未全部成功"
                ;;
            6)
                plugin_menu || warn "插件操作未全部成功"
                ;;
            7)
                test_configuration || warn "配置测试未全部成功"
                ;;
            8)
                show_status || warn "状态读取失败"
                ;;
            9)
                uninstall_environment || warn "卸载流程未全部成功"
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
    read -r -p "按 Enter 返回菜单..." _ || true
}

# ============================================================
# Main
# ============================================================

main() {
    detect_os || exit 1
    setup_sudo || exit 1
    main_menu
}

main "$@"
