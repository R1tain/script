#!/bin/bash
# reality-warp.sh - 新建一个独立的 "Reality (走 WARP 出口)" 服务
#
# 与 reality.sh 装的原始 Reality 服务完全隔离、互不影响：
#   - 独立端口 / 独立 UUID / 独立密钥
#   - 独立 systemd 服务: sing-box-warp
#   - 独立配置文件: /usr/local/etc/sing-box-warp/config.json
#   - 出站不是 direct，而是打到 MicroWARP 提供的本地 SOCKS5 (127.0.0.1:1080)
#     MicroWARP: https://github.com/ccbkkb/MicroWARP (Cloudflare WARP 出口)
#
# 架构:
#   客户端 --Reality(新端口)--> sing-box-warp(vless-in) --socks--> 127.0.0.1:1080(MicroWARP) --> WARP 出口
#   原有的 reality.sh 服务 (另一个端口) 保持原样，直连出站，不受任何影响。
#
# 用法: bash reality-warp.sh

if [ -z "$BASH_VERSION" ]; then
    echo "错误：请使用 bash 运行此脚本（bash reality-warp.sh）"
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo -e "\033[31m错误：此脚本必须以 root 权限运行！\033[0m"
    exit 1
fi

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

# --- sing-box 二进制 (与 reality.sh 共用同一份，没有则自己下载) ---
SING_BOX_BIN="/usr/local/bin/sing-box"

# --- 新服务：独立配置/独立 systemd 单元，不碰原有 reality.sh 的任何文件 ---
CONFIG_DIR="/usr/local/etc/sing-box-warp"
CONFIG_FILE="$CONFIG_DIR/config.json"
SERVICE_NAME="sing-box-warp"
SERVICE_LOG="/root/sing-box-warp.log"

# --- MicroWARP (SOCKS5 出口容器) ---
WARP_DIR="/usr/local/etc/microwarp"
WARP_COMPOSE_FILE="$WARP_DIR/docker-compose.yml"
WARP_CONTAINER="microwarp"

LOG_DIR="/var/log/sing-box-warp"
LOG_FILE="/var/log/sing-box-warp-install.log"
TMP_DIR=""
COMPOSE_CMD="docker compose"

log() {
    local level="$1" message="$2" ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] [$level] $message" >> "$LOG_FILE"
    case "$level" in
        信息|INFO) echo -e "${GREEN}[$ts] [信息] $message${PLAIN}" ;;
        警告|WARN) echo -e "${YELLOW}[$ts] [警告] $message${PLAIN}" ;;
        错误|ERROR) echo -e "${RED}[$ts] [错误] $message${PLAIN}" ;;
        *) echo -e "[$ts] [$level] $message" ;;
    esac
}

check_result() {
    local name="$1"
    if [ $? -ne 0 ]; then log 错误 "$name 失败。"; return 1; fi
    return 0
}

sanitize_var() {
    echo "$1" | tr -d '\n\r"' | tr -dc 'A-Za-z0-9-._:'
}

# --- 防火墙 (不操作防火墙，直接跳过) ---
open_firewall_port() { return 0; }
close_firewall_port() { return 0; }

# --- 依赖 ---
install_base_packages() {
    local pkgs="curl wget tar openssl coreutils iproute2"
    if command -v apt &>/dev/null; then apt update -y && apt install -y $pkgs
    elif command -v apk &>/dev/null; then apk update && apk add $pkgs bash
    elif command -v dnf &>/dev/null; then dnf install -y $pkgs
    elif command -v yum &>/dev/null; then yum install -y $pkgs
    else log 错误 "未检测到支持的包管理器，请手动安装: $pkgs"; return 1
    fi
}

check_dependencies() {
    local deps=( "curl" "wget" "tar" "openssl" "install" "grep" "awk" "sed" "ss" )
    local missing=()
    for cmd in "${deps[@]}"; do command -v "$cmd" &>/dev/null || missing+=("$cmd"); done
    if [ ${#missing[@]} -ne 0 ]; then
        log 警告 "缺少依赖: ${missing[*]}，尝试自动安装..."
        install_base_packages || { log 错误 "依赖安装失败"; return 1; }
    fi
    return 0
}

ensure_sing_box_installed() {
    if command -v "$SING_BOX_BIN" &>/dev/null; then
        log 信息 "复用已存在的 sing-box 二进制: $SING_BOX_BIN"
        return 0
    fi
    log 信息 "未检测到 sing-box，开始下载..."
    local arch=""
    case $(uname -m) in
        x86_64 | amd64) arch="amd64" ;;
        aarch64 | arm64) arch="arm64" ;;
        *) log 错误 "不支持的系统架构: $(uname -m)"; return 1 ;;
    esac
    cd "$TMP_DIR" || return 1
    local api="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
    local tag
    tag=$(curl -s -H "User-Agent: reality-warp-script" --retry 3 --retry-delay 2 "$api" | grep -o '"tag_name":"[^"]*"' | head -1 | cut -d'"' -f4)
    [[ -z "$tag" ]] && { log 错误 "无法获取 sing-box 最新版本号。"; return 1; }
    local version=${tag#v}
    local url="https://github.com/SagerNet/sing-box/releases/download/${tag}/sing-box-${version}-linux-${arch}.tar.gz"
    wget --tries=3 --waitretry=3 -O sing-box.tar.gz "$url"
    check_result "下载 sing-box" || return 1
    tar -xzf sing-box.tar.gz --strip-components=1 "sing-box-${version}-linux-${arch}/sing-box"
    check_result "解压 sing-box" || return 1
    install -m 755 sing-box "$SING_BOX_BIN"
    check_result "安装 sing-box 二进制" || return 1
}

