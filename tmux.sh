#!/usr/bin/env bash
#
# install-tmux.sh
#
# Debian / Ubuntu
#
# 功能：
#   1. 检测已有 tmux
#   2. 停止旧 tmux server
#   3. 卸载 apt 安装的 tmux
#   4. 获取最新稳定版 tmux
#   5. 源码编译安装到 /usr/local
#   6. 清理旧版本残留
#   7. 配置 PATH
#   8. 生成 Claude Code / Codex 长时间运行优化配置
#   9. 自动备份旧 ~/.tmux.conf
#  10. 最终检查
#
# 使用：
#   bash install-tmux.sh
#
# ============================================================

set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

TMUX_PREFIX="/usr/local"
TMUX_BIN="/usr/local/bin/tmux"
TMUX_CONF="/root/.tmux.conf"

TMP_DIR=""

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

if [[ "${EUID}" -ne 0 ]]; then
    echo "请使用 root 运行："
    echo
    echo "  sudo bash $0"
    exit 1
fi


# ============================================================
# OS 检查
# ============================================================

[[ -f /etc/os-release ]] || die "无法检测操作系统"

source /etc/os-release

case "${ID:-}" in
    ubuntu|debian)
        ;;
    *)
        die "仅支持 Debian / Ubuntu，当前系统：${PRETTY_NAME:-unknown}"
        ;;
esac


log "系统信息"

echo "系统      : ${PRETTY_NAME:-unknown}"
echo "架构      : $(dpkg --print-architecture 2>/dev/null || uname -m)"
echo "内核      : $(uname -r)"


# ============================================================
# 检测旧 tmux
# ============================================================

log "检测已有 tmux"

OLD_TMUX=false

if command -v tmux >/dev/null 2>&1; then
    OLD_TMUX=true

    echo "发现 tmux："
    echo "路径    : $(command -v tmux)"
    echo "版本    : $(tmux -V 2>/dev/null || echo unknown)"
fi

if [[ -x /usr/bin/tmux ]]; then
    OLD_TMUX=true

    echo
    echo "系统 tmux："
    echo "路径    : /usr/bin/tmux"
    echo "版本    : $(/usr/bin/tmux -V 2>/dev/null || echo unknown)"
fi

if [[ -x /usr/local/bin/tmux ]]; then
    OLD_TMUX=true

    echo
    echo "本地 tmux："
    echo "路径    : /usr/local/bin/tmux"
    echo "版本    : $(/usr/local/bin/tmux -V 2>/dev/null || echo unknown)"
fi


# ============================================================
# 停止已有 tmux server
# ============================================================

if [[ "$OLD_TMUX" == true ]]; then

    log "检查 tmux Server"

    if tmux ls >/dev/null 2>&1; then

        echo
        echo "发现正在运行的 tmux Server："
        tmux ls || true

        echo
        echo "注意："
        echo "卸载旧 tmux 前必须停止 tmux Server。"
        echo "如果里面正在运行 Claude / Codex / 其他程序，"
        echo "这些程序会随着 tmux Server 关闭而终止。"
        echo

        read -r -p "确认停止旧 tmux Server 并继续升级？[y/N] " answer

        case "$answer" in
            y|Y|yes|YES)
                echo
                echo "停止 tmux Server..."
                tmux kill-server || true
                sleep 1
                ;;
            *)
                echo
                echo "已取消安装。"
                exit 0
                ;;
        esac

    else
        echo "没有正在运行的 tmux Server。"
    fi
fi


# ============================================================
# 卸载系统 tmux
# ============================================================

log "卸载旧版 tmux"

if dpkg-query -W -f='${Status}' tmux 2>/dev/null \
    | grep -q "install ok installed"; then

    echo "发现 apt 安装的 tmux，正在卸载..."

    apt-get remove -y tmux

    echo "旧 tmux 已卸载。"
else
    echo "没有发现 apt 安装的 tmux。"
fi


# ============================================================
# 清理旧源码安装版本
# ============================================================

if [[ -x /usr/local/bin/tmux ]]; then

    echo
    echo "发现旧的 /usr/local/bin/tmux"

    /usr/local/bin/tmux -V || true

    rm -f /usr/local/bin/tmux

    echo "旧的 /usr/local/bin/tmux 已删除。"
fi


# ============================================================
# 清理可能的残留
# ============================================================

rm -f /usr/local/sbin/tmux

hash -r 2>/dev/null || true


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
    xz-utils


# ============================================================
# 获取最新稳定版本
# ============================================================

log "获取 tmux 最新稳定版本"

