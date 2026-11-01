#!/usr/bin/env bash
# ==============================================================================
# 脚本名称: sni.sh (Qualys SSLLabs Recent Best SNI 筛选获取工具)
# 数据来源: https://www.ssllabs.com/ssltest/index.html
# 严格规则: 
#   1. 必须来自 Recent Best 榜单
#   2. 评级必须为 A+
#   3. CDN 必须为 Akamai CDN (CNAME / PTR / Server 响应头验证)
# 核心功能: 每次运行筛选 5 个高质量域名供交互式挑选，并输出 Reality 配置
# 兼容环境: 兼容 Bash 与 Zsh
# ==============================================================================

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
MAGENTA="\033[35m"
CYAN="\033[36m"
WHITE="\033[37m"
BOLD="\033[1m"
PLAIN="\033[0m"

# 跨 shell (bash/zsh) 及软链接的脚本绝对路径解析
RESOLVED_SELF="$0"
if [ -L "$RESOLVED_SELF" ]; then
    RESOLVED_SELF="$(readlink -f "$RESOLVED_SELF" 2>/dev/null || readlink "$RESOLVED_SELF")"
fi
SCRIPT_DIR="$(cd "$(dirname "$RESOLVED_SELF")" 2>/dev/null && pwd)"

# 缓存与数据文件
CACHE_FILE="${SCRIPT_DIR}/.sni_akamai_cache.txt"
LAST_CHOICE_FILE="${SCRIPT_DIR}/.last_selected_sni"
TMP_JSON="/tmp/.sni_candidates_$$.json"

# 退出时清理临时文件
trap 'rm -f /tmp/.sni_candidates_*.json' EXIT

# 检查环境基础依赖
check_dependencies() {
    local missing=()
    for cmd in python3 curl dig openssl; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${RED}[错误] 缺少必要依赖工具: ${missing[*]}${PLAIN}"
        echo -e "${YELLOW}请先安装依赖，例如: apt-get update && apt-get install -y python3 curl dnsutils openssl${PLAIN}"
        exit 1
    fi
}

# 打印横幅
print_banner() {
    clear 2>/dev/null || true
    echo -e "${CYAN}======================================================================${PLAIN}"
    echo -e "${BOLD}${GREEN}        Qualys SSLLabs Recent Best - SNI (Akamai CDN) 提取工具${PLAIN}"
    echo -e "${CYAN}======================================================================${PLAIN}"
    echo -e " ${BOLD}数据来源:${PLAIN} https://www.ssllabs.com/ssltest/index.html"
    echo -e " ${BOLD}严格筛选:${PLAIN} 必须为 Recent Best 榜单 | 评级为 ${GREEN}A+${PLAIN} | CDN 为 ${YELLOW}Akamai${PLAIN} | ${RED}已排除政府域名(gov/gob/gouv)${PLAIN}"
    echo -e " ${BOLD}交互模式:${PLAIN} 每次自动筛选 5 个合格域名供您挑选"
    echo -e "${CYAN}----------------------------------------------------------------------${PLAIN}"
}

# 抓取与筛选引擎 (Python 高效并发驱动)
fetch_and_select() {
    local mode="${1:-fast}" # fast (默认3轮+合格池补齐) 或 deep (纯实时直到凑齐5个)

    python3 - "$CACHE_FILE" "$TMP_JSON" "$mode" << 'PY_EOF'
import sys
import os
import re
import time
import ssl
import json
import random
import socket
import subprocess
import urllib.request
import urllib.parse
from concurrent.futures import ThreadPoolExecutor

CACHE_FILE = sys.argv[1] if len(sys.argv) > 1 else ""
OUT_JSON = sys.argv[2] if len(sys.argv) > 2 else "/tmp/.sni_candidates.json"
MODE = sys.argv[3] if len(sys.argv) > 3 else "fast"
TARGET_COUNT = 5

RED = "\033[31m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
CYAN = "\033[36m"
BOLD = "\033[1m"
PLAIN = "\033[0m"

# 过滤国家政府 (gov/gob/gouv) 及军事 (mil) 域名
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

# 抓取 SSLLabs 首页 Recent Best
def fetch_ssllabs_recent_best_aplus():
    url = "https://www.ssllabs.com/ssltest/index.html"
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Cache-Control": "no-cache"
        }
    )
    try:
        with urllib.request.urlopen(req, timeout=6) as resp:
            html = resp.read().decode("utf-8", "ignore")
    except Exception:
        return []

    # 严格匹配 Recent Best 容器块
    match = re.search(r"Recent Best</div>(.*?)(?:Recent Worst|</div>\s*</div>)", html, re.DOTALL)
    if not match:
        return []

    block = match.group(1)
    items = re.findall(r'<div class="rating[^"]*">\s*([^<]+?)\s*</div>\s*<a href="analyze\.html\?d=([^"&]+)"', block)
    
    aplus_list = []
    for rating, domain in items:
        rating = rating.strip()
        domain = urllib.parse.unquote(domain.strip()).lower().strip(".")
        if rating == "A+" and domain:
            if not is_gov_domain(domain):
                aplus_list.append(domain)
    return aplus_list