ensure_docker_installed() {
    if command -v docker &>/dev/null; then
        log 信息 "检测到 Docker: $(docker --version)"
    else
        log 信息 "未检测到 Docker，正在安装..."
        curl -fsSL https://get.docker.com | sh
        check_result "安装 Docker" || return 1
        systemctl enable docker 2>/dev/null
        systemctl start docker 2>/dev/null
    fi
    if docker compose version &>/dev/null; then
        COMPOSE_CMD="docker compose"
    elif command -v docker-compose &>/dev/null; then
        COMPOSE_CMD="docker-compose"
    else
        log 信息 "安装 docker compose 插件..."
        if command -v apt &>/dev/null; then apt install -y docker-compose-plugin
        elif command -v dnf &>/dev/null; then dnf install -y docker-compose-plugin
        elif command -v yum &>/dev/null; then yum install -y docker-compose-plugin
        elif command -v apk &>/dev/null; then apk add docker-cli-compose
        fi
        docker compose version &>/dev/null && COMPOSE_CMD="docker compose" || {
            log 错误 "docker compose 安装失败，请手动安装后重试。"; return 1;
        }
    fi
    return 0
}

get_public_ip() {
    local svcs=( "https://api.ipify.org" "https://icanhazip.com" "https://ipinfo.io/ip" "https://ifconfig.me/ip" "https://checkip.amazonaws.com" )
    local ip
    for s in "${svcs[@]}"; do
        ip=$(curl -s --max-time 8 -4 "$s")
        if [[ -n "$ip" ]] && ! [[ "$ip" == *\<* || "$ip" == *" "* ]]; then
            echo "$ip"; return 0
        fi
    done
    return 1
}

# --- MicroWARP 容器 (SOCKS5 出口, 供新 Reality 服务出站使用) ---
warp_port_from_compose() {
    # 注意: 不能直接对整段 "127.0.0.1:1080:1080" 做 grep -oE '[0-9]+' | head -1，
    # 那样会先匹配到 IP 里的 "127"，取到错误的端口号。必须用捕获组精确提取端口。
    [ -f "$WARP_COMPOSE_FILE" ] || return 0
    grep -oE '"127\.0\.0\.1:[0-9]+:[0-9]+"' "$WARP_COMPOSE_FILE" | head -1 | sed -E 's/.*:([0-9]+):[0-9]+"/\1/'
}

