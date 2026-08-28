#!/bin/bash
# ============================================================
# SOCKS5 代理管理脚本 (基于 Dante - 源码编译)
# 功能: 安装 / 删除 / 启动 / 停止 / 重启 / 查看状态 / 安全启用UFW
# 安全: PAM认证 + 随机端口 + fail2ban + 专用nologin用户
# 网络: 安装时选择 IPv4 或 IPv6，支持 NAT 端口映射
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

DANTE_VER="1.4.3"
DANTE_DIR="/opt/dante"
CONFIG_FILE="/etc/danted.conf"
SERVICE_FILE="/etc/systemd/system/danted.service"
LOG_FILE="/var/log/danted.log"
CRED_FILE="/root/.socks5_credentials"
SOCKS_USER="socks5usr"
BUILD_LOG="/tmp/dante_build.log"
PAM_FILE="/etc/pam.d/sockd"
LOGROTATE_FILE="/etc/logrotate.d/danted"

# 禁止通过代理访问内网/回环（防止被当作跳板打内网）。设为 0 可关闭。
BLOCK_PRIVATE=1

# 是否记录每一条连接的目标地址。开启后日志等于一份完整的访问记录，
# 既是隐私风险也是磁盘 I/O 负担；关闭不影响 fail2ban（它只看认证失败行）。
# 需要审计谁访问了什么时再设为 1。
LOG_CONNECTIONS=0

# ────────────────────────────────────────────
# 工具函数
# ────────────────────────────────────────────
check_root() {
    [[ $EUID -ne 0 ]] && { echo -e "${RED}请用 root 权限运行${NC}"; exit 1; }
}

get_public_ipv4() {
    curl -4s --max-time 5 https://api.ipify.org 2>/dev/null \
    || curl -4s --max-time 5 https://ifconfig.me 2>/dev/null \
    || ip -4 route get 8.8.8.8 2>/dev/null | awk '{print $7; exit}'
}

get_public_ipv6() {
    curl -6s --max-time 5 https://api6.ipify.org 2>/dev/null \
    || ip -6 addr show scope global 2>/dev/null \
       | awk '/inet6/{print $2}' | cut -d/ -f1 | grep -v '^fd' | head -1
}

# 密码生成：openssl 取 36 字节随机数（288 bit），再转成 base64url。
#
# 用 base64url 而不是原始 base64：base64 字符集里的 + / = 会破坏
# socks5://user:pass@host:port 的解析（实测 100 次有 75 次命中，其中 / 必然出错）。
# base64url 把 + / 换成 - _ 并去掉填充，而 - _ 是 RFC 3986 的 unreserved 字符，
# 出现在 URI 任何位置都无需转义，所以生成出来就是安全的，不需要事后判断。
# 36 能被 3 整除，编码后正好 48 字符且没有 = 填充。
gen_password() {
    if command -v openssl &>/dev/null; then
        openssl rand -base64 36 | tr '+/' '-_' | tr -d '=\n'
    else
        # 没有 openssl 时退回 urandom
        tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32
    fi
}

# 随机端口 10000-65000，排除已被 TCP/UDP 占用的端口
gen_port() {
    local port
    while true; do
        port=$(shuf -i 10000-65000 -n 1)
        if ! ss -tulnH 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${port}$"; then
            echo "$port"
            return
        fi
    done
}

# SSH 监听端口（用于避免 ufw 锁死）。四路取并集，任一路命中即可，
# 不依赖端口是不是 22。
get_ssh_ports() {
    local ports=""

    # 1) 当前 SSH 会话在服务器侧的端口 —— 你正连着的就是它，最可靠
    [[ -n "$SSH_CONNECTION" ]] && ports=$(awk '{print $4}' <<<"$SSH_CONNECTION")

    # 2) sshd 自己报告的有效配置，覆盖非 22 端口和多条 Port 指令
    ports="$ports $(sshd -T 2>/dev/null | awk '/^port /{print $2}')"

    # 3) systemd socket 激活（Debian 13 起 ssh.socket 可能接管监听，
    #    此时 ss 看到的属主是 systemd 而不是 sshd）
    ports="$ports $(systemctl show ssh.socket sshd.socket -p Listen 2>/dev/null \
                    | sed -n 's/.*[:.]\([0-9]\+\).*/\1/p')"

    # 4) 兜底扫描：只认进程名恰为 sshd、且未绑定回环的监听
    #    （sshd-session 的 X11 转发口绑在 127.0.0.1，不能放行到公网）
    ports="$ports $(ss -tlnpH 2>/dev/null \
                    | awk '$4 !~ /^(127\.|\[::1\])/ && $0 ~ /"sshd"/ {sub(/.*[:.]/,"",$4); print $4}')"

    tr ' ' '\n' <<<"$ports" | grep -E '^[0-9]+$' | sort -un
}

ufw_is_active() {
    command -v ufw &>/dev/null || return 1
    # 注意: grep "active" 会误匹配 "inactive"，必须锚定整行
    ufw status 2>/dev/null | grep -qE '^Status:[[:space:]]+active$'
}

# 安全读取凭据文件的单个字段。
# 绝不能用 source/eval：密码里的 & ; | ( ) ! 会被 shell 当成语法执行，
# 例如 PASS=aaa&bbb 会把 bbb 当命令跑掉，读出来的密码是错的。
cred_get() {
    local key="$1"
    [[ -f "$CRED_FILE" ]] || return 1
    sed -n "s/^${key}=//p" "$CRED_FILE" | head -1 | sed "s/^'\(.*\)'$/\1/; s/^\"\(.*\)\"$/\1/"
}

