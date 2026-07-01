#!/usr/bin/env bash
# ===========================================================
#  Realm 转发管理脚本
#  功能: 安装/CRUD转发规则/systemd持久化/双栈互转/性能参数优化
#  说明: 纯 TCP/UDP 转发，不涉及 TLS/WS
# ===========================================================
set -uo pipefail

# ----------------------- 基础路径 -----------------------
CONFIG_DIR="/etc/realm"
BIN="$CONFIG_DIR/realm"
RULES_FILE="$CONFIG_DIR/rules.json"
GLOBAL_FILE="$CONFIG_DIR/global.json"
CONFIG_FILE="$CONFIG_DIR/config.toml"
SERVICE_FILE="/etc/systemd/system/realm.service"

# ----------------------- 颜色输出 -----------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info(){ echo -e "${BLUE}[信息]${NC} $1"; }
ok(){ echo -e "${GREEN}[成功]${NC} $1"; }
warn(){ echo -e "${YELLOW}[警告]${NC} $1" >&2; }
err(){ echo -e "${RED}[错误]${NC} $1" >&2; }
press_enter(){ read -rp "按回车键继续..." _; }

require_root(){
  if [ "$(id -u)" -ne 0 ]; then
    err "请使用 root 权限运行此脚本 (例如: sudo bash $0)"
    exit 1
  fi
}

# ----------------------- 依赖安装 -----------------------
install_deps(){
  local need=()
  command -v curl >/dev/null 2>&1 || need+=(curl)
  command -v jq   >/dev/null 2>&1 || need+=(jq)
  command -v tar  >/dev/null 2>&1 || need+=(tar)
  command -v ss   >/dev/null 2>&1 || need+=(iproute2)
  [ ${#need[@]} -eq 0 ] && return 0
  info "正在安装依赖: ${need[*]}"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq "${need[@]}" >/dev/null 2>&1
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "${need[@]/iproute2/iproute}" >/dev/null 2>&1
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "${need[@]/iproute2/iproute}" >/dev/null 2>&1
  else
    err "未能识别系统包管理器，请手动安装: ${need[*]}"
    exit 1
  fi
  ok "依赖安装完成"
}

# ----------------------- 工具函数 -----------------------
valid_port(){ [[ $1 =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

is_port_used(){
  local port=$1 exclude_id=${2:-}
  if jq -e --argjson port "$port" --argjson excl "${exclude_id:-null}" \
      '[.[] | select(.listen_port==$port and .id != $excl)] | length > 0' \
      "$RULES_FILE" >/dev/null 2>&1; then
    return 0
  fi
  if command -v ss >/dev/null 2>&1 && ss -tuln 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"; then
    return 0
  fi
  return 1
}

random_port(){
  local p i
  for i in $(seq 1 50); do
    p=$(( (RANDOM % 55001) + 10000 ))
    if ! is_port_used "$p"; then echo "$p"; return 0; fi
  done
  err "未能找到可用随机端口，请手动指定"
  return 1
}

detect_family(){
  local addr=$1
  if [[ $addr =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    echo ipv4
  elif [[ $addr == *:* ]]; then
    echo ipv6
  else
    echo domain
  fi
}

format_remote(){
  local addr=$1 port=$2 fam
  fam=$(detect_family "$addr")
  if [ "$fam" = "ipv6" ]; then echo "[$addr]:$port"; else echo "$addr:$port"; fi
}

display_listen_string(){
  local fam=$1 ipc=$2 port=$3 cfam
  case $fam in
    ipv4) echo "0.0.0.0:$port" ;;
    ipv6) echo "[::]:$port" ;;
    dual) echo "0.0.0.0:$port + [::]:$port" ;;
    custom)
      cfam=$(detect_family "$ipc")
      if [ "$cfam" = "ipv6" ]; then echo "[$ipc]:$port"; else echo "$ipc:$port"; fi
      ;;
  esac
}

proto_display(){
  case $1 in
    tcp) echo "TCP" ;;
    udp) echo "UDP" ;;
    both) echo "TCP+UDP" ;;
  esac
}