ensure_microwarp_running() {
    if [ -f "$WARP_COMPOSE_FILE" ] && docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${WARP_CONTAINER}$"; then
        log 信息 "MicroWARP 容器已在运行，端口: $(warp_port_from_compose)"
        return 0
    fi

    ensure_docker_installed || return 1

    log 信息 "未检测到运行中的 MicroWARP，开始安装..."
    local bind_port="1080"
    echo -e "${YELLOW}MicroWARP 本地 SOCKS5 端口 [默认 1080，仅监听 127.0.0.1]:${PLAIN}"
    read -r ip
    [[ -n "$ip" ]] && bind_port="$ip"

    local socks_user="" socks_pass=""
    echo -e "${YELLOW}是否为 MicroWARP 的 SOCKS5 设置账号密码? (默认无密码) (y/N):${PLAIN}"
    read -r set_auth
    if [[ "$set_auth" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}用户名:${PLAIN}"
        read -r socks_user
        echo -e "${YELLOW}密码:${PLAIN}"
        read -r socks_pass
    fi

    local endpoint_ip=""
    echo -e "${YELLOW}是否启用端口跳跃 (机房 UDP 2408 被限速时用 4500)? (y/N):${PLAIN}"
    read -r use_hop
    [[ "$use_hop" =~ ^[Yy]$ ]] && endpoint_ip="162.159.192.1:4500"

    mkdir -p "$WARP_DIR"
    {
        echo "services:"
        echo "  microwarp:"
        echo "    image: ghcr.io/ccbkkb/microwarp:latest"
        echo "    container_name: $WARP_CONTAINER"
        echo "    restart: always"
        echo "    ports:"
        echo "      - \"127.0.0.1:${bind_port}:${bind_port}\""
        echo "    cap_add:"
        echo "      - NET_ADMIN"
        echo "      - SYS_MODULE"
        echo "    sysctls:"
        echo "      - net.ipv4.conf.all.src_valid_mark=1"
        echo "    environment:"
        echo "      - BIND_ADDR=0.0.0.0"
        echo "      - BIND_PORT=${bind_port}"
        echo "      - ALLOW_NO_AUTH=1"
        [[ -n "$socks_user" ]] && echo "      - SOCKS_USER=${socks_user}"
        [[ -n "$socks_pass" ]] && echo "      - SOCKS_PASS=${socks_pass}"
        [[ -n "$endpoint_ip" ]] && echo "      - ENDPOINT_IP=${endpoint_ip}"
        echo "    volumes:"
        echo "      - warp-data:/etc/wireguard"
        echo
        echo "volumes:"
        echo "  warp-data:"
    } > "$WARP_COMPOSE_FILE"

    (cd "$WARP_DIR" && $COMPOSE_CMD up -d)
    check_result "启动 MicroWARP 容器" || return 1

    log 信息 "等待 MicroWARP 就绪 (最多 20 秒)..."
    local i
    for i in $(seq 1 20); do
        ss -tuln | grep -q ":${bind_port} " && break
        sleep 1
    done
    log 信息 "MicroWARP 已就绪，本地 SOCKS5: 127.0.0.1:${bind_port}"
    return 0
}

# ------------------------------------------------------------------------------
# SNI 选择函数: 支持自动获取(SSLLabs Recent Best Akamai A+ 3选1, 3分钟超时) 或 手动填写
# ------------------------------------------------------------------------------
select_reality_sni() {
    local default_sni="icloud-content.com"
    local chosen_sni=""
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
    local cache_file="${script_dir}/.sni_akamai_cache.txt"
    local tmp_json="/tmp/.sni_candidates_$$.json"

    echo -e "\n${CYAN}============================================================${PLAIN}"
    echo -e "${BOLD}${GREEN}配置目标服务器伪装域名 (SNI)${PLAIN}"
    echo -e "${CYAN}============================================================${PLAIN}"
    echo -e "  ${BOLD}1)${PLAIN} ${GREEN}自动获取${PLAIN} (从 SSLLabs Recent Best 筛选 Akamai A+ 优质域名，3选1，超时3分钟)"
    echo -e "  ${BOLD}2)${PLAIN} 手动填写 (自行输入指定域名，默认: ${default_sni})"
    echo -e "${CYAN}------------------------------------------------------------${PLAIN}"

    local sni_mode=""
    read -p "请选择 SNI 获取方式 [1-2, 默认: 1]: " sni_mode
    sni_mode="${sni_mode:-1}"

    if [[ "$sni_mode" == "1" ]]; then
        log 信息 "已选择自动获取 SNI，正在从 SSLLabs Recent Best 检索 Akamai A+ 域名 (超时 3 分钟)..."
        
        # 执行 Python 自动筛选器 (3个目标, 180秒超时, 自动排除gov)
        python3 - "$cache_file" "$tmp_json" 3 180 << 'PY_EOF'
import sys, os, time, re, ssl, json, random, socket, subprocess, urllib.request, urllib.parse
from concurrent.futures import ThreadPoolExecutor

CACHE_FILE = sys.argv[1] if len(sys.argv) > 1 else ""
OUT_JSON = sys.argv[2] if len(sys.argv) > 2 else "/tmp/.sni_candidates.json"
TARGET_COUNT = int(sys.argv[3]) if len(sys.argv) > 3 else 3
MAX_TIMEOUT = int(sys.argv[4]) if len(sys.argv) > 4 else 180

RED = "\033[31m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
CYAN = "\033[36m"
BOLD = "\033[1m"
PLAIN = "\033[0m"

def is_gov_domain(domain):
    d = domain.lower().strip(".")
    if re.search(r'\.(gov|gob|gouv|mil)($|\.)', d):
        return True
    if re.search(r'\.(fed\.us|state\.[a-z]{2}\.us)$', d):
        return True
    parts = d.split(".")
    if any(p in ("gov", "gob", "gouv", "mil") for p in parts):
        return True
    return False

def fetch_ssllabs_recent_best_aplus():
    url = "https://www.ssllabs.com/ssltest/index.html"
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120.0.0.0 Safari/537.36",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Cache-Control": "no-cache"
        }
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            html = resp.read().decode("utf-8", "ignore")
    except Exception:
        return []

    match = re.search(r"Recent Best</div>(.*?)(?:Recent Worst|</div>\s*</div>)", html, re.DOTALL)
    if not match:
        return []

    block = match.group(1)
    items = re.findall(r'<div class="rating[^"]*">\s*([^<]+?)\s*</div>\s*<a href="analyze\.html\?d=([^"&]+)"', block)
    
    aplus_list = []
    for rating, domain in items:
        rating = rating.strip()
        domain = urllib.parse.unquote(domain.strip()).lower().strip(".")
        if rating == "A+" and domain and not is_gov_domain(domain):
            aplus_list.append(domain)
    return aplus_list

def verify_akamai(domain):
    try:
        res = subprocess.run(["dig", "+short", "A", domain], capture_output=True, text=True, timeout=2.5)
        lines = [l.strip().rstrip(".").lower() for l in res.stdout.strip().splitlines() if l.strip()]
        for l in lines:
            if any(k in l for k in [
                "edgekey.net", "edgesuite.net", "akamaiedge.net",
                "akamai.net", "akadns.net", "akamaitechnologies.com"
            ]):
                return True, f"CNAME: {l}"
        ips = [l for l in lines if re.match(r"^\d+\.\d+\.\d+\.\d+$", l)]
        for ip in ips[:2]:
            ptr_res = subprocess.run(["dig", "+short", "-x", ip], capture_output=True, text=True, timeout=2)
            for ptr in ptr_res.stdout.strip().splitlines():
                ptr_clean = ptr.strip().rstrip(".").lower()
                if "akamai" in ptr_clean:
                    return True, f"PTR: {ptr_clean}"
    except Exception:
        pass

    try:
        req = urllib.request.Request(f"https://{domain}", headers={"User-Agent": "Mozilla/5.0"})
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        with urllib.request.urlopen(req, timeout=2.5, context=ctx) as resp:
            for k, v in resp.headers.items():
                kl = k.lower()
                vl = v.lower()
                if kl == "server" and "akamai" in vl:
                    return True, f"Server: {v}"
                if kl.startswith("x-akamai") or kl.startswith("akamai"):
                    return True, f"Header: {k}"
    except Exception:
        pass

    return False, ""

def inspect_domain(domain):
    info = {
        "domain": domain,
        "tls13": "-",
        "alpn": "-",
        "latency_ms": "-",
        "http_code": "-",
        "ip": "-"
    }
    t0 = time.time()
    try:
        ip = socket.gethostbyname(domain)
        info["ip"] = ip
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(2.0)
        s.connect((ip, 443))
        info["latency_ms"] = f"{int((time.time() - t0) * 1000)}ms"
        s.close()
    except Exception:
        pass

    try:
        cmd = ["openssl", "s_client", "-connect", f"{domain}:443", "-servername", domain, "-alpn", "h2,http/1.1"]
        proc = subprocess.run(cmd, input=b"", capture_output=True, timeout=2.5)
        out = proc.stdout.decode("utf-8", "ignore")
        if "TLSv1.3" in out:
            info["tls13"] = "TLS 1.3"
        elif "TLSv1.2" in out:
            info["tls13"] = "TLS 1.2"
        m_alpn = re.search(r"ALPN protocol:\s*(\S+)", out)
        if m_alpn:
            info["alpn"] = m_alpn.group(1)
        elif "h2" in out:
            info["alpn"] = "h2"
    except Exception:
        pass

    try:
        req = urllib.request.Request(f"https://{domain}", headers={"User-Agent": "Mozilla/5.0"})
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        with urllib.request.urlopen(req, timeout=2.5, context=ctx) as r:
            info["http_code"] = str(r.status)
    except urllib.error.HTTPError as e:
        info["http_code"] = str(e.code)
    except Exception:
        pass

    return info

cached_pool = []
if CACHE_FILE and os.path.exists(CACHE_FILE):
    try:
        with open(CACHE_FILE, "r", encoding="utf-8") as f:
            for line in f:
                d = line.strip().lower()
                if d and not d.startswith("#") and not is_gov_domain(d):
                    cached_pool.append(d)
    except Exception:
        pass

found_candidates = []
seen_domains = set()
round_count = 0
start_time = time.time()

while len(found_candidates) < TARGET_COUNT:
    elapsed = time.time() - start_time
    if elapsed >= MAX_TIMEOUT:
        print(f"\n{RED}[警告] 自动获取超时 ({MAX_TIMEOUT}秒)。{PLAIN}")
        break

    round_count += 1
    sys.stdout.write(f"\r{YELLOW}[第 {round_count:02d} 轮] 正在抓取并验证... (已找到 {len(found_candidates)}/{TARGET_COUNT}, 耗时 {int(elapsed)}s){PLAIN}   ")
    sys.stdout.flush()

    aplus_doms = fetch_ssllabs_recent_best_aplus()
    for dom in aplus_doms:
        if dom in seen_domains:
            continue
        seen_domains.add(dom)
        
        is_ak, reason = verify_akamai(dom)
        if is_ak:
            found_candidates.append({"domain": dom, "evidence": reason})
            sys.stdout.write("\n")
            print(f" {GREEN}[+] 命中 Akamai A+:{PLAIN} {BOLD}{dom}{PLAIN} ({reason})")
            sys.stdout.flush()
            if len(found_candidates) >= TARGET_COUNT:
                break

    if len(found_candidates) < TARGET_COUNT and round_count >= 3 and cached_pool:
        print(f"\n{YELLOW}[i] 实时补充：从历史已验证的 Akamai A+ 候选池补齐至 {TARGET_COUNT} 个...{PLAIN}")
        pool_shuffled = cached_pool.copy()
        random.shuffle(pool_shuffled)
        for c_dom in pool_shuffled:
            if any(c["domain"] == c_dom for c in found_candidates):
                continue
            is_ak, reason = verify_akamai(c_dom)
            if is_ak:
                found_candidates.append({"domain": c_dom, "evidence": f"池补充: {reason}"})
                print(f" {GREEN}[+] 补充合格域名:{PLAIN} {BOLD}{c_dom}{PLAIN}")
                if len(found_candidates) >= TARGET_COUNT:
                    break
        break

    if len(found_candidates) < TARGET_COUNT:
        time.sleep(1.0)

if not found_candidates:
    sys.exit(1)

# 回写缓存
if CACHE_FILE:
    try:
        new_set = {d for d in cached_pool if not is_gov_domain(d)}
        for c in found_candidates:
            if not is_gov_domain(c["domain"]):
                new_set.add(c["domain"])
        with open(CACHE_FILE, "w", encoding="utf-8") as f:
            for d in sorted(new_set):
                f.write(f"{d}\n")
    except Exception:
        pass

print(f"\n{CYAN}[*] 正在对筛选出的 {len(found_candidates)} 个优质域名进行网络与 TLS 握手测试...{PLAIN}")
with ThreadPoolExecutor(max_workers=3) as executor:
    inspected_results = list(executor.map(lambda c: (c, inspect_domain(c["domain"])), found_candidates))

# 输出格式化表格
print("\n" + "=" * 82)
print(f"{BOLD}{'编号':<4}  {'SNI 域名':<34} {'评级':<6} {'CDN':<8} {'TLS版本':<9} {'ALPN':<6} {'延迟':<7} {'状态':<6}{PLAIN}")
print("-" * 82)

for idx, (cand, info) in enumerate(inspected_results, 1):
    tls_colored = f"{GREEN}{info['tls13']}{PLAIN}" if "1.3" in info['tls13'] else f"{YELLOW}{info['tls13']}{PLAIN}"
    alpn_colored = f"{GREEN}{info['alpn']}{PLAIN}" if info['alpn'] == "h2" else f"{PLAIN}{info['alpn']}{PLAIN}"
    print(f"{BOLD}[ {idx} ]{PLAIN}  {info['domain']:<34} {GREEN}A+{PLAIN}     Akamai   {tls_colored:<18} {alpn_colored:<15} {info['latency_ms']:<7} {info['http_code']:<6}")

print("=" * 82)

with open(OUT_JSON, "w", encoding="utf-8") as jf:
    json.dump([item[1] for item in inspected_results], jf)

PY_EOF

        # 检查是否生成了候选文件供用户 3 选 1
        if [[ -f "$tmp_json" ]]; then
            local count
            count=$(python3 -c "import json; print(len(json.load(open('$tmp_json'))))" 2>/dev/null || echo 0)
            if [[ "$count" -gt 0 ]]; then
                while true; do
                    echo -ne "${BOLD}${YELLOW}请从上述域名中挑选一个作为 SNI [1-${count}, 默认: 1]: ${PLAIN}"
                    local choice=""
                    read -r choice
                    choice="${choice:-1}"
                    if [[ "$choice" =~ ^[1-3]$ ]] && [[ "$choice" -le "$count" ]]; then
                        chosen_sni=$(python3 -c "import json; data=json.load(open('$tmp_json')); print(data[$((choice-1))]['domain'])")
                        log 信息 "您已挑选 SNI: ${GREEN}${chosen_sni}${PLAIN}"
                        break
                    else
                        echo -e "${RED}输入无效，请输入 1 到 ${count} 之间的编号。${PLAIN}"
                    fi
                done
            fi
            rm -f "$tmp_json"
        fi

        if [[ -z "$chosen_sni" ]]; then
            log 警告 "未能自动获取到有效域名（或已超时），自动进入手动填写模式。"
        fi
    fi

    # 如果未自动获取或选择了手动模式
    if [[ -z "$chosen_sni" ]]; then
        read -p "请输入目标服务器域名 (SNI) [默认: $default_sni]: " input_dest_server
        if [[ -n "$input_dest_server" ]]; then
            local sanitized_sni
            sanitized_sni=$(echo "$input_dest_server" | tr -dc 'A-Za-z0-9-.' | head -c 253)
            if [[ -n "$sanitized_sni" ]]; then
                chosen_sni="$sanitized_sni"
            else
                log 警告 "输入的目标服务器域名无效，将使用默认值: $default_sni"
                chosen_sni="$default_sni"
            fi
        else
            chosen_sni="$default_sni"
        fi
    fi

    log 信息 "将使用目标服务器 (SNI): $chosen_sni"
    eval "$1='$chosen_sni'"
}

