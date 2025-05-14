#!/usr/bin/env bash
#
# smart-stop-tmux.sh — 先优雅后强制关闭所有 tmux 会话
# Author: Lilja Peltola (@emmanuelthalie35)
#
# 用法：
#   ./smart-stop-tmux.sh          # 只关当前用户
#   sudo ./smart-stop-tmux.sh     # 关全系统（root）
#
set -euo pipefail

# 若系统未安装 tmux，直接退出
command -v tmux &>/dev/null || { echo "tmux 未安装或不在 PATH，已跳过。"; exit 0; }

uid=$(id -u)

#######################################
# 1. 收集 tmux sockets（用于优雅关闭）
#######################################
declare -a SOCKETS
# 当前用户
mapfile -t SOCKETS < <(find /tmp -maxdepth 1 -type s -user "$uid" -name "tmux-*")

# root 再并入其他用户
if [[ $uid -eq 0 ]]; then
  mapfile -t ALL_SOCKETS < <(find /tmp -maxdepth 1 -type s -name "tmux-*")
  SOCKETS+=("${ALL_SOCKETS[@]}")
fi
SOCKETS=($(printf '%s\n' "${SOCKETS[@]}" | sort -u))  # 去重

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

# 等待 3 秒让 tmux 自行退出
sleep 3

#######################################
# 3. 检查是否仍有残留进程
#######################################
leftover_pids=()
if [[ $uid -eq 0 ]]; then
  mapfile -t leftover_pids < <(pgrep -x tmux)
else
  mapfile -t leftover_pids < <(pgrep -x -u "$uid" tmux)
fi

if (( ${#leftover_pids[@]} )); then
  echo "检测到 ${#leftover_pids[@]} 个 tmux 进程未退出，执行强制关闭 (SIGKILL)..."
  kill -9 "${leftover_pids[@]}" 2>/dev/null || true
  echo "已强制终止所有残留 tmux 进程。"
else
  echo "所有 tmux 会话已优雅关闭。"
fi
