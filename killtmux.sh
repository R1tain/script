#!/usr/bin/env bash
#
# smart-stop-tmux.sh — 先优雅再强制关闭所有 tmux 会话（改进版）
# Author: Lilja Peltola (@emmanuelthalie35)
#
# 用法：
#   ./smart-stop-tmux.sh          # 仅关当前用户
#   sudo ./smart-stop-tmux.sh     # 关全系统（root）
#
set -euo pipefail

command -v tmux &>/dev/null || { echo "tmux 未安装或不在 PATH，已跳过。"; exit 0; }

uid=$(id -u)

#######################################
# 1. 收集 tmux sockets
#######################################
collect_sockets() {
  local -a paths=()

  # /tmp/tmux-UID/…   通常深度 = 2
  if [[ $uid -eq 0 ]]; then
    mapfile -t paths < <(find /tmp -maxdepth 2 -type s -path "/tmp/tmux-*/*" 2>/dev/null)
  else
    mapfile -t paths < <(find /tmp -maxdepth 2 -type s -user "$uid" -path "/tmp/tmux-*/*" 2>/dev/null)
  fi

  # /run/user/UID/tmux-…/…   systemd‑user 环境常见
  if [[ -d /run/user ]]; then
    if [[ $uid -eq 0 ]]; then
      mapfile -t runpaths < <(find /run/user -maxdepth 3 -type s -path "/run/user/*/tmux-*/*" 2>/dev/null)
    else
      mapfile -t runpaths < <(find "/run/user/$uid" -maxdepth 2 -type s -path "/run/user/$uid/tmux-*/*" 2>/dev/null || true)
    fi
    paths+=("${runpaths[@]}")
  fi

  printf '%s\n' "${paths[@]}" | sort -u
}

mapfile -t SOCKETS < <(collect_sockets)

#######################################
# 2. 优雅关闭
#######################################
if (( ${#SOCKETS[@]} )); then
  echo "尝试优雅关闭 ${#SOCKETS[@]} 个 tmux 服务器..."
  for sock in "${SOCKETS[@]}"; do
    tmux -S "$sock" kill-server 2>/dev/null || true
  done
else
  echo "未发现正在运行的 tmux 会话。"
fi

sleep 3  # 给 tmux 自行退出的时间

#######################################
# 3. 强制扫尾
#######################################
leftover_pids=()
if [[ $uid -eq 0 ]]; then
  mapfile -t leftover_pids < <(pgrep -x tmux)
else
  mapfile -t leftover_pids < <(pgrep -x -u "$uid" tmux)
fi

if (( ${#leftover_pids[@]} )); then
  echo "仍有 ${#leftover_pids[@]} 个 tmux 进程存活，执行 SIGKILL..."
  kill -9 "${leftover_pids[@]}" 2>/dev/null || true
  echo "已强制终止所有残留 tmux 进程。"
else
  echo "所有 tmux 会话已优雅关闭。"
fi