# ----------------------- 交互采集函数(设置全局变量) -----------------------
collect_listen_family(){
  echo ""
  echo "请选择监听地址族:"
  echo "  1) IPv4  (0.0.0.0)"
  echo "  2) IPv6  ([::])"
  echo "  3) 双栈  (同时监听IPv4和IPv6)"
  echo "  4) 自定义IP"
  local c
  while true; do
    read -rp "请输入选项 [1-4]: " c
    case $c in
      1) LISTEN_FAMILY=ipv4; LISTEN_IP_CUSTOM=""; break ;;
      2) LISTEN_FAMILY=ipv6; LISTEN_IP_CUSTOM=""; break ;;
      3) LISTEN_FAMILY=dual; LISTEN_IP_CUSTOM=""; break ;;
      4) read -rp "请输入自定义监听IP: " LISTEN_IP_CUSTOM
         [ -z "$LISTEN_IP_CUSTOM" ] && { warn "IP不能为空"; continue; }
         LISTEN_FAMILY=custom; break ;;
      *) warn "无效输入" ;;
    esac
  done
}

collect_port(){
  local exclude_id=${1:-}
  echo ""
  echo "请选择监听端口方式:"
  echo "  1) 手动指定"
  echo "  2) 随机分配"
  local c
  while true; do
    read -rp "请输入选项 [1-2]: " c
    case $c in
      1)
        while true; do
          read -rp "请输入监听端口(1-65535): " LISTEN_PORT
          if ! valid_port "$LISTEN_PORT"; then warn "端口格式不正确"; continue; fi
          if is_port_used "$LISTEN_PORT" "$exclude_id"; then warn "该端口已被占用或已存在规则使用"; continue; fi
          break
        done
        break ;;
      2)
        LISTEN_PORT=$(random_port) || continue
        info "已分配随机端口: $LISTEN_PORT"
        break ;;
      *) warn "无效输入" ;;
    esac
  done
}

collect_protocol(){
  echo ""
  echo "请选择转发协议:"
  echo "  1) 仅TCP"
  echo "  2) 仅UDP"
  echo "  3) TCP+UDP"
  local c
  while true; do
    read -rp "请输入选项 [1-3]: " c
    case $c in
      1) PROTO=tcp; break ;;
      2) PROTO=udp; break ;;
      3) PROTO=both; break ;;
      *) warn "无效输入" ;;
    esac
  done
}

collect_target(){
  while true; do
    read -rp "请输入目标地址(IP或域名): " TARGET_ADDR
    [ -n "$TARGET_ADDR" ] && break
    warn "目标地址不能为空"
  done
  while true; do
    read -rp "请输入目标端口: " TARGET_PORT
    valid_port "$TARGET_PORT" && break
    warn "端口格式不正确"
  done
}

collect_remark(){
  read -rp "请输入备注(可留空): " REMARK
}

# ----------------------- 生成 config.toml -----------------------
write_endpoint(){
  local listen_addr=$1 remote=$2 netline=$3
  {
    echo "[[endpoints]]"
    echo "listen = \"$listen_addr\""
    echo "remote = \"$remote\""
    [ -n "$netline" ] && echo "$netline"
    echo ""
  } >> "$CONFIG_FILE.tmp"
}

