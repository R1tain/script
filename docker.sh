#!/bin/bash

# 遇到错误时立即退出, 未定义的变量视为错误, 管道命令中任何一个失败都视为失败
set -euo pipefail

# --- 配置项 ---
# 可以修改为你偏好的 Docker 镜像加速器地址
DOCKER_MIRROR="https://mirror.ccs.tencentyun.com"

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- 日志函数 ---
log_info() { echo -e "${GREEN}[信息]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[警告]${NC} $1"; }
log_error() { echo -e "${RED}[错误]${NC} $1"; }

# --- 辅助函数 ---

# 检测操作系统
detect_os() {
    log_info "正在检测操作系统..."
    if [ -f /etc/os-release ]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        OS=$ID
        log_info "检测到操作系统: ${OS}"
    else
        log_error "无法检测操作系统，请检查 /etc/os-release 文件是否存在。"
        exit 1
    fi
}

# 检查命令是否存在
check_command() {
    if ! command -v "$1" &> /dev/null; then
        log_error "必需命令 '$1' 未安装。"
        return 1
    fi
    return 0
}

# 检查系统要求
check_requirements() {
    log_info "正在检查系统要求..."
    local min_memory=2048 # 最低内存要求 (MB)
    local memory
    # 尝试获取内存大小，如果 free 命令失败则设为 0
    memory=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || echo "0")

    if [ "$memory" -lt "$min_memory" ]; then
        log_warn "系统内存 (${memory}MB) 低于 ${min_memory}MB，可能会影响 Docker 运行性能。"
    else
        log_info "系统内存满足要求 (${memory}MB)。"
    fi

    # 检查必要工具
    local missing_pkgs=0
    for cmd in curl sudo; do
        if ! check_command "$cmd"; then
            log_error "请先安装 '$cmd' 工具后再运行此脚本。"
            missing_pkgs=1
        fi
    done

    if [ $missing_pkgs -eq 1 ]; then
        exit 1
    fi

    # 检查sudo权限
    if ! sudo -v &> /dev/null; then
        log_error "当前用户没有sudo权限，请将用户添加到sudo组或使用有sudo权限的用户运行。"
        exit 1
    fi
    log_info "必要工具和sudo权限检查通过。"
}

# --- 安装函数 ---

# 在 Alpine Linux 上安装 Docker
# 注意：使用 edge 仓库可能包含不稳定软件包
install_docker_alpine() {
    log_info "开始在 Alpine Linux (${OS}) 上安装 Docker..."
    log_warn "Alpine 的 Docker 包通常来自 'edge' 社区仓库，可能包含不稳定版本。"

    # 添加社区仓库 (确保 edge/community 已启用)
    if ! grep -q '/edge/community' /etc/apk/repositories; then
        log_info "添加 Alpine edge/community 仓库..."
        # 通常需要编辑 /etc/apk/repositories 文件，取消注释或添加包含 /edge/community 的行
        # 这里使用 sed 尝试将版本号替换为 edge，但请根据实际情况调整
        sudo sed -i -e "/v[0-9.]*\/community/ s/^# //" -e "s/v[0-9.]*/edge/g" /etc/apk/repositories
    fi

    log_info "更新包索引..."
    sudo apk update

    log_info "安装 Docker 组件..."
    # 尝试安装现代化的 Docker 组件，包括 compose 插件
    sudo apk add --no-cache \
        docker-cli \
        containerd \
        runc \
        docker-engine \
        docker-openrc \
        docker-buildx-plugin \
        docker-compose-plugin || {
            log_warn "安装 docker-compose-plugin 失败，尝试安装独立的 docker-compose..."
            sudo apk add --no-cache docker-compose
            # 如果安装了独立的 compose，验证时需要用 docker-compose version
            VERIFY_COMPOSE_COMMAND="docker-compose version"
        }

    log_info "设置 Docker 服务开机自启并启动..."
    sudo rc-update add docker boot
    sudo rc-service docker start
}

# 在 Debian/Ubuntu 上安装 Docker
install_docker_debian() {
    log_info "开始在 Debian/Ubuntu (${OS}) 上安装 Docker..."

    log_info "卸载可能存在的旧版本 Docker..."
    sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

    log_info "更新包索引并安装依赖..."
    sudo apt-get update
    sudo apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        apt-transport-https

    log_info "添加 Docker 官方 GPG 密钥..."
    local keyrings_dir="/usr/share/keyrings"
    local docker_gpg_key="${keyrings_dir}/docker-archive-keyring.gpg"
    sudo mkdir -p "${keyrings_dir}"
    if [ ! -f "${docker_gpg_key}" ]; then
        curl -fsSL "https://download.docker.com/linux/${OS}/gpg" | sudo gpg --dearmor -o "${docker_gpg_key}"
    else
        log_info "Docker GPG 密钥已存在。"
    fi

    log_info "添加 Docker 官方 APT 仓库..."
    echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=${docker_gpg_key}] https://download.docker.com/linux/${OS} \
    $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    log_info "更新包索引..."
    sudo apt-get update

    log_info "安装 Docker CE (社区版)..."
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