# ------------------------------------------------------------------------------
# 端口选择函数: 自动 (30000-65530, 不含数字 4) 或 手动输入
# ------------------------------------------------------------------------------
select_reality_port() {
    local target_var="$1"
    local prompt_title="${2:-Reality 连接端口}"
    local chosen_port=""

    echo -e "\n${CYAN}============================================================${PLAIN}"
    echo -e "${BOLD}${GREEN}配置 ${prompt_title}${PLAIN}"
    echo -e "${CYAN}============================================================${PLAIN}"
    echo -e "  ${BOLD}1)${PLAIN} ${GREEN}自动生成${PLAIN} (范围 30000-65530，不含数字 4，自动排查占用)"
    echo -e "  ${BOLD}2)${PLAIN} 手动输入 (自定义端口 1-65535)"
    echo -e "${CYAN}------------------------------------------------------------${PLAIN}"

    local port_mode=""
    read -p "请选择端口配置方式 [1-2, 默认: 1]: " port_mode
    port_mode="${port_mode:-1}"

    if [[ "$port_mode" == "1" ]]; then
        local candidate=""
        local attempts=0
        while [ $attempts -lt 2000 ]; do
            attempts=$((attempts + 1))
            candidate=$(shuf -i 30000-65530 -n 1 2>/dev/null || python3 -c "import random; print(random.randint(30000, 65530))")
            if [[ "$candidate" =~ 4 ]]; then
                continue
            fi
            if ss -tuln | grep -q ":$candidate "; then
                continue
            fi
            chosen_port="$candidate"
            break
        done

        if [[ -n "$chosen_port" ]]; then
            log 信息 "自动分配随机端口: ${GREEN}${chosen_port}${PLAIN} (30000-65530, 不含4, 未被占用)"
        else
            log 警告 "自动生成端口失败，切换为手动输入模式。"
        fi
    fi

    if [[ -z "$chosen_port" ]]; then
        while true; do
            read -p "请输入连接端口 (1-65535): " chosen_port
            if [[ "$chosen_port" =~ ^[0-9]+$ ]] && [ "$chosen_port" -ge 1 ] && [ "$chosen_port" -le 65535 ]; then
                if ss -tuln | grep -q ":$chosen_port "; then
                    log 错误 "端口 $chosen_port 已被占用，请更换其他端口。"
                else
                    log 信息 "选定端口: $chosen_port"
                    break
                fi
            else
                log 错误 "端口无效，请输入 1 到 65535 之间的有效数字。"
            fi
        done
    fi

    eval "$target_var='$chosen_port'"
}

