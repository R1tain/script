#!/usr/bin/env bash
#
# install-tmux.sh
#
# Debian / Ubuntu 专用：
#   - 自动安装 tmux 编译依赖
#   - 获取最新稳定版 tmux Release
#   - 源码编译安装到 /usr/local
#   - 自动保证 /usr/local/bin 优先
#   - 自动生成 Claude Code / Codex 长时间运行优化配置
#   - 不安装任何第三方 tmux 插件
#
# 适用于：
#   Debian 11 / 12 / 13
#   Ubuntu 20.04 / 22.04 / 24.04
#
# 使用：
#   bash install-tmux.sh
#
# 可选：
#   bash install-tmux.sh --config-only
#   bash install-tmux.sh --no-config
#
# ============================================================

set -Eeuo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly TMUX_PREFIX="/usr/local"
readonly TMUX_BIN="${TMUX_PREFIX}/bin/tmux"
readonly TMUX_CONF="/root/.tmux.conf"

NO_CONFIG=false
CONFIG_ONLY=false

for arg in "$@"; do
    case "$arg" in
        --no-config)
            NO_CONFIG=true
            ;;
        --config-only)
            CONFIG_ONLY=true
            ;;
        -h|--help)
            cat <<EOF
Usage:
  $SCRIPT_NAME
  $SCRIPT_NAME --config-only
  $SCRIPT_NAME --no-config

Options:
  --config-only   只生成 tmux 配置，不编译安装
  --no-config     只安装/升级 tmux，不修改 ~/.tmux.conf
EOF
            exit 0
            ;;
        *)
            echo "未知参数: $arg"
            exit 1
            ;;
    esac
done


# ============================================================
# Root
# ============================================================

if [[ "${EUID}" -ne 0 ]]; then
    echo "请使用 root 运行："
    echo
    echo "  sudo bash $SCRIPT_NAME"
    exit 1
fi


# ============================================================
# 基础工具
# ============================================================

export DEBIAN_FRONTEND=noninteractive

log() {
    echo
    echo "============================================================"
    echo " $*"
    echo "============================================================"
}


die() {
    echo
    echo "[ERROR] $*" >&2
    exit 1
}


# ============================================================
# 检测 Debian / Ubuntu
# ============================================================

[[ -f /etc/os-release ]] || die "无法检测操作系统。"

source /etc/os-release

case "${ID:-}" in
    ubuntu|debian)
        ;;
    *)
        die "此脚本专门针对 Debian / Ubuntu。当前系统：${PRETTY_NAME:-unknown}"
        ;;
esac

log "系统信息"

echo "系统      : ${PRETTY_NAME:-unknown}"
echo "架构      : $(dpkg --print-architecture 2>/dev/null || uname -m)"
echo "内核      : $(uname -r)"


# ============================================================
# 只生成配置
# ============================================================