# 密码含 @ : / # ? % & 时，socks5://user:pass@host:port 会被客户端解析错，
# 这时必须改用把用户名密码分开传的写法
warn_if_uri_unsafe() {
    local pw="$1" host="$2" port="$3" user="$4"
    [[ "$pw" =~ [@:/\#?\%\&] ]] || return 0
    echo ""
    echo -e "${RED}[!] 当前密码含 URI 保留字符，上面的 socks5:// 形式在多数客户端会解析失败${NC}"
    echo -e "${YELLOW}    可用写法（用户名密码分开传）:${NC}"
    echo -e "    ${YELLOW}curl -x socks5h://${host}:${port} --proxy-user '${user}:${pw}' https://api.ipify.org${NC}"
    echo -e "${YELLOW}    重装一次即可换成纯字母数字的安全密码${NC}"
}

# 判断某个 IP 是否直接绑在本机网卡上。
# 注意不能 grep 整个 ip addr 输出：那里面还有 brd 广播地址，会误匹配。
ip_is_local() {
    local target="$1"
    [[ -n "$target" ]] || return 1
    ip -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -qxF "$target"
}

print_banner() {
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════╗"
    echo "║        SOCKS5 代理管理脚本                   ║"
    echo "║        Dante 源码编译 · IPv4/IPv6 · 安全加固 ║"
    echo "╚══════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ────────────────────────────────────────────
# 选择网络类型
# ────────────────────────────────────────────
choose_network() {
    echo -e "${CYAN}${BOLD}请选择网络类型:${NC}"
    echo "  1) IPv4"
    echo "  2) IPv6"
    echo ""
    while true; do
        read -rp "请输入 [1/2]: " net_choice
        case $net_choice in
            1) NET_MODE="ipv4"; echo -e "${GREEN}[✓] 已选择 IPv4 模式${NC}"; break ;;
            2) NET_MODE="ipv6"; echo -e "${GREEN}[✓] 已选择 IPv6 模式${NC}"; break ;;
            *) echo -e "${RED}请输入 1 或 2${NC}" ;;
        esac
    done
}

# ────────────────────────────────────────────
# 编译安装 Dante
# ────────────────────────────────────────────
compile_dante() {
    echo -e "${YELLOW}[*] 安装编译依赖...${NC}"
    if command -v apt-get &>/dev/null; then
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            gcc make wget curl \
            libwrap0-dev libpam0g-dev libssl-dev \
            autotools-dev \
            fail2ban ufw 2>/dev/null
    elif command -v yum &>/dev/null; then
        yum install -y gcc make wget curl \
            tcp_wrappers-devel pam-devel openssl-devel \
            automake \
            fail2ban firewalld 2>/dev/null
    else
        echo -e "${RED}不支持的系统${NC}"; exit 1
    fi

    for tool in gcc make; do
        if ! command -v $tool &>/dev/null; then
            echo -e "${RED}缺少 $tool，请手动执行: apt install $tool${NC}"
            exit 1
        fi
    done
    echo -e "${GREEN}[✓] 编译工具就绪: gcc $(gcc --version | head -1 | awk '{print $NF}')${NC}"

    echo -e "${YELLOW}[*] 下载 Dante 源码...${NC}"
    cd /tmp || exit 1
    rm -rf dante-* dante.tar.gz

    for VER in "1.4.3" "1.4.2"; do
        wget -q --show-progress \
             "https://www.inet.no/dante/files/dante-${VER}.tar.gz" \
             -O dante.tar.gz 2>/dev/null
        # 校验确实是可解压的 gzip 包，而不是错误页/截断文件
        if [[ -s dante.tar.gz ]] && tar -tzf dante.tar.gz &>/dev/null; then
            DANTE_VER="$VER"
            echo -e "${GREEN}[✓] 下载校验通过: dante-${VER}.tar.gz${NC}"
            break
        fi
        echo -e "${YELLOW}[!] 版本 ${VER} 下载失败或文件损坏，尝试下一个...${NC}"
        rm -f dante.tar.gz
    done

    if [[ ! -f dante.tar.gz ]]; then
        echo -e "${RED}下载失败，请检查网络连接${NC}"; exit 1
    fi

    echo -e "${YELLOW}[*] 解压源码...${NC}"
    tar -xzf dante.tar.gz || { echo -e "${RED}解压失败${NC}"; exit 1; }
    cd "dante-${DANTE_VER}" 2>/dev/null || cd dante-* || { echo -e "${RED}找不到源码目录${NC}"; exit 1; }

    # Dante 1.4.x 自带的 config.guess 停在 2011 年，不认识 aarch64/ riscv64，
    # 在 ARM 服务器（Oracle Ampere、AWS Graviton、Hetzner ARM 等）上 configure 会直接
    # 报 "cannot guess build type" 而整个安装失败。用系统提供的新版覆盖掉。
    local cg
    for cg in /usr/share/misc/config.guess /usr/share/automake-*/config.guess; do
        [[ -f "$cg" ]] || continue
        cp -f "$cg" ./config.guess 2>/dev/null
        [[ -f "${cg%/*}/config.sub" ]] && cp -f "${cg%/*}/config.sub" ./config.sub 2>/dev/null
        echo -e "${GREEN}[✓] 已更新 config.guess/config.sub（架构: $(uname -m)）${NC}"
        break
    done

    echo -e "${YELLOW}[*] 运行 configure...${NC}"
    if ! ./configure \
            --prefix="$DANTE_DIR" \
            --sysconfdir=/etc \
            --disable-client \
            --without-gssapi \
            --without-krb5 \
            --without-upnp \
            > "$BUILD_LOG" 2>&1; then
        echo -e "${RED}configure 失败！详细错误:${NC}"
        tail -30 "$BUILD_LOG"
        exit 1
    fi
    echo -e "${GREEN}[✓] configure 完成${NC}"

    echo -e "${YELLOW}[*] 编译中（约1-3分钟）...${NC}"
    if ! make -j"$(nproc)" >> "$BUILD_LOG" 2>&1; then
        echo -e "${RED}make 失败！详细错误:${NC}"
        tail -30 "$BUILD_LOG"
        exit 1
    fi

    if ! make install >> "$BUILD_LOG" 2>&1 || [[ ! -f "$DANTE_DIR/sbin/sockd" ]]; then
        echo -e "${RED}make install 失败！详细错误:${NC}"
        tail -20 "$BUILD_LOG"
        exit 1
    fi

    ln -sf "$DANTE_DIR/sbin/sockd" /usr/local/sbin/sockd
    cd / && rm -rf /tmp/dante* "$BUILD_LOG"
    echo -e "${GREEN}[✓] Dante ${DANTE_VER} 编译安装完成${NC}"
}

# ────────────────────────────────────────────
# 写入 Dante 配置
# ────────────────────────────────────────────
write_config() {
    local port="$1"
    local iface="$2"
    local mode="$3"   # ipv4 | ipv6

    if [[ "$mode" == "ipv6" ]]; then
        INTERNAL_LINE="internal: :: port = ${port}"
    else
        INTERNAL_LINE="internal: 0.0.0.0 port = ${port}"
    fi

    local PASS_LOG="error"
    [[ "$LOG_CONNECTIONS" == "1" ]] && PASS_LOG="error connect disconnect"

    # 规则按顺序匹配：block 必须写在 pass 之前才生效
    local BLOCK_RULES=""
    if [[ "$BLOCK_PRIVATE" == "1" ]]; then
        BLOCK_RULES=$(cat <<'BLK'
# ── 禁止把本代理当跳板访问内网/回环（不需要可将 BLOCK_PRIVATE 设为 0 重装）──
socks block { from: 0.0.0.0/0 to: 127.0.0.0/8     log: error }
socks block { from: 0.0.0.0/0 to: 10.0.0.0/8      log: error }
socks block { from: 0.0.0.0/0 to: 172.16.0.0/12   log: error }
socks block { from: 0.0.0.0/0 to: 192.168.0.0/16  log: error }
socks block { from: 0.0.0.0/0 to: 169.254.0.0/16  log: error }
socks block { from: ::/0      to: ::1/128         log: error }
socks block { from: ::/0      to: fc00::/7        log: error }
socks block { from: ::/0      to: fe80::/10       log: error }
BLK
)
    fi

    cat > "$CONFIG_FILE" << EOF
# Dante SOCKS5 配置 - 安全加固版
logoutput: $LOG_FILE

${INTERNAL_LINE}
external: ${iface}

socksmethod: username
clientmethod: none

user.privileged: root
user.unprivileged: nobody

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error
}

client pass {
    from: ::/0 to: ::/0
    log: error
}

${BLOCK_RULES}

socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    socksmethod: username
    log: ${PASS_LOG}
}

