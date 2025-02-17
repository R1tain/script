#!/bin/bash

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# 检查是否以 root 权限运行
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}请使用 sudo 运行此脚本${NC}"
    exit 1
fi

# 获取当前 SSH 端口
current_port=$(grep -E "^Port" /etc/ssh/sshd_config | awk '{print $2}')
if [ -z "$current_port" ]; then
    current_port=22
fi
echo -e "${YELLOW}当前 SSH 端口: $current_port${NC}"

# 询问新的 SSH 端口
while true; do
    echo -e "${YELLOW}请输入新的 SSH 端口号 (1024-65535):${NC}"
    read -r new_port
    # 验证端口号
    if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1024 ] && [ "$new_port" -le 65535 ]; then
        # 检查端口是否已被占用
        if netstat -tuln | grep ":$new_port " >/dev/null; then
            echo -e "${RED}端口 $new_port 已被占用，请选择其他端口${NC}"
            continue
        fi
        break
    else
        echo -e "${RED}无效的端口号，请输入 1024-65535 之间的数字${NC}"
    fi
done

# 备份 SSH 配置文件
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
echo -e "${GREEN}SSH 配置文件已备份到 /etc/ssh/sshd_config.bak${NC}"

# 修改 SSH 端口
if grep -q "^Port" /etc/ssh/sshd_config; then
    sed -i "s/^Port .*/Port $new_port/" /etc/ssh/sshd_config
else
    sed -i "1i Port $new_port" /etc/ssh/sshd_config
fi

# 处理防火墙规则
if command -v ufw >/dev/null 2>&1; then
    echo -e "${YELLOW}检测到 UFW 防火墙，正在更新防火墙规则...${NC}"
    ufw allow "$new_port"/tcp
    ufw delete allow "$current_port"/tcp 2>/dev/null
    ufw status
elif command -v firewall-cmd >/dev/null 2>&1; then
    echo -e "${YELLOW}检测到 firewalld，正在更新防火墙规则...${NC}"
    firewall-cmd --permanent --add-port="$new_port"/tcp
    firewall-cmd --permanent --remove-port="$current_port"/tcp
    firewall-cmd --reload
    firewall-cmd --list-all
fi

# 检查配置文件语法
sshd -t
if [ $? -ne 0 ]; then
    echo -e "${RED}SSH 配置文件有误，正在还原备份...${NC}"
    cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
    systemctl restart sshd
    exit 1
fi

# 重启 SSH 服务
systemctl restart sshd

echo -e "\n${GREEN}SSH 端口修改完成！${NC}"
echo -e "${YELLOW}新的 SSH 端口: $new_port${NC}"
echo -e "\n${RED}重要提示：${NC}"
echo -e "1. 请保持当前会话，新开一个终端测试新端口连接："
echo -e "   ${GREEN}ssh -p $new_port user@your_server_ip${NC}"
echo -e "2. 确认可以使用新端口登录后，再关闭当前会话"
echo -e "3. 如果需要恢复原始配置，可以使用以下命令："
echo -e "   ${YELLOW}sudo cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config${NC}"
echo -e "   ${YELLOW}sudo systemctl restart sshd${NC}"

# 显示当前 SSH 端口配置
echo -e "\n${GREEN}当前 SSH 端口配置：${NC}"
grep -E "^Port" /etc/ssh/sshd_config