generate_config(){
  local tcp_timeout udp_timeout tcp_keepalive tcp_keepalive_probe
  tcp_timeout=$(jq -r '.tcp_timeout' "$GLOBAL_FILE")
  udp_timeout=$(jq -r '.udp_timeout' "$GLOBAL_FILE")
  tcp_keepalive=$(jq -r '.tcp_keepalive' "$GLOBAL_FILE")
  tcp_keepalive_probe=$(jq -r '.tcp_keepalive_probe' "$GLOBAL_FILE")

  {
    echo "[log]"
    echo "level = \"warn\""
    echo ""
    echo "[network]"
    echo "tcp_timeout = $tcp_timeout"
    echo "udp_timeout = $udp_timeout"
    echo "tcp_keepalive = $tcp_keepalive"
    echo "tcp_keepalive_probe = $tcp_keepalive_probe"
    echo ""
  } > "$CONFIG_FILE.tmp"

  while read -r row; do
    [ -z "$row" ] && continue
    local fam ip port proto target tport remote netline cfam
    fam=$(echo "$row" | jq -r '.listen_family')
    ip=$(echo "$row" | jq -r '.listen_ip')
    port=$(echo "$row" | jq -r '.listen_port')
    proto=$(echo "$row" | jq -r '.protocol')
    target=$(echo "$row" | jq -r '.target')
    tport=$(echo "$row" | jq -r '.target_port')
    remote=$(format_remote "$target" "$tport")

    case $proto in
      tcp) netline="" ;;
      udp) netline="network = { no_tcp = true, use_udp = true }" ;;
      both) netline="network = { use_udp = true }" ;;
    esac

    case $fam in
      ipv4) write_endpoint "0.0.0.0:$port" "$remote" "$netline" ;;
      ipv6) write_endpoint "[::]:$port" "$remote" "$netline" ;;
      dual)
        write_endpoint "0.0.0.0:$port" "$remote" "$netline"
        write_endpoint "[::]:$port" "$remote" "$netline"
        ;;
      custom)
        cfam=$(detect_family "$ip")
        if [ "$cfam" = "ipv6" ]; then
          write_endpoint "[$ip]:$port" "$remote" "$netline"
        else
          write_endpoint "$ip:$port" "$remote" "$netline"
        fi
        ;;
    esac
  done < <(jq -c '.[] | select(.enabled==true)' "$RULES_FILE")

  mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
}

restart_service(){
  if [ ! -x "$BIN" ]; then
    warn "realm 尚未安装，跳过服务重启"
    return
  fi
  systemctl daemon-reload
  systemctl restart realm
  sleep 1
  if systemctl is-active --quiet realm; then
    ok "realm 服务运行正常"
  else
    err "realm 服务启动失败，请查看日志: journalctl -u realm -n 50 --no-pager"
  fi
}

# ----------------------- CRUD -----------------------
add_rule(){
  echo "===== 新增转发规则 ====="
  collect_listen_family
  collect_port
  collect_protocol
  collect_target
  collect_remark

  echo ""
  echo "—— 确认信息 ——"
  echo "监听: $(display_listen_string "$LISTEN_FAMILY" "$LISTEN_IP_CUSTOM" "$LISTEN_PORT")"
  echo "目标: $(format_remote "$TARGET_ADDR" "$TARGET_PORT")"
  echo "协议: $(proto_display "$PROTO")"
  echo "备注: ${REMARK:-无}"
  read -rp "确认添加? [y/N]: " yn
  if [[ ! $yn =~ ^[Yy]$ ]]; then warn "已取消"; press_enter; return; fi

  local id now rule
  id=$(jq '(map(.id) | max // 0) + 1' "$RULES_FILE")
  now=$(date '+%Y-%m-%d %H:%M:%S')
  rule=$(jq -n \
    --argjson id "$id" \
    --arg remark "$REMARK" \
    --arg family "$LISTEN_FAMILY" \
    --arg ip "$LISTEN_IP_CUSTOM" \
    --argjson port "$LISTEN_PORT" \
    --arg proto "$PROTO" \
    --arg target "$TARGET_ADDR" \
    --argjson tport "$TARGET_PORT" \
    --arg created "$now" \
    '{id:$id, remark:$remark, listen_family:$family, listen_ip:$ip, listen_port:$port,
      protocol:$proto, target:$target, target_port:$tport, enabled:true, created:$created}')
  jq --argjson r "$rule" '. + [$r]' "$RULES_FILE" > "$RULES_FILE.tmp" && mv "$RULES_FILE.tmp" "$RULES_FILE"

  generate_config
  restart_service
  ok "规则添加成功 (ID: $id)"
  press_enter
}

