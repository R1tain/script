#!/bin/bash
## Author: SuperManito
## Modified: 2024-05-17  # <-- 修正日期
## License: MIT
## GitHub: https://github.com/SuperManito/LinuxMirrors
## Website: https://linuxmirrors.cn

# --- 全局变量定义 ---

## Docker CE 软件源列表 (保持不变)
mirror_list_docker_ce=(
    "阿里云@mirrors.aliyun.com/docker-ce"
    "腾讯云@mirrors.tencent.com/docker-ce"
    "华为云@mirrors.huaweicloud.com/docker-ce"
    "微软 Azure 中国@mirror.azure.cn/docker-ce"
    "网易@mirrors.163.com/docker-ce"
    "火山引擎@mirrors.volces.com/docker"
    "清华大学@mirrors.tuna.tsinghua.edu.cn/docker-ce"
    "北京大学@mirrors.pku.edu.cn/docker-ce"
    "南京大学@mirrors.nju.edu.cn/docker-ce"
    "上海交通大学@mirror.sjtu.edu.cn/docker-ce"
    "中国科学技术大学@mirrors.ustc.edu.cn/docker-ce"
    "中国科学院软件研究所@mirror.iscas.ac.cn/docker-ce"
    "官方@download.docker.com"
)

## Docker Registry 仓库列表 (保持不变)
mirror_list_registry=(
    "Docker Proxy（推荐）@dockerproxy.net"
    "道客 DaoCloud@docker.m.daocloud.io"
    "AtomHub 可信镜像中心@hub.atomgit.com"
    "阿里云（杭州）@registry.cn-hangzhou.aliyuncs.com"
    "阿里云（上海）@registry.cn-shanghai.aliyuncs.com"
    "阿里云（青岛）@registry.cn-qingdao.aliyuncs.com"
    "阿里云（北京）@registry.cn-beijing.aliyuncs.com"
    "阿里云（张家口）@registry.cn-zhangjiakou.aliyuncs.com"
    "阿里云（呼和浩特）@registry.cn-huhehaote.aliyuncs.com"
    "阿里云（乌兰察布）@registry.cn-wulanchabu.aliyuncs.com"
    "阿里云（深圳）@registry.cn-shenzhen.aliyuncs.com"
    "阿里云（河源）@registry.cn-heyuan.aliyuncs.com"
    "阿里云（广州）@registry.cn-guangzhou.aliyuncs.com"
    "阿里云（成都）@registry.cn-chengdu.aliyuncs.com"
    "阿里云（香港）@registry.cn-hongkong.aliyuncs.com"
    "阿里云（日本-东京）@registry.ap-northeast-1.aliyuncs.com"
    "阿里云（新加坡）@registry.ap-southeast-1.aliyuncs.com"
    "阿里云（澳大利亚-悉尼）@registry.ap-southeast-2.aliyuncs.com"
    "阿里云（马来西亚-吉隆坡）@registry.ap-southeast-3.aliyuncs.com"
    "阿里云（印度尼西亚-雅加达）@registry.ap-southeast-5.aliyuncs.com"
    "阿里云（印度-孟买）@registry.ap-south-1.aliyuncs.com"
    "阿里云（德国-法兰克福）@registry.eu-central-1.aliyuncs.com"
    "阿里云（英国-伦敦）@registry.eu-west-1.aliyuncs.com"
    "阿里云（美国西部-硅谷）@registry.us-west-1.aliyuncs.com"
    "阿里云（美国东部-弗吉尼亚）@registry.us-east-1.aliyuncs.com"
    "阿里云（阿联酋-迪拜）@registry.me-east-1.aliyuncs.com"
    "腾讯云@mirror.ccs.tencentyun.com"
    "谷歌云@mirror.gcr.io"
    "官方 Docker Hub@registry.hub.docker.com"
)

## 定义系统判定变量 (保持不变)
SYSTEM_DEBIAN="Debian"
SYSTEM_UBUNTU="Ubuntu"
SYSTEM_KALI="Kali"
SYSTEM_DEEPIN="Deepin"
SYSTEM_LINUX_MINT="Linuxmint"
SYSTEM_ZORIN="Zorin"
SYSTEM_RASPBERRY_PI_OS="Raspberry Pi OS"
SYSTEM_REDHAT="RedHat"
SYSTEM_RHEL="Red Hat Enterprise Linux"
SYSTEM_CENTOS="CentOS"
SYSTEM_CENTOS_STREAM="CentOS Stream"
SYSTEM_ROCKY="Rocky"
SYSTEM_ALMALINUX="AlmaLinux"
SYSTEM_FEDORA="Fedora"
SYSTEM_OPENCLOUDOS="OpenCloudOS"
SYSTEM_OPENCLOUDOS_STREAM="OpenCloudOS Stream"
SYSTEM_OPENEULER="openEuler"
SYSTEM_ANOLISOS="Anolis"
SYSTEM_OPENKYLIN="openKylin"
SYSTEM_OPENSUSE="openSUSE"
SYSTEM_ARCH="Arch"
SYSTEM_ALPINE="Alpine"
SYSTEM_GENTOO="Gentoo"
SYSTEM_NIXOS="NixOS"

## 定义系统版本文件 (保持不变)
File_LinuxRelease=/etc/os-release
File_RedHatRelease=/etc/redhat-release
File_DebianVersion=/etc/debian_version
File_ArmbianRelease=/etc/armbian-release
File_RaspberryPiOSRelease=/etc/rpi-issue
File_openEulerRelease=/etc/openEuler-release
File_OpenCloudOSRelease=/etc/opencloudos-release
File_AnolisOSRelease=/etc/anolis-release
File_OracleLinuxRelease=/etc/oracle-release
File_ArchLinuxRelease=/etc/arch-release
File_AlpineRelease=/etc/alpine-release
File_ProxmoxVersion=/etc/pve/.version

## 定义软件源相关文件或目录 (保持不变)
File_DebianSourceList=/etc/apt/sources.list
Dir_DebianExtendSource=/etc/apt/sources.list.d
Dir_YumRepos=/etc/yum.repos.d

## 定义 Docker 相关变量 (保持不变)
DockerDir=/etc/docker
DockerConfig=$DockerDir/daemon.json
DockerConfigBackup=$DockerDir/daemon.json.bak
DockerVersionFile=docker-version.txt
# DockerCEVersionFile=docker-ce-version.txt # 不再需要独立文件
# DockerCECLIVersionFile=docker-ce-cli-version.txt # 不再需要独立文件

## 定义颜色变量 (保持不变)
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
PURPLE='\033[35m'
AZURE='\033[36m'
PLAIN='\033[0m'
BOLD='\033[1m'
SUCCESS="\033[1;32m✔${PLAIN}"
COMPLETE="\033[1;32m✔${PLAIN}"
WARN="\033[1;43m 警告 ${PLAIN}"
ERROR="\033[1;31m✘${PLAIN}"
FAIL="\033[1;31m✘${PLAIN}"
TIP="\033[1;44m 提示 ${PLAIN}"
WORKING="\033[1;36m◉${PLAIN}"

## 包管理器相关变量 (新增)
PKG_MANAGER=""         # 包管理器命令 (apt-get, yum, dnf)
CMD_UPDATE=""          # 更新源命令
CMD_INSTALL=""         # 安装包命令
CMD_REMOVE=""          # 移除包命令
CMD_AUTOREMOVE=""      # 自动移除无用包命令
CMD_LIST_PACKAGES=""   # 列出包信息 (用于检查是否安装)
CMD_LIST_VERSIONS=""   # 列出可用版本命令 (带包名参数)
CMD_MAKECACHE=""       # 创建缓存命令 (Yum/DNF specific)
DEBIAN_FRONTEND_NONINTERACTIVE="DEBIAN_FRONTEND=noninteractive" # Debian系非交互式环境变量

# --- 主函数 ---
function main() {
    permission_judgment
    check_dependencies # 新增：检查核心依赖
    collect_system_info
    set_package_manager_commands # 新增：设置包管理器命令
    run_start
    choose_mirrors
    choose_protocol
    close_firewall_service
    install_dependency_packages
    configure_docker_ce_mirror
    install_docker_engine
    check_version
    run_end
}

# --- 功能函数 ---

## 处理命令选项 (基本保持不变，文本改为中文)
function handle_command_options() {
    function output_command_help() {
        echo -e "
命令选项(名称/含义/值)：

  --source                 指定 Docker CE 源地址(域名或IP)      地址
  --source-registry        指定镜像仓库地址(域名或IP)           地址
  --branch                 指定 Docker CE 源仓库(路径)          仓库名 (例如: ubuntu, debian, centos, fedora, raspbian)
  --codename               指定 Debian 系操作系统的版本代号     代号名称 (例如: bullseye, bookworm, focal, jammy)
  --designated-version     指定 Docker CE 安装版本              版本号 (例如: 26.1.4)
  --protocol               指定 Docker CE 源的 WEB 协议         http 或 https
  --install-latest         是否安装最新版本的 Docker Engine     true 或 false
  --close-firewall         是否关闭防火墙                       true 或 false
  --clean-screen           是否在运行前清除屏幕上的所有内容     true 或 false
  --ignore-backup-tips     忽略覆盖备份提示                     无
  --pure-mode              纯净模式，精简打印内容               无

问题报告 https://github.com/SuperManito/LinuxMirrors/issues
  "
    }

    while [ $# -gt 0 ]; do
        case "$1" in
        --source)
            if [ "$2" ]; then
                echo "$2" | grep -Eq "\(|\)|\[|\]|\{|\}"
                if [ $? -eq 0 ]; then
                    output_error "命令选项 ${BLUE}$2${PLAIN} 无效，请在该选项后指定有效的地址！"
                else
                    SOURCE="$(echo "$2" | sed -e 's,^http[s]\?://,,g' -e 's,/$,,')"
                    shift
                fi
            else
                output_error "命令选项 ${BLUE}$1${PLAIN} 无效，请在该选项后指定软件源地址！"
            fi
            ;;
        --source-registry)
            if [ "$2" ]; then
                echo "$2" | grep -Eq "\(|\)|\[|\]|\{|\}"
                if [ $? -eq 0 ]; then
                    output_error "命令选项 ${BLUE}$2${PLAIN} 无效，请在该选项后指定有效的地址！"
                else
                    SOURCE_REGISTRY="$(echo "$2" | sed -e 's,^http[s]\?://,,g' -e 's,/$,,')"
                    shift
                fi
            else
                output_error "命令选项 ${BLUE}$1${PLAIN} 无效，请在该选项后指定镜像仓库地址！"
            fi
            ;;
        --branch)
            if [ "$2" ]; then
                SOURCE_BRANCH="$2"
                shift
            else
                output_error "命令选项 ${BLUE}$1${PLAIN} 无效，请在该选项后指定软件源仓库！"
            fi
            ;;
        --codename)
            if [ "$2" ]; then
                DEBIAN_CODENAME="$2"
                shift
            else
                output_error "命令选项 ${BLUE}$1${PLAIN} 无效，请在该选项后指定版本代号！"
            fi
            ;;
        --designated-version)
            if [ "$2" ]; then
                # 允许更灵活的版本格式，例如 RC 或 beta，但基础格式仍需匹配
                if [[ "$2" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
                    DESIGNATED_DOCKER_VERSION="$2"
                    shift
                else
                    output_error "命令选项 ${BLUE}$2${PLAIN} 无效，请在该选项后指定有效的版本号 (例如: 26.1.4)！"
                fi
            else
                output_error "命令选项 ${BLUE}$1${PLAIN} 无效，请在该选项后指定版本号！"
            fi
            ;;
        --protocol)
            if [ "$2" ]; then
                case "$2" in
                http | https | HTTP | HTTPS)
                    WEB_PROTOCOL="${2,,}"
                    shift
                    ;;
                *)
                    output_error "检测到 ${BLUE}$2${PLAIN} 为无效参数值，请在该选项后指定 http 或 https ！"
                    ;;
                esac
            else
                output_error "命令选项 ${BLUE}$1${PLAIN} 无效，请在该选项后指定 WEB 协议（http/https）！"
            fi
            ;;
        --install-latest | --install-latested) # 保留旧的别名
            if [ "$2" ]; then
                case "$2" in
                [Tt]rue | [Ff]alse)
                    INSTALL_LATESTED_DOCKER="${2,,}"
                    shift
                    ;;
                *)
                    output_error "命令选项 ${BLUE}$2${PLAIN} 无效，请在该选项后指定 true 或 false ！"
                    ;;
                esac
            else
                # 允许不带值的标志，默认为 true
                INSTALL_LATESTED_DOCKER="true"
                # output_error "命令选项 ${BLUE}$1${PLAIN} 无效，请在该选项后指定 true 或 false ！"
            fi
            ;;
        --ignore-backup-tips)
            IGNORE_BACKUP_TIPS="true"
            ;;
        --close-firewall)
            if [ "$2" ]; then
                case "$2" in
                [Tt]rue | [Ff]alse)
                    CLOSE_FIREWALL="${2,,}"
                    shift
                    ;;
                *)
                    output_error "命令选项 ${BLUE}$2${PLAIN} 无效，请在该选项后指定 true 或 false ！"
                    ;;
                esac
            else
                 # 允许不带值的标志，默认为 true
                 CLOSE_FIREWALL="true"
                # output_error "命令选项 ${BLUE}$1${PLAIN} 无效，请在该选项后指定 true 或 false ！"
            fi
            ;;
        --clean-screen)
             if [ "$2" ]; then
                case "$2" in
                [Tt]rue | [Ff]alse)
                    CLEAN_SCREEN="${2,,}"
                    shift
                    ;;
                *)
                    output_error "命令选项 ${BLUE}$2${PLAIN} 无效，请在该选项后指定 true 或 false ！"
                    ;;
                esac
            else
                 # 允许不带值的标志，默认为 true
                 CLEAN_SCREEN="true"
                # output_error "命令选项 ${BLUE}$1${PLAIN} 无效，请在该选项后指定 true 或 false ！"
            fi
            ;;
        --pure-mode)
            PURE_MODE="true"
            ;;
        --help)
            output_command_help
            exit 0
            ;;
        *)
            output_error "命令选项 ${BLUE}$1${PLAIN} 无效，请确认后重新输入！使用 --help 查看帮助。"
            ;;
        esac
        shift
    done
    ## 设置部分功能的默认值
    IGNORE_BACKUP_TIPS="${IGNORE_BACKUP_TIPS:-"false"}"
    if [[ "${DESIGNATED_DOCKER_VERSION}" ]]; then
        INSTALL_LATESTED_DOCKER="${INSTALL_LATESTED_DOCKER:-"false"}" # 如果指定版本，默认不装最新
    else
        INSTALL_LATESTED_DOCKER="${INSTALL_LATESTED_DOCKER:-"true"}" # 否则默认装最新
    fi
    CLOSE_FIREWALL="${CLOSE_FIREWALL:-"false"}" # 默认不关闭防火墙
    CLEAN_SCREEN="${CLEAN_SCREEN:-"false"}"     # 默认不清屏
    PURE_MODE="${PURE_MODE:-"false"}"
}

