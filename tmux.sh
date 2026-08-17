#!/usr/bin/env bash
#
# install-tmux.sh
#
# Debian / Ubuntu
#
# tmux 最新稳定版源码安装
# Claude Code / OpenAI Codex 长时间运行优化
#
# 特性：
#   - 自动卸载旧 tmux
#   - 自动关闭所有旧 tmux session
#   - 删除旧 ~/.tmux.conf，不保留
#   - 自动获取最新稳定版
#   - 源码编译安装
#   - 首次安装不创建 /usr/bin/tmux
#   - 升级旧版本时保留 /usr/bin/tmux 兼容入口
#   - 自动处理 PATH
#   - 无需手动 hash -r
#
# ============================================================

set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

readonly TMUX_PREFIX="/usr/local"
readonly TMUX_BIN="/usr/local/bin/tmux"
readonly SYSTEM_TMUX="/usr/bin/tmux"
readonly TMUX_CONF="/root/.tmux.conf"
readonly PROFILE_FILE="/etc/profile.d/local-bin.sh"

TMP_DIR=""

# ============================================================
# 日志
# ============================================================

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

cleanup() {
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}

trap cleanup EXIT


# ============================================================
# Root
# ============================================================

if [[ "$EUID" -ne 0 ]]; then
    die "请使用 root 运行：sudo bash $0"
fi


# ============================================================
# OS
# ============================================================

[[ -f /etc/os-release ]] || die "无法检测操作系统"

source /etc/os-release

case "${ID:-}" in
    ubuntu|debian)
        ;;
    *)
        die "仅支持 Debian / Ubuntu。当前系统：${PRETTY_NAME:-unknown}"
        ;;
esac


log "系统信息"

echo "系统      : ${PRETTY_NAME:-unknown}"
echo "架构      : $(dpkg --print-architecture 2>/dev/null || uname -m)"
echo "内核      : $(uname -r)"
echo "CPU       : $(nproc) 核"


# ============================================================
# 记录升级前 /usr/bin/tmux 是否存在
#
# 用于决定升级完成后是否创建兼容软链接
# ============================================================

COMPAT_LINK=false

if [[ -e "$SYSTEM_TMUX" || -L "$SYSTEM_TMUX" ]]; then
    COMPAT_LINK=true
fi


# ============================================================
# 检测 tmux
# ============================================================

log "检测旧 tmux"

if command -v tmux >/dev/null 2>&1; then
    echo "当前 tmux："
    tmux -V 2>/dev/null || true
fi

if [[ -x "$SYSTEM_TMUX" ]]; then
    echo
    echo "/usr/bin/tmux："
    "$SYSTEM_TMUX" -V 2>/dev/null || true
fi

if [[ -x "$TMUX_BIN" ]]; then
    echo
    echo "/usr/local/bin/tmux："
    "$TMUX_BIN" -V 2>/dev/null || true
fi


# ============================================================
# 关闭所有 tmux session
#
# 注意：
# Claude / Codex / Shell 等运行中的程序会被终止
# ============================================================

log "关闭旧 tmux Server"

TMUX_RUNNING=false

for candidate in \
    "$SYSTEM_TMUX" \
    "$TMUX_BIN" \
    "$(command -v tmux 2>/dev/null || true)"
do

    [[ -n "$candidate" ]] || continue
    [[ -x "$candidate" ]] || continue

    if "$candidate" ls >/dev/null 2>&1; then

        TMUX_RUNNING=true

        echo
        echo "发现 tmux session："

        "$candidate" ls || true

        echo
        echo "正在关闭 tmux Server..."

        "$candidate" kill-server 2>/dev/null || true

        sleep 1

        break
    fi
done

if [[ "$TMUX_RUNNING" == false ]]; then
    echo "没有运行中的 tmux Server。"
fi


# ============================================================
# 删除旧配置
# ============================================================

log "删除旧 tmux 配置"

if [[ -f "$TMUX_CONF" ]]; then
    rm -f "$TMUX_CONF"
    echo "已删除：$TMUX_CONF"
else
    echo "不存在旧配置。"
fi


# ============================================================
# 卸载 apt tmux
# ============================================================

log "卸载旧版 tmux"

if dpkg-query -W -f='${Status}' tmux 2>/dev/null \
    | grep -q "install ok installed"; then

    echo "发现 apt 安装的 tmux"

    apt-get remove -y tmux

    echo "apt tmux 已卸载。"
else
    echo "没有 apt 安装的 tmux。"
fi


# ============================================================
# 删除旧源码版本
# ============================================================