list_rules(){
  local count
  count=$(jq 'length' "$RULES_FILE")
  echo ""
  if [ "$count" -eq 0 ]; then
    warn "暂无转发规则"
    return
  fi
  printf "%-4s %-10s %-8s %-26s %-26s %-6s %-6s\n" "ID" "备注" "协议" "监听" "目标" "族" "状态"
  echo "------------------------------------------------------------------------------------"
  while read -r row; do
    [ -z "$row" ] && continue
    local id remark fam ip port proto target tport enabled listen_str target_str proto_str status
    id=$(echo "$row" | jq -r '.id')
    remark=$(echo "$row" | jq -r '.remark')
    fam=$(echo "$row" | jq -r '.listen_family')
    ip=$(echo "$row" | jq -r '.listen_ip')
    port=$(echo "$row" | jq -r '.listen_port')
    proto=$(echo "$row" | jq -r '.protocol')
    target=$(echo "$row" | jq -r '.target')
    tport=$(echo "$row" | jq -r '.target_port')
    enabled=$(echo "$row" | jq -r '.enabled')
    listen_str=$(display_listen_string "$fam" "$ip" "$port")
    target_str=$(format_remote "$target" "$tport")
    proto_str=$(proto_display "$proto")
    if [ "$enabled" = "true" ]; then status="启用"; else status="禁用"; fi
    printf "%-4s %-10s %-8s %-26s %-26s %-6s %-6s\n" "$id" "${remark:-无}" "$proto_str" "$listen_str" "$target_str" "$fam" "$status"
  done < <(jq -c '.[]' "$RULES_FILE")
  echo ""
}

edit_rule(){
  list_rules
  local count
  count=$(jq 'length' "$RULES_FILE")
  [ "$count" -eq 0 ] && { press_enter; return; }
  read -rp "请输入要修改的规则ID: " id
  if ! [[ $id =~ ^[0-9]+$ ]]; then err "请输入有效数字ID"; press_enter; return; fi
  if ! jq -e --argjson id "$id" 'any(.[]; .id==$id)' "$RULES_FILE" >/dev/null 2>&1; then
    err "ID不存在"; press_enter; return
  fi

  echo ""
  echo "修改哪一项?"
  echo "  1) 监听地址族/IP"
  echo "  2) 监听端口"
  echo "  3) 协议"
  echo "  4) 目标地址"
  echo "  5) 目标端口"
  echo "  6) 备注"
  echo "  0) 返回"
  read -rp "请输入选项: " c
  case $c in
    1)
      collect_listen_family
      jq --argjson id "$id" --arg fam "$LISTEN_FAMILY" --arg ip "$LISTEN_IP_CUSTOM" \
        'map(if .id==$id then .listen_family=$fam | .listen_ip=$ip else . end)' \
        "$RULES_FILE" > "$RULES_FILE.tmp" && mv "$RULES_FILE.tmp" "$RULES_FILE" ;;
    2)
      collect_port "$id"
      jq --argjson id "$id" --argjson port "$LISTEN_PORT" \
        'map(if .id==$id then .listen_port=$port else . end)' \
        "$RULES_FILE" > "$RULES_FILE.tmp" && mv "$RULES_FILE.tmp" "$RULES_FILE" ;;
    3)
      collect_protocol
      jq --argjson id "$id" --arg proto "$PROTO" \
        'map(if .id==$id then .protocol=$proto else . end)' \
        "$RULES_FILE" > "$RULES_FILE.tmp" && mv "$RULES_FILE.tmp" "$RULES_FILE" ;;
    4)
      read -rp "请输入新的目标地址: " newaddr
      [ -z "$newaddr" ] && { err "目标地址不能为空"; press_enter; return; }
      jq --argjson id "$id" --arg t "$newaddr" \
        'map(if .id==$id then .target=$t else . end)' \
        "$RULES_FILE" > "$RULES_FILE.tmp" && mv "$RULES_FILE.tmp" "$RULES_FILE" ;;
    5)
      read -rp "请输入新的目标端口: " newport
      valid_port "$newport" || { err "端口格式不正确"; press_enter; return; }
      jq --argjson id "$id" --argjson t "$newport" \
        'map(if .id==$id then .target_port=$t else . end)' \
        "$RULES_FILE" > "$RULES_FILE.tmp" && mv "$RULES_FILE.tmp" "$RULES_FILE" ;;
    6)
      read -rp "请输入新的备注: " newremark
      jq --argjson id "$id" --arg r "$newremark" \
        'map(if .id==$id then .remark=$r else . end)' \
        "$RULES_FILE" > "$RULES_FILE.tmp" && mv "$RULES_FILE.tmp" "$RULES_FILE" ;;
    0) return ;;
    *) warn "无效输入"; press_enter; return ;;
  esac

  generate_config
  restart_service
  ok "修改成功"
  press_enter
}