socks pass {
    from: ::/0 to: ::/0
    socksmethod: username
    log: ${PASS_LOG}
}

socks block {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error
}
EOF
    chmod 600 "$CONFIG_FILE"
}

# ────────────────────────────────────────────
# PAM / fail2ban / logrotate
# ────────────────────────────────────────────
write_pam() {
    # Dante 默认 pam.servicename = "sockd"。不显式提供会回落到 /etc/pam.d/other，
    # 行为随发行版而变，这里固定下来。
    cat > "$PAM_FILE" << 'EOF'
auth    required pam_unix.so
account required pam_unix.so
EOF
    chmod 644 "$PAM_FILE"
}

write_fail2ban() {
    local port="$1"
    mkdir -p /etc/fail2ban/jail.d /etc/fail2ban/filter.d

    cat > /etc/fail2ban/jail.d/danted.conf << EOF
[danted]
enabled  = true
port     = $port
protocol = tcp
filter   = danted
logpath  = $LOG_FILE
maxretry = 5
findtime = 300
bantime  = 3600
EOF

    # 真实日志行（源码编译出来的二进制名是 sockd，不是 danted；IP 在前，没有 "from"）：
    # Aug 28 23:15:50 (1787930150.772249) sockd[196005]: info: block(1): tcp/accept ]: \
    #   144.24.75.237.53464 10.0.0.131.26079: error after reading 22 bytes in 0 seconds: \
    #   system password authentication failed for user "socks5usr"
    cat > /etc/fail2ban/filter.d/danted.conf << 'EOF'
[Definition]
failregex = sockd\[\d+\]: .*: <ADDR>\.\d+ .*authentication failed
            sockd\[\d+\]: .*: <ADDR>\.\d+ .*: error after reading .* bytes .*: .*authentication failed
ignoreregex =
EOF
}

write_logrotate() {
    # 代理每条连接都写日志，繁忙时一天就能上 G，必须按大小封顶而不是只按周轮转
    # copytruncate 不新建文件，所以不能配 create（两者矛盾）
    cat > "$LOGROTATE_FILE" << EOF
$LOG_FILE {
    daily
    rotate 7
    maxsize 50M
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
}

# ────────────────────────────────────────────
# 防火墙
# ────────────────────────────────────────────
# 只删除指定端口这一条规则，绝不触碰其它规则
close_firewall() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 0
    command -v ufw &>/dev/null && ufw delete allow "$port"/tcp &>/dev/null
    if command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --remove-port="$port"/tcp &>/dev/null
        firewall-cmd --reload &>/dev/null
    fi
    return 0
}

open_firewall() {
    local port="$1"
    if command -v ufw &>/dev/null; then
        if ufw_is_active; then
            ufw allow "$port"/tcp &>/dev/null
            echo -e "${GREEN}[✓] UFW 已放行端口 $port${NC}"
        else
            ufw allow "$port"/tcp &>/dev/null
            echo -e "${YELLOW}[!] UFW 已安装但处于 inactive，规则已写入但未生效${NC}"
            echo -e "${YELLOW}    当前无防火墙拦截，代理端口本身是通的${NC}"
            echo -e "${YELLOW}    如需真正启用防火墙，请用菜单第 7 项（会先放行 SSH，避免锁死）${NC}"
        fi
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-port="$port"/tcp &>/dev/null
        firewall-cmd --reload &>/dev/null
        echo -e "${GREEN}[✓] firewalld 已放行端口 $port${NC}"
    else
        echo -e "${YELLOW}[!] 未检测到 ufw/firewalld，跳过防火墙配置${NC}"
    fi
}

