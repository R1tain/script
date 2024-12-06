#!/bin/bash

set -euo pipefail

# 顏色定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 日誌函數
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 檢測操作系統
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        log_error "無法檢測操作系統"
        exit 1
    fi
}

# 檢查命令是否存在
check_command() {
    if ! command -v "$1" &> /dev/null; then
        log_error "$1 未安裝"
        return 1
    fi
}

# 檢查系統要求
check_requirements() {
    local min_memory=2048
    local memory=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || echo "0")
    
    if [ "$memory" -lt "$min_memory" ]; then
        log_warn "系統內存小於2GB，可能影響Docker運行性能"
    fi

    # 檢查必要工具
    for cmd in curl wget sudo; do
        check_command "$cmd" || {
            log_error "請先安裝 $cmd"
            exit 1
        }
    done
}

# Alpine系統安裝方法
install_docker_alpine() {
    log_info "開始在Alpine系統上安裝Docker..."
    
    # 添加社區倉庫
    sudo sed -i 's/v[0-9.]\+/edge/g' /etc/apk/repositories
    
    # 更新包索引
    sudo apk update
    
    # 安裝Docker
    sudo apk add --no-cache \
        docker \
        docker-cli \
        docker-compose \
        docker-engine
    
    # 啟動Docker服務
    sudo rc-update add docker boot
    sudo service docker start
}

# Debian/Ubuntu安裝方法
install_docker_debian() {
    log_info "開始安裝Docker..."
    
    sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
    
    sudo apt-get update
    sudo apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        apt-transport-https

    if [ ! -f /usr/share/keyrings/docker-archive-keyring.gpg ]; then
        curl -fsSL https://download.docker.com/linux/${OS}/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    fi

    echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/${OS} \
    $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

# CentOS/RHEL安裝方法
install_docker_centos() {
    log_info "開始安裝Docker..."
    
    sudo yum remove -y docker docker-client docker-client-latest docker-common \
                     docker-latest docker-latest-logrotate docker-logrotate docker-engine 2>/dev/null || true

    sudo yum install -y yum-utils
    sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    sudo yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

# 配置Docker
configure_docker() {
    # 創建配置目錄
    sudo mkdir -p /etc/docker

    # 設置Docker守護進程
    sudo tee /etc/docker/daemon.json > /dev/null <<EOF
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "10m",
        "max-file": "3"
    },
    "registry-mirrors": ["https://mirror.ccs.tencentyun.com"]
}
EOF

    # 重啟Docker服務
    case ${OS} in
        alpine)
            sudo service docker restart
            ;;
        *)
            sudo systemctl restart docker
            sudo systemctl enable docker
            ;;
    esac
}

# 驗證安裝
verify_installation() {
    log_info "驗證Docker安裝..."
    
    if ! docker --version; then
        log_error "Docker安裝失敗"
        exit 1
    fi
    
    if ! docker compose version; then
        log_error "Docker Compose安裝失敗"
        exit 1
    fi
    
    log_info "Docker安裝成功！"
}

# 主安裝邏輯
main() {
    if [[ $EUID -ne 0 ]]; then
        log_error "請使用sudo權限運行此腳本" 
        exit 1
    fi

    detect_os
    check_requirements

    case ${OS} in
        ubuntu|debian)
            install_docker_debian
            ;;
        centos|rhel|fedora)
            install_docker_centos
            ;;
        alpine)
            install_docker_alpine
            ;;
        *)
            log_error "不支持的操作系統: ${OS}"
            exit 1
            ;;
    esac

    configure_docker
    verify_installation
}

# 捕獲錯誤
trap 'log_error "腳本執行失敗，請檢查錯誤信息"; exit 1' ERR

# 執行主函數
main
