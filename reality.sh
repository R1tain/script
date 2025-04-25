#!/bin/bash

# reality.sh - Sing-box Reality 安装/管理脚本
# 版本: 1.4 (2025-04-22) - 错误修复

# --- 脚本初始检查 ---
# 确保使用 Bash 运行
if [ -z "$BASH_VERSION" ]; then
    echo "错误：请使用 bash 运行此脚本（bash reality.sh），而不是 sh 或其他 shell"
    exit 1
fi
# 确保以 root 权限运行
if [[ $EUID -ne 0 ]]; then
   echo -e "\033[31m错误：此脚本必须以 root 权限运行！\033[0m"
   exit 1
fi

# --- 基本设置 ---
# set -e # 如果需要更严格的错误处理，可以取消注释

# --- 颜色定义 ---
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

# --- 全局变量 ---
SING_BOX_BIN="/usr/local/bin/sing-box"
CONFIG_DIR="/usr/local/etc/sing-box"
CONFIG_FILE="$CONFIG_DIR/config.json"
LOG_DIR="/var/log/sing-box"
LOG_FILE="/var/log/sing-box-install.log"
TMP_DIR="" # 将在 cleanup_and_init 中初始化

# --- 工具函数 ---

# 日志记录函数 (已汉化)
log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    # 始终记录到文件
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    # 根据级别输出带颜色的信息到控制台
    case "$level" in
        信息|INFO)   echo -e "${GREEN}[$timestamp] [信息] $message${PLAIN}" ;;
        警告|WARN)   echo -e "${YELLOW}[$timestamp] [警告] $message${PLAIN}" ;;
        错误|ERROR)  echo -e "${RED}[$timestamp] [错误] $message${PLAIN}" ;;
        *)          echo -e "[$timestamp] [$level] $message" ;; # 其他级别无颜色
    esac
}

# 检查命令执行结果 (已汉化)
check_result() {
    local operation_name="$1" # 操作名称，如 "下载 sing-box"
    # $? 在这里是上一个命令的退出状态
    if [ $? -ne 0 ]; then
        log 错误 "$operation_name 失败。"
        return 1
    else
        # 成功时可以不输出日志，或者输出更简洁的日志
        # log 信息 "$operation_name 成功。"
        return 0
    fi
}