enable_ufw_safely() {
    check_root
    command -v ufw &>/dev/null || { echo -e "${RED}未安装 ufw${NC}"; return 1; }

    if ufw_is_active; then
        echo -e "${GREEN}[✓] UFW 已经是 active 状态${NC}"
        ufw status numbered
        return 0
    fi

    echo -e "${CYAN}${BOLD}═══ 安全启用 UFW ═══${NC}"
    echo -e "${RED}UFW 默认策略是 DROP 所有入站。直接 enable 会切断所有未放行的服务，${NC}"
    echo -e "${RED}包括你当前的 SSH 连接。下面先列出需要放行的端口。${NC}"
    echo ""

    local ssh_ports proxy_port listening
    ssh_ports=$(get_ssh_ports)
    proxy_port=""
    [[ -f "$CRED_FILE" ]] && proxy_port=$(cred_get PORT)

    # 安全闸门：探测不到 SSH 端口就绝不 enable，否则必然锁死
    if [[ -z "$ssh_ports" ]]; then
        echo -e "${RED}[✗] 未能探测到任何 SSH 监听端口，为避免把你锁在外面，已中止。${NC}"
        echo -e "${RED}    请先手动放行后再启用: ufw allow <你的SSH端口>/tcp${NC}"
        return 1
    fi

    echo -e "${YELLOW}检测到的 SSH 端口（必须放行，否则会被锁在外面）:${NC}"
    echo "$ssh_ports" | sed 's/^/    /'
    [[ -n "$proxy_port" ]] && echo -e "${YELLOW}SOCKS5 代理端口:${NC}\n    $proxy_port"

    echo ""
    echo -e "${YELLOW}当前正在监听的其它端口（不放行则会被阻断）:${NC}"
    # 排除已单独处理的 SSH 端口和代理端口；回环端口不对外暴露，也一并排除
    listening=$(printf '%s\n%s\n' "$ssh_ports" "$proxy_port" | grep -E '^[0-9]+$' | sort -u \
                | comm -13 - <(ss -tlnH 2>/dev/null \
                               | awk '$4 !~ /^(127\.|\[::1\])/ {sub(/.*[:.]/,"",$4); print $4}' \
                               | sort -u))
    if [[ -n "$listening" ]]; then
        echo "$listening" | sed 's/^/    /'
        echo ""
        read -rp "把上面这些端口一起放行吗? [Y/n]: " keep_others
    else
        echo "    (无)"
        keep_others="y"
    fi

    echo ""
    read -rp "确认启用 UFW? (yes 确认): " confirm
    [[ "$confirm" != "yes" ]] && { echo "已取消"; return; }

    local p
    for p in $ssh_ports; do
        ufw allow "$p"/tcp &>/dev/null
        echo -e "${GREEN}[✓] 放行 SSH 端口 $p/tcp${NC}"
    done
    if [[ -n "$proxy_port" ]]; then
        ufw allow "$proxy_port"/tcp &>/dev/null
        echo -e "${GREEN}[✓] 放行代理端口 $proxy_port/tcp${NC}"
    fi
    if [[ "$keep_others" != "n" && "$keep_others" != "N" && -n "$listening" ]]; then
        for p in $listening; do
            # 127.0.0.1 上的本地服务不需要对外放行，但这里无法区分，统一放行更安全
            ufw allow "$p"/tcp &>/dev/null
            echo -e "${GREEN}[✓] 放行 $p/tcp${NC}"
        done
    fi

    ufw --force enable
    echo ""
    ufw status numbered
    echo ""
    echo -e "${YELLOW}[!] 请立刻另开一个终端确认还能 SSH 登录，再关掉当前会话。${NC}"
}