if [[ -e "$TMUX_BIN" || -L "$TMUX_BIN" ]]; then

    echo
    echo "删除旧源码 tmux：$TMUX_BIN"

    rm -f "$TMUX_BIN"
fi


# ============================================================
# 删除旧 /usr/bin/tmux
#
# 如果升级前存在，安装完成后会重新创建兼容软链接
# ============================================================

if [[ -e "$SYSTEM_TMUX" || -L "$SYSTEM_TMUX" ]]; then

    echo
    echo "删除旧系统 tmux：$SYSTEM_TMUX"

    rm -f "$SYSTEM_TMUX"
fi


# ============================================================
# 安装编译依赖
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
    xz-utils \
    file


# ============================================================
# 临时目录
# ============================================================

TMP_DIR="$(mktemp -d)"


# ============================================================
# 获取最新稳定版本
# ============================================================

log "获取 tmux 最新稳定版"

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

[[ -n "$LATEST_TAG" ]] || die "无法获取 tmux 最新稳定版本"

echo
echo "最新版本：$LATEST_TAG"


# ============================================================
# 下载源码
# ============================================================

log "下载 tmux $LATEST_TAG"

git clone \
    --depth=1 \
    --branch "$LATEST_TAG" \
    https://github.com/tmux/tmux.git \
    "$TMP_DIR/tmux"

cd "$TMP_DIR/tmux"


# ============================================================
# 编译
# ============================================================

log "生成 configure"

sh autogen.sh


log "配置编译参数"

./configure \
    --prefix=/usr/local \
    --sysconfdir=/etc \
    --disable-static


log "开始编译"

make -j"$(nproc)"


# ============================================================
# 安装
# ============================================================

log "安装 tmux"

make install


[[ -x "$TMUX_BIN" ]] || die "tmux 安装失败"


# ============================================================
# 动态库
# ============================================================

if [[ -d /usr/local/lib ]]; then

    echo "/usr/local/lib" \
        > /etc/ld.so.conf.d/usr-local.conf

    ldconfig
fi


# ============================================================
# PATH
# ============================================================

log "配置 PATH"

cat > "$PROFILE_FILE" <<'EOF'
export PATH="/usr/local/bin:$PATH"
EOF

chmod 644 "$PROFILE_FILE"

export PATH="/usr/local/bin:$PATH"

hash -r 2>/dev/null || true


# ============================================================
# /usr/bin/tmux 兼容入口
#
# 只有升级前存在 /usr/bin/tmux 时才创建
#
# 首次安装：
#   不创建
#
# 升级：
#   创建
#
# ============================================================

if [[ "$COMPAT_LINK" == true ]]; then

    log "创建兼容软链接"

    ln -s "$TMUX_BIN" "$SYSTEM_TMUX"

    echo
    echo "$SYSTEM_TMUX -> $TMUX_BIN"

else

    echo
    echo "首次安装，不创建 $SYSTEM_TMUX"
fi


# ============================================================
# 生成全新 tmux 配置
# ============================================================

log "生成 Claude Code / Codex 优化配置"

cat > "$TMUX_CONF" <<'EOF'
# ============================================================
# tmux
#
# Claude Code / OpenAI Codex
# SSH 长时间运行优化
# ============================================================

# ============================================================
# Prefix
# ============================================================

# 默认 Prefix：Ctrl+B
set -g prefix C-b

# 兼容 Ctrl+A
bind C-a send-prefix

# ============================================================
# 基础
# ============================================================

set -g mouse on

set -g focus-events on

set -g history-limit 50000

set -s escape-time 10

set -g repeat-time 300

set -g default-terminal "tmux-256color"


# ============================================================
# Modern Terminal
# ============================================================

set -s extended-keys on

set -as terminal-features 'xterm*:extkeys'

set -as terminal-features 'xterm*:focus'

set -as terminal-features 'xterm*:RGB'

set -as terminal-features 'xterm*:clipboard'

set -as terminal-features ',*:RGB'

set -as terminal-features ',*:256'


# ============================================================
# Claude Code / Codex
# ============================================================

set -g allow-passthrough on


# ============================================================
# Window
# ============================================================

set -g base-index 1

setw -g pane-base-index 1

set -g renumber-windows on

setw -g automatic-rename on

setw -g allow-rename on


# ============================================================
# 新窗口保持当前目录
# ============================================================

bind c new-window -c "#{pane_current_path}"

bind '"' split-window -v -c "#{pane_current_path}"

bind % split-window -h -c "#{pane_current_path}"

bind | split-window -h -c "#{pane_current_path}"