write_tmux_config() {

    log "生成 tmux / Claude Code / Codex 优化配置"

    if [[ -f "$TMUX_CONF" ]]; then
        local backup
        backup="${TMUX_CONF}.backup.$(date +%Y%m%d-%H%M%S)"

        cp -a "$TMUX_CONF" "$backup"

        echo "已备份原配置："
        echo "  $backup"
    fi

    cat > "$TMUX_CONF" <<'EOF'
# ============================================================
# tmux 3.x
#
# Claude Code / OpenAI Codex
# SSH 长时间运行优化
# ============================================================


# ------------------------------------------------------------
# Prefix
# ------------------------------------------------------------

unbind C-b
set -g prefix C-a
bind C-a send-prefix


# ------------------------------------------------------------
# 基础
# ------------------------------------------------------------

set -g mouse on

set -g focus-events on

# 长时间运行程序建议保留较大的 scrollback
set -g history-limit 50000

# Escape 响应速度
set -s escape-time 10

# 重复按键时间
set -g repeat-time 300

# 使用现代终端类型
set -g default-terminal "tmux-256color"


# ------------------------------------------------------------
# Modern terminal / Claude Code / Codex
# ------------------------------------------------------------

# Extended keys
set -s extended-keys on

# xterm 扩展键
set -as terminal-features 'xterm*:extkeys'

# focus events
set -as terminal-features 'xterm*:focus'

# RGB / TrueColor
set -as terminal-features 'xterm*:RGB'

# clipboard
set -as terminal-features 'xterm*:clipboard'

# 允许程序发送 passthrough escape sequence
#
# Claude Code / Codex / modern terminal UI
# 可能使用 OSC / DCS 等终端序列。
#
set -g allow-passthrough on


# ------------------------------------------------------------
# 兼容不同 SSH Terminal
# ------------------------------------------------------------

# 如果客户端不是 xterm，仍然允许 RGB
set -as terminal-features ',*:RGB'

# 256 color
set -as terminal-features ',*:256'


# ------------------------------------------------------------
# Window
# ------------------------------------------------------------

set -g base-index 1
setw -g pane-base-index 1

set -g renumber-windows on

setw -g automatic-rename on
setw -g allow-rename on


# ------------------------------------------------------------
# 新 Pane / Window 保持当前目录
# ------------------------------------------------------------

bind c new-window -c "#{pane_current_path}"

bind '"' split-window -v -c "#{pane_current_path}"

bind % split-window -h -c "#{pane_current_path}"

bind | split-window -h -c "#{pane_current_path}"

bind - split-window -v -c "#{pane_current_path}"


# ------------------------------------------------------------
# Pane 快速切换
# ------------------------------------------------------------

bind h select-pane -L
bind j select-pane -D
bind k select-pane -U
bind l select-pane -R


# Alt + 方向键
bind -n M-Left  select-pane -L
bind -n M-Right select-pane -R
bind -n M-Up    select-pane -U
bind -n M-Down  select-pane -D


# ------------------------------------------------------------
# Pane Resize
# ------------------------------------------------------------

bind -r H resize-pane -L 5
bind -r J resize-pane -D 5
bind -r K resize-pane -U 5
bind -r L resize-pane -R 5


# ------------------------------------------------------------
# Window 快速切换
# ------------------------------------------------------------

bind -r C-h previous-window
bind -r C-l next-window


# ------------------------------------------------------------
# Copy Mode
# ------------------------------------------------------------

setw -g mode-keys vi

bind -T copy-mode-vi v send-keys -X begin-selection
bind -T copy-mode-vi y send-keys -X copy-selection-and-cancel
bind -T copy-mode-vi C-v send-keys -X rectangle-toggle


# ------------------------------------------------------------
# Paste
# ------------------------------------------------------------

bind p paste-buffer


# ------------------------------------------------------------
# Reload
# ------------------------------------------------------------

bind r source-file ~/.tmux.conf \; display-message "tmux config reloaded"


# ------------------------------------------------------------
# Window number
# ------------------------------------------------------------

bind -n M-1 select-window -t 1
bind -n M-2 select-window -t 2
bind -n M-3 select-window -t 3
bind -n M-4 select-window -t 4
bind -n M-5 select-window -t 5
bind -n M-6 select-window -t 6
bind -n M-7 select-window -t 7
bind -n M-8 select-window -t 8
bind -n M-9 select-window -t 9


# ------------------------------------------------------------
# Pane appearance
# ------------------------------------------------------------

set -g pane-border-status off

set -g pane-border-style 'fg=colour238'

set -g pane-active-border-style 'fg=cyan'


# ------------------------------------------------------------
# Status bar
# ------------------------------------------------------------

set -g status on

set -g status-interval 5

set -g status-left-length 50

set -g status-right-length 100

set -g status-left '#[bold] #S '

set -g status-right '#(hostname)  %Y-%m-%d %H:%M'


# ------------------------------------------------------------
# Terminal title
# ------------------------------------------------------------

set -g set-titles on

set -g set-titles-string '#S:#I.#P - #W'


# ------------------------------------------------------------
# Activity
# ------------------------------------------------------------

setw -g monitor-activity off

set -g visual-activity off


# ------------------------------------------------------------
# SSH / long running process
# ------------------------------------------------------------

# 不因为 session/window 销毁导致其它 pane 被一起关闭
set -g detach-on-destroy off

# 不强制根据最小 pane 调整尺寸
setw -g aggressive-resize off


# ------------------------------------------------------------
# Environment
# ------------------------------------------------------------

set -g update-environment \
    "DISPLAY SSH_ASKPASS SSH_AUTH_SOCK SSH_CONNECTION \
     SSH_TTY SSH_CLIENT XAUTHORITY WAYLAND_DISPLAY \
     XDG_CURRENT_DESKTOP"


# ------------------------------------------------------------
# Claude Code / Codex 建议：
#
# 不在这里设置：
#
#   remain-on-exit
#
# 因为 Claude / Codex 正常退出后，
# 我们希望 session 可以正常管理。
#
# 长时间运行应该使用：
#
#   tmux new -As claude
#   tmux new -As codex
#
# ------------------------------------------------------------
EOF

    chmod 600 "$TMUX_CONF"

    echo
    echo "tmux 配置已生成："
    echo "  $TMUX_CONF"
}