## 打印开始信息 (中文)
function run_start() {
    if [ -z "${CLEAN_SCREEN}" ] && [ -z "${SOURCE}" ] && [ -z "${SOURCE_REGISTRY}" ]; then
         clear
    elif [ "${CLEAN_SCREEN}" == "true" ]; then
        clear
    fi
    if [[ "${PURE_MODE}" == "true" ]]; then
        return
    fi
    echo -e "+-----------------------------------+"
    echo -e "| \033[0;1;35;95m⡇\033[0m  \033[0;1;33;93m⠄\033[0m \033[0;1;32;92m⣀⡀\033[0m \033[0;1;36;96m⡀\033[0;1;34;94m⢀\033[0m \033[0;1;35;95m⡀⢀\033[0m \033[0;1;31;91m⡷\033[0;1;33;93m⢾\033[0m \033[0;1;32;92m⠄\033[0m \033[0;1;36;96m⡀⣀\033[0m \033[0;1;34;94m⡀\033[0;1;35;95m⣀\033[0m \033[0;1;31;91m⢀⡀\033[0m \033[0;1;33;93m⡀\033[0;1;32;92m⣀\033[0m \033[0;1;36;96m⢀⣀\033[0m |"
    echo -e "| \033[0;1;31;91m⠧\033[0;1;33;93m⠤\033[0m \033[0;1;32;92m⠇\033[0m \033[0;1;36;96m⠇⠸\033[0m \033[0;1;34;94m⠣\033[0;1;35;95m⠼\033[0m \033[0;1;31;91m⠜⠣\033[0m \033[0;1;33;93m⠇\033[0;1;32;92m⠸\033[0m \033[0;1;36;96m⠇\033[0m \033[0;1;34;94m⠏\033[0m  \033[0;1;35;95m⠏\033[0m  \033[0;1;33;93m⠣⠜\033[0m \033[0;1;32;92m⠏\033[0m  \033[0;1;34;94m⠭⠕\033[0m |"
    echo -e "+-----------------------------------+"
    echo -e "欢迎使用 Docker Engine 安装与换源脚本 (中文优化版)"
}

## 打印结束信息 (中文)
function run_end() {
    if [[ "${PURE_MODE}" == "true" ]]; then
        echo ''
        return
    fi
    local sponsor_ad=(
        "🔥 1Panel · Linux 面板｜极简运维 ➜  https://1panel.cn"
        "🔥 林枫云 · 专注独立IP高频VPS｜R9/i9系列定制 ➜  https://www.dkdun.cn"
        "🔥 乔星欢 · 香港4核4G服务器28元起_香港500Mbps大带宽 ➜  https://www.qiaoxh.com"
        "🔥 速拓云 · 国内高防云服务器新用户享5折优惠 ➜  https://www.sutuoyun.com"
        "🔥 云悠YUNYOO · 全球高性价比云服务器｜低至15.99元起 ➜  https://yunyoo.cc"
    )
    echo -e "\n✨ 脚本运行完毕，更多使用教程详见官网 👉 \033[3mhttps://linuxmirrors.cn\033[0m\n"
    for ad in "${sponsor_ad[@]}"; do
        echo -e "  ${ad} \033[3;2m【广告】\033[0m"
    done
    echo -e "\n\033[3;1mPowered by \033[34mLinuxMirrors\033[0m\n"
}

## 报错退出 (中文)
function output_error() {
    [ "$1" ] && echo -e "\n$ERROR $1\n" >&2 # 输出到 stderr
    exit 1
}

## 权限判定 (中文)
function permission_judgment() {
    if [ $UID -ne 0 ]; then
        output_error "权限不足，请使用 Root 用户运行本脚本！"
    fi
}

## 检查核心依赖 (新增)
function check_dependencies() {
    local missing_deps=()
    local dependencies=("curl" "grep" "sed" "awk" "systemctl" "tput") # 添加 systemctl 和 tput
    for dep in "${dependencies[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing_deps+=("$dep")
        fi
    done

    if [ ${#missing_deps[@]} -gt 0 ]; then
        output_error "检测到缺少核心依赖：${BLUE}${missing_deps[*]}${PLAIN}，请先安装它们再运行脚本。\n例如，在 Debian/Ubuntu 上运行: apt update && apt install -y ${missing_deps[*]};\n在 CentOS/RHEL 上运行: yum update && yum install -y ${missing_deps[*]}"
    fi
    # tput 的检查移到 collect_system_info 中，因为它只影响高级交互
}


## 收集系统信息 (基本保持不变，增加 CAN_USE_ADVANCED_INTERACTIVE_SELECTION 判断)
function collect_system_info() {
    ## 定义系统名称
    SYSTEM_NAME="$(cat $File_LinuxRelease | grep -E "^NAME=" | awk -F '=' '{print$2}' | sed "s/[\'\"]//g")"
    grep -q "PRETTY_NAME=" $File_LinuxRelease && SYSTEM_PRETTY_NAME="$(cat $File_LinuxRelease | grep -E "^PRETTY_NAME=" | awk -F '=' '{print$2}' | sed "s/[\'\"]//g")"
    ## 定义系统版本号
    SYSTEM_VERSION_ID="$(cat $File_LinuxRelease | grep -E "^VERSION_ID=" | awk -F '=' '{print$2}' | sed "s/[\'\"]//g")"
    SYSTEM_VERSION_ID_MAJOR="${SYSTEM_VERSION_ID%.*}"
    SYSTEM_VERSION_ID_MINOR="${SYSTEM_VERSION_ID#*.}"
    ## 定义系统ID
    SYSTEM_ID="$(cat $File_LinuxRelease | grep -E "^ID=" | awk -F '=' '{print$2}' | sed "s/[\'\"]//g")"

    ## 判定当前系统派系
    if [ -s "${File_DebianVersion}" ]; then
        SYSTEM_FACTIONS="${SYSTEM_DEBIAN}"
    elif [ -s "${File_OracleLinuxRelease}" ]; then
        output_error "当前操作系统（Oracle Linux）不在本脚本的支持范围内，请前往官网查看支持列表！"
    elif [ -s "${File_RedHatRelease}" ]; then
        SYSTEM_FACTIONS="${SYSTEM_REDHAT}"
    elif [ -s "${File_openEulerRelease}" ]; then
        SYSTEM_FACTIONS="${SYSTEM_OPENEULER}"
    elif [ -s "${File_OpenCloudOSRelease}" ]; then
        if [[ "${SYSTEM_VERSION_ID_MAJOR}" -ge 9 ]]; then
            output_error "不支持当前操作系统（OpenCloudOS ${SYSTEM_VERSION_ID_MAJOR}+），请参考如下命令自行安装：\n\ndnf install -y docker\nsystemctl enable --now docker"
        fi
        SYSTEM_FACTIONS="${SYSTEM_OPENCLOUDOS}"
    elif [ -s "${File_AnolisOSRelease}" ]; then
         # Anolis OS 8.8 及以下版本不支持官方源，Anolis OS 23 支持
        if [[ "${SYSTEM_VERSION_ID_MAJOR}" == 8 ]]; then
             output_error "不支持当前操作系统（Anolis OS 8），请参考如下命令自行安装：\n\ndnf install -y docker\nsystemctl enable --now docker"
        fi
        SYSTEM_FACTIONS="${SYSTEM_ANOLISOS}"
    else
        output_error "当前操作系统 ($SYSTEM_NAME) 不在本脚本的支持范围内，请前往官网查看支持列表！"
    fi

    ## 判定系统类型、版本、版本号
    case "${SYSTEM_FACTIONS}" in
    "${SYSTEM_DEBIAN}")
        if ! command -v lsb_release &>/dev/null; then
            echo -e "$WARN 检测到 lsb-release 未安装，正在尝试安装..."
            # 需要先设置包管理器才能安装
            set_package_manager_commands # 临时调用以获取CMD_INSTALL
            if [[ -z "${CMD_INSTALL}" ]]; then
                 output_error "无法确定包管理器，无法自动安装 lsb-release。"
            fi
            execute_commands "安装 lsb-release" "${CMD_INSTALL} lsb-release"
            if [ $? -ne 0 ] || ! command -v lsb_release &>/dev/null; then
                output_error "lsb-release 软件包安装失败！\n\n本脚本依赖 lsb_release 判断系统具体类型和版本，请手动安装 (${CMD_INSTALL} lsb-release) 后重新执行脚本！"
            fi
        fi
        SYSTEM_JUDGMENT="$(lsb_release -is)"
        SYSTEM_VERSION_CODENAME="${DEBIAN_CODENAME:-"$(lsb_release -cs)"}"
        if [ -s "${File_RaspberryPiOSRelease}" ]; then
            SYSTEM_JUDGMENT="${SYSTEM_RASPBERRY_PI_OS}"
            SYSTEM_PRETTY_NAME="${SYSTEM_RASPBERRY_PI_OS}" # 强制使用 Raspberry Pi OS 名称
        fi
        ;;
    "${SYSTEM_REDHAT}")
        SYSTEM_JUDGMENT="$(awk '{printf $1}' $File_RedHatRelease)"
        if [[ "${SYSTEM_JUDGMENT}" == "${SYSTEM_ANOLISOS}" ]] && [[ "${SYSTEM_VERSION_ID_MAJOR}" != 23 ]]; then # Anolis 8 已经在前面拦截了
            output_error "不支持当前操作系统（Anolis OS ${SYSTEM_VERSION_ID_MAJOR}），请参考如下命令自行安装：\n\ndnf install -y docker\nsystemctl enable --now docker"
        fi
        grep -q "${SYSTEM_RHEL}" $File_RedHatRelease && SYSTEM_JUDGMENT="${SYSTEM_RHEL}"
        grep -q "${SYSTEM_CENTOS_STREAM}" $File_RedHatRelease && SYSTEM_JUDGMENT="${SYSTEM_CENTOS_STREAM}"
        ;;
    *)
        SYSTEM_JUDGMENT="${SYSTEM_FACTIONS}" # 对于 openEuler 等直接使用派系名
        ;;
    esac

    ## 判定系统处理器架构 (保持不变)
    DEVICE_ARCH_RAW="$(uname -m)"
    case "${DEVICE_ARCH_RAW}" in
    x86_64) DEVICE_ARCH="x86_64" ;;
    aarch64) DEVICE_ARCH="ARM64" ;;
    armv8l) DEVICE_ARCH="ARMv8_32" ;;
    armv7l) DEVICE_ARCH="ARMv7" ;;
    armv6l) DEVICE_ARCH="ARMv6" ;;
    armv5tel) DEVICE_ARCH="ARMv5" ;;
    ppc64le) DEVICE_ARCH="ppc64le" ;;
    s390x) DEVICE_ARCH="s390x" ;;
    i386 | i686) output_error "Docker Engine 不支持安装在 x86_32 架构的环境上！" ;;
    *) output_error "未知的系统架构：${DEVICE_ARCH_RAW}" ;;
    esac

    ## 定义软件源仓库名称 (保持不变)
    if [[ -z "${SOURCE_BRANCH}" ]]; then
        case "${SYSTEM_FACTIONS}" in
        "${SYSTEM_DEBIAN}")
            case "${SYSTEM_JUDGMENT}" in
            "${SYSTEM_DEBIAN}") SOURCE_BRANCH="debian" ;;
            "${SYSTEM_UBUNTU}" | "${SYSTEM_ZORIN}") SOURCE_BRANCH="ubuntu" ;;
             "${SYSTEM_RASPBERRY_PI_OS}")
                # Raspberry Pi OS 64位使用 debian 源, 32位使用 raspbian 源
                case "${DEVICE_ARCH_RAW}" in
                x86_64 | aarch64) SOURCE_BRANCH="debian" ;;
                *) SOURCE_BRANCH="raspbian" ;;
                esac
                ;;
            *) # 其他 Debian 衍生版，尝试用 bookworm (Debian 12)
               SOURCE_BRANCH="debian"
               SYSTEM_VERSION_CODENAME="bookworm"
               echo -e "$WARN 未知 Debian 衍生版 (${SYSTEM_JUDGMENT}), 将尝试使用 Debian 12 (bookworm) 的 Docker 源."
               ;;
            esac
            ;;
        "${SYSTEM_REDHAT}")
            case "${SYSTEM_JUDGMENT}" in
            "${SYSTEM_FEDORA}") SOURCE_BRANCH="fedora" ;;
            "${SYSTEM_RHEL}") SOURCE_BRANCH="rhel" ;;
            *) SOURCE_BRANCH="centos" ;;
            esac
            ;;
        "${SYSTEM_OPENEULER}" | "${SYSTEM_OPENCLOUDOS}" | "${SYSTEM_ANOLISOS}")
            SOURCE_BRANCH="centos" # 这些系统通常兼容 CentOS 的源
            ;;
        esac
    fi

    ## 定义软件源更新文字 (移至 set_package_manager_commands)

    ## 判断是否可以使用高级交互式选择器
    CAN_USE_ADVANCED_INTERACTIVE_SELECTION="false"
    if command -v tput &>/dev/null; then
        CAN_USE_ADVANCED_INTERACTIVE_SELECTION="true"
    fi
}