# 在 CentOS/RHEL/Fedora 上安装 Docker
install_docker_centos() {
    log_info "开始在 CentOS/RHEL/Fedora (${OS}) 上安装 Docker..."
    # 注意: 对 Fedora 的支持依赖于其与 CentOS/RHEL 的相似性，可能需要调整

    log_info "卸载可能存在的旧版本 Docker..."
    sudo yum remove -y docker \
                      docker-client \
                      docker-client-latest \
                      docker-common \
                      docker-latest \
                      docker-latest-logrotate \
                      docker-logrotate \
                      docker-engine 2>/dev/null || true

    log_info "安装 yum-utils..."
    sudo yum install -y yum-utils

    log_info "添加 Docker 官方 YUM 仓库..."
    sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

    log_info "安装 Docker CE (社区版)..."
    sudo yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

# --- 配置与验证 ---

# 配置 Docker 守护进程 (daemon)
configure_docker() {
    log_info "配置 Docker 守护进程..."
    local docker_config_dir="/etc/docker"
    local docker_daemon_json="${docker_config_dir}/daemon.json"

    sudo mkdir -p "${docker_config_dir}"

    log_info "设置日志选项和镜像加速器 (${DOCKER_MIRROR})..."
    # 创建或覆盖 daemon.json 文件
    sudo tee "${docker_daemon_json}" > /dev/null <<EOF
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "50m",
        "max-file": "3"
    },
    "registry-mirrors": ["${DOCKER_MIRROR}"]
}
EOF
    # 增加了 max-size 到 50m

    log_info "重启并启用 Docker 服务..."
    case ${OS} in
        alpine)
            sudo rc-service docker restart
            ;;
        *)
            sudo systemctl daemon-reload
            sudo systemctl restart docker
            # 检查 systemctl 是否存在 enable 命令 (例如在某些容器环境或老系统可能没有)
            if command -v systemctl &> /dev/null && systemctl list-unit-files --type=service | grep -q docker.service; then
                 sudo systemctl enable docker
            else
                 log_warn "无法使用 systemctl enable docker，请手动配置开机自启 (如果需要)。"
            fi
            ;;
    esac
    log_info "Docker 服务已重启。"
}

# 验证 Docker 和 Docker Compose 是否安装成功
verify_installation() {
    log_info "开始验证 Docker 安装..."

    if ! command -v docker &> /dev/null; then
        log_error "Docker 命令未找到，安装可能失败。"
        return 1
    fi
    if ! docker --version; then
        log_error "执行 'docker --version' 失败。"
        return 1
    fi

    # 根据 Alpine 安装情况选择不同的验证命令
    local compose_cmd=${VERIFY_COMPOSE_COMMAND:-"docker compose version"} # 默认为插件命令
    local compose_name=${VERIFY_COMPOSE_COMMAND:-"Docker Compose Plugin"} # 日志名称

    log_info "验证 ${compose_name}..."
    if ! ${compose_cmd}; then
        log_error "执行 '${compose_cmd}' 失败。Docker Compose 安装或配置可能存在问题。"
         # 尝试给出可能的提示
        if [[ "$compose_cmd" == "docker compose version" ]]; then
             log_warn "如果看到 'docker: 'compose' is not a docker command.' 错误, 可能是 Docker Compose 插件未正确安装或 Docker 版本过旧。"
             log_warn "尝试运行 'docker-compose --version' (如果安装了独立版本)。"
        fi
        return 1
    fi

    log_info "Docker 和 Docker Compose 似乎已成功安装并配置！"
    log_info "你可以尝试运行 'docker run hello-world' 来进行最终测试。"
}

# --- 主逻辑 ---
main() {
    # 不再检查 EUID，依赖内部的 sudo
    # if [[ $EUID -ne 0 ]]; then
    #    log_error "请使用 sudo 权限运行此脚本 (例如: sudo ./install_docker.sh)"
    #    exit 1
    # fi
    log_info "Docker 安装脚本开始执行..."
    log_warn "运行此脚本需要有效的 sudo 权限。"

    detect_os
    check_requirements

    # 根据检测到的操作系统选择安装方法
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
            log_error "不支持的操作系统: ${OS}"
            exit 1
            ;;
    esac

    # 检查 Docker 是否成功安装 (包管理器层面)
    if ! command -v docker &> /dev/null; then
         log_error "Docker 安装过程似乎失败了，未找到 docker 命令。"
         exit 1
    fi

    configure_docker
    verify_installation

    log_info "脚本执行完毕。"
}

# --- 错误捕获 ---
# 定义一个函数来处理错误退出
handle_error() {
    local exit_code=$?
    log_error "脚本在行号 $1 附近执行失败，退出码: $exit_code"
    # 可以在这里添加清理步骤，如果需要的话
    exit $exit_code
}

# 设置陷阱，当发生错误 (ERR) 时调用 handle_error 函数，并传递行号
trap 'handle_error $LINENO' ERR

# --- 执行入口 ---
main

exit 0 # 脚本成功完成