# 清理变量中的非法字符 (已汉化)
sanitize_var() {
    local input="$1"
    if [ $# -eq 0 ]; then
        log 警告 "sanitize_var 函数调用时缺少输入参数"
        return 1
    fi
    local sanitized_output
    # 移除换行符、回车符、双引号，仅保留 A-Z a-z 0-9 - . _ :
    sanitized_output=$(echo "$input" | tr -d '\n\r"' | tr -dc 'A-Za-z0-9-._:')
    local tr_ret=$?
    if [ $tr_ret -ne 0 ]; then
        log 错误 "sanitize_var: tr 命令处理失败，输入: [$input]"
        return 1
    fi
    if [[ -z "$sanitized_output" && -n "$input" ]]; then
         log 警告 "sanitize_var 处理后结果为空，原始输入: [$input]"
         return 1
    fi
    echo "$sanitized_output"
    return 0
}

# 获取公网 IP 地址 (IPv4 优先) - 内部日志已重定向
get_public_ip() {
    local ip_services_4=( "https://api.ipify.org" "https://icanhazip.com" "https://ipinfo.io/ip" "https://ifconfig.me/ip" "https://checkip.amazonaws.com" )
    local ip_services_6=( "https://api6.ipify.org" "https://icanhazip.com" "https://ipinfo.io/ip" "https://ifconfig.me/ip" )
    local fetched_ip=""
    local curl_opts="-s --max-time 8 --connect-timeout 5"

    # 注意：此函数内部的 log 调用都添加了 >/dev/null，以防止其输出被 ip=$(...) 捕获
    log 信息 "尝试获取公网 IPv4 地址..." >/dev/null
    for service in "${ip_services_4[@]}"; do
        log 信息 "尝试 IPv4 服务: $service" >/dev/null
        fetched_ip=$(curl $curl_opts -4 "$service")
        local curl_ret=$?
        # 记录详细 Curl 信息到日志文件，但不影响 stdout
        log 信息 "Curl 退出码: $curl_ret, 获取内容: [$fetched_ip]" >/dev/null

        # 验证: curl 成功 & 内容非空 & 不含 HTML 标签或空格
        if [ $curl_ret -eq 0 ] && [[ -n "$fetched_ip" ]] && \
           ! ( [[ "$fetched_ip" == *\<* ]] || [[ "$fetched_ip" == *\>* ]] || [[ "$fetched_ip" == *" "* ]] ); then
            log 信息 "发现有效的 IPv4 地址: [$fetched_ip]" >/dev/null # 仍然记录到文件
            # 成功: 将纯净 IP 输出到 stdout 以便被捕获
            echo "$fetched_ip"
            return 0
        else
             if [ $curl_ret -eq 0 ]; then
                  log 警告 "获取的内容无效 (可能包含HTML或空格): [$fetched_ip]" >/dev/null
             fi
        fi
        sleep 1
    done

    log 警告 "获取 IPv4 地址失败，尝试 IPv6..." >/dev/null
    for service in "${ip_services_6[@]}"; do
        log 信息 "尝试 IPv6 服务: $service" >/dev/null
        for flag in "-6" ""; do
             log 信息 "使用 curl 参数: [$flag]" >/dev/null
             fetched_ip=$(curl $curl_opts $flag "$service")
             local curl_ret=$?
             log 信息 "Curl 退出码: $curl_ret, 获取内容: [$fetched_ip]" >/dev/null

             # 验证: curl 成功 & 内容非空 & 不含 HTML/空格 & 包含冒号(:)
             if [ $curl_ret -eq 0 ] && [[ -n "$fetched_ip" ]] && \
                ! ( [[ "$fetched_ip" == *\<* ]] || [[ "$fetched_ip" == *\>* ]] || [[ "$fetched_ip" == *" "* ]] ) && \
                [[ "$fetched_ip" == *:* ]]; then
                 log 信息 "发现有效的 IPv6 地址: [$fetched_ip]" >/dev/null
                 # 成功: 将纯净 IP 输出到 stdout
                 echo "$fetched_ip"
                 return 0
             else
                  if [ $curl_ret -eq 0 ]; then
                       log 警告 "获取的内容无效 (可能包含HTML/空格或缺少冒号): [$fetched_ip]" >/dev/null
                  fi
             fi
             sleep 1
        done
    done

    log 错误 "无法通过任何服务获取有效的公网 IP 地址。" >/dev/null # 记录错误到文件
    return 1 # 返回失败状态码
}





# 检查服务状态 (已汉化)
check_status() {
    log 信息 "正在检查 sing-box 服务状态..."
    if command -v systemctl &>/dev/null; then
        if systemctl is-active --quiet sing-box; then
            log 信息 "sing-box 服务 (systemd) 正在运行。"
            return 0
        else
            log 错误 "sing-box 服务 (systemd) 未运行或启动失败。"
            # 显示 systemd 日志帮助诊断
            log 信息 "显示最近的 systemd 服务日志:"
            journalctl -u sing-box --no-pager -n 20
            return 1
        fi
    elif command -v rc-service &>/dev/null; then
         # 检查 OpenRC 状态 (不同版本 OpenRC 输出可能略有不同)
        if rc-service sing-box status | grep -q -E 'status: started|status: starting'; then
            log 信息 "sing-box 服务 (OpenRC) 正在运行。"
            return 0
        else
            log 错误 "sing-box 服务 (OpenRC) 未运行或启动失败。"
             # 尝试显示 OpenRC 服务配置的日志文件 (如果存在)
             if [ -f /var/log/sing-box/sing-box.log ]; then
                  log 信息 "显示 OpenRC 日志文件 (/var/log/sing-box/sing-box.log) 末尾内容:"
                  tail -n 20 /var/log/sing-box/sing-box.log
             # 或者尝试在系统消息日志中查找
             elif [ -f /var/log/messages ]; then
                  log 信息 "尝试从 /var/log/messages 中查找 sing-box 相关日志:"
                  grep sing-box /var/log/messages | tail -n 20
             fi
            return 1
        fi
    else
        log 警告 "无法自动确定服务状态 (未知的服务管理器)。"
        # 作为后备，尝试通过进程名检查
        log 信息 "尝试通过进程名称检查..."
        if pgrep -f "$SING_BOX_BIN run -c $CONFIG_FILE" > /dev/null; then
             log 信息 "检测到 sing-box 进程正在运行 (通过 pgrep)。"
             return 0
        else
             log 错误 "未找到 sing-box 相关进程 (通过 pgrep)。"
             return 1
        fi
    fi
}




# --- 防火墙 & SELinux (已汉化) ---

stop_firewall() {
    log 信息 "临时停止并禁用防火墙 (ufw, firewalld)..."
    local firewall_status_ufw=""
    local firewall_status_firewalld=""

    if command -v ufw &>/dev/null; then
         ufw_status=$(ufw status | head -n 1)
         if [[ "$ufw_status" == "Status: active" ]]; then
            ufw disable && firewall_status_ufw="active"
            check_result "禁用 ufw"
         else
             log 信息 "ufw 当前未启用。"
             firewall_status_ufw="inactive"
         fi
         # 将状态写入临时文件，注意检查 TMP_DIR 是否已定义
         if [[ -n "$TMP_DIR" ]]; then echo "$firewall_status_ufw" > "$TMP_DIR/firewall_status_ufw"; fi
    fi

    if command -v firewalld &>/dev/null; then
        firewall_status_firewalld=$(systemctl is-active firewalld 2>/dev/null)
        if [ "$firewall_status_firewalld" = "active" ]; then
            systemctl stop firewalld && systemctl disable firewalld
            check_result "停止并禁用 firewalld"
        else
             log 信息 "firewalld 当前未运行。"
        fi
         if [[ -n "$TMP_DIR" ]]; then echo "$firewall_status_firewalld" > "$TMP_DIR/firewall_status_firewalld"; fi
    fi
    return 0
}

# 恢复防火墙状态 (Cleaned, Han化)
restore_firewall() {
    log 警告 "尝试恢复之前的防火墙状态..."

    # Restore firewalld
    if [ -f "$TMP_DIR/firewall_status_firewalld" ]; then
        local status_firewalld
        status_firewalld=$(cat "$TMP_DIR/firewall_status_firewalld")
        if [ "$status_firewalld" = "active" ] && command -v firewalld &>/dev/null; then
            log 信息 "恢复 firewalld 状态为 active..."
            systemctl enable firewalld && systemctl start firewalld
            check_result "恢复 firewalld"
        fi
        rm -f "$TMP_DIR/firewall_status_firewalld"
    fi

    # Restore ufw
    if [ -f "$TMP_DIR/firewall_status_ufw" ]; then
        local status_ufw
        status_ufw=$(cat "$TMP_DIR/firewall_status_ufw")
        if [[ "$status_ufw" == "active" ]] && command -v ufw &>/dev/null; then # Use "active" string directly
            log 信息 "恢复 ufw 状态为 active..."
            ufw enable
            check_result "恢复 ufw"
        fi
        rm -f "$TMP_DIR/firewall_status_ufw"
    fi

    log 信息 "防火墙状态恢复尝试完成。"
    return 0
}


configure_selinux() {
    local port="$1"
    if ! command -v sestatus &>/dev/null; then
        log 信息 "未找到 SELinux (sestatus 命令不存在)，跳过配置。"
        return 0
    fi
    if sestatus | grep -q "Current mode:.*enforcing"; then
        log 信息 "SELinux 处于 enforcing 模式，尝试配置端口 $port..."
        if ! command -v semanage &>/dev/null; then
             log 警告 "未找到 semanage 命令。无法自动配置 SELinux 端口策略。"
             log 警告 "如果遇到连接问题，请手动允许端口 $port (例如: semanage port -a -t http_port_t -p tcp $port)"
             return 0 # 继续安装，但发出警告
        fi
        # 尝试添加或修改 http_port_t 策略
        semanage port -a -t http_port_t -p tcp "$port" >/dev/null 2>&1 || \
        semanage port -m -t http_port_t -p tcp "$port" >/dev/null 2>&1
        if [ $? -ne 0 ]; then
             log 警告 "使用 semanage 配置 SELinux 端口 $port 失败。网络功能可能被 SELinux 阻止。"
             log 警告 "请检查 SELinux 日志 (audit.log) 或手动调整策略。"
             return 0 # 继续安装
        else
             log 信息 "SELinux 策略已为 TCP 端口 $port 更新 (类型 http_port_t)。"
        fi
    else
        log 信息 "SELinux 未处于 enforcing 模式，跳过配置。"
    fi
    return 0
}

# --- 软件包 & 依赖 (已汉化) ---

install_base_packages() {
    local pkg_manager=""
    # 确保 net-tools (提供 netstat) 或 iproute2 (提供 ss) 已安装
    # coreutils 提供 mktemp, tr 等基础命令
    local pkgs_to_install="curl wget unzip tar openssl coreutils iproute2"
    local update_cmd=""
    local install_cmd=""

    if command -v apt &>/dev/null; then
        pkg_manager="apt"
        update_cmd="apt update"
        install_cmd="apt install -y"
    elif command -v apk &>/dev/null; then
        pkg_manager="apk"
        update_cmd="apk update"
        install_cmd="apk add"
        pkgs_to_install="$pkgs_to_install bash" # Alpine 需要 bash
    elif command -v dnf &>/dev/null; then
        pkg_manager="dnf"
        install_cmd="dnf install -y"
    elif command -v yum &>/dev/null; then
        pkg_manager="yum"
        install_cmd="yum install -y"
    else
        log 错误 "未检测到支持的包管理器 (apt, apk, dnf, yum)。请手动安装所需依赖：$pkgs_to_install"
        return 1
    fi

    log 信息 "使用包管理器: $pkg_manager"

    # 更新软件源 (仅在需要时)
    if [[ -n "$update_cmd" ]]; then
         needs_update=false
         if [[ "$pkg_manager" == "apt" ]]; then
             # 检查 apt 缓存是否超过1天
             if ! find /var/lib/apt/lists/ -maxdepth 1 -type f -mtime +1 -print -quit | grep -q .; then
                 log 信息 "Apt 缓存似乎是最新的，跳过更新。"
             else
                 needs_update=true
             fi
         elif [[ "$pkg_manager" == "apk" ]]; then
              needs_update=true # apk 通常需要更新
         fi

         if $needs_update; then
             log 信息 "正在更新软件包列表 ($update_cmd)..."
             $update_cmd
             check_result "$update_cmd" || return 1
         fi
    fi

    # 安装软件包
    log 信息 "正在安装/确认核心依赖包: $pkgs_to_install..."
    $install_cmd $pkgs_to_install
    check_result "$install_cmd $pkgs_to_install" || return 1

    log 信息 "核心依赖包安装完成。"
    return 0
}

# 检查所有命令依赖 (已汉化)
check_dependencies() {
    # 移除了 netstat, 因为端口检查现在只用 ss
    local missing_deps=()
    local deps=( "curl" "wget" "tar" "openssl" "install" "grep" "awk" "sed" "tr" "mktemp" "ss" )
    log 信息 "正在检查所需命令依赖..."
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            log 警告 "所需命令 '$cmd' 未找到。"
            missing_deps+=("$cmd")
        fi
    done

    if [ ${#missing_deps[@]} -ne 0 ]; then
        log 警告 "尝试自动安装缺失的基础包..."
        install_base_packages || {
            log 错误 "基础包安装失败，无法继续。"
            log 错误 "请手动安装缺失的命令: ${missing_deps[*]}"
            return 1
        }
        # 安装后再次检查
        for cmd in "${missing_deps[@]}"; do
             if ! command -v "$cmd" &>/dev/null; then
                 log 错误 "仍然无法找到命令 '$cmd'。请手动安装后重试。"
                 return 1
             fi
        done
        log 信息 "依赖包似乎已成功安装。"
    else
        log 信息 "所有必需的命令依赖均已找到。"
    fi
    return 0
}


# --- Sing-box 操作 (已汉化) ---

validate_config() {
    log 信息 "正在验证配置文件: $CONFIG_FILE"
    if [ ! -f "$CONFIG_FILE" ]; then
        log 错误 "配置文件 '$CONFIG_FILE' 未找到！"
        return 1
    fi
     if ! command -v "$SING_BOX_BIN" &>/dev/null; then
        log 错误 "sing-box 命令 '$SING_BOX_BIN' 未找到！无法验证配置。"
        return 1
    fi

    local check_output
    set +e # 允许命令失败以便捕获输出
    check_output=$("$SING_BOX_BIN" check -c "$CONFIG_FILE" 2>&1)
    local check_ret=$?
    set -e # 恢复错误退出

    if [ $check_ret -ne 0 ]; then
        log 错误 "配置文件验证失败 (退出码: $check_ret)。"
        log 错误 "错误详情:\n$check_output"
        return 1
    else
        log 信息 "配置文件验证通过。"
        return 0
    fi
}

# 回滚安装 (已汉化)
rollback_install() {
    log 警告 "安装/操作失败，正在执行回滚..."
    # 先停止服务
    if command -v systemctl &>/dev/null; then
        systemctl stop sing-box 2>/dev/null
    elif command -v rc-service &>/dev/null; then
        rc-service sing-box stop 2>/dev/null
    fi

    log 信息 "删除已安装的文件: $SING_BOX_BIN, $CONFIG_DIR"
    rm -f "$SING_BOX_BIN"
    rm -rf "$CONFIG_DIR"

    # 删除服务定义
    if command -v systemctl &>/dev/null; then
        if [ -f /etc/systemd/system/sing-box.service ]; then
            log 信息 "删除 systemd 服务文件并重载..."
            rm -f /etc/systemd/system/sing-box.service
            systemctl daemon-reload
        fi
    elif command -v rc-update &>/dev/null; then
         if [ -f /etc/init.d/sing-box ]; then
            log 信息 "删除 OpenRC 服务文件和链接..."
            rc-update del sing-box default 2>/dev/null
            rm -f /etc/init.d/sing-box
        fi
    fi

    # 恢复防火墙状态
    restore_firewall

    log 信息 "回滚操作完成。"
}

# 安装 sing-box (已汉化)
install_sing_box() {
    log 信息 "开始 sing-box 安装流程..."

    # 1. 预检查
    if [ -f "$SING_BOX_BIN" ] || [ -f "$CONFIG_FILE" ]; then
        log 警告 "检测到 sing-box 可能已安装 ('$SING_BOX_BIN' 或 '$CONFIG_FILE' 存在)。"
        read -p "是否继续并覆盖现有安装? (y/N): " confirm_overwrite
        if [[ ! "$confirm_overwrite" =~ ^[Yy]$ ]]; then
            log 信息 "安装已由用户取消。"
            return 0
        fi
        log 警告 "继续覆盖安装..."
        uninstall || log 警告 "尝试卸载旧版本失败，将继续尝试安装..."
    fi

    # 2. 停止防火墙
    stop_firewall || { log 错误 "停止防火墙失败，安装中止。"; return 1; }

    # 3. 获取端口 (端口检查已修改)
    local port=""
    while true; do
        read -p "请输入 Reality 连接端口 (1-65535，建议 443 或 1024-65535): " port
        # 验证数字和范围
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
             # 检查端口占用 (仅使用 ss)
             if ss -tuln | grep -q ":$port "; then
                 log 错误 "端口 $port 已被占用，请选择其他端口。"
             else
                 log 信息 "选定端口: $port"
                 break # 端口有效，跳出循环
             fi
        else
            log 错误 "端口无效，请输入 1 到 65535 之间的数字。"
        fi
    done

    # 4. 检查架构
    local arch=""
    case $(uname -m) in
        x86_64 | amd64) arch="amd64" ;;
        aarch64 | arm64) arch="arm64" ;;
        *) log 错误 "不支持的系统架构: $(uname -m)"; restore_firewall; return 1 ;;
    esac
    log 信息 "检测到系统架构: $arch"

    # 5. 检查/安装依赖
    check_dependencies || { restore_firewall; return 1; }

    # 6. 下载和安装 Sing-box
    log 信息 "正在从 GitHub 获取最新的 sing-box 版本信息..."
    cd "$TMP_DIR" || { log 错误 "无法进入临时目录 '$TMP_DIR'"; restore_firewall; return 1; }

    local latest_release_url="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
    local version_tag=$(curl -s "$latest_release_url" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [[ -z "$version_tag" ]]; then
        log 错误 "无法从 GitHub API 获取最新版本标签。"
        restore_firewall; return 1
    fi
    log 信息 "最新版本标签: $version_tag"
    local version=${version_tag#v}
    local download_url="https://github.com/SagerNet/sing-box/releases/download/${version_tag}/sing-box-${version}-linux-${arch}.tar.gz"

    log 信息 "下载 sing-box: $download_url"
    wget --progress=bar:force -O "sing-box.tar.gz" "$download_url"
    check_result "下载 sing-box 压缩包" || { restore_firewall; return 1; }

    log 信息 "正在解压 sing-box 二进制文件..."
    tar -xzf "sing-box.tar.gz" --strip-components=1 "sing-box-${version}-linux-${arch}/sing-box"
    check_result "解压 sing-box 二进制文件" || { restore_firewall; return 1; }

    log 信息 "安装 sing-box 到 $SING_BOX_BIN..."
    install -m 755 sing-box "$SING_BOX_BIN"
    check_result "安装 sing-box 二进制文件" || { restore_firewall; return 1; }

    # 7. 创建目录
    log 信息 "创建目录: $CONFIG_DIR, $LOG_DIR"
    mkdir -p "$CONFIG_DIR" "$LOG_DIR"
    check_result "创建目录" || { restore_firewall; return 1; }

    # 8. 生成密钥, UUID, ShortID
    log 信息 "正在生成 Reality 密钥对..."
    local keys
    set +e; keys=$("$SING_BOX_BIN" generate reality-keypair 2>&1); local keygen_ret=$?; set -e
    if [ $keygen_ret -ne 0 ]; then
        log 错误 "'$SING_BOX_BIN generate reality-keypair' 命令执行失败 (返回码: $keygen_ret)。输出: $keys"
        restore_firewall; return 1
    fi
    log 信息 "密钥对生成命令执行成功。"

    # 提取和清理密钥
    local awk_priv_out=$(echo "$keys" | grep 'PrivateKey' | awk '{print $2}')
    local private_key=$(sanitize_var "$awk_priv_out")
    local priv_sanitize_ret=$?
    local awk_pub_out=$(echo "$keys" | grep 'PublicKey' | awk '{print $2}')
    local public_key=$(sanitize_var "$awk_pub_out")
    local pub_sanitize_ret=$?

    # 检查提取结果
    if [[ -z "$private_key" || -z "$public_key" || $priv_sanitize_ret -ne 0 || $pub_sanitize_ret -ne 0 ]]; then
        log 错误 "提取或处理密钥对失败！"
        log 错误 "原始输出: $keys"
        log 错误 "检查处理结果: 私钥 ($priv_sanitize_ret) 公钥 ($pub_sanitize_ret)"
        restore_firewall; return 1
    fi
    log 信息 "成功提取/处理密钥对。"
    log 信息 "公钥 (PublicKey): $public_key"

    log 信息 "正在生成 UUID..."
    local uuid=$("$SING_BOX_BIN" generate uuid) # 标准 UUID 无需清理
    check_result "生成 UUID" || { log 错误 "UUID 生成失败。"; restore_firewall; return 1; }
    log 信息 "UUID: $uuid"

    log 信息 "正在生成 Short ID..."
    local short_id=$(openssl rand -hex 8) # 十六进制输出无需清理
    check_result "生成 Short ID" || { log 错误 "Short ID 生成失败。"; restore_firewall; return 1; }
    log 信息 "Short ID: $short_id"

    # 9. 获取目标服务器 (SNI)
    local dest_server="gateway.icloud.com" # 新默认值
    read -p "请输入目标服务器域名 (SNI) [默认: $dest_server]: " input_dest_server
    if [[ -n "$input_dest_server" ]]; then
         local sanitized_sni
         # 只允许字母、数字、连字符、点
         sanitized_sni=$(echo "$input_dest_server" | tr -dc 'A-Za-z0-9-.' | head -c 253) # 限制长度
         if [[ -n "$sanitized_sni" ]]; then
              dest_server="$sanitized_sni"
         else
              log 警告 "输入的目标服务器域名无效，将使用默认值: $dest_server"
         fi
    fi
    log 信息 "将使用目标服务器 (SNI): $dest_server"

    # 10. 创建服务文件
    log 信息 "配置服务管理器..."
    if command -v systemctl &>/dev/null; then
        log 信息 "检测到 systemd，创建 systemd 服务文件..."
        cat > /etc/systemd/system/sing-box.service << EOF
[Unit]
Description=Sing-box Service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=root
Group=root
WorkingDirectory=$CONFIG_DIR
ExecStart=$SING_BOX_BIN run -c $CONFIG_FILE
Restart=on-failure
RestartSec=10s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
        check_result "创建 systemd 服务文件" || { rollback_install; return 1; }
    elif command -v rc-service &>/dev/null; then
        log 信息 "检测到 OpenRC，创建 OpenRC 服务文件..."
        cat > /etc/init.d/sing-box << EOF
#!/sbin/openrc-run

name="sing-box"
description="Sing-box Service"
supervisor=supervise-daemon

command="$SING_BOX_BIN"
command_args="run -c $CONFIG_FILE"
command_user="root"

output_log="/var/log/sing-box/sing-box.log"
error_log="/var/log/sing-box/sing-box.err"

pidfile="/run/${RC_SVCNAME}.pid"

depend() {
    need net
    after firewall
}
EOF
        chmod +x /etc/init.d/sing-box
        check_result "创建 OpenRC 服务文件" || { rollback_install; return 1; }
    else
        log 警告 "未找到 systemd 或 OpenRC。将跳过服务文件创建。"
        log 警告 "您需要手动配置 sing-box 的启动和守护进程。"
    fi

    # 11. 创建配置文件
    log 信息 "创建配置文件: $CONFIG_FILE"
    cat > "$CONFIG_FILE" << EOF
{
  "log": {
    "level": "error",
    "disabled": false,
    "output": "/root/sing-box.log",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": $port,
      "sniff": true,
      "users": [
        {
          "uuid": "$uuid",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$dest_server",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$dest_server",
            "server_port": 443
          },
          "private_key": "$private_key",
          "short_id": ["$short_id"]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "dns",
      "tag": "dns-out"
    }
  ],
  "route": {
    "rules": [
      {
        "protocol": ["dns"],
        "outbound": "dns-out"
      },
      {
        "network": ["tcp", "udp"],
        "outbound": "direct"
      }
    ],
    "auto_detect_interface": true,
    "default_mark": 0
  },
  "dns": {
    "servers": [
      { "address": "8.8.8.8", "tag": "google-dns" },
      { "address": "1.1.1.1", "tag": "cloudflare-dns" }
    ],
	"rules": [
	  {
		"action": "route",
		"outbound": "any",
		"server": "google-dns"
	  }
	],
    "final": "google-dns"
  }
}
EOF
    check_result "创建配置文件" || { rollback_install; return 1; }

    chmod 600 "$CONFIG_FILE"
    log 信息 "配置文件权限已设置为 600。"

    # 12. 验证配置
    validate_config || { rollback_install; return 1; }

    # 13. 配置 SELinux
    configure_selinux "$port" || { rollback_install; return 1; } # Consider just warning

    # 14. 启动服务
    log 信息 "启动 sing-box 服务..."
    if command -v systemctl &>/dev/null; then
        systemctl daemon-reload
        systemctl enable sing-box
        systemctl restart sing-box
        check_result "启用并重启 systemd 服务" || { rollback_install; return 1; }
    elif command -v rc-service &>/dev/null; then
        rc-update add sing-box default
        rc-service sing-box restart
        check_result "添加并重启 OpenRC 服务" || { rollback_install; return 1; }
    fi

    log 信息 "等待 5 秒以便服务初始化..."
    sleep 5
    # 检查服务状态 (修改后的调用方式)
    check_status
    if [ $? -ne 0 ]; then
         log 错误 "服务状态检查失败或服务未运行，执行回滚。"
         rollback_install
         return 1
    fi
    log 信息 "服务状态检查通过。" #明确成功日志

    # 15. 获取公网 IP (使用新函数)
    local ip=""
    ip=$(get_public_ip) # 调用 IP 获取函数

    if [[ -z "$ip" ]]; then
        log 警告 "无法自动获取公网 IP 地址。"
        read -p "请手动输入您的服务器公网 IP 地址: " manual_ip
        if [[ -n "$manual_ip" ]]; then
             local sanitized_manual_ip
             sanitized_manual_ip=$(sanitize_var "$manual_ip")
             if [[ $? -eq 0 && -n "$sanitized_manual_ip" ]]; then
                 ip="$sanitized_manual_ip"
                 log 信息 "使用手动输入的 IP 地址: $ip"
             else
                 log 错误 "手动输入的 IP 地址无效。"
                 ip=""
             fi
        else
             log 警告 "未输入手动 IP 地址。"
        fi
    else
         local sanitized_auto_ip
         sanitized_auto_ip=$(sanitize_var "$ip") # 对自动获取的 IP 再次清理
         if [[ $? -eq 0 && -n "$sanitized_auto_ip" ]]; then
              ip="$sanitized_auto_ip"
              log 信息 "使用自动获取的 IP 地址: $ip"
         else
              log 错误 "处理自动获取的 IP 地址 [$ip] 失败"
              ip=""
         fi
    fi

    # 16. 生成并显示分享链接
    if [[ -n "$ip" ]]; then
        local share_tag="Reality_${port}"
        local vless_link=""
        local safe_ip="$ip"

        # 为 IPv6 地址添加方括号
        if [[ "$safe_ip" =~ ":" ]]; then
            safe_ip="[$safe_ip]"
        fi

        vless_link=$(printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#%s' \
                     "$uuid" "$safe_ip" "$port" "$dest_server" "$public_key" "$short_id" "$share_tag")

        log 信息 "-------------------------------------------"
        log 信息 "${GREEN}安装成功！ Reality 配置信息:${PLAIN}"
        log 信息 "  服务器地址 : $ip"
        log 信息 "  端口       : $port"
        log 信息 "  UUID       : $uuid"
        log 信息 "  公钥       : $public_key"
        log 信息 "  ShortID    : $short_id"
        log 信息 "  目标服务器 : $dest_server"
        log 信息 "${GREEN}  分享链接 (VLESS):${PLAIN}"
        echo -e "${YELLOW}$vless_link${PLAIN}"
        log 信息 "-------------------------------------------"
    else
        log 错误 "未能获取有效的服务器 IP 地址，无法生成分享链接。"
        log 信息 "-------------------------------------------"
        log 信息 "${YELLOW}安装已完成，但需要手动配置客户端:${PLAIN}"
        log 信息 "  服务器地址 : <你的服务器IP>"
        log 信息 "  端口       : $port"
        log 信息 "  UUID       : $uuid"
        log 信息 "  公钥       : $public_key"
        log 信息 "  ShortID    : $short_id"
        log 信息 "  目标服务器 : $dest_server"
        log 信息 "-------------------------------------------"
    fi

    log 信息 "安装流程结束。"
    return 0 # 表示成功
}


# 更新密钥 (已汉化)
update_keys() {
    log 信息 "开始更新 Reality 密钥..."
    if [ ! -f "$CONFIG_FILE" ]; then
        log 错误 "配置文件 '$CONFIG_FILE' 未找到。无法更新。"
        return 1
    fi
     if ! command -v "$SING_BOX_BIN" &>/dev/null; then
        log 错误 "sing-box 命令 '$SING_BOX_BIN' 未找到。无法生成新密钥。"
        return 1
    fi

    log 信息 "正在生成新的 Reality 密钥对..."
    local keys
    set +e; keys=$("$SING_BOX_BIN" generate reality-keypair 2>&1); local keygen_ret=$?; set -e
    if [ $keygen_ret -ne 0 ]; then
        log 错误 "'$SING_BOX_BIN generate reality-keypair' 命令执行失败 (返回码: $keygen_ret)。输出: $keys"
        return 1
    fi

    # 提取和处理新密钥
    local awk_priv_out=$(echo "$keys" | grep 'PrivateKey' | awk '{print $2}')
    local new_private_key=$(sanitize_var "$awk_priv_out")
    local priv_sanitize_ret=$?
    local awk_pub_out=$(echo "$keys" | grep 'PublicKey' | awk '{print $2}')
    local new_public_key=$(sanitize_var "$awk_pub_out")
    local pub_sanitize_ret=$?

    if [[ -z "$new_private_key" || -z "$new_public_key" || $priv_sanitize_ret -ne 0 || $pub_sanitize_ret -ne 0 ]]; then
        log 错误 "提取或处理新密钥对失败！"
        log 错误 "原始输出: $keys"
        return 1
    fi
    log 信息 "成功生成并处理了新的密钥对。"
    log 信息 "新的公钥 (PublicKey): $new_public_key"

    # 备份当前配置
    local backup_file="${CONFIG_FILE}.bak_$(date +%Y%m%d_%H%M%S)"
    log 信息 "备份当前配置文件到 '$backup_file'"
    cp "$CONFIG_FILE" "$backup_file"
    check_result "备份配置文件" || return 1

    # 使用 sed 更新配置文件中的 private_key
    log 信息 "正在更新配置文件中的 private_key..."
    sed -i.bak "s|\(\"private_key\":\s*\)\"[^\"]*\"|\1\"$new_private_key\"|" "$CONFIG_FILE"
    if [ $? -ne 0 ]; then
        log 错误 "使用 sed 更新 private_key 失败。正在恢复备份..."
        mv "$backup_file" "$CONFIG_FILE"
        return 1
    fi
    rm -f "${CONFIG_FILE}.bak" # 删除 sed 创建的备份

    log 信息 "配置文件已更新。"

    # 验证新配置
    validate_config || {
        log 错误 "更新后的配置文件无效！正在恢复备份..."
        mv "$backup_file" "$CONFIG_FILE"
        return 1
    }

    # 重启服务以应用新密钥
    log 信息 "正在重启 sing-box 服务以应用新密钥..."
    if command -v systemctl &>/dev/null; then
        systemctl restart sing-box
        check_result "重启 systemd 服务" || return 1 # 如果重启失败则报错返回
    elif command -v rc-service &>/dev/null; then
        rc-service sing-box restart
        check_result "重启 OpenRC 服务" || return 1
    else
         log 警告 "未找到服务管理器。请手动重启 sing-box 以应用新密钥。"
    fi

    log 信息 "等待 5 秒以便服务应用更改..."
    sleep 5
    check_status || {
        log 错误 "服务在密钥更新后未能成功启动或运行不正常。"
        # 配置有效但服务启动失败，不自动回滚，让用户检查日志
        return 1
    }

    log 信息 "${GREEN}密钥更新成功！${PLAIN}"
    log 信息 "请使用新的公钥更新您的客户端配置: ${YELLOW}$new_public_key${PLAIN}"
    return 0
}

# 卸载 (已汉化)
uninstall() {
    log 信息 "开始卸载 sing-box..."

    log 信息 "停止 sing-box 服务 (如果正在运行)..."
    if command -v systemctl &>/dev/null; then
        systemctl stop sing-box 2>/dev/null
        systemctl disable sing-box 2>/dev/null # 确保禁用开机启动
    elif command -v rc-service &>/dev/null; then
        rc-service sing-box stop 2>/dev/null
        rc-update del sing-box default 2>/dev/null # 从默认运行级别移除
    fi

    log 信息 "删除文件和目录..."
    log 信息 "删除二进制文件: $SING_BOX_BIN"
    rm -f "$SING_BOX_BIN"
    log 信息 "删除配置目录: $CONFIG_DIR"
    rm -rf "$CONFIG_DIR"
    log 信息 "删除日志目录: $LOG_DIR"
    rm -rf "$LOG_DIR"

    log 信息 "删除服务定义..."
    if command -v systemctl &>/dev/null; then
        if [ -f /etc/systemd/system/sing-box.service ]; then
            rm -f /etc/systemd/system/sing-box.service
            systemctl daemon-reload
            log 信息 "已删除 systemd 服务文件。"
        fi
    elif command -v rc-update &>/dev/null; then
         if [ -f /etc/init.d/sing-box ]; then
            rm -f /etc/init.d/sing-box
            log 信息 "已删除 OpenRC 服务文件。"
        fi
    fi

    log 信息 "${GREEN}卸载完成。${PLAIN}"
    log 信息 "注意：脚本添加的任何防火墙或 SELinux 规则可能需要手动移除（如果需要）。"
}

# --- 主菜单 & 执行流程 (已汉化) ---

show_menu() {
    echo -e "
  ${GREEN}Sing-box Reality 管理脚本 (v1.4)${PLAIN}
  ----------------------------------------
  ${GREEN}1.${PLAIN} 安装 Sing-box (Reality)
  ${GREEN}2.${PLAIN} 更新 Reality 密钥
  ${GREEN}3.${PLAIN} 卸载 Sing-box
  ----------------------------------------
  ${GREEN}4.${PLAIN} 启动 Sing-box 服务
  ${GREEN}5.${PLAIN} 停止 Sing-box 服务
  ${GREEN}6.${PLAIN} 重启 Sing-box 服务
  ${GREEN}7.${PLAIN} 查看 Sing-box 服务状态
  ${GREEN}8.${PLAIN} 查看 Sing-box 配置文件
  ${GREEN}9.${PLAIN} 查看安装日志
  ----------------------------------------
  ${GREEN}0.${PLAIN} 退出脚本
  ----------------------------------------"
    read -p "请输入选项 [0-9]: " num

    case "$num" in
        1) install_sing_box ;;
        2) update_keys ;;
        3) uninstall ;;
        4)
            log 信息 "尝试启动 Sing-box 服务..."
            if command -v systemctl &>/dev/null; then systemctl start sing-box; check_result "启动 systemd 服务";
            elif command -v rc-service &>/dev/null; then rc-service sing-box start; check_result "启动 OpenRC 服务";
            else log 错误 "未知的服务管理器。"; fi
            check_status # 启动后检查状态
            ;;
        5)
            log 信息 "尝试停止 Sing-box 服务..."
            if command -v systemctl &>/dev/null; then systemctl stop sing-box; check_result "停止 systemd 服务";
            elif command -v rc-service &>/dev/null; then rc-service sing-box stop; check_result "停止 OpenRC 服务";
            else log 错误 "未知的服务管理器。"; fi
            ;;
        6)
            log 信息 "尝试重启 Sing-box 服务..."
            if command -v systemctl &>/dev/null; then systemctl restart sing-box; check_result "重启 systemd 服务";
            elif command -v rc-service &>/dev/null; then rc-service sing-box restart; check_result "重启 OpenRC 服务";
            else log 错误 "未知的服务管理器。"; fi
            sleep 2 # 等待服务重启
            check_status # 重启后检查状态
            ;;
        7)
            check_status ;;
        8)
            log 信息 "显示配置文件内容: $CONFIG_FILE"
            if [ -f "$CONFIG_FILE" ]; then
                 cat "$CONFIG_FILE"
            else
                 log 错误 "配置文件未找到！"
            fi
             ;;
        9)
             log 信息 "显示安装日志内容: $LOG_FILE"
             if [ -f "$LOG_FILE" ]; then
                  cat "$LOG_FILE" # 可以考虑用 less 或 more
             else
                  log 错误 "日志文件未找到！"
             fi
              ;;
        0) exit 0 ;;
        *) log 错误 "无效选项: $num" ;;
    esac
}

