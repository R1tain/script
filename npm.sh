#!/bin/bash

# --- 配置 ---
NETWORK_NAME="vv-yesterday"
SUBNET="172.29.0.0/24"
IP_ADDRESS="172.29.0.2"
# --- 结束配置 ---

# 函数：自动检测并返回可用的 compose 命令
find_compose_command() {
  if command -v docker-compose &> /dev/null; then
    echo "docker-compose"
  elif docker compose version &> /dev/null; then
    echo "docker compose"
  else
    echo ""
  fi
}

# 获取可用的命令
COMPOSE_CMD=$(find_compose_command)

# 如果找不到任何 compose 命令，则报错退出
if [ -z "$COMPOSE_CMD" ]; then
  echo "错误：找不到 'docker-compose' 或 'docker compose' 命令。" >&2
  echo "请确保已安装 Docker Compose (独立版或插件版)。" >&2
  exit 1
fi

echo "将使用 '$COMPOSE_CMD' 命令..."

# 检查网络是否已存在，如果不存在则创建
if ! docker network ls | grep -q "$NETWORK_NAME"; then
  echo "正在创建网络 '$NETWORK_NAME'..."
  docker network create --subnet=$SUBNET $NETWORK_NAME
else
  echo "网络 '$NETWORK_NAME' 已存在。"
fi

# 创建 docker-compose.yml 文件
echo "正在创建 docker-compose.yml 文件..."
cat <<EOF > docker-compose.yml
version: '3.8'
services:
  app:
    image: 'docker.io/jc21/nginx-proxy-manager:latest'
    restart: unless-stopped
    ports:
      # 公共端口
      - '80:80'
      - '443:443'
      # 管理端口
      - '81:81'
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
    networks:
      ${NETWORK_NAME}:
        ipv4_address: ${IP_ADDRESS}

networks:
  ${NETWORK_NAME}:
    external: true
EOF

echo "docker-compose.yml 文件创建成功。"
echo "正在启动服务..."

# 使用检测到的命令启动服务
$COMPOSE_CMD up -d

echo "----------------------------------------"
echo "Nginx Proxy Manager 已成功启动！"
echo ""
echo "服务IP地址: ${IP_ADDRESS}"
echo "管理界面请访问: http://localhost:81"
echo "----------------------------------------"