delete_rule(){
  list_rules
  local count
  count=$(jq 'length' "$RULES_FILE")
  [ "$count" -eq 0 ] && { press_enter; return; }
  read -rp "请输入要删除的规则ID(多个用空格分隔): " ids
  [ -z "$ids" ] && return
  read -rp "确认删除以上ID: $ids ? [y/N]: " yn
  if [[ ! $yn =~ ^[Yy]$ ]]; then warn "已取消"; press_enter; return; fi

  local idjson
  idjson=$(printf '%s\n' $ids | grep -oE '^[0-9]+$' | jq -R . | jq -s 'map(tonumber)')
  jq --argjson ids "$idjson" \
    'map(select((.id as $i | ($ids | index($i))) == null))' \
    "$RULES_FILE" > "$RULES_FILE.tmp" && mv "$RULES_FILE.tmp" "$RULES_FILE"

  generate_config
  restart_service
  ok "删除完成"
  press_enter
}

toggle_rule(){
  list_rules
  local count
  count=$(jq 'length' "$RULES_FILE")
  [ "$count" -eq 0 ] && { press_enter; return; }
  read -rp "请输入要切换启用/禁用的规则ID: " id
  if ! [[ $id =~ ^[0-9]+$ ]]; then err "请输入有效数字ID"; press_enter; return; fi
  if ! jq -e --argjson id "$id" 'any(.[]; .id==$id)' "$RULES_FILE" >/dev/null 2>&1; then
    err "ID不存在"; press_enter; return
  fi
  jq --argjson id "$id" 'map(if .id==$id then .enabled=(.enabled|not) else . end)' \
    "$RULES_FILE" > "$RULES_FILE.tmp" && mv "$RULES_FILE.tmp" "$RULES_FILE"

  generate_config
  restart_service
  ok "状态已切换"
  press_enter
}

# ----------------------- 全局性能参数 -----------------------
global_settings(){
  echo ""
  echo "===== 全局性能参数设置 ====="
  echo "当前配置:"
  jq . "$GLOBAL_FILE"
  echo ""
  echo "TCP空闲超时(tcp_timeout, 类似socat -T):"
  echo "  1) 宽松 60s"
  echo "  2) 标准 30s"
  echo "  3) 严格 10s"
  echo "  4) 自定义"
  local c tcp_timeout
  read -rp "请选择: " c
  case $c in
    1) tcp_timeout=60 ;;
    2) tcp_timeout=30 ;;
    3) tcp_timeout=10 ;;
    4) read -rp "请输入秒数: " tcp_timeout
       [[ $tcp_timeout =~ ^[0-9]+$ ]] || { err "输入无效"; press_enter; return; } ;;
    *) tcp_timeout=$(jq -r '.tcp_timeout' "$GLOBAL_FILE") ;;
  esac

  echo ""
  echo "UDP会话超时(udp_timeout):"
  echo "  1) 短连接 30s"
  echo "  2) 长连接/游戏 120s"
  echo "  3) 自定义"
  local c2 udp_timeout
  read -rp "请选择: " c2
  case $c2 in
    1) udp_timeout=30 ;;
    2) udp_timeout=120 ;;
    3) read -rp "请输入秒数: " udp_timeout
       [[ $udp_timeout =~ ^[0-9]+$ ]] || { err "输入无效"; press_enter; return; } ;;
    *) udp_timeout=$(jq -r '.udp_timeout' "$GLOBAL_FILE") ;;
  esac

  jq -n --argjson t "$tcp_timeout" --argjson u "$udp_timeout" --argjson k 30 --argjson kp 3 \
    '{tcp_timeout:$t, udp_timeout:$u, tcp_keepalive:$k, tcp_keepalive_probe:$kp}' \
    > "$GLOBAL_FILE.tmp" && mv "$GLOBAL_FILE.tmp" "$GLOBAL_FILE"

  generate_config
  restart_service
  ok "全局参数已更新"
  press_enter
}