# ------------------------------------------------------------------------------
# 生成全英文地理信息名称的 VLESS 链接及 Base64 编码
# ------------------------------------------------------------------------------
generate_reality_links() {
    local uuid="$1"
    local ip="$2"
    local port="$3"
    local dest_server="$4"
    local public_key="$5"
    local short_id="$6"
    local suffix="${7:-Reality-WARP}"
    local out_json="/tmp/.reality_links_$$.json"

    python3 - "$uuid" "$ip" "$port" "$dest_server" "$public_key" "$short_id" "$out_json" << 'PY_EOF'
import sys, json, base64, urllib.request, urllib.parse

uuid = sys.argv[1]
ip = sys.argv[2]
port = sys.argv[3]
dest = sys.argv[4]
pbk = sys.argv[5]
sid = sys.argv[6]
out_json = sys.argv[7]

def format_node_name(ip_addr):
    clean_ip = ip_addr.strip("[]")
    country, region, city = "", "", ""
    try:
        url = f"http://ip-api.com/json/{clean_ip}"
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=3) as resp:
            data = json.loads(resp.read().decode())
            if data.get("status") == "success":
                country = data.get("country", "").strip()
                region = data.get("regionName", "").strip()
                city = data.get("city", "").strip()
    except Exception:
        pass

    # 类似 United States North Carolina Charlotte，全英文，无缩写，不加 | Reality
    parts = []
    seen_words_lower = set()

    for section in [country, region, city]:
        if not section:
            continue
        words = section.split()
        filtered = []
        for w in words:
            w_clean = w.strip(",.-")
            if w_clean and w_clean.lower() not in seen_words_lower:
                filtered.append(w_clean)
                seen_words_lower.add(w_clean.lower())
        if filtered:
            parts.append(" ".join(filtered))

    name = " ".join(parts).strip()
    return name if name else "Server Node"