# 严格检测 Akamai CDN
def verify_akamai(domain):
    # 1. CNAME 链检测
    try:
        res = subprocess.run(["dig", "+short", "A", domain], capture_output=True, text=True, timeout=2.5)
        lines = [l.strip().rstrip(".").lower() for l in res.stdout.strip().splitlines() if l.strip()]
        for l in lines:
            if any(k in l for k in [
                "edgekey.net", "edgesuite.net", "akamaiedge.net",
                "akamai.net", "akadns.net", "akamaitechnologies.com"
            ]):
                return True, f"CNAME: {l}"
        
        # 2. IP PTR 反向解析
        ips = [l for l in lines if re.match(r"^\d+\.\d+\.\d+\.\d+$", l)]
        for ip in ips[:2]:
            ptr_res = subprocess.run(["dig", "+short", "-x", ip], capture_output=True, text=True, timeout=2)
            for ptr in ptr_res.stdout.strip().splitlines():
                ptr_clean = ptr.strip().rstrip(".").lower()
                if "akamai" in ptr_clean:
                    return True, f"PTR: {ptr_clean}"
    except Exception:
        pass

    # 3. HTTP Header Server / x-akamai-*
    try:
        req = urllib.request.Request(
            f"https://{domain}",
            headers={"User-Agent": "Mozilla/5.0"}
        )
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

# 深度检测选出域名的协议与网络状态
def inspect_domain(domain):
    info = {
        "domain": domain,
        "tls13": "-",
        "alpn": "-",
        "latency_ms": "-",
        "http_code": "-",
        "ip": "-"
    }
    
    # 测延迟与真实 IP
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

    # TLS 握手测试
    try:
        cmd = ["openssl", "s_client", "-connect", f"{domain}:443", "-servername", domain, "-alpn", "h2,http/1.1"]
        proc = subprocess.run(cmd, input=b"", capture_output=True, timeout=3)
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

    # HTTP 连通性测试
    try:
        req = urllib.request.Request(
            f"https://{domain}",
            headers={"User-Agent": "Mozilla/5.0"}
        )
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

# 加载缓存池
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
max_rounds = 40 if MODE == "deep" else 3

print(f"{CYAN}[*] 正在从 SSLLabs Recent Best 实时轮询筛选 A+ 且 Akamai CDN 的域名...{PLAIN}")

while len(found_candidates) < TARGET_COUNT and round_count < max_rounds:
    round_count += 1
    sys.stdout.write(f"\r{YELLOW}[第 {round_count:02d} 轮] 抓取 SSLLabs 实时榜单并验证... (已找到 {len(found_candidates)}/{TARGET_COUNT}){PLAIN}   ")
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
            print(f" {GREEN}[+] 实时命中 Akamai A+:{PLAIN} {BOLD}{dom}{PLAIN} ({reason})")
            sys.stdout.flush()
            if len(found_candidates) >= TARGET_COUNT:
                break

    if len(found_candidates) < TARGET_COUNT and round_count < max_rounds:
        time.sleep(1.0)

# 如果实时抓取不足 5 个，从已验证池中随机补齐
if len(found_candidates) < TARGET_COUNT and cached_pool:
    print(f"\n{YELLOW}[i] 实时榜单补充：从已验证的 SSLLabs Akamai A+ 候选池补齐至 5 个...{PLAIN}")
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

if not found_candidates:
    print(f"\n{RED}[错误] 未能找到符合条件的域名，请检查网络后重试。{PLAIN}")
    sys.exit(1)

# 将新收集到的合格域名回写保存到缓存
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

print(f"\n{CYAN}[*] 正在对筛选出的 {len(found_candidates)} 个域名进行网络与 TLS 握手测试...{PLAIN}")
with ThreadPoolExecutor(max_workers=5) as executor:
    inspected_results = list(executor.map(lambda c: (c, inspect_domain(c["domain"])), found_candidates))

# 输出格式化结果表格
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
}