TMP_DIR="$(mktemp -d)"

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
echo "最新稳定版：$LATEST_TAG"


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


log "配置编译"

./configure \
    --prefix=/usr/local \
    --sysconfdir=/etc \
    --disable-static


log "编译 tmux"

make -j"$(nproc)"


# ============================================================
# 安装
# ============================================================

log "安装 tmux"

make install


# ============================================================
# 动态库
# ============================================================

if [[ -d /usr/local/lib ]]; then

    cat > /etc/ld.so.conf.d/usr-local.conf <<'EOF'
/usr/local/lib
EOF

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
# 确认新 tmux
# ============================================================

log "验证 tmux"

[[ -x "$TMUX_BIN" ]] || die "tmux 安装失败"

echo
echo "tmux 路径："
command -v tmux

echo
echo "tmux 版本："
tmux -V


# ============================================================
# 备份旧配置
# ============================================================

log "处理 tmux 配置"

if [[ -f "$TMUX_CONF" ]]; then

    BACKUP="${TMUX_CONF}.backup.$(date +%Y%m%d-%H%M%S)"

    cp -a "$TMUX_CONF" "$BACKUP"

    echo "旧配置已备份："
    echo "  $BACKUP"
fi


# ============================================================
# Claude Code / Codex 配置
# ============================================================

cat > "$TMUX_CONF" <<'EOF'
# ============================================================
# tmux
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

set -g history-limit 50000

set -s escape-time 10

set -g repeat-time 300

set -g default-terminal "tmux-256color"


# ------------------------------------------------------------
# Modern Terminal
# ------------------------------------------------------------

set -s extended-keys on

set -as terminal-features 'xterm*:extkeys'

set -as terminal-features 'xterm*:focus'

set -as terminal-features 'xterm*:RGB'

set -as terminal-features 'xterm*:clipboard'

set -as terminal-features ',*:RGB'

set -as terminal-features ',*:256'


# ------------------------------------------------------------
# Claude Code / Codex
# ------------------------------------------------------------

set -g allow-passthrough on


# ------------------------------------------------------------
# Window
# ------------------------------------------------------------

set -g base-index 1

setw -g pane-base-index 1

set -g renumber-windows on

setw -g automatic-rename on

setw -g allow-rename on


# ------------------------------------------------------------
# 新窗口 / Pane 保持当前目录
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
bind -n M-Left select-pane -L
bind -n M-Right select-pane -R
bind -n M-Up select-pane -U
bind -n M-Down select-pane -D


# ------------------------------------------------------------
# Pane Resize
# ------------------------------------------------------------

bind -r H resize-pane -L 5
bind -r J resize-pane -D 5
bind -r K resize-pane -U 5
bind -r L resize-pane -R 5


# ------------------------------------------------------------
# Window
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
# Window 快速切换
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
# Pane 外观
# ------------------------------------------------------------

set -g pane-border-status off

set -g pane-border-style 'fg=colour238'

set -g pane-active-border-style 'fg=cyan'


# ------------------------------------------------------------
# Status
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
# SSH / Long Running
# ------------------------------------------------------------

set -g detach-on-destroy off

setw -g aggressive-resize off


# ------------------------------------------------------------
# Environment
# ------------------------------------------------------------

set -g update-environment \
    "DISPLAY SSH_ASKPASS SSH_AUTH_SOCK SSH_CONNECTION \
     SSH_TTY SSH_CLIENT XAUTHORITY WAYLAND_DISPLAY \
     XDG_CURRENT_DESKTOP"


# ============================================================
# 推荐：
#
# Claude:
#   tmux new -As claude
#   claude
#
# Codex:
#   tmux new -As codex
#   codex
#
# 重连：
#   tmux attach -t claude
#   tmux attach -t codex
# ============================================================
EOF

chmod 600 "$TMUX_CONF"


# ============================================================
# 配置检查
# ============================================================

log "检查 tmux 配置"

"$TMUX_BIN" -f "$TMUX_CONF" \
    start-server \; \
    kill-server

echo "配置检查：OK"


# ============================================================
# 最终检查
# ============================================================

log "安装完成"

echo
echo "系统："
echo "  ${PRETTY_NAME:-unknown}"

echo
echo "tmux："
echo "  $(command -v tmux)"

echo
echo "版本："
echo "  $(tmux -V)"

echo
echo "配置："
echo "  $TMUX_CONF"

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
echo "Prefix：Ctrl+A"

echo
echo "============================================================"
echo " tmux 安装 / 升级完成"
echo "============================================================"