node_name = format_node_name(ip)
quoted_tag = urllib.parse.quote(node_name)

safe_ip = f"[{ip}]" if ":" in ip and not ip.startswith("[") else ip

vless_link = (
    f"vless://{uuid}@{safe_ip}:{port}"
    f"?encryption=none&flow=xtls-rprx-vision&security=reality&sni={dest}&fp=chrome&pbk={pbk}&sid={sid}&type=tcp&headerType=none"
    f"#{quoted_tag}"
)

# Base64 编码
b64_link = base64.b64encode(vless_link.encode("utf-8")).decode("utf-8")

result = {
    "node_name": node_name,
    "vless_link": vless_link,
    "b64_link": b64_link
}

with open(out_json, "w", encoding="utf-8") as f:
    json.dump(result, f)
PY_EOF

    if [[ -f "$out_json" ]]; then
        local node_name vless_link b64_link
        node_name=$(python3 -c "import json; print(json.load(open('$out_json'))['node_name'])")
        vless_link=$(python3 -c "import json; print(json.load(open('$out_json'))['vless_link'])")
        b64_link=$(python3 -c "import json; print(json.load(open('$out_json'))['b64_link'])")
        rm -f "$out_json"

        echo -e "\n${GREEN}======================================================================${PLAIN}"
        echo -e "${BOLD}${GREEN}✔ Reality (WARP 出口) 安装成功！节点配置与分享链接:${PLAIN}"
        echo -e "${GREEN}======================================================================${PLAIN}"
        echo -e " • ${BOLD}节点名称 :${PLAIN} ${CYAN}${node_name}${PLAIN}"
        echo -e " • ${BOLD}服务器IP :${PLAIN} ${ip}"
        echo -e " • ${BOLD}监听端口 :${PLAIN} ${port}"
        echo -e " • ${BOLD}UUID     :${PLAIN} ${uuid}"
        echo -e " • ${BOLD}公钥     :${PLAIN} ${public_key}"
        echo -e " • ${BOLD}ShortID  :${PLAIN} ${short_id}"
        echo -e " • ${BOLD}目标 SNI :${PLAIN} ${dest_server}"
        echo -e " • ${BOLD}出站出口 :${PLAIN} Cloudflare WARP"
        echo -e "----------------------------------------------------------------------"
        echo -e "${BOLD}${YELLOW}【VLESS 分享链接 (明文)】:${PLAIN}"
        echo -e "${vless_link}"
        echo -e "----------------------------------------------------------------------"
        echo -e "${BOLD}${YELLOW}【Base64 订阅/节点链接 (Base64)】:${PLAIN}"
        echo -e "${b64_link}"
        echo -e "${GREEN}======================================================================${PLAIN}\n"

        echo -e "节点名称: ${node_name}\nVLESS链接:\n${vless_link}\n\nBase64链接:\n${b64_link}" > "/root/reality_warp_link.txt"
        log 信息 "分享链接已保存至: /root/reality_warp_link.txt"
    fi
}