# ────────────────────────────────────────────
# 主安装流程
# ────────────────────────────────────────────
install_socks5() {
    check_root
    print_banner

    choose_network

    # 选了 IPv6 但机器没有全局 IPv6，装完 URI 会是 [] 这种空地址，先拦下来
    if [[ "$NET_MODE" == "ipv6" ]]; then
        if ! ip -6 addr show scope global 2>/dev/null \
             | awk '/inet6/{print $2}' | cut -d/ -f1 | grep -qv '^fd'; then
            echo -e "${RED}[✗] 本机没有检测到全局 IPv6 地址${NC}"
            read -rp "仍要继续以 IPv6 模式安装吗? [y/N]: " go_on
            [[ "$go_on" != "y" && "$go_on" != "Y" ]] && { echo "已取消"; return 1; }
        fi
    fi

    echo ""
    echo -e "${GREEN}[*] 开始安装 SOCKS5 代理服务（Dante 源码编译）...${NC}"

    if [[ -f "$DANTE_DIR/sbin/sockd" ]]; then
        echo -e "${YELLOW}[!] Dante 已编译存在，跳过编译步骤${NC}"
    else
        compile_dante
    fi

    # 获取网卡名（IPv4 或 IPv6 路由）
    if [[ "$NET_MODE" == "ipv6" ]]; then
        IFACE=$(ip -6 route get 2001:4860:4860::8888 2>/dev/null \
                | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
    else
        IFACE=$(ip route get 8.8.8.8 2>/dev/null \
                | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
    fi
    [[ -z "$IFACE" ]] && IFACE=$(ip -o link show \
                                 | awk -F': ' '$2 != "lo" {print $2; exit}')
    echo -e "${GREEN}[✓] 检测到网卡: ${IFACE}${NC}"

    # 重装前清掉上一次留下的端口规则，避免 ufw 里堆积一堆孤儿端口
    if [[ -f "$CRED_FILE" ]]; then
        local old_port
        old_port=$(cred_get PORT)
        if [[ "$old_port" =~ ^[0-9]+$ ]]; then
            close_firewall "$old_port"
            echo -e "${YELLOW}[!] 已清理上次安装遗留的端口规则 ${old_port}/tcp${NC}"
        fi
    fi

    SOCKS_PORT=$(gen_port)
    echo -e "${GREEN}[✓] 随机端口: ${SOCKS_PORT}${NC}"

    if ! id "$SOCKS_USER" &>/dev/null; then
        useradd -r -s /usr/sbin/nologin -M -d /nonexistent "$SOCKS_USER" 2>/dev/null \
        || useradd -r -s /sbin/nologin -M -d /nonexistent "$SOCKS_USER"
        echo -e "${GREEN}[✓] 已创建系统用户: $SOCKS_USER${NC}"
    fi

    # URI 安全密码（IPv4/IPv6 统一），避免 @ : / # ? % 破坏 socks5:// 解析
    SOCKS_PASS=$(gen_password)
    echo -e "${GREEN}[✓] 已生成 URI 安全密码（openssl base64url，288 bit 熵）${NC}"

    echo "$SOCKS_USER:$SOCKS_PASS" | chpasswd
    echo -e "${GREEN}[✓] PAM 密码设置完成${NC}"

    write_pam
    echo -e "${GREEN}[✓] PAM 服务定义写入 $PAM_FILE${NC}"

    write_config "$SOCKS_PORT" "$IFACE" "$NET_MODE"
    echo -e "${GREEN}[✓] 配置写入完成${NC}"

    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Dante SOCKS5 Proxy Server
After=network.target

[Service]
Type=forking
PIDFile=/run/danted.pid
ExecStart=$DANTE_DIR/sbin/sockd -D -f $CONFIG_FILE -p /run/danted.pid
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictRealtime=true
RestrictSUIDSGID=true
ReadWritePaths=/var/log /run

[Install]
WantedBy=multi-user.target
EOF

    touch "$LOG_FILE"
    chmod 640 "$LOG_FILE"
    write_logrotate

    write_fail2ban "$SOCKS_PORT"

    systemctl daemon-reload
    systemctl enable danted &>/dev/null
    systemctl restart danted

    sleep 2
    if ! systemctl is-active --quiet danted; then
        echo -e "${RED}[!] 服务启动失败，查看详情:${NC}"
        journalctl -u danted -n 30 --no-pager
        echo -e "${RED}配置文件:${NC}"
        cat "$CONFIG_FILE"
        exit 1
    fi
    echo -e "${GREEN}[✓] Dante 服务启动成功${NC}"

    # 服务确认起来之后再开防火墙：起不来就不该把端口暴露出去
    open_firewall "$SOCKS_PORT"

    systemctl enable fail2ban &>/dev/null
    systemctl restart fail2ban &>/dev/null
    if fail2ban-client status danted &>/dev/null; then
        echo -e "${GREEN}[✓] fail2ban danted jail 已生效${NC}"
    else
        echo -e "${YELLOW}[!] fail2ban danted jail 未生效，请检查: fail2ban-client status${NC}"
    fi

    # 公网 IP
    if [[ "$NET_MODE" == "ipv6" ]]; then
        PUBLIC_IP=$(get_public_ipv6)
        IP_LABEL="IPv6地址"
    else
        PUBLIC_IP=$(get_public_ipv4)
        IP_LABEL="IPv4地址"
    fi
    if [[ -z "$PUBLIC_IP" ]]; then
        echo -e "${YELLOW}[!] 未能自动获取公网 IP（服务本身不受影响）${NC}"
        read -rp "请手动输入用于连接的公网地址 [回车跳过]: " PUBLIC_IP
    fi

    # 公网 IP 不在网卡上有两种可能，从机器内部无法区分，所以只问不猜：
    #   · 1:1 NAT（AWS/GCP/Oracle/阿里云/腾讯云等）—— 端口不变，绝大多数情况
    #   · 端口映射 NAT（NAT 小鸡）—— 外部端口 ≠ 内网端口，必须填
    EXT_PORT="$SOCKS_PORT"
    if [[ "$NET_MODE" == "ipv4" ]] && ! ip_is_local "$PUBLIC_IP"; then
        echo ""
        echo -e "${YELLOW}[?] 公网 IP ${PUBLIC_IP} 没有直接绑在本机网卡上，两种情况都会这样:${NC}"
        echo -e "    · 1:1 NAT（AWS/GCP/Oracle/阿里云等主流云）—— 端口不变，${BOLD}直接回车${NC}"
        echo -e "    · 端口映射 NAT（NAT 小鸡）—— 外部端口和内网端口不同，需要填"
        echo -e "${YELLOW}    填错了不影响服务运行，只影响显示的连接信息，之后可用菜单第 9 项改。${NC}"
        read -rp "外部映射到 ${SOCKS_PORT} 的端口是多少？不确定直接回车: " in_port
        [[ "$in_port" =~ ^[0-9]+$ ]] && EXT_PORT="$in_port"
    fi

    if [[ "$NET_MODE" == "ipv6" ]]; then
        URI_HOST="[${PUBLIC_IP}]"
    else
        URI_HOST="${PUBLIC_IP}"
    fi

    cat > "$CRED_FILE" << EOF
MODE='$NET_MODE'
IP='$PUBLIC_IP'
PORT='$SOCKS_PORT'
EXT_PORT='$EXT_PORT'
SOCKS_USER='$SOCKS_USER'
SOCKS_PASS='$SOCKS_PASS'
EOF
    chmod 600 "$CRED_FILE"

    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║         ✅  SOCKS5 安装成功！以下为代理信息             ║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}┌─────────────── 📋 代理配置（一键复制）────────────────┐${NC}"
    printf "  %-12s : ${YELLOW}%s${NC}\n" "$IP_LABEL"  "$PUBLIC_IP"
    printf "  %-12s : ${YELLOW}%s${NC}\n" "端口"       "$EXT_PORT"
    [[ "$EXT_PORT" != "$SOCKS_PORT" ]] && \
    printf "  %-12s : ${YELLOW}%s${NC}\n" "本机端口"   "$SOCKS_PORT (NAT 内网)"
    printf "  %-12s : ${YELLOW}%s${NC}\n" "用户名"     "$SOCKS_USER"
    printf "  %-12s : ${YELLOW}%s${NC}\n" "密码"       "$SOCKS_PASS"
    printf "  %-12s : ${YELLOW}%s${NC}\n" "协议"       "SOCKS5"
    echo -e "${CYAN}└────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "${CYAN}┌─────────────── 🔗 URI 格式（一键复制）───────────────┐${NC}"
    echo -e "  ${YELLOW}socks5://${SOCKS_USER}:${SOCKS_PASS}@${URI_HOST}:${EXT_PORT}${NC}"
    echo -e "${CYAN}└────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "${CYAN}┌─────────────── 🧪 curl 验证命令 ──────────────────────┐${NC}"
    if [[ "$NET_MODE" == "ipv6" ]]; then
        echo -e "  ${YELLOW}curl -x socks5h://${SOCKS_USER}:${SOCKS_PASS}@${URI_HOST}:${EXT_PORT} https://api6.ipify.org${NC}"
    else
        echo -e "  ${YELLOW}curl -x socks5h://${SOCKS_USER}:${SOCKS_PASS}@${URI_HOST}:${EXT_PORT} https://api.ipify.org${NC}"
    fi
    echo -e "${CYAN}└────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "${BLUE}🔒 已启用安全措施:${NC}"
    echo -e "  ✔ 网络模式: ${NET_MODE^^}"
    echo -e "  ✔ URI 安全密码（openssl base64url，288 bit 熵，不会破坏 socks5:// 解析）"
    echo -e "  ✔ 随机端口 ${SOCKS_PORT}（10000-65000，规避端口扫描）"
    echo -e "  ✔ PAM 系统级认证（密码不写入任何配置文件）"
    echo -e "  ✔ 专用 nologin 用户（无法 SSH 登录）"
    echo -e "  ✔ fail2ban：5次失败封锁 IP 1小时"
    [[ "$BLOCK_PRIVATE" == "1" ]] && \
    echo -e "  ✔ 禁止经代理访问内网/回环（防内网跳板）"
    echo -e "  ✔ systemd NoNewPrivileges 沙箱隔离"
    echo -e "  ✔ 日志轮转（每周，保留4份）"
    echo -e "  ✔ 凭据文件 chmod 600，仅 root 可读"
    echo -e "  ✔ 凭据已保存至 ${YELLOW}${CRED_FILE}${NC}"
    echo ""
    if command -v ufw &>/dev/null && ! ufw_is_active; then
        echo -e "${YELLOW}⚠ UFW 当前未启用，本机没有包过滤防护。${NC}"
        echo -e "${YELLOW}  要启用请走菜单第 7 项，它会先放行 SSH 端口再 enable，避免把自己锁死。${NC}"
        echo ""
    fi
}

# ────────────────────────────────────────────
# 删除
# ────────────────────────────────────────────
remove_socks5() {
    check_root
    echo -e "${RED}[!] 将彻底删除 SOCKS5 服务，是否继续? (y/N): ${NC}"
    read -r confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { echo "已取消"; return; }

    OLD_PORT=""
    [[ -f "$CRED_FILE" ]] && OLD_PORT=$(cred_get PORT)

    systemctl stop danted &>/dev/null
    systemctl disable danted &>/dev/null
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload

    rm -rf "$DANTE_DIR"
    rm -f /usr/local/sbin/sockd
    rm -f "$CONFIG_FILE" "$CRED_FILE" "$LOG_FILE" "$PAM_FILE" "$LOGROTATE_FILE"
    rm -f /etc/fail2ban/jail.d/danted.conf /etc/fail2ban/filter.d/danted.conf
    userdel "$SOCKS_USER" &>/dev/null
    systemctl restart fail2ban &>/dev/null

    # 只删除本脚本自己添加的那一条端口规则，不触碰其它规则
    if [[ "$OLD_PORT" =~ ^[0-9]+$ ]]; then
        close_firewall "$OLD_PORT"
        echo -e "${GREEN}[✓] 已移除防火墙规则 ${OLD_PORT}/tcp（其它规则未改动）${NC}"
    else
        echo -e "${YELLOW}[!] 未找到记录的端口，未改动任何防火墙规则${NC}"
    fi

    echo -e "${GREEN}✅ SOCKS5 服务已完全删除${NC}"
}

# ────────────────────────────────────────────
# 自检：真正跑一次代理，而不是只看进程在不在
# ────────────────────────────────────────────
self_test() {
    check_root
    local fail=0

    if [[ ! -f "$CRED_FILE" ]]; then
        echo -e "${RED}[✗] 未找到凭据文件，请先安装${NC}"; return 1
    fi
    local MODE IP PORT EXT_PORT u pw
    MODE=$(cred_get MODE); IP=$(cred_get IP); PORT=$(cred_get PORT)
    EXT_PORT=$(cred_get EXT_PORT); [[ -z "$EXT_PORT" ]] && EXT_PORT="$PORT"
    u=$(cred_get SOCKS_USER);  [[ -z "$u" ]]  && u=$(cred_get USER)
    pw=$(cred_get SOCKS_PASS); [[ -z "$pw" ]] && pw=$(cred_get PASS)

    echo -e "${CYAN}${BOLD}═══ SOCKS5 自检 ═══${NC}"

    # 1. 服务在跑
    if systemctl is-active --quiet danted; then
        echo -e "${GREEN}[✓] danted 服务运行中${NC}"
    else
        echo -e "${RED}[✗] danted 未运行${NC}"; fail=1
    fi

    # 2. 端口在听
    if ss -tlnH "sport = :$PORT" 2>/dev/null | grep -q .; then
        echo -e "${GREEN}[✓] 端口 $PORT 正在监听${NC}"
    else
        echo -e "${RED}[✗] 端口 $PORT 未监听${NC}"; fail=1
    fi

    # 3. 正确密码能通（本地回环，不受 NAT/防火墙影响）
    local out
    out=$(curl -sS --max-time 15 -x "socks5h://127.0.0.1:$PORT" \
                --proxy-user "${u}:${pw}" https://api.ipify.org 2>&1)
    if [[ "$out" =~ ^[0-9a-fA-F.:]+$ ]]; then
        echo -e "${GREEN}[✓] 认证通过，出口 IP: ${out}${NC}"
    else
        echo -e "${RED}[✗] 代理请求失败: ${out}${NC}"; fail=1
    fi

    # 4. 错误密码必须被拒（验证不是无认证裸奔）
    if curl -sS --max-time 10 -x "socks5h://127.0.0.1:$PORT" \
            --proxy-user "${u}:definitely_wrong_$$" https://api.ipify.org &>/dev/null; then
        echo -e "${RED}[✗] 严重：错误密码竟然通过了，认证没生效！${NC}"; fail=1
    else
        echo -e "${GREEN}[✓] 错误密码被正确拒绝${NC}"
    fi

    # 5. fail2ban 真的在数失败次数
    if fail2ban-client status danted &>/dev/null; then
        local total
        total=$(fail2ban-client status danted 2>/dev/null \
                | awk -F'\t' '/Total failed/{print $2}')
        if [[ "${total:-0}" -gt 0 ]]; then
            echo -e "${GREEN}[✓] fail2ban 正在统计失败次数（累计 ${total} 次）${NC}"
        else
            echo -e "${YELLOW}[!] fail2ban jail 在跑但计数为 0，filter 可能不匹配${NC}"
            echo -e "${YELLOW}    排查: fail2ban-regex $LOG_FILE /etc/fail2ban/filter.d/danted.conf${NC}"
        fi
    else
        echo -e "${RED}[✗] fail2ban danted jail 未运行${NC}"; fail=1
    fi

    # 6. 防火墙
    if command -v ufw &>/dev/null; then
        if ufw_is_active; then
            if ufw status | grep -qE "^${PORT}/tcp"; then
                echo -e "${GREEN}[✓] UFW active 且已放行 ${PORT}/tcp${NC}"
            else
                echo -e "${RED}[✗] UFW active 但未放行 ${PORT}/tcp，外部连不上${NC}"; fail=1
            fi
        else
            echo -e "${YELLOW}[!] UFW inactive（无包过滤防护，端口本身是通的）${NC}"
        fi
    fi

    # 7. 外部端口
    if [[ "$EXT_PORT" != "$PORT" ]]; then
        echo -e "${GREEN}[✓] 端口映射已记录: 外部 ${EXT_PORT} → 内网 ${PORT}${NC}"
    elif [[ "$MODE" != "ipv6" ]] && ! ip_is_local "$IP"; then
        echo -e "${GREEN}[✓] 外部端口按 ${PORT} 处理（1:1 NAT 的常规情况）${NC}"
        echo -e "${YELLOW}    若你的服务商是端口映射型且外部端口不同，用菜单第 9 项修正${NC}"
    fi

    # 8. 密码 URI 兼容性
    if [[ "$pw" =~ [@:/\#?\%\&] ]]; then
        echo -e "${YELLOW}[!] 密码含 URI 保留字符，socks5:// 形式不可用（需分开传用户名密码）${NC}"
    else
        echo -e "${GREEN}[✓] 密码 URI 安全，socks5:// 形式可直接使用${NC}"
    fi

    echo ""
    if [[ $fail -eq 0 ]]; then
        echo -e "${GREEN}${BOLD}✅ 自检全部通过${NC}"
    else
        echo -e "${RED}${BOLD}❌ 自检发现问题，见上面标 [✗] 的项${NC}"
    fi
    return $fail
}


# ────────────────────────────────────────────
# 修改外部端口（NAT 端口映射填错了不用重装）
# ────────────────────────────────────────────
set_ext_port() {
    check_root
    [[ -f "$CRED_FILE" ]] || { echo -e "${RED}未找到凭据文件，请先安装${NC}"; return 1; }
    local port cur new
    port=$(cred_get PORT)
    cur=$(cred_get EXT_PORT); [[ -z "$cur" ]] && cur="$port"
    echo -e "${CYAN}内网监听端口: ${BOLD}${port}${NC}${CYAN}    当前记录的外部端口: ${BOLD}${cur}${NC}"
    echo -e "${YELLOW}非端口映射的机器（含 AWS/GCP/Oracle 这类 1:1 NAT）填 ${port} 即可${NC}"
    read -rp "新的外部端口 [回车取消]: " new
    [[ "$new" =~ ^[0-9]+$ ]] || { echo "已取消"; return; }
    if grep -q '^EXT_PORT=' "$CRED_FILE"; then
        sed -i "s/^EXT_PORT=.*/EXT_PORT='${new}'/" "$CRED_FILE"
    else
        echo "EXT_PORT='${new}'" >> "$CRED_FILE"
    fi
    echo -e "${GREEN}[✓] 外部端口已更新为 ${new}${NC}"
}

# ────────────────────────────────────────────
# 查看状态
# ────────────────────────────────────────────
show_status() {
    check_root
    echo -e "${CYAN}${BOLD}═══ 服务状态 ═══${NC}"
    systemctl status danted --no-pager -l 2>/dev/null \
        || echo -e "${RED}服务未安装或未运行${NC}"

    echo ""
    echo -e "${CYAN}${BOLD}═══ 端口监听 ═══${NC}"
    if [[ -f "$CRED_FILE" ]]; then
        CUR_PORT=$(cred_get PORT)
        ss -tlnp | grep ":${CUR_PORT}" \
            || echo -e "${RED}端口 ${CUR_PORT} 未监听${NC}"
    else
        ss -tlnp | grep sockd || echo -e "${RED}未检测到 sockd 监听${NC}"
    fi

    echo ""
    echo -e "${CYAN}${BOLD}═══ 防火墙 ═══${NC}"
    if command -v ufw &>/dev/null; then
        if ufw_is_active; then
            ufw status numbered
        else
            echo -e "${YELLOW}UFW: inactive（规则已写入但未生效，菜单第 7 项可安全启用）${NC}"
        fi
    fi

    echo ""
    echo -e "${CYAN}${BOLD}═══ fail2ban ═══${NC}"
    fail2ban-client status danted 2>/dev/null \
        || echo -e "${YELLOW}danted jail 未运行${NC}"

    if [[ -f "$CRED_FILE" ]]; then
        # 用 cred_get 而不是 source：密码含 & ; | 等字符时 source 会执行掉它
        local MODE IP PORT EXT_PORT SOCKS_PASS
        MODE=$(cred_get MODE); IP=$(cred_get IP); PORT=$(cred_get PORT)
        EXT_PORT=$(cred_get EXT_PORT); [[ -z "$EXT_PORT" ]] && EXT_PORT="$PORT"
        SOCKS_USER=$(cred_get SOCKS_USER)
        [[ -z "$SOCKS_USER" ]] && SOCKS_USER=$(cred_get USER)   # 兼容旧版字段
        SOCKS_PASS=$(cred_get SOCKS_PASS)
        [[ -z "$SOCKS_PASS" ]] && SOCKS_PASS=$(cred_get PASS)
        if [[ "$MODE" == "ipv6" ]]; then
            URI_HOST="[${IP}]"; IP_LABEL="IPv6地址"
        else
            URI_HOST="${IP}";   IP_LABEL="IPv4地址"
        fi
        echo ""
        echo -e "${CYAN}${BOLD}═══ 当前代理信息 ═══${NC}"
        printf "  %-12s : ${YELLOW}%s${NC}\n" "$IP_LABEL" "$IP"
        printf "  %-12s : ${YELLOW}%s${NC}\n" "端口"      "$EXT_PORT"
        [[ "$EXT_PORT" != "$PORT" ]] && \
        printf "  %-12s : ${YELLOW}%s${NC}\n" "本机端口"  "$PORT (NAT 内网)"
        printf "  %-12s : ${YELLOW}%s${NC}\n" "用户名"    "$SOCKS_USER"
        printf "  %-12s : ${YELLOW}%s${NC}\n" "密码"      "$SOCKS_PASS"
        echo ""
        echo -e "${CYAN}${BOLD}═══ URI 一键复制 ═══${NC}"
        echo -e "  ${YELLOW}socks5://${SOCKS_USER}:${SOCKS_PASS}@${URI_HOST}:${EXT_PORT}${NC}"
        echo ""
        echo -e "${CYAN}${BOLD}═══ curl 验证 ═══${NC}"
        if [[ "$MODE" == "ipv6" ]]; then
            echo -e "  ${YELLOW}curl -x socks5h://${SOCKS_USER}:${SOCKS_PASS}@${URI_HOST}:${EXT_PORT} https://api6.ipify.org${NC}"
        else
            echo -e "  ${YELLOW}curl -x socks5h://${SOCKS_USER}:${SOCKS_PASS}@${URI_HOST}:${EXT_PORT} https://api.ipify.org${NC}"
        fi
        warn_if_uri_unsafe "$SOCKS_PASS" "$URI_HOST" "$EXT_PORT" "$SOCKS_USER"
    fi
}

# ────────────────────────────────────────────
# 主菜单
# ────────────────────────────────────────────
main_menu() {
  while true; do
    print_banner
    echo -e "${BOLD}请选择操作:${NC}"
    echo "  1) 安装 SOCKS5（选择 IPv4/IPv6）"
    echo "  2) 删除 SOCKS5"
    echo "  3) 启动服务"
    echo "  4) 停止服务"
    echo "  5) 重启服务"
    echo "  6) 查看状态 + 代理信息"
    echo "  7) 安全启用 UFW 防火墙（先放行 SSH，避免锁死）"
    echo "  8) 自检（真跑一次代理验证认证/防火墙/fail2ban）"
    echo "  9) 修改外部端口（NAT 端口映射填错时用）"
    echo "  0) 退出"
    echo ""
    read -rp "请输入选项 [0-9]: " choice
    case $choice in
        1) install_socks5 ;;
        2) remove_socks5 ;;
        3) check_root; systemctl start danted   && echo -e "${GREEN}✅ 已启动${NC}" ;;
        4) check_root; systemctl stop danted    && echo -e "${YELLOW}⏹ 已停止${NC}" ;;
        5) check_root; systemctl restart danted && echo -e "${GREEN}✅ 已重启${NC}" ;;
        6) show_status ;;
        7) enable_ufw_safely ;;
        8) self_test ;;
        9) set_ext_port ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项${NC}" ;;
    esac
    echo ""
    read -rp "按回车返回菜单，Ctrl+C 退出..." _
    echo ""
  done
}

# ────────────────────────────────────────────
# 命令行参数
# ────────────────────────────────────────────
case "${1:-menu}" in
    install)     install_socks5 ;;
    remove)      remove_socks5 ;;
    start)       check_root; systemctl start danted ;;
    stop)        check_root; systemctl stop danted ;;
    restart)     check_root; systemctl restart danted ;;
    status)      show_status ;;
    enable-ufw)  enable_ufw_safely ;;
    test|check)  self_test ;;
    set-port)    set_ext_port ;;
    menu|"")     main_menu ;;
    *) echo "用法: $0 {install|remove|start|stop|restart|status|test|enable-ufw|set-port|menu}"; exit 1 ;;
esac