## 设置包管理器命令 (新增)
function set_package_manager_commands() {
    case "${SYSTEM_FACTIONS}" in
    "${SYSTEM_DEBIAN}")
        PKG_MANAGER="apt-get"
        CMD_UPDATE="${DEBIAN_FRONTEND_NONINTERACTIVE} apt-get update"
        CMD_INSTALL="${DEBIAN_FRONTEND_NONINTERACTIVE} apt-get install -y"
        CMD_REMOVE="${DEBIAN_FRONTEND_NONINTERACTIVE} apt-get remove -y"
        CMD_AUTOREMOVE="${DEBIAN_FRONTEND_NONINTERACTIVE} apt-get autoremove -y"
        CMD_LIST_PACKAGES="dpkg -l" # 需要后续 grep
        # 列出版本需要包名，格式: apt-cache madison <package>
        CMD_LIST_VERSIONS="apt-cache madison"
        CMD_MAKECACHE="" # apt 不需要
        SYNC_MIRROR_TEXT="更新软件包列表"
        ;;
    "${SYSTEM_REDHAT}" | "${SYSTEM_OPENEULER}" | "${SYSTEM_OPENCLOUDOS}" | "${SYSTEM_ANOLISOS}")
        # 判断使用 dnf 还是 yum
        if command -v dnf &>/dev/null && [[ "${SYSTEM_VERSION_ID_MAJOR}" -ge 8 || "${SYSTEM_JUDGMENT}" == "${SYSTEM_FEDORA}" || "${SYSTEM_JUDGMENT}" == "${SYSTEM_OPENEULER}" || "${SYSTEM_JUDGMENT}" == "${SYSTEM_OPENCLOUDOS}" || "${SYSTEM_JUDGMENT}" == "${SYSTEM_ANOLISOS}" ]]; then
            PKG_MANAGER="dnf"
            CMD_INSTALL="$PKG_MANAGER install -y"
        elif command -v yum &>/dev/null; then
             PKG_MANAGER="yum"
             # CentOS 7/RHEL 7 安装 yum-utils
             if [[ "${SYSTEM_VERSION_ID_MAJOR}" -eq 7 ]]; then
                if ! command -v yum-config-manager &>/dev/null; then
                    echo -e "$TIP 正在安装 yum-utils..."
                    yum install -y yum-utils > /dev/null 2>&1 || output_error "安装 yum-utils 失败！"
                fi
             fi
             CMD_INSTALL="$PKG_MANAGER install -y"
        else
            output_error "未找到 yum 或 dnf 包管理器！"
        fi
        CMD_UPDATE="$PKG_MANAGER makecache"
        CMD_REMOVE="$PKG_MANAGER remove -y"
        CMD_AUTOREMOVE="$PKG_MANAGER autoremove -y"
        CMD_LIST_PACKAGES="rpm -qa" # 需要后续 grep
        # 列出版本需要包名，格式: $PKG_MANAGER list <package> --showduplicates | sort -r
        CMD_LIST_VERSIONS="$PKG_MANAGER list --showduplicates"
        CMD_MAKECACHE="$PKG_MANAGER makecache"
        SYNC_MIRROR_TEXT="生成软件源缓存"
        ;;
     *)
        output_error "无法识别的系统派系 (${SYSTEM_FACTIONS})，无法设置包管理器命令。"
        ;;
    esac
}


