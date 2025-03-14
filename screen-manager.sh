#!/bin/sh
# Screen 会话管理脚本 - 兼容 sh 和 bash
# 用途: 列出并管理screen会话

# 清屏
clear

# 检测是否支持颜色
if [ -t 1 ]; then
  # 定义基本颜色
  ncolors=$(tput colors 2>/dev/null || echo 0)
  if [ $ncolors -ge 8 ]; then
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    RED=$(tput setaf 1)
    BLUE=$(tput setaf 4)
    BOLD=$(tput bold)
    NORMAL=$(tput sgr0)
  else
    GREEN=""
    YELLOW=""
    RED=""
    BLUE=""
    BOLD=""
    NORMAL=""
  fi
else
  GREEN=""
  YELLOW=""
  RED=""
  BLUE=""
  BOLD=""
  NORMAL=""
fi

# 显示标题
echo "${GREEN}${BOLD}Screen 会话管理器${NORMAL}"
echo "==============================="

# 检查 screen 是否已安装
if ! command -v screen >/dev/null 2>&1; then
  echo "${RED}错误: screen 命令未找到，请先安装 screen${NORMAL}"
  echo "在 Debian/Ubuntu 系统中，可以使用命令：sudo apt-get install screen"
  echo "在 CentOS/RHEL 系统中，可以使用命令：sudo yum install screen"
  exit 1
fi

# 创建临时文件
tmp_dir="/tmp"
prefix="screen_sessions_"
tmp_file="${tmp_dir}/${prefix}$$"

# 确保退出时删除临时文件
trap 'rm -f ${tmp_file}*' EXIT

# 获取当前所有 screen 会话
screen -ls > "${tmp_file}"

# 检查是否有活跃的 screen 会话
if grep -q "No Sockets found" "${tmp_file}"; then
  echo "${YELLOW}当前没有 screen 会话运行${NORMAL}"
  exit 0
fi

# 提取 screen 会话信息并过滤
grep -E '\s+[0-9]+\.' "${tmp_file}" | sed 's/^\s*//' > "${tmp_file}.filtered"

# 显示会话列表
echo "${BLUE}当前活跃的 screen 会话:${NORMAL}"
echo "-------------------------------"

# 计数器
i=1

# 读取并显示会话
while read -r line; do
  # 提取PID (会话ID)
  pid=$(echo "$line" | cut -d. -f1)
  
  # 提取会话名称 (如果有)
  session_name=$(echo "$line" | cut -d. -f2- | sed 's/(.*)$//' | tr -d '\t' | sed 's/^[ \t]*//;s/[ \t]*$//')
  
  # 如果这只是一个数字ID没有名称，则使用默认名称
  if [ -z "$session_name" ]; then
    session_name="session-$pid"
  fi
  
  # 保存会话信息到临时文件
  echo "$pid:$session_name" >> "${tmp_file}.data"
  
  # 显示会话信息
  echo "$i) ${YELLOW}$session_name${NORMAL} (PID: $pid)"
  
  i=$((i + 1))
done < "${tmp_file}.filtered"

total=$((i - 1))

echo "-------------------------------"
echo "$i) ${RED}关闭所有会话${NORMAL}"
echo "q) ${GREEN}退出管理器${NORMAL}"
echo "-------------------------------"

# 提示用户选择
echo "${BLUE}请输入序号选择要关闭的会话，输入 'q' 退出:${NORMAL}"
read -r choice

# 处理用户选择
if [ "$choice" = "q" ]; then
  echo "${GREEN}退出管理器${NORMAL}"
  exit 0
elif [ "$choice" = "$i" ]; then
  # 关闭所有会话
  echo "${RED}正在关闭所有 screen 会话...${NORMAL}"
  
  j=1
  while read -r data_line; do
    pid=$(echo "$data_line" | cut -d: -f1)
    name=$(echo "$data_line" | cut -d: -f2)
    
    echo "关闭会话: ${YELLOW}$name${NORMAL} (PID: $pid)"
    screen -S "$pid" -X quit
    
    j=$((j + 1))
  done < "${tmp_file}.data"
  
  echo "${GREEN}所有会话已关闭${NORMAL}"
elif [ -n "$choice" ] && [ "$choice" -eq "$choice" ] 2>/dev/null; then
  # 检查是否是有效数字且在范围内
  if [ "$choice" -ge 1 ] && [ "$choice" -le "$total" ]; then
    # 获取选定会话信息
    selected=$(sed -n "${choice}p" "${tmp_file}.data")
    pid=$(echo "$selected" | cut -d: -f1)
    name=$(echo "$selected" | cut -d: -f2)
    
    # 关闭选定会话
    echo "${RED}正在关闭会话: ${YELLOW}$name${NORMAL} (PID: $pid)${NORMAL}"
    screen -S "$pid" -X quit
    echo "${GREEN}会话已关闭${NORMAL}"
  else
    echo "${RED}无效的选择: 超出范围${NORMAL}"
  fi
else
  echo "${RED}无效的选择: 请输入数字或 'q'${NORMAL}"
fi

exit 0
