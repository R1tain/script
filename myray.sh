#!/usr/bin/env bash
set -Eeuo pipefail

if [[ -z "${BASH_VERSION:-}" ]]; then
    printf '错误：请使用 bash 运行此脚本。\n' >&2
    exit 1
fi
if [[ "$EUID" -ne 0 ]]; then
    printf '错误：此脚本必须以 root 运行。\n' >&2
    exit 1
fi

RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; PLAIN='\033[0m'
log() {
    local level="$1" message="$2" color="$PLAIN"
    case "$level" in
        信息|INFO) color="$GREEN" ;;
        警告|WARN) color="$YELLOW" ;;
        错误|ERROR) color="$RED" ;;
    esac
    printf '%b[%s] [%s] %s%b\n' "$color" "$(date '+%F %T')" "$level" "$message" "$PLAIN"
}

readonly BIN_DIR=/usr/local/bin
readonly CONFIG_DIR=/etc/myray
readonly HTML_DIR=$CONFIG_DIR/html
readonly LOG_DIR=/var/log/myray-caddy
readonly UNIT_DIR=/etc/systemd/system
readonly LOGROTATE=/etc/logrotate.d/myray-caddy
readonly UUID=00000000-0000-0000-0000-000000000000
readonly CADDY_BIN=$BIN_DIR/mycaddy
readonly MYRAY_BIN=$BIN_DIR/myray
readonly CADDYFILE=$CONFIG_DIR/Caddyfile
readonly INDEX_FILE=$HTML_DIR/index.html
readonly RELAYS_FILE=$CONFIG_DIR/relays.conf
readonly SERVER_CONF=$CONFIG_DIR/server.conf
readonly MYRAY_UNIT=$UNIT_DIR/myray.service
readonly CADDY_UNIT=$UNIT_DIR/mycaddy.service

backup_dir=''
declare -A backup_seen=()
declare -a backup_paths=()
committed=0
rollback() {
    local rc=$? i path saved
    trap - ERR INT TERM
    if (( committed == 0 )) && [[ -n "$backup_dir" ]]; then
        log 错误 '操作失败，正在恢复原文件。'
        for ((i=${#backup_paths[@]}-1; i>=0; i--)); do
            path=${backup_paths[i]}; saved=$backup_dir$path
            rm -rf -- "$path"
            if [[ -e "$saved" || -L "$saved" ]]; then
                mkdir -p -- "$(dirname -- "$path")"
                cp -a -- "$saved" "$path"
            fi
        done
        systemctl daemon-reload >/dev/null 2>&1 || true
        if [[ -x "$CADDY_BIN" && -f "$CADDYFILE" ]]; then
            systemctl reload mycaddy.service >/dev/null 2>&1 || true
        fi
    fi
    [[ -z "$backup_dir" ]] || rm -rf -- "$backup_dir"
    exit "$rc"
}
trap rollback ERR INT TERM

backup_path() {
    local path="$1" saved
    [[ -n "${backup_seen[$path]+yes}" ]] && return 0
    backup_seen[$path]=1; backup_paths+=("$path")
    saved=$backup_dir$path
    mkdir -p -- "$(dirname -- "$saved")"
    if [[ -e "$path" || -L "$path" ]]; then cp -a -- "$path" "$saved"; fi
}

start_transaction() {
    backup_dir=$(mktemp -d /tmp/myray-caddy-backup.XXXXXX)
    backup_seen=(); backup_paths=(); committed=0
}
commit_transaction() {
    committed=1
    rm -rf -- "$backup_dir"
    backup_dir=''
}

is_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] &&
        python3 -c 'import ipaddress,sys; ipaddress.IPv4Address(sys.argv[1])' "$1" >/dev/null 2>&1
}
valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
valid_sni() { [[ "$1" =~ ^[A-Za-z0-9.-]+$ ]]; }

read_server_conf() {
    server_ip=''; myray_path=''
    if [[ -f "$SERVER_CONF" ]]; then
        while IFS='=' read -r key value; do
            case "$key" in
                SERVER_IP) server_ip=$value ;;
                MYRAY_PATH) myray_path=$value ;;
            esac
        done < "$SERVER_CONF"
    fi
}

detect_server_ip() {
    local candidate endpoint
    for endpoint in https://ip.sb https://api.ipify.org https://icanhazip.com; do
        candidate=$(curl -4fsS --connect-timeout 5 --max-time 10 "$endpoint" 2>/dev/null | tr -d '[:space:]' || true)
        if is_ipv4 "$candidate"; then printf '%s' "$candidate"; return 0; fi
    done
    return 1
}