# ----------------------- 安装 -----------------------
detect_arch(){
  local m
  m=$(uname -m)
  case $m in
    x86_64) echo "x86_64-unknown-linux-gnu" ;;
    aarch64|arm64) echo "aarch64-unknown-linux-gnu" ;;
    armv7l) echo "armv7-unknown-linux-gnueabihf" ;;
    *) err "不支持的架构: $m"; return 1 ;;
  esac
}

write_service_file(){
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=realm forwarding service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN -c $CONFIG_FILE
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

init_files(){
  mkdir -p "$CONFIG_DIR"
  [ -f "$RULES_FILE" ] || echo '[]' > "$RULES_FILE"
  if [ ! -f "$GLOBAL_FILE" ]; then
    cat > "$GLOBAL_FILE" <<EOF
{
  "tcp_timeout": 30,
  "udp_timeout": 60,
  "tcp_keepalive": 30,
  "tcp_keepalive_probe": 3
}
EOF
  fi
  [ -f "$CONFIG_FILE" ] || generate_config
}

install_realm(){
  mkdir -p "$CONFIG_DIR"
  local arch json tag pattern url tmpdir
  arch=$(detect_arch) || { press_enter; return 1; }
  info "正在获取最新版本信息..."
  json=$(curl -s https://api.github.com/repos/zhboner/realm/releases/latest)
  tag=$(echo "$json" | jq -r '.tag_name')
  if [ -z "$tag" ] || [ "$tag" = "null" ]; then
    err "获取版本信息失败，请检查网络"; press_enter; return 1
  fi
  pattern="realm-${arch}.tar.gz"
  url=$(echo "$json" | jq -r --arg p "$pattern" '.assets[] | select(.name==$p) | .browser_download_url')
  if [ -z "$url" ] || [ "$url" = "null" ]; then
    err "未找到匹配架构($arch)的发行包"; press_enter; return 1
  fi
  tmpdir=$(mktemp -d)
  info "下载 realm $tag ..."
  curl -sL -o "$tmpdir/realm.tar.gz" "$url"
  tar xzf "$tmpdir/realm.tar.gz" -C "$tmpdir"
  if [ ! -f "$tmpdir/realm" ]; then
    err "解压后未找到 realm 二进制"; rm -rf "$tmpdir"; press_enter; return 1
  fi
  install -m 755 "$tmpdir/realm" "$BIN"
  rm -rf "$tmpdir"

  init_files
  write_service_file
  systemctl daemon-reload
  systemctl enable realm >/dev/null 2>&1
  ok "realm $tag 安装完成"
  press_enter
}

# ----------------------- 服务管理 -----------------------
service_menu(){
  while true; do
    echo ""
    echo "===== 服务管理 ====="
    echo "  1) 启动"
    echo "  2) 停止"
    echo "  3) 重启"
    echo "  4) 状态"
    echo "  5) 查看日志(最近100行)"
    echo "  0) 返回"
    read -rp "请选择: " c
    case $c in
      1) systemctl start realm && ok "已启动" ;;
      2) systemctl stop realm && ok "已停止" ;;
      3) systemctl restart realm && ok "已重启" ;;
      4) systemctl status realm --no-pager ;;
      5) journalctl -u realm -n 100 --no-pager ;;
      0) return ;;
      *) warn "无效输入" ;;
    esac
    press_enter
  done
}

