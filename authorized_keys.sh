#!/bin/bash

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 创建 .ssh 目录并设置权限
mkdir -p ~/.ssh
chmod 700 ~/.ssh

# 创建 authorized_keys 文件并设置权限
touch ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

echo -e "${YELLOW}请输入你的 SSH 公钥（以 ssh-rsa 或 ssh-ed25519 开头）：${NC}"
read -r pubkey

# 验证公钥格式
if [[ ! $pubkey =~ ^(ssh-rsa|ssh-ed25519) ]]; then
    echo -e "${YELLOW}警告：输入的不像是有效的 SSH 公钥${NC}"
    echo -e "${YELLOW}是否继续？(y/n)${NC}"
    read -r confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        echo "操作已取消"
        exit 1
    fi
fi

# 添加公钥
echo "$pubkey" >> ~/.ssh/authorized_keys

# 修改 SSH 配置
sudo sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config
sudo sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config

# 重启 SSH 服务
sudo systemctl restart sshd

echo -e "${GREEN}SSH 密钥登录配置完成！${NC}"
echo -e "${YELLOW}重要：请保持当前会话，新开一个终端测试密钥登录是否正常！${NC}"
echo -e "${YELLOW}如果需要恢复密码登录，请执行：${NC}"
echo 'sudo sed -i "s/PasswordAuthentication no/PasswordAuthentication yes/" /etc/ssh/sshd_config && sudo systemctl restart sshd'