## 执行命令并显示动画或详细输出 (新增)
# $1: 任务标题
# $2...: 要执行的命令 (将用 && 连接)
function execute_commands() {
    local title="$1"; shift
    local commands_to_run=("$@")
    local cmd_string=""
    local i

    # 构建命令字符串
    for (( i=0; i<${#commands_to_run[@]}; i++ )); do
        if [[ -z "$cmd_string" ]]; then
            cmd_string="${commands_to_run[i]}"
        else
            cmd_string="$cmd_string && ${commands_to_run[i]}"
        fi
    done

    # 如果没有命令，直接返回
    if [[ -z "$cmd_string" ]]; then
        echo -e "$WARN 在 \"$title\" 任务中没有要执行的命令。"
        return 0
    fi

    echo "" # 添加空行增加间距

    if [[ "$PURE_MODE" == "true" ]]; then
        animate_exec "$cmd_string" "$title"
        return $?
    else
        echo -e "$WORKING $title..."
        # 使用 bash -c 执行组合命令，更好地处理引号和重定向等复杂情况
        bash -c "$cmd_string"
        local exit_status=$?
        if [ $exit_status -eq 0 ]; then
            echo -e "$COMPLETE $title 完成"
        else
            echo -e "$FAIL $title 失败 (退出码: ${exit_status})。请检查上面的错误信息。" >&2
        fi
        return $exit_status
    fi
}


## 选择镜像源 (交互文本改为中文)
function choose_mirrors() {
    ## 打印软件源列表 (保持不变, 内部函数)
    function print_mirrors_list() {
        local tmp_mirror_name tmp_mirror_url arr_num default_mirror_name_length tmp_mirror_name_length tmp_spaces_nums a i j
        function StringLength() { local text=$1; echo "${#text}"; }
        echo -e ''
        local list_arr=(); local list_arr_sum="$(eval echo \${#$1[@]})"
        for ((a = 0; a < $list_arr_sum; a++)); do list_arr[$a]="$(eval echo \${$1[a]})"; done
        if command -v printf &>/dev/null; then
            for ((i = 0; i < ${#list_arr[@]}; i++)); do
                tmp_mirror_name=$(echo "${list_arr[i]}" | awk -F '@' '{print$1}')
                arr_num=$((i + 1)); default_mirror_name_length=${2:-"30"}
                [[ $(echo "${tmp_mirror_name}" | grep -c "“") -gt 0 ]] && let default_mirror_name_length+=$(echo "${tmp_mirror_name}" | grep -c "“")
                [[ $(echo "${tmp_mirror_name}" | grep -c "”") -gt 0 ]] && let default_mirror_name_length+=$(echo "${tmp_mirror_name}" | grep -c "”")
                [[ $(echo "${tmp_mirror_name}" | grep -c "‘") -gt 0 ]] && let default_mirror_name_length+=$(echo "${tmp_mirror_name}" | grep -c "‘")
                [[ $(echo "${tmp_mirror_name}" | grep -c "’") -gt 0 ]] && let default_mirror_name_length+=$(echo "${tmp_mirror_name}" | grep -c "’")
                tmp_mirror_name_length=$(StringLength $(echo "${tmp_mirror_name}" | sed "s| ||g" | sed "s|[0-9a-zA-Z\.\=\:\_\(\)\'\"-\/\!·]||g;"))
                tmp_spaces_nums=$(($(($default_mirror_name_length - ${tmp_mirror_name_length} - $(StringLength "${tmp_mirror_name}"))) / 2))
                for ((j = 1; j <= ${tmp_spaces_nums}; j++)); do tmp_mirror_name="${tmp_mirror_name} "; done
                printf "❖  %-$(($default_mirror_name_length + ${tmp_mirror_name_length}))s %4s\n" "${tmp_mirror_name}" "$arr_num)"
            done
        else
            for ((i = 0; i < ${#list_arr[@]}; i++)); do
                tmp_mirror_name="${list_arr[i]%@*}"; tmp_mirror_url="${list_arr[i]#*@}"
                arr_num=$((i + 1)); echo -e " ❖  $arr_num. ${tmp_mirror_url} | ${tmp_mirror_name}"
            done
        fi
    }

    function print_title() {
        local system_name="${SYSTEM_PRETTY_NAME:-"${SYSTEM_NAME} ${SYSTEM_VERSION_ID}"}"
        local arch="${DEVICE_ARCH}"; local date_time time_zone
        date_time="$(date "+%Y-%m-%d %H:%M")"
        timezone="$(timedatectl status 2>/dev/null | grep "Time zone" | awk -F ':' '{print$2}' | awk -F ' ' '{print$1}')"
        echo -e ''
        echo -e "运行环境 ${BLUE}${system_name} ${arch}${PLAIN}"
        echo -e "系统时间 ${BLUE}${date_time} ${timezone}${PLAIN}"
    }

    [[ "${PURE_MODE}" != "true" ]] && print_title

    local mirror_list_name
    if [[ -z "${SOURCE}" ]]; then
        mirror_list_name="mirror_list_docker_ce"
        if [[ "${CAN_USE_ADVANCED_INTERACTIVE_SELECTION}" == "true" ]]; then
            sleep 0.1 # 短暂延迟
            eval "interactive_select_mirror \"\${${mirror_list_name}[@]}\" \"\\n \${BOLD}请选择 Docker CE 软件源 (按 Enter 确认): \${PLAIN}\\n\""
            SOURCE="${_SELECT_RESULT#*@}"
            echo -e "\n${GREEN}➜${PLAIN}  ${BOLD}Docker CE 源: ${_SELECT_RESULT%@*}${PLAIN}"
        else
            print_mirrors_list "${mirror_list_name}" 38
            local CHOICE_B=$(echo -e "\n${BOLD}└─ 请输入 Docker CE 源的数字序号 [ 1-$(eval echo \${#$mirror_list_name[@]}) ]：${PLAIN}")
            while true; do
                read -p "${CHOICE_B}" INPUT
                INPUT=$(echo $INPUT | tr -cd '[0-9]') # 只保留数字
                if [[ "$INPUT" -ge 1 && "$INPUT" -le $(eval echo \${#$mirror_list_name[@]}) ]]; then
                    SOURCE="$(eval echo \${${mirror_list_name}[$(($INPUT - 1))]} | awk -F '@' '{print$2}')"
                     echo -e "\n${GREEN}➜${PLAIN}  ${BOLD}已选择 Docker CE 源: $(eval echo \${${mirror_list_name}[$(($INPUT - 1))]} | awk -F '@' '{print$1}')${PLAIN}"
                    break
                else
                    echo -e "\n$WARN 请输入列表中的有效数字序号！"
                fi
            done
        fi
    fi

    if [[ -z "${SOURCE_REGISTRY}" ]]; then
        mirror_list_name="mirror_list_registry"
        if [[ "${CAN_USE_ADVANCED_INTERACTIVE_SELECTION}" == "true" ]]; then
            sleep 0.1
            eval "interactive_select_mirror \"\${${mirror_list_name}[@]}\" \"\\n \${BOLD}请选择 Docker Registry 镜像仓库 (按 Enter 确认): \${PLAIN}\\n\""
            SOURCE_REGISTRY="${_SELECT_RESULT#*@}"
            echo -e "\n${GREEN}➜${PLAIN}  ${BOLD}Docker Registry: $(echo "${_SELECT_RESULT%@*}" | sed 's|（推荐）||g')${PLAIN}"
        else
            print_mirrors_list "${mirror_list_name}" 44
            local CHOICE_C=$(echo -e "\n${BOLD}└─ 请输入 Docker Registry 的数字序号 [ 1-$(eval echo \${#$mirror_list_name[@]}) ]：${PLAIN}")
            while true; do
                read -p "${CHOICE_C}" INPUT
                INPUT=$(echo $INPUT | tr -cd '[0-9]') # 只保留数字
                 if [[ "$INPUT" -ge 1 && "$INPUT" -le $(eval echo \${#$mirror_list_name[@]}) ]]; then
                    SOURCE_REGISTRY="$(eval echo \${${mirror_list_name}[$(($INPUT - 1))]} | awk -F '@' '{print$2}')"
                     echo -e "\n${GREEN}➜${PLAIN}  ${BOLD}已选择 Docker Registry: $(eval echo \${${mirror_list_name}[$(($INPUT - 1))]} | awk -F '@' '{print$1}' | sed 's|（推荐）||g')${PLAIN}"
                    break
                else
                    echo -e "\n$WARN 请输入列表中的有效数字序号！"
                fi
            done
        fi
    fi
}

## 选择 WEB 协议 (交互文本改为中文)
function choose_protocol() {
    if [[ -z "${WEB_PROTOCOL}" ]]; then
        if [[ "${ONLY_HTTP}" == "true" ]]; then # 假设有这个变量，虽然原脚本没有
            WEB_PROTOCOL="http"
        else
            if [[ "${CAN_USE_ADVANCED_INTERACTIVE_SELECTION}" == "true" ]]; then
                echo ''
                interactive_select_boolean "${BOLD}Docker CE 软件源是否使用 HTTP 协议? (默认 HTTPS)${PLAIN}"
                if [[ "${_SELECT_RESULT}" == "true" ]]; then
                    WEB_PROTOCOL="http"
                else
                    WEB_PROTOCOL="https"
                fi
            else
                local CHOICE=$(echo -e "\n${BOLD}└─ Docker CE 软件源是否使用 HTTP 协议? (建议 N 使用 HTTPS) [y/N] ${PLAIN}")
                read -rp "${CHOICE}" INPUT
                [[ -z "${INPUT}" ]] && INPUT=N # 默认 N (HTTPS)
                case "${INPUT}" in
                [Yy] | [Yy][Ee][Ss])
                    WEB_PROTOCOL="http"
                    echo -e "\n${YELLOW}⚠ 已选择使用 HTTP 协议，安全性较低。${PLAIN}"
                    ;;
                [Nn] | [Nn][Oo])
                    WEB_PROTOCOL="https"
                     echo -e "\n${GREEN}➜${PLAIN}  已选择使用 HTTPS 协议。"
                    ;;
                *)
                    echo -e "\n$WARN 输入错误，默认使用 HTTPS 协议！"
                    WEB_PROTOCOL="https"
                    ;;
                esac
            fi
        fi
    fi
    WEB_PROTOCOL="${WEB_PROTOCOL,,}" # 转小写
}

## 关闭防火墙和SELinux (交互文本改为中文)
function close_firewall_service() {
    local firewall_active=false
    local selinux_active=false

    if command -v systemctl &>/dev/null && systemctl is-active firewalld &>/dev/null; then
         firewall_active=true
    fi
    if command -v getenforce &>/dev/null && [[ "$(getenforce)" == "Enforcing" ]]; then
        selinux_active=true
    fi

    if [[ "$firewall_active" == "true" || "$selinux_active" == "true" ]]; then
        # 如果命令行已指定，则直接使用
        if [[ -n "${CLOSE_FIREWALL}" ]]; then
            if [[ "${CLOSE_FIREWALL}" == "true" ]]; then
                 echo -e "$TIP 根据命令行参数，将尝试关闭防火墙和 SELinux。"
                 # 执行关闭操作
                 perform_firewall_selinux_disable "$firewall_active" "$selinux_active"
            else
                 echo -e "$TIP 根据命令行参数，不关闭防火墙或 SELinux。"
            fi
            return # 处理完毕，退出函数
        fi

        # 未通过命令行指定，进行交互询问
        local prompt_message="${BOLD}检测到防火墙 (firewalld) 或 SELinux 处于活动状态，是否关闭它们？\n   (关闭有助于避免 Docker 网络问题，但会降低系统安全性) ${PLAIN}"
        local choice_needed=true

        if [[ "${CAN_USE_ADVANCED_INTERACTIVE_SELECTION}" == "true" ]]; then
            echo ''
            interactive_select_boolean "$prompt_message"
            if [[ "${_SELECT_RESULT}" == "true" ]]; then
                CLOSE_FIREWALL="true"
                 perform_firewall_selinux_disable "$firewall_active" "$selinux_active"
            else
                CLOSE_FIREWALL="false"
                echo -e "\n$TIP 已选择不关闭防火墙或 SELinux。"
            fi
        else
            local CHOICE=$(echo -e "\n${BOLD}└─ ${prompt_message} [y/N] ${PLAIN}")
            read -rp "${CHOICE}" INPUT
            [[ -z "${INPUT}" ]] && INPUT=N
            case "${INPUT}" in
            [Yy] | [Yy][Ee][Ss])
                CLOSE_FIREWALL="true"
                 perform_firewall_selinux_disable "$firewall_active" "$selinux_active"
                ;;
            [Nn] | [Nn][Oo])
                CLOSE_FIREWALL="false"
                echo -e "\n$TIP 已选择不关闭防火墙或 SELinux。"
                ;;
            *)
                echo -e "\n$WARN 输入错误，默认不关闭！"
                CLOSE_FIREWALL="false"
                ;;
            esac
        fi
    else
        # 如果防火墙和SELinux都未激活，则无需操作
        if [[ -z "${CLOSE_FIREWALL}" ]]; then # 仅在未通过命令行设置时提示
             echo -e "$TIP 防火墙 (firewalld) 和 SELinux 均未激活或未检测到，跳过关闭步骤。"
        fi
    fi
}

## 执行关闭防火墙和SELinux的操作 (新增内部函数)
function perform_firewall_selinux_disable() {
    local firewall_active="$1"
    local selinux_active="$2"
    local cmds=()
    local title="关闭防火墙和SELinux"

    if [[ "$firewall_active" == "true" ]]; then
        cmds+=("systemctl disable --now firewalld")
        echo -e "$YELLOW  - 正在禁用并停止 firewalld...${PLAIN}"
    fi

    if [[ "$selinux_active" == "true" ]]; then
        local SelinuxConfig=/etc/selinux/config
        if [ -s "${SelinuxConfig}" ]; then
            # 检查是否已经是 permissive 或 disabled
            if grep -q "SELINUX=enforcing" "$SelinuxConfig"; then
                 cmds+=("sed -i 's/SELINUX=enforcing/SELINUX=permissive/g' $SelinuxConfig") # 改为 permissive 更安全
                 cmds+=("setenforce 0")
                 echo -e "$YELLOW  - 正在将 SELinux 设置为 Permissive 模式 (下次重启生效)...${PLAIN}"
                 echo -e "$YELLOW  - 正在临时将 SELinux 设置为 Permissive 模式 (立即生效)...${PLAIN}"
            else
                 echo -e "$TIP   SELinux 已处于 permissive 或 disabled 状态。"
                 # 如果已经是 permissive，可能仍需 setenforce 0
                 if [[ "$(getenforce)" == "Enforcing" ]]; then
                     cmds+=("setenforce 0")
                     echo -e "$YELLOW  - 正在临时将 SELinux 设置为 Permissive 模式 (立即生效)...${PLAIN}"
                 fi
            fi
        else
            # 如果配置文件不存在但 getenforce 是 Enforcing，则只临时禁用
            cmds+=("setenforce 0")
            echo -e "$YELLOW  - 未找到 SELinux 配置文件，正在临时将 SELinux 设置为 Permissive 模式...${PLAIN}"
        fi
    fi

    if [ ${#cmds[@]} -gt 0 ]; then
        execute_commands "$title" "${cmds[@]}"
        if [ $? -ne 0 ]; then
             echo -e "$WARN 关闭防火墙或设置 SELinux 时遇到问题，请检查输出。"
             # 不认为是致命错误，脚本继续
        else
             echo -e "$COMPLETE 防火墙/SELinux 关闭/设置操作已执行。"
             echo -e "$YELLOW   请注意：SELinux 的永久更改将在系统重启后完全生效。${PLAIN}"
        fi
    else
        echo -e "$TIP 无需执行防火墙或 SELinux 关闭操作。"
    fi
}


## 安装环境依赖包 (使用抽象命令)
function install_dependency_packages() {
    local cmds_update=()
    local cmds_install=()
    local dependency_packages=""

    ## 删除可能存在的旧 Docker 源文件
    case "${SYSTEM_FACTIONS}" in
    "${SYSTEM_DEBIAN}")
        # 使用 find 更安全地删除，避免误删其他文件
        find "${Dir_DebianExtendSource}" -name '*docker*.list' -delete > /dev/null 2>&1
        # 谨慎修改主 sources.list
        if grep -q 'docker-ce' "$File_DebianSourceList"; then
             echo -e "$TIP 正在尝试从 $File_DebianSourceList 中移除 Docker CE 相关行..."
             # 备份原文件
             cp "$File_DebianSourceList" "${File_DebianSourceList}.bak.$(date +%s)"
             # 删除包含 docker-ce 的行
             sed -i.bak '/docker-ce/d' "$File_DebianSourceList"
        fi
        ;;
    "${SYSTEM_REDHAT}" | "${SYSTEM_OPENEULER}" | "${SYSTEM_OPENCLOUDOS}" | "${SYSTEM_ANOLISOS}")
        find "${Dir_YumRepos}" -name '*docker*.repo' -delete > /dev/null 2>&1
        ;;
    esac

    ## 更新软件源缓存
    if [[ -n "${CMD_UPDATE}" ]]; then
        cmds_update+=("${CMD_UPDATE}")
    fi
    if [ ${#cmds_update[@]} -gt 0 ]; then
        execute_commands "${SYNC_MIRROR_TEXT}" "${cmds_update[@]}"
        if [ $? -ne 0 ]; then
            output_error "${SYNC_MIRROR_TEXT}失败！请检查您的网络连接和系统软件源配置 (${BLUE}例如: /etc/apt/sources.list 或 /etc/yum.repos.d/*${PLAIN})。确保 ${BLUE}${PKG_MANAGER}${PLAIN} 可以正常工作。"
        fi
    fi

    ## 安装必要的依赖
    case "${SYSTEM_FACTIONS}" in
    "${SYSTEM_DEBIAN}")
        dependency_packages="ca-certificates curl gnupg" # gnupg 用于处理 GPG 密钥
        ;;
    "${SYSTEM_REDHAT}" | "${SYSTEM_OPENEULER}" | "${SYSTEM_OPENCLOUDOS}" | "${SYSTEM_ANOLISOS}")
        if [[ "$PKG_MANAGER" == "yum" && "${SYSTEM_VERSION_ID_MAJOR}" -eq 7 ]]; then
             # CentOS 7 / RHEL 7
             dependency_packages="yum-utils device-mapper-persistent-data lvm2 curl"
             # yum-utils 已在 set_package_manager_commands 中检查安装
        else
             # RHEL 8+, Fedora, openEuler, etc.
             dependency_packages="dnf-plugins-core curl" # dnf-plugins-core 包含 config-manager
             # 检查是否已安装
             if ! command -v "${PKG_MANAGER}-config-manager" &>/dev/null; then
                 echo -e "$TIP 正在安装 ${PKG_MANAGER}-plugins-core..."
             else
                 # 如果已安装，则不重复安装
                 dependency_packages="curl" # 只需要 curl
             fi
        fi
        ;;
    esac

    if [[ -n "$dependency_packages" ]]; then
         # 检查包是否已安装，避免不必要的安装操作
        local packages_to_install=()
        for pkg in $dependency_packages; do
            local check_cmd=""
            case "$PKG_MANAGER" in
                apt-get) check_cmd="dpkg -s $pkg" ;;
                yum|dnf) check_cmd="rpm -q $pkg" ;;
            esac
            if [[ -n "$check_cmd" ]]; then
                $check_cmd &> /dev/null
                if [ $? -ne 0 ]; then
                    packages_to_install+=("$pkg")
                fi
            fi
        done

        if [ ${#packages_to_install[@]} -gt 0 ]; then
             cmds_install+=("${CMD_INSTALL} ${packages_to_install[*]}")
             execute_commands "安装环境依赖包 (${packages_to_install[*]})" "${cmds_install[@]}"
             if [ $? -ne 0 ]; then
                 output_error "安装环境依赖包失败！请检查 ${BLUE}${PKG_MANAGER}${PLAIN} 的输出信息。"
             fi
        else
             echo -e "$TIP 所需的环境依赖包 (${dependency_packages}) 均已安装。"
        fi
    fi
}


## 配置 Docker CE 源 (使用抽象命令, 增强错误处理)
function configure_docker_ce_mirror() {
    local cmds_repo=()
    local cmds_update=()
    local repo_config_success=false

    case "${SYSTEM_FACTIONS}" in
    "${SYSTEM_DEBIAN}")
        ## 处理 GPG 密钥
        local file_keyring="/etc/apt/keyrings/docker.asc"
        # apt-key 已弃用，不再删除旧密钥
        # 创建目录
        install -m 0755 -d /etc/apt/keyrings
        if [ $? -ne 0 ]; then output_error "创建 GPG 密钥目录 /etc/apt/keyrings 失败！"; fi
        # 下载密钥
        curl -fsSL "${WEB_PROTOCOL}://${SOURCE}/linux/${SOURCE_BRANCH}/gpg" -o "${file_keyring}"
        if [ $? -ne 0 ]; then output_error "下载 Docker GPG 密钥失败！请检查网络或更换 Docker CE 源后重试。 URL: ${WEB_PROTOCOL}://${SOURCE}/linux/${SOURCE_BRANCH}/gpg"; fi
        # 设置权限
        chmod a+r "${file_keyring}"
        if [ $? -ne 0 ]; then output_error "设置 GPG 密钥文件权限失败！ (${file_keyring})"; fi

        ## 添加源
        local repo_line="deb [arch=$(dpkg --print-architecture) signed-by=${file_keyring}] ${WEB_PROTOCOL}://${SOURCE}/linux/${SOURCE_BRANCH} ${SYSTEM_VERSION_CODENAME} stable"
        echo "${repo_line}" | tee "$Dir_DebianExtendSource/docker.list" > /dev/null
         if [ $? -ne 0 ]; then output_error "写入 Docker CE 软件源配置失败！ (${Dir_DebianExtendSource}/docker.list)"; fi
        echo -e "$COMPLETE Docker CE 源配置完成: ${Dir_DebianExtendSource}/docker.list"
        repo_config_success=true
        ;;

    "${SYSTEM_REDHAT}" | "${SYSTEM_OPENEULER}" | "${SYSTEM_OPENCLOUDOS}" | "${SYSTEM_ANOLISOS}")
        local repo_file="$Dir_YumRepos/docker-ce.repo"
        local repo_url="${WEB_PROTOCOL}://${SOURCE}/linux/${SOURCE_BRANCH}/docker-ce.repo"
        local config_manager_cmd=""

        if [[ "$PKG_MANAGER" == "yum" && "${SYSTEM_VERSION_ID_MAJOR}" -eq 7 ]]; then
             config_manager_cmd="yum-config-manager"
        elif [[ "$PKG_MANAGER" == "dnf" ]]; then
             config_manager_cmd="dnf config-manager"
        else
             # 对于其他情况，直接下载 repo 文件
             echo -e "$TIP 未找到 config-manager, 尝试直接下载 repo 文件..."
             curl -fsSL "$repo_url" -o "$repo_file"
             if [ $? -ne 0 ]; then output_error "下载 docker-ce.repo 文件失败！ URL: $repo_url"; fi
             # 手动替换 baseurl
             sed -i "s|https://download.docker.com|${WEB_PROTOCOL}://${SOURCE}|g" "$repo_file"
             if [ $? -ne 0 ]; then output_error "修改 ${repo_file} 中的仓库地址失败！ (sed)"; fi
             repo_config_success=true # 标记成功
        fi

        # 如果有 config-manager 命令，则使用它添加仓库
        if [[ -n "$config_manager_cmd" && "$repo_config_success" == false ]]; then
             execute_commands "添加 Docker CE 仓库" "$config_manager_cmd --add-repo $repo_url"
             if [ $? -ne 0 ]; then output_error "使用 ${config_manager_cmd} 添加 Docker CE 仓库失败！"; fi

             # 替换 baseurl
             sed -i "s|https://download.docker.com|${WEB_PROTOCOL}://${SOURCE}|g" "$repo_file"
              if [ $? -ne 0 ]; then output_error "修改 ${repo_file} 中的仓库地址失败！ (sed)"; fi
             repo_config_success=true # 标记成功
        fi

        ## 兼容处理版本号 (仅当非 Fedora 且成功配置了 repo 文件)
        if [[ "${SYSTEM_JUDGMENT}" != "${SYSTEM_FEDORA}" && "$repo_config_success" == true ]]; then
            local target_version
            # 优先使用主版本号，如果主版本号大于9，则尝试用9 (Docker官方通常只提供到特定RHEL版本的源)
            case "${SYSTEM_VERSION_ID_MAJOR}" in
            7 | 8 | 9) target_version="${SYSTEM_VERSION_ID_MAJOR}" ;;
            *) target_version="9" ;; # 默认尝试 RHEL 9 的源
            esac
            echo -e "$TIP 正在将仓库配置文件中的 \$releasever 替换为 ${target_version} ..."
            sed -i "s|\$releasever|${target_version}|g" "$repo_file"
            if [ $? -ne 0 ]; then echo -e "$WARN 修改 ${repo_file} 中的版本号失败 (sed)，可能导致无法找到包。"; fi
        fi

        if [[ "$repo_config_success" == true ]]; then
             echo -e "$COMPLETE Docker CE 源配置完成: ${repo_file}"
        fi
        ;;
    *)
        output_error "无法为系统派系 ${SYSTEM_FACTIONS} 配置 Docker CE 源。"
        ;;
    esac

    ## 更新软件源列表/缓存
    if [[ "$repo_config_success" == true && -n "${CMD_UPDATE}" ]]; then
         execute_commands "${SYNC_MIRROR_TEXT} (包含新 Docker 源)" "${CMD_UPDATE}"
         if [ $? -ne 0 ]; then
             output_error "更新包含 Docker 源的 ${SYNC_MIRROR_TEXT} 失败！请检查 ${PKG_MANAGER} 输出。"
         fi
    fi
}

## 卸载旧版本 Docker (使用抽象命令)
function uninstall_original_version() {
    local packages_to_remove=()
    local pkgs_found=false

    # 检查是否安装了旧版本
    local old_pkgs_pattern='docker\|containerd\|runc\|podman'
    case "${SYSTEM_FACTIONS}" in
    "${SYSTEM_DEBIAN}")
        # dpkg-query 更精确
        packages_to_remove=$(dpkg-query -W -f='${Package}\n' docker docker-engine docker.io containerd runc podman docker-ce docker-ce-cli 2>/dev/null | grep -E '^(docker|containerd|runc|podman)')
        ;;
    "${SYSTEM_REDHAT}" | "${SYSTEM_OPENEULER}" | "${SYSTEM_OPENCLOUDOS}" | "${SYSTEM_ANOLISOS}")
        packages_to_remove=$(rpm -qa | grep -E "$old_pkgs_pattern")
        ;;
    esac

    if [[ -n "$packages_to_remove" ]]; then
        pkgs_found=true
        echo -e "$TIP 检测到可能冲突的旧软件包，将尝试卸载："
        echo -e "${YELLOW}${packages_to_remove}${PLAIN}"

        # 先停止并禁用 Docker 服务 (如果存在)
        if command -v systemctl &>/dev/null && systemctl is-active docker &>/dev/null; then
             execute_commands "停止并禁用现有 Docker 服务" "systemctl disable --now docker"
             sleep 1 # 等待服务停止
        fi

        # 执行卸载
        # 将换行符转换为空格
        local remove_list=$(echo "$packages_to_remove" | tr '\n' ' ')
        execute_commands "卸载旧软件包" "${CMD_REMOVE} ${remove_list}"
        # 卸载后清理依赖
        if [[ -n "${CMD_AUTOREMOVE}" ]]; then
             execute_commands "清理残留依赖" "${CMD_AUTOREMOVE}"
        fi
         echo -e "$COMPLETE 旧软件包卸载完成。"
    else
         echo -e "$TIP 未检测到需要卸载的旧 Docker 相关软件包。"
    fi
}


## 安装 Docker Engine (使用抽象命令, 优化版本选择)
function install_docker_engine() {

    ## 导出可安装的版本列表 (内部函数)
    function export_version_list() {
        echo -e "$WORKING 正在查询可用的 Docker Engine 版本列表..."
        local list_cmd=""
        local raw_list=""
        local version_list=()
        local pkg_ce="docker-ce"
        local pkg_cli="docker-ce-cli"

        # 获取 CE 版本列表
        list_cmd="${CMD_LIST_VERSIONS} ${pkg_ce}"
        raw_ce_list=$(eval "$list_cmd" 2>/dev/null)
        if [ $? -ne 0 ]; then echo -e "$WARN 查询 ${pkg_ce} 版本列表失败。"; fi

        # 获取 CLI 版本列表
        list_cmd="${CMD_LIST_VERSIONS} ${pkg_cli}"
        raw_cli_list=$(eval "$list_cmd" 2>/dev/null)
         if [ $? -ne 0 ]; then echo -e "$WARN 查询 ${pkg_cli} 版本列表失败。"; fi

        # 解析版本号
        local ce_versions=()
        local cli_versions=()
        case "$PKG_MANAGER" in
        apt-get)
            # 格式: 5:26.1.4-1~debian.11~bullseye
            ce_versions=($(echo "$raw_ce_list" | awk '{print $3}' | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | sort -Vru))
            cli_versions=($(echo "$raw_cli_list" | awk '{print $3}' | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | sort -Vru))
            ;;
        yum|dnf)
            # 格式: docker-ce-cli-3:26.1.4-3.el7.x86_64
             # RHEL/CentOS 格式: 3:26.1.4-3.elN
             # Fedora 格式: 3:26.1.4-3.fcN
            ce_versions=($(echo "$raw_ce_list" | awk '{print $2}' | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | sort -Vru))
            cli_versions=($(echo "$raw_cli_list" | awk '{print $2}' | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | sort -Vru))
            ;;
        *)
            output_error "无法为包管理器 ${PKG_MANAGER} 解析版本列表。"
            ;;
        esac

        # 取交集，确保 CE 和 CLI 版本都存在
        version_list=($(comm -12 <(printf '%s\n' "${ce_versions[@]}") <(printf '%s\n' "${cli_versions[@]}")))

        if [ ${#version_list[@]} -eq 0 ]; then
            rm -f "$DockerVersionFile" # 清理空文件
            output_error "无法获取有效的 Docker Engine (CE 和 CLI) 版本列表！请检查软件源配置或网络。"
        fi

        # 写入文件供选择
        printf '%s\n' "${version_list[@]}" > "$DockerVersionFile"
        echo -e "$COMPLETE 可用版本列表查询完成。"
    }

    ## 安装主逻辑 (内部函数)
    function install_main() {
        local target_docker_version=""
        local install_cmds=()
        local docker_ce_pkg=""
        local docker_cli_pkg=""
        # 基础依赖包 (通常和 Docker CE/CLI 一起安装或作为依赖自动安装)
        local base_deps="containerd.io docker-buildx-plugin docker-compose-plugin"

        if [[ "${INSTALL_LATESTED_DOCKER}" == "true" ]]; then
             echo -e "$TIP 正在尝试安装最新版本的 Docker Engine..."
             # 直接安装包名，让包管理器选择最新版本
             docker_ce_pkg="docker-ce"
             docker_cli_pkg="docker-ce-cli"
             install_cmds+=("${CMD_INSTALL} ${docker_ce_pkg} ${docker_cli_pkg} ${base_deps}")
        else
            export_version_list # 获取版本列表到 $DockerVersionFile
            if [ ! -s "${DockerVersionFile}" ]; then
                # export_version_list 内部会处理错误，这里再检查一次
                output_error "未能生成 Docker Engine 版本列表文件！"
            fi

            # 如果通过命令行指定了版本
            if [[ -n "${DESIGNATED_DOCKER_VERSION}" ]]; then
                 if grep -q -w "${DESIGNATED_DOCKER_VERSION}" "$DockerVersionFile"; then
                     target_docker_version="${DESIGNATED_DOCKER_VERSION}"
                     echo -e "$TIP 根据命令行参数，将安装指定版本: ${target_docker_version}"
                 else
                     rm -f "$DockerVersionFile"
                     output_error "指定的 Docker Engine 版本 ${DESIGNATED_DOCKER_VERSION} 在可用列表 (${DockerVersionFile}) 中未找到或无效！"
                 fi
            else
                # 交互式选择版本
                if [[ "${CAN_USE_ADVANCED_INTERACTIVE_SELECTION}" == "true" ]]; then
                    # 从文件中读取版本列表到数组
                     mapfile -t version_options < "$DockerVersionFile"
                     # 检查 mapfile 是否成功
                     if [ ${#version_options[@]} -eq 0 ]; then
                         rm -f "$DockerVersionFile"
                         output_error "无法从 ${DockerVersionFile} 读取版本列表！"
                     fi

                    local mirror_list_name="version_options" # 使用 mapfile 创建的数组名
                    # 注意：这里的 eval 用于传递数组名给选择函数
                    eval "interactive_select_mirror \"\${${mirror_list_name}[@]}\" \"\\n \${BOLD}请选择要安装的 Docker Engine 版本 (按 Enter 确认): \${PLAIN}\\n\""
                    target_docker_version="${_SELECT_RESULT}"
                    echo -e "\n${GREEN}➜${PLAIN}  ${BOLD}已选择安装版本：${target_docker_version}${PLAIN}\n"
                else
                    echo -e "\n${GREEN}--- 请选择您要安装的 Docker Engine 版本 (例如: 26.1.4) ---${PLAIN}\n"
                    cat "$DockerVersionFile" | nl # 使用 nl 添加行号
                    echo -e '' # 加个空行
                    while true; do
                        local CHOICE=$(echo -e "${BOLD}└─ 请根据上面的列表，输入您想安装的具体版本号：${PLAIN}")
                        read -p "${CHOICE}" target_docker_version
                        # 精确匹配行
                        if grep -q -x "${target_docker_version}" "$DockerVersionFile"; then
                            echo -e "\n${GREEN}➜${PLAIN}  ${BOLD}已选择安装版本：${target_docker_version}${PLAIN}\n"
                            break
                        else
                            echo -e "$ERROR 输入的版本号无效或不在列表中，请重新输入！"
                        fi
                    done
                fi
            fi

            # 清理版本文件
            rm -f "$DockerVersionFile"

            # 构建特定版本的包名
            case "$PKG_MANAGER" in
            apt-get)
                 # apt 需要版本字符串，格式如 5:26.1.4*
                 # 注意：apt 可能需要epoch (如 5:)，但通常指定版本号 * 通配符可以工作
                 # 需要找到包含该版本号的完整包版本字符串
                 local full_ce_version=$(apt-cache madison docker-ce | grep " ${target_docker_version}" | head -n 1 | awk '{print $3}')
                 local full_cli_version=$(apt-cache madison docker-ce-cli | grep " ${target_docker_version}" | head -n 1 | awk '{print $3}')
                 if [[ -z "$full_ce_version" || -z "$full_cli_version" ]]; then
                     output_error "无法找到版本 ${target_docker_version} 对应的完整包名 (docker-ce 或 docker-ce-cli)。"
                 fi
                 docker_ce_pkg="docker-ce=${full_ce_version}"
                 docker_cli_pkg="docker-ce-cli=${full_cli_version}"
                ;;
            yum|dnf)
                 # yum/dnf 格式: docker-ce-<version>
                 docker_ce_pkg="docker-ce-${target_docker_version}"
                 docker_cli_pkg="docker-ce-cli-${target_docker_version}"
                 ;;
            esac
             install_cmds+=("${CMD_INSTALL} ${docker_ce_pkg} ${docker_cli_pkg} ${base_deps}")
        fi

        # 执行安装
        execute_commands "安装 Docker Engine" "${install_cmds[@]}"
        if [ $? -ne 0 ]; then
            output_error "安装 Docker Engine 失败！请检查 ${PKG_MANAGER} 的输出信息。"
        fi
    }

    ## 修改 Docker Registry 镜像仓库源 (中文提示, 增强错误处理)
    function change_docker_registry_mirror() {
        # 如果选择的是官方源，则无需配置 mirror
        if [[ "${SOURCE_REGISTRY}" == "registry.hub.docker.com" ]]; then
            echo -e "$TIP 您选择了官方 Docker Hub 作为 Registry，无需配置镜像加速器。"
            # 如果 daemon.json 存在且包含 registry-mirrors，可以选择移除或保留
            if [ -f "${DockerConfig}" ] && grep -q '"registry-mirrors"' "${DockerConfig}"; then
                 echo -e "$WARN 检测到 ${DockerConfig} 中已存在 registry-mirrors 配置。"
                 # 可以添加逻辑询问用户是否移除，或默认保留
                 echo -e "$TIP   将保留现有配置。如需移除请手动编辑 ${DockerConfig}。"
            fi
            return
        fi

        echo -e "$TIP 正在配置 Docker Registry 镜像加速器: ${SOURCE_REGISTRY}"
        # 检查 Docker 目录是否存在
        if [ ! -d "${DockerDir}" ]; then
             mkdir -p "$DockerDir"
             if [ $? -ne 0 ]; then output_error "创建 Docker 配置目录 ${DockerDir} 失败！"; fi
        fi

        # 备份现有配置
        if [ -f "${DockerConfig}" ]; then
            if [ -f "${DockerConfigBackup}" ]; then
                if [[ "${IGNORE_BACKUP_TIPS}" == "false" ]]; then
                     if [[ "${CAN_USE_ADVANCED_INTERACTIVE_SELECTION}" == "true" ]]; then
                         echo ''
                         interactive_select_boolean "${BOLD}检测到已备份的 Docker 配置文件 (${DockerConfigBackup})，是否覆盖备份? (选择否则跳过备份)${PLAIN}"
                         if [[ "${_SELECT_RESULT}" == "true" ]]; then
                             cp -af "$DockerConfig" "$DockerConfigBackup" # 使用 -a 保持权限和时间戳
                             if [ $? -ne 0 ]; then echo -e "$WARN 备份 Docker 配置文件失败 (cp)！"; else echo -e "$COMPLETE 已覆盖备份原有 Docker 配置文件至 ${DockerConfigBackup}"; fi
                         else
                             echo -e "$TIP 跳过覆盖备份。"
                         fi
                     else
                         local CHOICE_BACKUP=$(echo -e "\n${BOLD}└─ 检测到已备份 (${DockerConfigBackup})，是否覆盖? (N 则跳过备份) [y/N] ${PLAIN}")
                         read -p "${CHOICE_BACKUP}" INPUT
                         [[ -z "${INPUT}" ]] && INPUT=N
                         case $INPUT in
                         [Yy] | [Yy][Ee][Ss])
                             cp -af "$DockerConfig" "$DockerConfigBackup"
                              if [ $? -ne 0 ]; then echo -e "$WARN 备份 Docker 配置文件失败 (cp)！"; else echo -e "$COMPLETE 已覆盖备份原有 Docker 配置文件至 ${DockerConfigBackup}"; fi
                             ;;
                         [Nn] | [Nn][Oo])
                              echo -e "$TIP 跳过覆盖备份。"
                              ;;
                         *)
                             echo -e "\n$WARN 输入错误，默认不覆盖备份！"
                             ;;
                         esac
                     fi
                fi
            else
                 cp -af "$DockerConfig" "$DockerConfigBackup"
                 if [ $? -ne 0 ]; then echo -e "$WARN 备份 Docker 配置文件失败 (cp)！"; else echo -e "$COMPLETE 已备份原有 Docker 配置文件至 ${DockerConfigBackup}"; fi
                 sleep 1 # 短暂暂停
            fi
        else
            # 如果原始文件不存在，创建一个空的 JSON 文件
             echo "{}" > "$DockerConfig"
             if [ $? -ne 0 ]; then output_error "创建空的 Docker 配置文件 ${DockerConfig} 失败！"; fi
        fi

        # 写入或更新配置 (使用更健壮的方式，避免破坏原有其他配置)
        # 尝试使用 jq 如果可用
        if command -v jq &>/dev/null; then
             echo -e "$TIP 检测到 jq, 使用 jq 更新配置..."
             # 读取现有 JSON，添加或更新 registry-mirrors，然后写回
             jq --argjson mirrors '["https://'${SOURCE_REGISTRY}'"]' '. * {"registry-mirrors": $mirrors}' "${DockerConfig}" > "${DockerConfig}.tmp"
             if [ $? -eq 0 ]; then
                 mv "${DockerConfig}.tmp" "${DockerConfig}"
                 if [ $? -ne 0 ]; then
                     output_error "移动临时配置文件失败！"
                     rm -f "${DockerConfig}.tmp" # 清理
                 fi
             else
                 output_error "使用 jq 更新 Docker 配置文件失败！请检查 JSON 格式或 jq 命令。"
                 rm -f "${DockerConfig}.tmp" # 清理
             fi
        else
            # jq 不可用，使用简单的 echo 覆盖 (可能丢失其他配置)
            echo -e "$WARN 未检测到 jq 命令，将直接覆盖 ${DockerConfig} 文件 (可能丢失原有其他配置)。建议安装 jq (例如: ${CMD_INSTALL} jq)。"
            echo -e '{\n  "registry-mirrors": ["https://'${SOURCE_REGISTRY}'"]\n}' > "$DockerConfig"
             if [ $? -ne 0 ]; then output_error "写入 Docker Registry 配置失败！ (${DockerConfig})"; fi
        fi


        echo -e "$COMPLETE Docker Registry 镜像配置完成。"

        # 重载配置并重启 Docker
        local reload_cmds=("systemctl daemon-reload")
        if systemctl is-active docker &>/dev/null; then
            reload_cmds+=("systemctl restart docker")
        fi
        execute_commands "重载 Docker 配置并重启服务" "${reload_cmds[@]}"
         if [ $? -ne 0 ]; then
             echo -e "$WARN 重载或重启 Docker 服务失败。请稍后尝试手动执行: systemctl daemon-reload && systemctl restart docker"
         fi
    }

    # --- install_docker_engine 主流程 ---

    ## 交互式询问是否安装最新版本 (如果命令行未指定)
    if [[ -z "${INSTALL_LATESTED_DOCKER}" ]]; then # 修正变量名检查
        if [[ "${CAN_USE_ADVANCED_INTERACTIVE_SELECTION}" == "true" ]]; then
            echo ''
            interactive_select_boolean "${BOLD}是否安装最新可用版本的 Docker Engine? (默认是)${PLAIN}"
            if [[ "${_SELECT_RESULT}" == "true" ]]; then
                INSTALL_LATESTED_DOCKER="true"
            else
                INSTALL_LATESTED_DOCKER="false"
            fi
        else
            local CHOICE_A=$(echo -e "\n${BOLD}└─ 是否安装最新可用版本的 Docker Engine? [Y/n] ${PLAIN}")
            read -p "${CHOICE_A}" INPUT
            [[ -z "${INPUT}" ]] && INPUT=Y
            case $INPUT in
            [Yy] | [Yy][Ee][Ss])
                INSTALL_LATESTED_DOCKER="true"
                 echo -e "\n${GREEN}➜${PLAIN}  将安装最新版本。"
                ;;
            [Nn] | [Nn][Oo])
                INSTALL_LATESTED_DOCKER="false"
                 echo -e "\n${GREEN}➜${PLAIN}  将让您选择要安装的版本。"
                ;;
            *)
                INSTALL_LATESTED_DOCKER="true"
                echo -e "\n$WARN 输入错误，默认安装最新版本！"
                ;;
            esac
        fi
    fi

    ## 检查是否已安装 Docker
    local is_installed=false
    local current_docker_version=""
    if command -v docker &>/dev/null; then
        # 尝试获取版本
        current_docker_version=$(docker version --format '{{.Server.Version}}' 2>/dev/null || docker -v | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
        if [[ -n "$current_docker_version" ]]; then
             is_installed=true
             echo -e "$TIP 检测到已安装 Docker Engine 版本: ${current_docker_version}"
        fi
    fi

    # 如果已安装且要求安装最新版，检查是否已经是最新
    if [[ "$is_installed" == "true" && "${INSTALL_LATESTED_DOCKER}" == "true" ]]; then
        export_version_list # 需要版本列表来比较
        local latest_docker_version=""
        if [ -s "$DockerVersionFile" ]; then
             latest_docker_version=$(head -n 1 "$DockerVersionFile")
             rm -f "$DockerVersionFile"
        fi

        if [[ -n "$latest_docker_version" && "$current_docker_version" == "$latest_docker_version" ]]; then
            echo -e "$COMPLETE 当前已是最新版本 (${current_docker_version})，跳过安装步骤。"
            change_docker_registry_mirror # 仍然尝试配置镜像
            return # 安装完成
        elif [[ -n "$latest_docker_version" ]]; then
             echo -e "$TIP 检测到更新版本 (${latest_docker_version})，将继续执行升级..."
             # 继续执行下面的卸载和安装
        else
             echo -e "$WARN 无法获取最新版本号，但检测到已安装版本。将继续尝试安装最新版..."
             # 继续执行下面的卸载和安装
        fi
    fi

    # 如果指定了版本，且已安装的版本与指定版本相同
    if [[ "$is_installed" == "true" && -n "${DESIGNATED_DOCKER_VERSION}" && "$current_docker_version" == "${DESIGNATED_DOCKER_VERSION}" ]]; then
         echo -e "$COMPLETE 当前已安装指定版本 (${current_docker_version})，跳过安装步骤。"
         change_docker_registry_mirror # 仍然尝试配置镜像
         return # 安装完成
    fi

    # 执行安装/升级前，先卸载旧版本
    uninstall_original_version

    # 执行安装
    install_main

    # 配置 Registry 镜像
    change_docker_registry_mirror
}