# 交互式挑选与应用
interactive_select() {
    if [ ! -f "$TMP_JSON" ]; then
        return
    fi

    local count
    count=$(python3 -c "import json; print(len(json.load(open('$TMP_JSON'))))" 2>/dev/null || echo 0)
    if [ "$count" -eq 0 ]; then
        return
    fi

    while true; do
        echo -e ""
        echo -ne "${BOLD}${YELLOW}请选择要使用的 SNI 域名编号 [1-${count}]，[r] 刷新，[f] 深度纯实时抓取，[q] 退出: ${PLAIN}"
        if [ -t 0 ]; then
            read -r choice
        else
            read -r choice || break
        fi

        case "$choice" in
            [1-5])
                if [ "$choice" -le "$count" ]; then
                    local selected_domain selected_ip selected_tls selected_alpn selected_latency selected_http
                    selected_domain=$(python3 -c "import json; data=json.load(open('$TMP_JSON')); print(data[$((choice-1))]['domain'])")
                    selected_ip=$(python3 -c "import json; data=json.load(open('$TMP_JSON')); print(data[$((choice-1))]['ip'])")
                    selected_tls=$(python3 -c "import json; data=json.load(open('$TMP_JSON')); print(data[$((choice-1))]['tls13'])")
                    selected_alpn=$(python3 -c "import json; data=json.load(open('$TMP_JSON')); print(data[$((choice-1))]['alpn'])")
                    selected_latency=$(python3 -c "import json; data=json.load(open('$TMP_JSON')); print(data[$((choice-1))]['latency_ms'])")
                    selected_http=$(python3 -c "import json; data=json.load(open('$TMP_JSON')); print(data[$((choice-1))]['http_code'])")

                    echo -e "\n${GREEN}======================================================================${PLAIN}"
                    echo -e "${BOLD}${GREEN}✔ 您已成功挑选 SNI 域名: ${CYAN}${selected_domain}${PLAIN}"
                    echo -e "${GREEN}======================================================================${PLAIN}"
                    echo -e " • ${BOLD}目标域名 (SNI):${PLAIN}       ${BOLD}${selected_domain}${PLAIN}"
                    echo -e " • ${BOLD}SSLLabs 评级:${PLAIN}         ${GREEN}A+${PLAIN}"
                    echo -e " • ${BOLD}CDN 架构:${PLAIN}             ${YELLOW}Akamai CDN${PLAIN}"
                    echo -e " • ${BOLD}解析 IP 地址:${PLAIN}         ${selected_ip}"
                    echo -e " • ${BOLD}TCP 握手延迟:${PLAIN}         ${selected_latency}"
                    echo -e " • ${BOLD}TLS 握手协议:${PLAIN}         ${GREEN}${selected_tls}${PLAIN}"
                    echo -e " • ${BOLD}ALPN 协商:${PLAIN}            ${GREEN}${selected_alpn}${PLAIN}"
                    echo -e " • ${BOLD}HTTP 返回码:${PLAIN}          ${selected_http}"
                    echo -e " • ${BOLD}推荐回落目标 (dest):${PLAIN}  ${selected_domain}:443"
                    echo -e "----------------------------------------------------------------------"
                    echo -e "${BOLD}Sing-box / Xray Reality 配置参数:${PLAIN}"
                    echo -e "  \"server_name\": \"${selected_domain}\","
                    echo -e "  \"dest\": \"${selected_domain}:443\""
                    echo -e "----------------------------------------------------------------------"
                    echo -e "${BOLD}VLESS 链接 Reality SNI 参数:${PLAIN}"
                    echo -e "  &sni=${selected_domain}"
                    echo -e "----------------------------------------------------------------------"

                    # 保存到持久化状态文件
                    echo "${selected_domain}" > "$LAST_CHOICE_FILE"
                    echo -e "${CYAN}[i] 选中的域名已保存至: ${LAST_CHOICE_FILE}${PLAIN}"

                    # 尝试复制到系统剪贴板 (如果有相应工具)
                    if command -v xclip &>/dev/null; then
                        echo -n "$selected_domain" | xclip -selection clipboard 2>/dev/null && \
                        echo -e "${GREEN}[i] 已复制域名到剪贴板 (xclip)${PLAIN}"
                    fi
                    echo -e "${GREEN}======================================================================${PLAIN}\n"
                    break
                else
                    echo -e "${RED}输入无效，请输入 1 到 ${count} 之间的数字。${PLAIN}"
                fi
                ;;
            r|R)
                print_banner
                fetch_and_select "fast"
                interactive_select
                break
                ;;
            f|F)
                print_banner
                echo -e "${YELLOW}[!] 开启深度纯实时抓取模式 (轮询直到从 SSLLabs 实时榜单抓满 5 个)...${PLAIN}"
                fetch_and_select "deep"
                interactive_select
                break
                ;;
            q|Q)
                echo -e "\n${CYAN}已退出。${PLAIN}\n"
                break
                ;;
            *)
                echo -e "${RED}输入无效，请重新输入。${PLAIN}"
                ;;
        esac
    done
}

# 主执行入口
main() {
    check_dependencies
    print_banner
    local mode="fast"
    if [ "$1" = "--deep" ] || [ "$1" = "-d" ]; then
        mode="deep"
    fi
    fetch_and_select "$mode"
    interactive_select
}

main "$@"