# --- 脚本入口点 ---

# 1. Root 权限检查已在脚本开头完成

# 2. 设置清理 Trap (在任何可能创建临时文件之前)
cleanup_and_init() {
    # 初始化 TMP_DIR
    TMP_DIR=$(mktemp -d -t singbox-install-XXXXXX) || {
        log 错误 "无法创建临时目录！"
        exit 1
    }
    # 设置 Trap
    trap cleanup EXIT SIGINT SIGTERM
    log 信息 "临时目录已创建: $TMP_DIR"
}

cleanup() {
    log 信息 "执行清理程序..."
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        log 信息 "删除临时目录: $TMP_DIR"
        rm -rf "$TMP_DIR"
    else
         log 信息 "无需删除临时目录。"
    fi
    # 防火墙状态文件理论上应该在 restore_firewall 中被删除，这里作为后备清理
    rm -f /tmp/firewall_status_firewalld /tmp/firewall_status_ufw
    log 信息 "清理完成。"
}
# 调用初始化函数来设置 TMP_DIR 和 Trap
cleanup_and_init

# 3. 初始化日志文件
mkdir -p "$LOG_DIR" || { echo -e "${RED}无法创建日志目录 $LOG_DIR!${PLAIN}"; exit 1; }
if ! touch "$LOG_FILE"; then
     echo -e "${RED}无法创建或访问日志文件 $LOG_FILE! 请检查权限。${PLAIN}";
     # 如果日志文件失败，回退到标准错误输出
     log() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $2"; }
     log 错误 "无法写入日志文件，后续日志可能不完整。"
else
    chmod 644 "$LOG_FILE"
fi

log 信息 "--- 脚本启动: $0 ---"
log 信息 "时间戳: $(date)"

# 4. 检查核心依赖
check_dependencies || exit 1

# 5. 显示主菜单循环
while true; do
    show_menu
    echo # 菜单后空行
    read -n 1 -s -r -p "按任意键返回主菜单..." # 等待用户按键
    echo # 按键后换行
done

# 脚本正常退出点 (理论上由菜单中的 exit 0 触发)
exit 0