## 查看版本并验证安装结果 (中文提示, 增强检查)
function check_version() {
    echo -e "$WORKING 正在检查 Docker Engine 安装结果..."
    if ! command -v docker &>/dev/null; then
        output_error "Docker 命令未找到！安装失败。"
        # 不再提供手动命令提示，因为前面的步骤应该已经处理了
        exit 1
    fi

    # 尝试启动并启用服务
    local start_cmds=()
    if ! systemctl is-active docker &>/dev/null; then
         start_cmds+=("systemctl enable --now docker")
         echo -e "$TIP 检测到 Docker 服务未运行，正在尝试启动并设置开机自启..."
         execute_commands "启动并启用 Docker 服务" "${start_cmds[@]}"
         sleep 2 # 等待服务启动
         if ! systemctl is-active docker &>/dev/null; then
             echo -e "$ERROR 尝试启动 Docker 服务失败！"
             echo -e "${YELLOW}请尝试手动执行 'systemctl start docker' 并查看 'systemctl status docker' 或 'journalctl -u docker.service' 获取详细错误信息。${PLAIN}"
             # 可能是配置错误、资源不足或其他问题
             # 脚本可以继续，但提示用户检查
         fi
    else
         # 如果服务已在运行，确保它是启用的
         if ! systemctl is-enabled docker &>/dev/null; then
              execute_commands "设置 Docker 服务开机自启" "systemctl enable docker"
         fi
         echo -e "$TIP Docker 服务已在运行中。"
    fi

    # 获取版本信息
    local docker_server_version=""
    local docker_client_version=""
    local docker_compose_version=""

    # 使用 docker version 获取更详细信息
    if docker version > /dev/null 2>&1; then
        docker_client_version=$(docker version --format '{{.Client.Version}}' 2>/dev/null || echo "无法获取")
        docker_server_version=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "无法获取/未连接")
    else
         echo -e "$WARN 无法执行 'docker version' 命令，可能 Docker 服务未完全就绪或配置错误。"
         # 尝试用 docker -v 作为后备
         docker_client_version=$(docker -v | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || echo "无法获取")
         docker_server_version="未知 (无法连接守护进程)"
    fi

    # 获取 Compose 版本
    docker_compose_version=$(docker compose version 2>/dev/null | grep -Eo 'v[0-9]+\.[0-9]+\.[0-9]+' || echo "无法获取/未安装")


    echo -e "\n--- Docker Engine 安装结果 ---"
    if [[ "$docker_server_version" != "无法获取/未连接" && "$docker_server_version" != "未知 (无法连接守护进程)" ]]; then
        echo -e "${GREEN}✔ Docker Engine Server 版本: ${docker_server_version}${PLAIN}"
        echo -e "  客户端版本: ${docker_client_version}"
        echo -e "  Compose 版本: ${docker_compose_version}"
        echo -e "\n$COMPLETE Docker Engine 安装和配置似乎已成功完成！"
    else
        echo -e "${RED}✘ Docker Engine Server 状态异常: ${docker_server_version}${PLAIN}"
        echo -e "  客户端版本: ${docker_client_version}"
        echo -e "  Compose 版本: ${docker_compose_version}"
        echo -e "\n$ERROR 安装可能存在问题，Docker 服务未能正常运行或连接。"
        echo -e "${YELLOW}请检查服务状态 ('systemctl status docker') 和日志 ('journalctl -u docker.service')。${PLAIN}"
        # 不再退出脚本，让用户看到结束信息
    fi
    echo "------------------------------"
}