# ============================================================
# Config only
# ============================================================

if [[ "$CONFIG_ONLY" == true ]]; then
    write_tmux_config

    echo
    echo "完成。"
    exit 0
fi


# ============================================================
# APT
# ============================================================

log "安装编译依赖"

apt-get update

apt-get install -y \
    build-essential \
    autoconf \
    automake \
    pkg-config \
    bison \
    flex \
    libevent-dev \
    libncurses-dev \
    libncursesw5-dev \
    libutempter-dev \
    git \
    ca-certificates \
    curl \
    xz-utils


# ============================================================
# 获取最新 tmux Release
# ============================================================

log "检测 tmux 最新稳定版本"

TMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT


LATEST_TAG="$(
    git ls-remote \
        --tags \
        --refs \
        https://github.com/tmux/tmux.git \
    | awk -F/ '{print $3}' \
    | grep -E '^3\.[0-9]+[a-z]?$' \
    | sort -V \
    | tail -n1
)"

[[ -n "$LATEST_TAG" ]] || die "无法获取 tmux 最新版本。"

echo "最新稳定版：$LATEST_TAG"


# ============================================================
# 判断当前版本
# ============================================================

CURRENT_VERSION=""

if command -v tmux >/dev/null 2>&1; then
    CURRENT_VERSION="$(tmux -V 2>/dev/null || true)"
fi

echo "当前 tmux：${CURRENT_VERSION:-未安装}"


# ============================================================
# 编译
# ============================================================

log "下载 tmux $LATEST_TAG"

git clone \
    --depth=1 \
    --branch "$LATEST_TAG" \
    https://github.com/tmux/tmux.git \
    "$TMP_DIR/tmux"

cd "$TMP_DIR/tmux"


log "配置编译环境"

sh autogen.sh

./configure \
    --prefix="$TMUX_PREFIX" \
    --sysconfdir=/etc \
    --disable-static


log "开始编译"

make -j"$(nproc)"


log "安装 tmux"

make install


# ============================================================
# ldconfig
# ============================================================

if [[ -d /usr/local/lib ]]; then
    echo "/usr/local/lib" > /etc/ld.so.conf.d/usr-local.conf
    ldconfig
fi


# ============================================================
# PATH
# ============================================================

log "配置 PATH"

cat > /etc/profile.d/local-bin.sh <<'EOF'
export PATH="/usr/local/bin:$PATH"
EOF

chmod 644 /etc/profile.d/local-bin.sh

export PATH="/usr/local/bin:$PATH"

hash -r


# ============================================================
# 验证
# ============================================================

log "验证 tmux"

[[ -x "$TMUX_BIN" ]] || die "tmux 安装失败：$TMUX_BIN 不存在。"

echo "tmux binary : $TMUX_BIN"
echo "tmux version : $("$TMUX_BIN" -V)"


# ============================================================
# 生成配置
# ============================================================

if [[ "$NO_CONFIG" == false ]]; then
    write_tmux_config
fi


# ============================================================
# 检查配置
# ============================================================

log "检查 tmux 配置"

if "$TMUX_BIN" -f "$TMUX_CONF" start-server \; kill-server 2>/dev/null; then
    echo "tmux 配置检查：OK"
else
    echo
    echo "WARNING: tmux 配置检查失败。"
    echo "请执行："
    echo
    echo "  $TMUX_BIN -f $TMUX_CONF"
    exit 1
fi


# ============================================================
# 最终信息
# ============================================================

log "安装完成"

echo
echo "tmux："
echo "  $("$TMUX_BIN" -V)"

echo
echo "位置："
echo "  $(command -v tmux)"

echo
echo "配置："
echo "  $TMUX_CONF"

echo
echo "推荐启动 Claude："
echo "  tmux new -As claude"

echo
echo "推荐启动 Codex："
echo "  tmux new -As codex"

echo
echo "重新连接："
echo "  tmux attach -t claude"
echo "  tmux attach -t codex"

echo
echo "Prefix："
echo "  Ctrl+A"

echo
echo "配置重新加载："
echo "  Ctrl+A 然后按 r"

echo
echo "============================================================"