write_caddyfile() {
    local ip="$1" path="$2" sni backend index=0
    cat > "$CADDYFILE" <<EOF
{
	default_bind 0.0.0.0
	admin 127.0.0.1:2019
	auto_https disable_redirects
	ocsp_stapling off
	layer4 {
		:443 {
EOF
    if [[ -f "$RELAYS_FILE" ]]; then
        while read -r sni backend extra || [[ -n "${sni:-}${backend:-}${extra:-}" ]]; do
            [[ -z "${sni:-}" || "$sni" == \#* ]] && continue
            [[ -n "${backend:-}" && -z "${extra:-}" ]] || { log 错误 "中转配置格式错误：$sni ${backend:-}"; return 1; }
            valid_sni "$sni" || { log 错误 "无效 SNI：$sni"; return 1; }
            local host=${backend%:*} port=${backend##*:}
            if [[ ! "$host" =~ ^[A-Za-z0-9.-]+$ ]] || ! valid_port "$port"; then
                log 错误 "无效后端：$backend"; return 1
            fi
            ((index+=1))
            cat >> "$CADDYFILE" <<EOF
			@relay$index tls sni $sni
			route @relay$index {
				proxy $backend
			}
EOF
        done < "$RELAYS_FILE"
    fi
    cat >> "$CADDYFILE" <<EOF
			@main tls sni $ip
			route @main {
				tls {
					connection_policy {
						alpn http/1.1
					}
				}
				proxy 127.0.0.1:8442
			}
			route {
				tls {
					connection_policy {
						alpn http/1.1
					}
				}
				proxy 127.0.0.1:8442
			}
		}
	}
}

(myray_site) {
	encode
	root * $HTML_DIR
	header -Server
	@myraypath path /$path
	handle @myraypath {
		reverse_proxy unix/@myray
	}
	handle {
		file_server
	}
	handle_errors {
		rewrite * /index.html
		file_server
	}
}

https://$ip:8443 {
	tls {
		protocols tls1.3 tls1.3
		issuer acme {
			profile shortlived
		}
	}
	import myray_site
}

http://:8442 {
	bind 127.0.0.1
	import myray_site
}
EOF
}

validate_and_reload() {
    "$CADDY_BIN" validate --config "$CADDYFILE"
    systemctl reload mycaddy.service
}

install_missing_deps() {
    local missing=() cmd
    for cmd in curl openssl basenc systemctl ss python3; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    ((${#missing[@]} == 0)) && return 0
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update; apt-get install -y curl openssl coreutils systemd iproute2 python3
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl openssl coreutils systemd iproute python3
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl openssl coreutils systemd iproute python3
    else
        log 错误 "缺少依赖：${missing[*]}，且未找到 apt/dnf/yum。"; return 1
    fi
    for cmd in "${missing[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || { log 错误 "依赖安装后仍缺少 $cmd。"; return 1; }
    done
}

install_myray() {
    local arch caddy_arch old_path myray_path server_ip tmp_dir candidate ipv6='' endpoint
    install_missing_deps
    read_server_conf
    old_path=''
    if [[ -f "$MYRAY_UNIT" ]]; then
        local old_exec
        old_exec=$(sed -n 's/^ExecStart=//p' "$MYRAY_UNIT" | head -n 1 || true)
        if [[ "$old_exec" =~ -path[[:space:]]+(/[^[:space:]\"]+) ]]; then old_path=${BASH_REMATCH[1]#/}; fi
    fi
    myray_path=${MYRAY_PATH:-${myray_path:-${old_path:-}}}
    [[ -n "$myray_path" ]] || myray_path=$(openssl rand 16 | basenc --base64url | tr -d '=')
    myray_path=${myray_path#/}
    [[ "$myray_path" =~ ^[A-Za-z0-9_-]+$ ]] || { log 错误 'MYRAY_PATH 只允许字母、数字、下划线和连字符。'; return 1; }
    server_ip=${MYRAY_SERVER_IP:-${server_ip:-}}
    [[ -n "$server_ip" ]] || server_ip=$(detect_server_ip) || { log 错误 '无法确定公网 IPv4，请设置 MYRAY_SERVER_IP。'; return 1; }
    is_ipv4 "$server_ip" || { log 错误 "无效公网 IPv4：$server_ip"; return 1; }
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) arch=amd64; caddy_arch=amd64 ;;
        aarch64|arm64) arch=arm64; caddy_arch=arm64 ;;
        *) log 错误 "不支持的架构：$arch"; return 1 ;;
    esac
    tmp_dir=$(mktemp -d)
    trap 'rm -rf -- "$tmp_dir"' RETURN
    log 信息 "下载 Caddy layer4 与 myray（$arch）。"
    curl -fL --retry 3 "https://raw.githubusercontent.com/R1tain/script/main/caddy_l4_linux_${caddy_arch}" -o "$tmp_dir/mycaddy"
    chmod 0755 "$tmp_dir/mycaddy"
    local modules
    modules=$("$tmp_dir/mycaddy" list-modules 2>/dev/null) || { log 错误 'mycaddy list-modules 执行失败。'; return 1; }
    grep -qx 'layer4' <<<"$modules" || { log 错误 '下载的 Caddy 未包含 layer4 模块。'; return 1; }
    curl -fL --retry 3 "https://raw.githubusercontent.com/bocduck/myray/refs/heads/main/linux_${arch}" -o "$tmp_dir/myray"
    chmod 0755 "$tmp_dir/myray"

    mkdir -p "$CONFIG_DIR" "$HTML_DIR" "$LOG_DIR" "$BIN_DIR" "$UNIT_DIR" /etc/logrotate.d
    start_transaction
    for path in "$MYRAY_BIN" "$CADDY_BIN" "$CADDYFILE" "$INDEX_FILE" "$MYRAY_UNIT" "$CADDY_UNIT" "$LOGROTATE" "$RELAYS_FILE" "$SERVER_CONF"; do backup_path "$path"; done
    install -m 0755 "$tmp_dir/myray" "$MYRAY_BIN"
    install -m 0755 "$tmp_dir/mycaddy" "$CADDY_BIN"
    printf 'SERVER_IP=%s\nMYRAY_PATH=%s\n' "$server_ip" "$myray_path" > "$SERVER_CONF"
    [[ -e "$RELAYS_FILE" ]] || : > "$RELAYS_FILE"
    write_caddyfile "$server_ip" "$myray_path"
    cat > "$INDEX_FILE" <<'EOF'
<!DOCTYPE html><html><head><title>Welcome</title></head><body><h1>Welcome</h1></body></html>
EOF
    cat > "$LOGROTATE" <<EOF
$LOG_DIR/caddy*.log {
    rotate 2
    size 5M
    missingok
    notifempty
    compress
    copytruncate
}
EOF
    cat > "$MYRAY_UNIT" <<EOF
[Unit]
Description=myray VLESS HTTPUpgrade server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$CONFIG_DIR
ExecStart=$MYRAY_BIN -s unix/@myray -path /$myray_path
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF
    cat > "$CADDY_UNIT" <<EOF
[Unit]
Description=Caddy layer4 and myray HTTPS site
After=network.target myray.service
Requires=myray.service

[Service]
Type=simple
User=root
WorkingDirectory=$CONFIG_DIR
ExecStart=$CADDY_BIN run --config $CADDYFILE
ExecReload=$CADDY_BIN reload --config $CADDYFILE --force
Restart=on-failure
RestartSec=3s
StandardOutput=append:$LOG_DIR/caddy.log
StandardError=append:$LOG_DIR/caddy-error.log

[Install]
WantedBy=multi-user.target
EOF
    "$CADDY_BIN" validate --config "$CADDYFILE"
    systemctl daemon-reload
    systemctl enable myray.service mycaddy.service
    systemctl restart myray.service
    systemctl restart mycaddy.service
    sleep 2
    systemctl is-active --quiet myray.service
    systemctl is-active --quiet mycaddy.service
    for port in 443 8443 8442; do
        ss -lnt "( sport = :$port )" | awk 'NR > 1 && /LISTEN/ { found=1 } END { exit !found }'
    done
    commit_transaction
    trap - RETURN
    rm -rf -- "$tmp_dir"
    for endpoint in https://api6.ipify.org https://icanhazip.com; do
        candidate=$(curl -6fsS --connect-timeout 4 --max-time 8 "$endpoint" 2>/dev/null | tr -d '[:space:]' || true)
        if [[ "$candidate" == *:* ]] && python3 -c 'import ipaddress,sys; ipaddress.IPv6Address(sys.argv[1])' "$candidate" >/dev/null 2>&1; then ipv6=$candidate; break; fi
    done
    log 信息 '安装成功。'
    log 信息 "IPv4 链接：vless://$UUID@$server_ip:443?security=tls&type=httpupgrade&path=%2F$myray_path&sni=$server_ip&udp=0"
    [[ -z "$ipv6" ]] || log 信息 "IPv6 链接：vless://$UUID@[$ipv6]:443?security=tls&type=httpupgrade&path=%2F$myray_path&sni=$server_ip&udp=0"
}

ensure_relay_ready() {
    if [[ ! -x "$CADDY_BIN" || ! -f "$CADDYFILE" || ! -f "$SERVER_CONF" ]]; then
        log 警告 '尚未安装，请先安装 myray。'; return 1
    fi
    read_server_conf
    is_ipv4 "$server_ip" || { log 错误 'server.conf 中 SERVER_IP 无效。'; return 1; }
    [[ "$myray_path" =~ ^[A-Za-z0-9_-]+$ ]] || { log 错误 'server.conf 中 MYRAY_PATH 无效。'; return 1; }
}

show_relays() {
    local i=0 sni backend extra
    printf '%-6s %-32s %s\n' '序号' 'SNI' '后端'
    if [[ -f "$RELAYS_FILE" ]]; then
        while read -r sni backend extra || [[ -n "${sni:-}${backend:-}${extra:-}" ]]; do
            [[ -n "${sni:-}" ]] || continue
            ((i+=1)); printf '%-6s %-32s %s\n' "$i" "$sni" "${backend:-}"
        done < "$RELAYS_FILE"
    fi
    (( i > 0 )) || printf '（暂无中转）\n'
}

update_relays() {
    local mode="$1" sni backend choice tmp_file count=0 line
    ensure_relay_ready || return 1
    tmp_file=$(mktemp "$CONFIG_DIR/relays.XXXXXX")
    cp -f -- "$RELAYS_FILE" "$tmp_file" 2>/dev/null || :
    if [[ "$mode" == add ]]; then
        sni=$(read_input '输入 SNI：')
        backend=$(read_input '输入后端 IP:PORT：')
        valid_sni "$sni" || { rm -f "$tmp_file"; log 错误 'SNI 格式无效。'; return 1; }
        [[ "$backend" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$ ]] || { rm -f "$tmp_file"; log 错误 '后端必须是 IP:PORT。'; return 1; }
        local host=${backend%:*} port=${backend##*:}
        if ! is_ipv4 "$host" || ! valid_port "$port"; then
            rm -f "$tmp_file"; log 错误 '后端 IP 或端口无效。'; return 1
        fi
        if awk -v sni="$sni" '$1 == sni { found=1 } END { exit !found }' "$tmp_file"; then
            rm -f "$tmp_file"; log 错误 '该 SNI 已存在。'; return 1
        fi
        printf '%s %s\n' "$sni" "$backend" >> "$tmp_file"
    else
        show_relays
        choice=$(read_input '输入要删除的序号：')
        if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 )); then
            rm -f "$tmp_file"; log 错误 '序号无效。'; return 1
        fi
        : > "$tmp_file"
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -n "$line" ]] || continue
            ((count+=1))
            (( count == choice )) || printf '%s\n' "$line" >> "$tmp_file"
        done < "$RELAYS_FILE"
        (( choice <= count )) || { rm -f "$tmp_file"; log 错误 '序号超出范围。'; return 1; }
    fi
    start_transaction
    backup_path "$RELAYS_FILE"; backup_path "$CADDYFILE"
    cp "$tmp_file" "$RELAYS_FILE"; rm -f "$tmp_file"
    write_caddyfile "$server_ip" "$myray_path"
    validate_and_reload
    commit_transaction
    log 信息 '中转配置已更新。'
}

uninstall() {
    log 信息 '开始卸载 myray/Caddy。'
    systemctl disable --now myray.service mycaddy.service >/dev/null 2>&1 || true
    rm -f -- "$MYRAY_BIN" "$CADDY_BIN" "$MYRAY_UNIT" "$CADDY_UNIT" "$LOGROTATE"
    rm -rf -- "$CONFIG_DIR" "$LOG_DIR"
    systemctl daemon-reload
    log 信息 '卸载完成。'
}

service_status() {
    for service in myray mycaddy; do
        if systemctl is-active --quiet "$service.service"; then log 信息 "$service：active"; else log 警告 "$service：inactive"; fi
    done
    printf '\n监听端口：\n'
    ss -lntp '( sport = :80 or sport = :443 or sport = :8443 )' || true
    printf '\n最近日志：\n'
    journalctl -u myray.service -u mycaddy.service --no-pager -n 20 || true
}

pause_menu() {
    if [[ -t 0 ]]; then read -r -n 1 -s -p '按任意键返回菜单...' || true; printf '\n'; fi
}
read_input() {
    local prompt="$1" var
    read -r -p "$prompt" var || exit 0
    printf '%s' "$var"
}
show_menu() {
    local choice
    while true; do
        printf '\n%smyray / Caddy 管理%s\n' "$GREEN" "$PLAIN"
        printf '1) 安装 / 更新 myray\n2) 添加中转\n3) 删除中转\n4) 查看中转列表\n5) 卸载\n6) 服务状态\n0) 退出\n'
        read -r -p '请选择 [0-6]：' choice || exit 0
        case "$choice" in
            1) install_myray ;;
            2) update_relays add ;;
            3) update_relays delete ;;
            4) show_relays ;;
            5) uninstall ;;
            6) service_status ;;
            0) return 0 ;;
            *) log 错误 '无效选项。' ;;
        esac
        pause_menu
    done
}

if [[ "${MYRAY_AUTO:-}" == 1 ]]; then
    install_myray
else
    show_menu
fi