# ----------------------- 备份/恢复 -----------------------
backup_rules(){
  local out
  out="/root/realm-backup-$(date +%Y%m%d%H%M%S).tar.gz"
  tar czf "$out" -C "$CONFIG_DIR" rules.json global.json
  ok "已备份到: $out"
  press_enter
}

restore_rules(){
  read -rp "请输入备份文件完整路径: " path
  if [ ! -f "$path" ]; then err "文件不存在"; press_enter; return; fi
  local tmpdir
  tmpdir=$(mktemp -d)
  tar xzf "$path" -C "$tmpdir" 2>/dev/null
  if [ ! -f "$tmpdir/rules.json" ]; then
    err "备份文件格式不正确"; rm -rf "$tmpdir"; press_enter; return
  fi
  cp "$tmpdir/rules.json" "$RULES_FILE"
  [ -f "$tmpdir/global.json" ] && cp "$tmpdir/global.json" "$GLOBAL_FILE"
  rm -rf "$tmpdir"
  generate_config
  restart_service
  ok "恢复完成"
  press_enter
}

# ----------------------- 卸载 -----------------------
uninstall_realm(){
  read -rp "确认卸载 realm? 这将停止服务并删除程序 [y/N]: " yn
  if [[ ! $yn =~ ^[Yy]$ ]]; then warn "已取消"; press_enter; return; fi
  systemctl stop realm 2>/dev/null
  systemctl disable realm 2>/dev/null
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload 2>/dev/null
  read -rp "是否保留规则数据(rules.json)以便下次重装恢复? [Y/n]: " keep
  if [[ $keep =~ ^[Nn]$ ]]; then
    rm -rf "$CONFIG_DIR"
    ok "已完全卸载，规则数据已删除"
  else
    rm -f "$BIN" "$CONFIG_FILE"
    ok "已卸载，规则数据保留在 $RULES_FILE"
  fi
  press_enter
}

# ----------------------- 主菜单 -----------------------
main_menu(){
  while true; do
    clear
    echo "========================================"
    echo "         Realm 转发管理脚本"
    echo "========================================"
    if [ -x "$BIN" ]; then
      if systemctl is-active --quiet realm 2>/dev/null; then
        echo "  realm 状态: 运行中"
      else
        echo "  realm 状态: 未运行"
      fi
    else
      echo "  realm 状态: 未安装"
    fi
    echo "----------------------------------------"
    echo "  1) 新增转发规则"
    echo "  2) 查看所有规则"
    echo "  3) 修改规则"
    echo "  4) 删除规则"
    echo "  5) 启用/禁用规则"
    echo "  6) 全局性能参数设置"
    echo "  7) 服务管理"
    echo "  8) 安装/更新 realm"
    echo "  9) 备份规则"
    echo " 10) 恢复规则"
    echo " 11) 卸载"
    echo "  0) 退出"
    echo "========================================"
    read -rp "请输入选项: " choice
    case $choice in
      1) if [ ! -x "$BIN" ]; then warn "请先安装realm(选项8)"; press_enter; else add_rule; fi ;;
      2) list_rules; press_enter ;;
      3) if [ ! -x "$BIN" ]; then warn "请先安装realm(选项8)"; press_enter; else edit_rule; fi ;;
      4) delete_rule ;;
      5) toggle_rule ;;
      6) global_settings ;;
      7) service_menu ;;
      8) install_realm ;;
      9) backup_rules ;;
      10) restore_rules ;;
      11) uninstall_realm ;;
      0) exit 0 ;;
      *) warn "无效输入"; press_enter ;;
    esac
  done
}

# ----------------------- 入口 -----------------------
require_root
install_deps
init_files
main_menu
