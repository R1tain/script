#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # 无颜色

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检测操作系统和架构
detect_os_and_arch() {
    OS=$(cat /etc/os-release | grep -E "^ID=" | cut -d'=' -f2 | tr -d '"')
    VERSION_ID=$(cat /etc/os-release | grep -E "^VERSION_ID=" | cut -d'=' -f2 | tr -d '"')
    ARCH=$(uname -m)

    case "$ARCH" in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        arm*) ARCH="arm" ;;
        *) 
            log_error "不支持的架构: $ARCH"
            exit 1 
        ;;
    esac

    log_info "检测到系统: $OS $VERSION_ID, 架构: $ARCH"
}

# 安装依赖
install_dependencies() {
    log_info "正在安装必要依赖..."
    
    case "$OS" in
        ubuntu|debian)
            sudo apt update
            sudo apt install -y curl wget
            ;;
        alpine)
            apk add --no-cache curl wget
            ;;
        almalinux|oracle|centos|rhel)
            sudo yum install -y curl wget
            ;;
        *)
            log_warn "未知系统，可能需要手动安装依赖"
            ;;
    esac
}

# 安装 NextTrace
install_nexttrace() {
    log_info "正在安装 NextTrace..."

    # 创建临时目录
    TMP_DIR=$(mktemp -d)
    cd $TMP_DIR

    # 获取最新版本
    LATEST_VERSION=$(curl -s https://api.github.com/repos/sjlleo/nexttrace/releases/latest | grep '"tag_name":' | sed -E 's/.*"v?([^"]+)".*/\1/')

    # 下载二进制文件
    DOWNLOAD_URL="https://github.com/sjlleo/nexttrace/releases/download/v${LATEST_VERSION}/nexttrace_linux_${ARCH}"
    
    log_info "下载 NextTrace v${LATEST_VERSION}..."
    
    # 使用 curl 或 wget 下载
    if command -v curl &> /dev/null; then
        curl -L -o nexttrace $DOWNLOAD_URL
    elif command -v wget &> /dev/null; then
        wget -O nexttrace $DOWNLOAD_URL
    else
        log_error "无法下载文件，需要 curl 或 wget"
        exit 1
    fi

    # 检查下载是否成功
    if [ ! -f nexttrace ]; then
        log_error "下载失败"
        exit 1
    fi

    # 设置执行权限
    chmod +x nexttrace

    # 移动到系统目录
    case "$OS" in
        alpine)
            # Alpine 可能没有 sudo
            mv nexttrace /usr/local/bin/nexttrace
            ;;
        *)
            sudo mv nexttrace /usr/local/bin/nexttrace
            ;;
    esac

    # 清理临时目录
    cd && rm -rf $TMP_DIR

    log_info "NextTrace 安装完成！"
}

# 验证安装
verify_installation() {
    if command -v nexttrace &> /dev/null; then
        log_info "安装验证通过："
        nexttrace --version
    else
        log_error "安装失败，无法找到 nexttrace 命令"
        exit 1
    fi
}

# 主安装流程
main() {
    # 检查是否为 Linux 系统
    if [[ "$OSTYPE" != "linux"* ]]; then
        log_error "此脚本仅支持 Linux 系统"
        exit 1
    fi

    # 检测系统和架构
    detect_os_and_arch

    # 安装依赖
    install_dependencies

    # 执行安装
    install_nexttrace

    # 验证安装
    verify_installation
}

# 运行主函数
main