bind - split-window -v -c "#{pane_current_path}"


# ============================================================
# Pane Navigation
# ============================================================

bind h select-pane -L
bind j select-pane -D
bind k select-pane -U
bind l select-pane -R


# Alt + 方向键
bind -n M-Left select-pane -L
bind -n M-Right select-pane -R
bind -n M-Up select-pane -U
bind -n M-Down select-pane -D


# ============================================================
# Pane Resize
# ============================================================

bind -r H resize-pane -L 5
bind -r J resize-pane -D 5
bind -r K resize-pane -U 5
bind -r L resize-pane -R 5


# ============================================================
# Window Navigation
# ============================================================

bind -r C-h previous-window
bind -r C-l next-window


# ============================================================
# Copy Mode
# ============================================================

setw -g mode-keys vi

bind -T copy-mode-vi v \
    send-keys -X begin-selection

bind -T copy-mode-vi y \
    send-keys -X copy-selection-and-cancel

bind -T copy-mode-vi C-v \
    send-keys -X rectangle-toggle


# ============================================================
# Paste
# ============================================================

bind p paste-buffer


# ============================================================
# Reload
# ============================================================

bind r \
    source-file ~/.tmux.conf \; \
    display-message "tmux config reloaded"


# ============================================================
# 快速窗口
# ============================================================

bind -n M-1 select-window -t 1
bind -n M-2 select-window -t 2
bind -n M-3 select-window -t 3
bind -n M-4 select-window -t 4
bind -n M-5 select-window -t 5
bind -n M-6 select-window -t 6
bind -n M-7 select-window -t 7
bind -n M-8 select-window -t 8
bind -n M-9 select-window -t 9


# ============================================================
# Pane Appearance
# ============================================================

set -g pane-border-status off

set -g pane-border-style 'fg=colour238'

set -g pane-active-border-style 'fg=cyan'


# ============================================================
# Status Bar
# ============================================================

set -g status on

set -g status-interval 5

set -g status-left-length 50

set -g status-right-length 100

set -g status-left '#[bold] #S '

set -g status-right '#(hostname)  %Y-%m-%d %H:%M'


# ============================================================
# Terminal Title
# ============================================================

set -g set-titles on

set -g set-titles-string '#S:#I.#P - #W'


# ============================================================
# Activity
# ============================================================

setw -g monitor-activity off

set -g visual-activity off


# ============================================================
# SSH / Long Running
# ============================================================

set -g detach-on-destroy off

setw -g aggressive-resize off


# ============================================================
# Environment
# ============================================================

set -g update-environment \
    "DISPLAY SSH_ASKPASS SSH_AUTH_SOCK SSH_CONNECTION \
     SSH_TTY SSH_CLIENT XAUTHORITY WAYLAND_DISPLAY \
     XDG_CURRENT_DESKTOP"


# ============================================================
# 推荐
#
# Claude：
#
#   tmux new -As claude
#   claude
#
# Codex：
#
#   tmux new -As codex
#   codex
#
# 重新连接：
#
#   tmux attach -t claude
#   tmux attach -t codex
#
# Prefix：
#
#   Ctrl+A
#
# ============================================================
EOF

chmod 600 "$TMUX_CONF"


# ============================================================
# 配置检查
# ============================================================

log "检查 tmux 配置"

"$TMUX_BIN" \
    -f "$TMUX_CONF" \
    start-server \; \
    kill-server

echo "配置检查：OK"


# ============================================================
# 最终 PATH
# ============================================================

export PATH="/usr/local/bin:$PATH"

hash -r 2>/dev/null || true


# ============================================================
# 最终检查
# ============================================================

log "最终检查"

echo
echo "tmux 版本："
tmux -V

echo
echo "tmux 路径："
type -a tmux

echo
echo "实际二进制："
readlink -f "$(command -v tmux)"

echo
echo "配置文件："
ls -lh "$TMUX_CONF"


if [[ "$COMPAT_LINK" == true ]]; then
    echo
    echo "兼容入口："
    ls -l "$SYSTEM_TMUX"
fi


# ============================================================
# 完成
# ============================================================

log "tmux 安装 / 升级完成"

echo
echo "Claude："
echo "  tmux new -As claude"

echo
echo "Codex："
echo "  tmux new -As codex"

echo
echo "重新连接："
echo "  tmux attach -t claude"
echo "  tmux attach -t codex"

echo
echo "Prefix：Ctrl+B（默认） / Ctrl+A（兼容）"

echo
echo "============================================================"
echo " 完成"
echo "============================================================"