## 高级交互式选择器 - 选择镜像/版本 (基本保持不变)
function interactive_select_mirror() {
    # ... (函数体保持不变) ...
    _SELECT_RESULT=""
    local options=("$@")
    local message="${options[${#options[@]} - 1]}"
    unset options[${#options[@]}-1]
    local selected=0; local start=0
    local page_size=$(($(tput lines 2>/dev/null || echo 20) - 4)) # 减去标题和导航提示行
    [[ $page_size -lt 5 ]] && page_size=5 # 最小页面大小

    function clear_menu() {
        # 使用相对定位清除，避免完全清屏
        local lines_to_clear=$((${#options[@]} > page_size ? page_size : ${#options[@]}))
        lines_to_clear=$((lines_to_clear + 3)) # 选项 + 标题 + 导航
        tput cup $(($(tput lines) - lines_to_clear)) 0
        for ((i=0; i<lines_to_clear; i++)); do echo -e "\r\033[K"; tput cuu1; done
        tput cup $(($(tput lines) - lines_to_clear)) 0
    }
    function cleanup() {
        tput rmcup 2>/dev/null # 恢复屏幕
        tput cnorm 2>/dev/null # 恢复光标
        echo -e "\n$TIP 操作已取消。\n"
        exit 130
    }
    function draw_menu() {
        # clear_menu # 清除旧菜单
        tput cup 0 0 # 移动到左上角 (如果 smcup/rmcup 工作正常)
        tput ed # 清除从光标到屏幕末尾的内容
        echo -e "${message}" # 打印标题
        local end=$((start + page_size - 1))
        [[ $end -ge ${#options[@]} ]] && end=$((${#options[@]} - 1))
        for ((i = start; i <= end; i++)); do
            local item_display="${options[$i]%@*}" # 只显示名称部分
            # 截断过长的名称
             local max_item_width=$(($(tput cols 2>/dev/null || echo 80) - 5))
             if ((${#item_display} > max_item_width)); then
                  item_display="${item_display:0:$((max_item_width-3))}..."
             fi

            if [ "$i" -eq "$selected" ]; then
                echo -e "  ${BLUE}➤ ${item_display}${PLAIN}"
            else
                echo -e "    ${item_display}"
            fi
        done
         # 显示导航提示
         echo -e "\n${BOLD}[↑/w] 上移 [↓/s] 下移 [Enter] 确认 [Ctrl+C] 退出${PLAIN}"
         # 将光标移回菜单顶部，准备下一次绘制
         tput cup 1 0 # 移动到标题下方第一行
    }
    function read_key() {
        IFS= read -rsn1 key
        # 读取方向键的转义序列
        if [[ "$key" == $'\e' ]]; then
             read -rsn2 -t 0.1 key # 短暂超时读取后续字符
        fi
        echo "$key"
    }

    tput smcup 2>/dev/null || echo -e "$WARN tput smcup/rmcup 可能不受支持，界面可能混乱。" # 保存屏幕
    tput civis 2>/dev/null # 隐藏光标
    trap "cleanup" INT TERM # 捕获中断信号
    draw_menu # 绘制初始菜单

    while true; do
        key=$(read_key)
        case "$key" in
        $'\e[A' | w | W) # Up arrow / w
            [[ "$selected" -gt 0 ]] && selected=$((selected - 1))
            if [[ "$selected" -lt "$start" ]]; then
                start=$((start - 1)) # 向上翻页
                [[ $start -lt 0 ]] && start=0
            fi
            draw_menu
            ;;
        $'\e[B' | s | S) # Down arrow / s
             if [[ "$selected" -lt $((${#options[@]} - 1)) ]]; then
                 selected=$((selected + 1))
                 if [[ "$selected" -gt $((start + page_size - 1)) ]]; then
                      start=$((start + 1)) # 向下翻页
                 fi
                 draw_menu
             fi
             ;;
        "") # Enter key
            tput rmcup 2>/dev/null # 恢复屏幕
            tput cnorm 2>/dev/null # 恢复光标
            _SELECT_RESULT="${options[$selected]}" # 设置结果
            break
            ;;
        *) ;; # Ignore other keys
        esac
    done
}


## 高级交互式选择器 - 布尔选择 (中文提示)
function interactive_select_boolean() {
    # ... (函数体保持不变，修改提示文字) ...
    _SELECT_RESULT=""
    local selected=0 # 0 for Yes, 1 for No
    local message="$1"
    local prompt="╰─ [←/a] 选择 [→/d] 选择 [Enter] 确认 [Ctrl+C] 退出"

    function cleanup() {
        tput cnorm 2>/dev/null
        echo -e "\n$TIP 操作已取消。\n"
        exit 130
    }
    function draw_menu() {
        tput cr; tput el; echo -e "╭─ ${message}" # 清除并打印标题行
        tput cr; tput cud1; tput el; echo -e "│" # 清除并打印分隔行
        tput cr; tput cud1; tput el # 清除选项行
        if [ "$selected" -eq 0 ]; then
            echo -e "╰─ ${BLUE}➤ 是${PLAIN}    ○ 否"
        else
            echo -e "╰─ ○ 是    ${BLUE}➤ 否${PLAIN}"
        fi
        tput cr; tput cud1; tput el; echo -e "${BOLD}${prompt}${PLAIN}" # 清除并打印提示行
        tput cuu 3 # 将光标移回选项行上方，准备下次绘制
    }

     function read_key() {
        IFS= read -rsn1 key
        if [[ "$key" == $'\e' ]]; then
             read -rsn2 -t 0.1 key
        fi
        echo "$key"
    }

    tput civis 2>/dev/null # Hide cursor
    trap "cleanup" INT TERM
    # 预留空间并绘制
    echo -e "\n\n\n\n" # 预留4行
    tput cuu 4 # 移动光标到开始位置
    draw_menu

    while true; do
        key=$(read_key)
        case "$key" in
        $'\e[D' | a | A) # Left arrow / a
            [[ "$selected" -gt 0 ]] && selected=0 && draw_menu
            ;;
        $'\e[C' | d | D) # Right arrow / d
            [[ "$selected" -lt 1 ]] && selected=1 && draw_menu
            ;;
        "") # Enter key
            # 清除菜单和提示 (4行)
             tput cud 3 # 移动到提示行下方
             for i in {1..4}; do tput cuu1; tput el; done
             tput cnorm 2>/dev/null # 恢复光标
            break
            ;;
        *) ;; # Ignore other keys
        esac
    done

    # 绘制最终选择结果
     echo -e "╭─ ${message}"
     echo -e "│"
    if [ "$selected" -eq 0 ]; then
        echo -e "╰─ ${GREEN}✔ 是${PLAIN}    ○ 否"
        _SELECT_RESULT="true"
    else
        echo -e "╰─ ○ 是    ${GREEN}✔ 否${PLAIN}"
        _SELECT_RESULT="false"
    fi
     echo "" # 加一个空行
}

## 动画执行函数 (基本保持不变)
function animate_exec() {
    # ... (函数体基本保持不变，只修改标题行的图标和完成状态) ...
    local cmd="$1"; local title="$2"; local max_lines=${3:-5}; local spinner_style="${4:-dots}"; local refresh_rate="${5:-0.1}"
    local -A spinners=([dots]="⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏" [circle]="◐ ◓ ◑ ◒" [classic]="-\\|/")
    local -A recommended_rates=([dots]="0.08" [circle]="0.12" [classic]="0.12")
    [[ -z "${spinners[$spinner_style]}" ]] && spinner_style="dots"
    [[ "${refresh_rate}" == "0.1" ]] && refresh_rate="${recommended_rates[$spinner_style]}"
    local term_width=$(tput cols 2>/dev/null || echo 80); local display_width=$((term_width - 2))
    function simple_truncate() { # 省略内部实现 (保持不变)
        local line="$1"; local truncate_marker="..."; local max_length=$((display_width - 3))
        if [[ "${line}" =~ ^[[:ascii:]]*$ && ${#line} -le $display_width ]]; then echo "${line}"; return; fi
        local non_ascii_count=$(echo "${line// /}" | sed "s|[0-9a-zA-Z\.\=\:\_\(\)\'\"-\/\!·]||g;" | wc -m); local total_length=${#line}
        local display_length=$((total_length + non_ascii_count))
        local quote_count=0
        [[ $(echo "${line}" | grep -c "“") -gt 0 ]] && quote_count=$((quote_count + $(echo "${line}" | grep -c "“")))
        [[ $(echo "${line}" | grep -c "”") -gt 0 ]] && quote_count=$((quote_count + $(echo "${line}" | grep -c "”")))
        [[ $(echo "${line}" | grep -c "‘") -gt 0 ]] && quote_count=$((quote_count + $(echo "${line}" | grep -c "‘")))
        [[ $(echo "${line}" | grep -c "’") -gt 0 ]] && quote_count=$((quote_count + $(echo "${line}" | grep -c "’")))
        display_length=$((display_length - quote_count))
        if [[ $display_length -le $display_width ]]; then echo "$line"; return; fi
        local result=""; local current_width=0; local i=0
        while [ $i -lt ${#line} ]; do
            local char="${line:$i:1}"; local char_width=1
            if ! [[ "$char" =~ [0-9a-zA-Z\.\=\:\_\(\)\'\"-\/\!·] ]]; then
                if [[ "$char" != "“" && "$char" != "”" && "$char" != "‘" && "$char" != "’" ]]; then char_width=2; fi
            fi
            if [[ $((current_width + char_width)) -gt $max_length ]]; then echo "${result}${truncate_marker}"; return; fi
            result+="${char}"; current_width=$((current_width + char_width)); ((i++))
        done; echo "${line}"
    }
    function cleanup() { [ -f "${temp_file}" ] && rm -f "${temp_file}"; tput cnorm 2>/dev/null; echo -e "\n$TIP 操作已取消。\n"; exit 130; }
    function make_temp_file() { # 省略内部实现 (保持不变)
         local temp_dirs=("." "/tmp"); local tmp_file=""
         for dir in "${temp_dirs[@]}"; do
             [[ ! -d "${dir}" || ! -w "${dir}" ]] && continue
             tmp_file="${dir}/animate_exec_$$_$(date +%s)"; touch "${tmp_file}" 2>/dev/null || continue
             if [[ -f "${tmp_file}" && -w "${tmp_file}" ]]; then echo "${tmp_file}"; return; fi
         done; echo "${tmp_file}" # 返回空字符串如果失败
    }
    function update_display() { # 省略内部实现 (保持不变)
        local current_size=$(wc -c <"${temp_file}" 2>/dev/null || echo 0)
        if [[ $current_size -le $last_size ]]; then return 1; fi
        local -a lines=(); mapfile -t -n "${max_lines}" lines < <(tail -n "$max_lines" "${temp_file}")
        local -a processed_lines=(); for ((i = 0; i < ${#lines[@]}; i++)); do processed_lines[i]=$(simple_truncate "${lines[i]}"); done
        tput cud1 2>/dev/null; echo -ne "\r\033[K"; tput cud1 2>/dev/null
        for ((i = 0; i < $max_lines; i++)); do
            echo -ne "\r\033[K"; [[ $i -lt ${#processed_lines[@]} ]] && echo -ne "\033[2m${processed_lines[$i]}\033[0m"
            [[ $i -lt $((max_lines - 1)) ]] && tput cud1 2>/dev/null
        done
        for ((i = 0; i < $max_lines + 1; i++)); do tput cuu1 2>/dev/null; done
        last_size=$current_size; return 0
    }
    local spinner_frames=(${spinners[$spinner_style]}); local temp_file="$(make_temp_file)"
    if [[ -z "$temp_file" ]]; then echo -e "$ERROR 无法创建临时文件！"; return 1; fi
    trap "cleanup" INT TERM; tput civis 2>/dev/null; echo ''; echo ''; for ((i = 0; i < $max_lines; i++)); do echo ''; done
    # 使用 bash -c 执行，确保能在子 shell 中正确处理复杂命令
    bash -c "$cmd" >"${temp_file}" 2>&1 &
    local cmd_pid=$!; local last_size=0; local spin_idx=0
    tput cuu $((max_lines + 2)) 2>/dev/null; sleep 0.05
    echo -ne "\r\033[K${WORKING} ${title} [${BOLD}${BLUE}${spinner_frames[$spin_idx]}${PLAIN}${BOLD}]${PLAIN}" # 修改图标和颜色
    spin_idx=$(((spin_idx + 1) % ${#spinner_frames[@]}))
    update_display
    local update_count=0; local adaptive_rate=$refresh_rate
    while kill -0 $cmd_pid 2>/dev/null; do
        echo -ne "\r\033[K${WORKING} ${title} [${BOLD}${BLUE}${spinner_frames[$spin_idx]}${PLAIN}${BOLD}]${PLAIN}" # 修改图标和颜色
        spin_idx=$(((spin_idx + 1) % ${#spinner_frames[@]}))
        if update_display; then
            update_count=$((update_count + 1))
            if [[ $update_count -gt 5 ]]; then
                adaptive_rate=$(awk "BEGIN {print $adaptive_rate * 1.5; exit}")
                [[ $(awk "BEGIN {print ($adaptive_rate > 0.5); exit}") -eq 1 ]] && adaptive_rate=0.5
                update_count=0
            fi
        else
            update_count=0; adaptive_rate=$refresh_rate
        fi; sleep $adaptive_rate
    done
    wait $cmd_pid; local exit_status=$?
    update_display
    if [ $exit_status -eq 0 ]; then
        echo -ne "\r\033[K${SUCCESS} ${title} [${BOLD}${GREEN}✔${PLAIN}${BOLD}]${PLAIN}\n" # 使用 ✔
    else
        echo -ne "\r\033[K${FAIL} ${title} [${BOLD}${RED}✘${PLAIN}${BOLD}]${PLAIN}\n" # 使用 ✘
    fi
    echo -ne "\r\033[K\n" # 清除空行
    local actual_lines=$(wc -l <"${temp_file}" 2>/dev/null || echo 0); [[ $actual_lines -gt $max_lines ]] && actual_lines=$max_lines
    if [[ $actual_lines -gt 0 ]]; then
        local -a final_lines=(); mapfile -t -n "$actual_lines" final_lines < <(tail -n "$actual_lines" "${temp_file}")
        for ((i = 0; i < actual_lines; i++)); do local line=$(simple_truncate "${final_lines[$i]}"); echo -ne "\r\033[K\033[2m${line}\033[0m\n"; done
    fi
    tput cnorm 2>/dev/null; rm -f "${temp_file}"; return $exit_status
}


# --- 脚本入口 ---
# 解析命令行参数
handle_command_options "$@"
# 执行主逻辑
main

exit 0