# --- 新建 "Reality 走 WARP 出口" 服务 ---
install_reality_warp() {
    if [ -f "$CONFIG_FILE" ]; then
        log 警告 "检测到本服务已安装 ($CONFIG_FILE 已存在)。"
        echo -e "${YELLOW}是否覆盖重新安装? (y/N):${PLAIN}"
        read -r ov
        [[ ! "$ov" =~ ^[Yy]$ ]] && { log 信息 "已取消。"; return 0; }
        uninstall_reality_warp keep_warp
    fi

    check_dependencies || return 1
    ensure_sing_box_installed || return 1
    ensure_microwarp_running || return 1
    local warp_port
    warp_port=$(warp_port_from_compose)
    if ! [[ "$warp_port" =~ ^[0-9]+$ ]]; then
        log 警告 "未能从 $WARP_COMPOSE_FILE 解析出端口，回退使用默认值 1080。"
        warp_port=1080
    fi

    # 安装前先探测一下 MicroWARP 的 SOCKS5 端口是否真的能连上，避免把错误端口写进新配置
    if ! (exec 3<>"/dev/tcp/127.0.0.1/${warp_port}") 2>/dev/null; then
        log 错误 "无法连接 127.0.0.1:${warp_port} (MicroWARP)，请先用选项 8 检查容器状态/日志再重试。"
        return 1
    fi
    exec 3<&- 3>&- 2>/dev/null
    log 信息 "已确认 MicroWARP 的 SOCKS5 端口 127.0.0.1:${warp_port} 可连接。"

    # 1. 新端口 - 两个选择: 自动(30000-65530不含4) 或 手动
    local port=""
    select_reality_port port "Reality (WARP出口) 连接端口"

    # 2. 密钥 / UUID / short_id
    log 信息 "生成 Reality 密钥对..."
    local keys
    keys=$("$SING_BOX_BIN" generate reality-keypair 2>&1)
    check_result "生成密钥对" || return 1
    local private_key public_key
    private_key=$(sanitize_var "$(echo "$keys" | grep 'PrivateKey' | awk '{print $2}')")
    public_key=$(sanitize_var "$(echo "$keys" | grep 'PublicKey' | awk '{print $2}')")
    [[ -z "$private_key" || -z "$public_key" ]] && { log 错误 "提取密钥失败"; return 1; }

    local uuid short_id
    uuid=$("$SING_BOX_BIN" generate uuid)
    short_id=$(openssl rand -hex 8)

    # 3. SNI - 支持自动获取(3选1, 3分钟超时) 或 手动填写
    local dest_server="icloud-content.com"
    select_reality_sni dest_server

    # 4. 写配置：inbound 与原版一致，outbound 换成指向 MicroWARP 的 socks
    mkdir -p "$CONFIG_DIR" "$LOG_DIR"
    cat > "$CONFIG_FILE" << EOF
{
  "log": {
    "level": "info",
    "disabled": false,
    "output": "$SERVICE_LOG",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": $port,
      "users": [
        { "uuid": "$uuid", "flow": "xtls-rprx-vision" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$dest_server",
        "reality": {
          "enabled": true,
          "handshake": { "server": "$dest_server", "server_port": 443 },
          "private_key": "$private_key",
          "short_id": ["$short_id"]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "socks",
      "tag": "warp-out",
      "server": "127.0.0.1",
      "server_port": $warp_port,
      "version": "5"
    },
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "rules": [
      { "network": ["tcp", "udp"], "outbound": "warp-out" }
    ],
    "auto_detect_interface": true,
    "default_mark": 0,
    "default_domain_resolver": "cloudflare"
  },
  "dns": {
    "servers": [
      { "tag": "google-dns", "type": "udp", "server": "8.8.8.8" },
      { "tag": "cloudflare", "type": "udp", "server": "1.1.1.1" }
    ],
    "final": "cloudflare"
  }
}
EOF
    check_result "写入配置文件" || return 1
    chmod 600 "$CONFIG_FILE"

    local out
    out=$("$SING_BOX_BIN" check -c "$CONFIG_FILE" 2>&1)
    if [ $? -ne 0 ]; then
        log 错误 "配置校验失败:\n$out"
        rm -rf "$CONFIG_DIR"
        return 1
    fi
    log 信息 "配置校验通过。"

    # 5. systemd / OpenRC 服务
    if command -v systemctl &>/dev/null; then
        cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=Sing-box Reality Service (WARP egress)
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target docker.service

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
        systemctl daemon-reload
        systemctl enable "$SERVICE_NAME"
        systemctl restart "$SERVICE_NAME"
        check_result "启用并启动 ${SERVICE_NAME}" || { uninstall_reality_warp keep_warp; return 1; }
    elif command -v rc-service &>/dev/null; then
        cat > "/etc/init.d/${SERVICE_NAME}" << EOF
#!/sbin/openrc-run
name="${SERVICE_NAME}"
description="Sing-box Reality Service (WARP egress)"
supervisor=supervise-daemon
command="$SING_BOX_BIN"
command_args="run -c $CONFIG_FILE"
command_user="root"
output_log="$LOG_DIR/${SERVICE_NAME}.log"
error_log="$LOG_DIR/${SERVICE_NAME}.err"
pidfile="/run/\${RC_SVCNAME}.pid"
depend() { need net; after firewall docker; }
EOF
        chmod +x "/etc/init.d/${SERVICE_NAME}"
        rc-update add "$SERVICE_NAME" default
        rc-service "$SERVICE_NAME" restart
        check_result "启用并启动 ${SERVICE_NAME}" || { uninstall_reality_warp keep_warp; return 1; }
    else
        log 警告 "未找到 systemd 或 OpenRC，请手动运行: $SING_BOX_BIN run -c $CONFIG_FILE"
    fi

    sleep 3
    check_service_status || { uninstall_reality_warp keep_warp; return 1; }

    # 6. 输出分享链接 (优化节点名称展示国家城市，并生成 Base64 链接)
    local ip
    ip=$(get_public_ip)
    if [[ -n "$ip" ]]; then
        generate_reality_links "$uuid" "$ip" "$port" "$dest_server" "$public_key" "$short_id" "Reality-WARP"
    else
        log 警告 "未能自动获取公网 IP，请手动拼接分享链接。"
    fi
    return 0
}

# --- 删除新服务 ---
# 参数 keep_warp: 传入时跳过 “是否顺带删除 MicroWARP” 的询问（内部失败回滚时使用，不动 MicroWARP）
uninstall_reality_warp() {
    local mode="$1"
    log 信息 "开始卸载 Reality (WARP 出口) 服务..."

    local existing_port=""
    [ -f "$CONFIG_FILE" ] && existing_port=$(grep -oE '"listen_port"[[:space:]]*:[[:space:]]*[0-9]+' "$CONFIG_FILE" | grep -oE '[0-9]+' | head -1)

    if command -v systemctl &>/dev/null; then
        systemctl stop "$SERVICE_NAME" 2>/dev/null
        systemctl disable "$SERVICE_NAME" 2>/dev/null
        [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ] && rm -f "/etc/systemd/system/${SERVICE_NAME}.service" && systemctl daemon-reload
    elif command -v rc-service &>/dev/null; then
        rc-service "$SERVICE_NAME" stop 2>/dev/null
        rc-update del "$SERVICE_NAME" default 2>/dev/null
        rm -f "/etc/init.d/${SERVICE_NAME}"
    fi

    rm -rf "$CONFIG_DIR" "$LOG_DIR"
    rm -f "$SERVICE_LOG"

    log 信息 "本服务(端口 ${existing_port:-未知}) 已卸载。原有 reality.sh 服务未受任何影响。"

    if [[ "$mode" != "keep_warp" ]]; then
        if [ -f "$WARP_COMPOSE_FILE" ] && command -v docker &>/dev/null; then
            echo -e "${YELLOW}是否同时停止/删除 MicroWARP 容器? (若还有其他服务在用，请选 N) (y/N):${PLAIN}"
            read -r rm_warp
            if [[ "$rm_warp" =~ ^[Yy]$ ]]; then
                echo -e "${YELLOW}是否同时删除 WARP 账号数据卷 warp-data (删除后下次重新注册账号)? (y/N):${PLAIN}"
                read -r rmvol
                if [[ "$rmvol" =~ ^[Yy]$ ]]; then
                    (cd "$WARP_DIR" && $COMPOSE_CMD down -v)
                else
                    (cd "$WARP_DIR" && $COMPOSE_CMD down)
                fi
                rm -rf "$WARP_DIR"
                log 信息 "MicroWARP 容器已移除。"
            fi
        fi
    fi

    log 信息 "${GREEN}卸载完成。${PLAIN}"
    return 0
}

check_service_status() {
    log 信息 "正在检查 ${SERVICE_NAME} 服务状态..."
    if command -v systemctl &>/dev/null; then
        if systemctl is-active --quiet "$SERVICE_NAME"; then
            log 信息 "${SERVICE_NAME} 正在运行。"; return 0
        else
            log 错误 "${SERVICE_NAME} 未运行。最近日志:"
            journalctl -u "$SERVICE_NAME" --no-pager -n 20
            return 1
        fi
    elif command -v rc-service &>/dev/null; then
        if rc-service "$SERVICE_NAME" status | grep -q -E 'status: started|status: starting'; then
            log 信息 "${SERVICE_NAME} 正在运行。"; return 0
        else
            log 错误 "${SERVICE_NAME} 未运行。"
            [ -f "$SERVICE_LOG" ] && tail -n 20 "$SERVICE_LOG"
            return 1
        fi
    else
        pgrep -f "$SING_BOX_BIN run -c $CONFIG_FILE" >/dev/null && return 0 || return 1
    fi
}

# --- 主菜单 ---
show_menu() {
    echo -e "
  ${GREEN}Reality (WARP 出口) 独立服务 管理脚本${PLAIN}
  (与 reality.sh 装的原 Reality 服务并存，互不影响)
  ----------------------------------------
  ${GREEN}1.${PLAIN} 新建 / 安装 (Reality + MicroWARP 出口)
  ${GREEN}2.${PLAIN} 删除 / 卸载 本服务
  ----------------------------------------
  ${GREEN}3.${PLAIN} 启动服务
  ${GREEN}4.${PLAIN} 停止服务
  ${GREEN}5.${PLAIN} 重启服务
  ${GREEN}6.${PLAIN} 查看服务状态
  ${GREEN}7.${PLAIN} 查看配置文件
  ${GREEN}8.${PLAIN} 查看 MicroWARP 容器状态/日志
  ----------------------------------------
  ${GREEN}0.${PLAIN} 退出脚本
  ----------------------------------------"
    echo -e "${YELLOW}请输入选项 [0-8]:${PLAIN}"
    read -r num
    case "$num" in
        1) install_reality_warp ;;
        2)
            echo -e "${YELLOW}确认删除本服务(新建的 WARP 出口 Reality)? 不会影响原有 Reality 服务 (y/N):${PLAIN}"
            read -r c
            [[ "$c" =~ ^[Yy]$ ]] && uninstall_reality_warp || log 信息 "已取消。"
            ;;
        3)
            if command -v systemctl &>/dev/null; then systemctl start "$SERVICE_NAME"; check_result "启动服务";
            elif command -v rc-service &>/dev/null; then rc-service "$SERVICE_NAME" start; check_result "启动服务";
            else log 错误 "未知服务管理器"; fi
            check_service_status ;;
        4)
            if command -v systemctl &>/dev/null; then systemctl stop "$SERVICE_NAME"; check_result "停止服务";
            elif command -v rc-service &>/dev/null; then rc-service "$SERVICE_NAME" stop; check_result "停止服务";
            else log 错误 "未知服务管理器"; fi ;;
        5)
            if command -v systemctl &>/dev/null; then systemctl restart "$SERVICE_NAME"; check_result "重启服务";
            elif command -v rc-service &>/dev/null; then rc-service "$SERVICE_NAME" restart; check_result "重启服务";
            else log 错误 "未知服务管理器"; fi
            sleep 2; check_service_status ;;
        6) check_service_status ;;
        7)
            if [ -f "$CONFIG_FILE" ]; then cat "$CONFIG_FILE"; else log 错误 "配置文件未找到！"; fi ;;
        8)
            if command -v docker &>/dev/null; then
                docker ps --filter "name=$WARP_CONTAINER" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
                echo; docker logs --tail 30 "$WARP_CONTAINER" 2>&1
            else
                log 错误 "未安装 Docker。"
            fi ;;
        0) exit 0 ;;
        *) log 错误 "无效选项: $num" ;;
    esac
}

# --- 入口 ---
cleanup_and_init() {
    TMP_DIR=$(mktemp -d -t singbox-warp-XXXXXX) || { echo "无法创建临时目录"; exit 1; }
    trap 'rm -rf "$TMP_DIR"' EXIT SIGINT SIGTERM
}
cleanup_and_init

mkdir -p "$LOG_DIR" 2>/dev/null
touch "$LOG_FILE" 2>/dev/null || log() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $2"; }

check_dependencies || exit 1

while true; do
    show_menu
    echo
    echo -e "${GREEN}按任意键返回主菜单...${PLAIN}"
    read -n 1 -s -r || exit 0
    echo
done
