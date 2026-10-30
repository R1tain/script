#!/bin/sh
# POSIX sh IPv4/IPv6 端口转发管理
CONFIG_DIR=/etc/iptables-fwd
RULES_FILE=$CONFIG_DIR/rules.conf
GLOBAL_FILE=$CONFIG_DIR/config.conf
BIN_LINK=/usr/local/bin/iptables-fwd
SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")
SERVICE_FILE=/etc/systemd/system/iptables-fwd.service
OPENRC_FILE=/etc/init.d/iptables-fwd
SYSCTL_FILE=/etc/sysctl.d/99-iptables-forward.conf
IPV4_NAT_OK=0
IPV6_NAT_OK=0
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { printf '%b[信息]%b %s\n' "$BLUE" "$NC" "$1"; }
ok() { printf '%b[成功]%b %s\n' "$GREEN" "$NC" "$1"; }
warn() { printf '%b[警告]%b %s\n' "$YELLOW" "$NC" "$1" >&2; }
err() { printf '%b[错误]%b %s\n' "$RED" "$NC" "$1" >&2; }
press_enter() { printf '按回车键继续...'; read -r _press; }
require_root() { [ "$(id -u)" -eq 0 ] || { err '请使用 root 权限运行此脚本'; return 1; }; }
migrate_rules_if_needed() {
  [ -f "$RULES_FILE" ] || return 0
  _is_v1=0
  if grep -q '^# id:proto:' "$RULES_FILE" 2>/dev/null; then _is_v1=1
  elif grep -q '^[0-9][0-9]*:' "$RULES_FILE" 2>/dev/null && ! grep -q '|' "$RULES_FILE" 2>/dev/null; then _is_v1=1; fi
  [ "$_is_v1" -eq 1 ] || return 0
  info '检测到 v1 规则格式，正在升级为 v2 双栈格式...'
  _bak=$CONFIG_DIR/rules.conf.v1.bak.$(date +%Y%m%d%H%M%S)
  cp -p "$RULES_FILE" "$_bak" || { err '备份旧规则失败，终止迁移'; return 1; }
  _tmp=$RULES_FILE.migrate.$$
  printf '# id|family|proto|listen_port|target_addr|target_port|enabled|remark\n' > "$_tmp" || return 1
  while IFS=: read -r _id _proto _lp _addr _tp _en _remark || [ -n "$_id" ]; do
    case $_id in ''|\#*) continue;; esac
    case $_en in 0|1) ;; *) continue;; esac
    printf '%s|v4|%s|%s|%s|%s|%s|%s\n' "$_id" "$_proto" "$_lp" "$_addr" "$_tp" "$_en" "$_remark" >> "$_tmp" || { rm -f "$_tmp"; return 1; }
  done < "$RULES_FILE"
  _invalid=$(awk -F'|' '/^[^#]/ {if(NF!=8 || $1 !~ /^[0-9]+$/ || $2!="v4" || $3!~/^(tcp|udp|both)$/ || $4<1 || $4>65535 || $6<1 || $6>65535 || $7!~/^[01]$/) print NR}' "$_tmp")
  if [ -n "$_invalid" ]; then err '规则迁移校验失败，保留旧配置并回滚'; cp -p "$_bak" "$RULES_FILE"; rm -f "$_tmp"; return 1; fi
  mv -f "$_tmp" "$RULES_FILE" || { cp -p "$_bak" "$RULES_FILE"; rm -f "$_tmp"; return 1; }
  ok "规则库已升级，原配置备份至 $_bak"
}
init_files() {
  mkdir -p "$CONFIG_DIR" "$CONFIG_DIR/backups" || return 1
  [ -f "$RULES_FILE" ] || printf '# id|family|proto|listen_port|target_addr|target_port|enabled|remark\n' > "$RULES_FILE" || return 1
  migrate_rules_if_needed || return 1
  [ -f "$GLOBAL_FILE" ] || printf 'tcp_timeout=1800\nudp_timeout=60\n' > "$GLOBAL_FILE"
}
valid_port() { case $1 in ''|*[!0-9]*) return 1;; esac; [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null; }
valid_id() { case $1 in ''|*[!0-9]*) return 1;; *) return 0;; esac; }
detect_addr_type() { case $1 in *:*) printf ipv6;; *[!0-9.]*|'') printf domain;; *.*.*.*) printf ipv4;; *) printf domain;; esac; }
valid_ipv4() {
  printf '%s\n' "$1" | awk -F. 'NF==4 {for(i=1;i<=4;i++) if($i !~ /^[0-9]+$/ || $i>255) exit 1; ok=1} END{if(!ok) exit 1}'
}
valid_ipv6() {
  _ip=$1; [ -n "$_ip" ] || return 1
  case $_ip in *[!0-9a-fA-F:]*) return 1;; *:::*) return 1;; esac
  _colons=$(printf '%s' "$_ip" | sed 's/[^:]//g')
  _double=$(printf '%s' "$_ip" | awk '{print gsub(/::/,"&")}')
  [ "$_double" -le 1 ] 2>/dev/null || return 1
  if [ "$_double" -eq 0 ]; then [ "${#_colons}" -eq 7 ] || return 1; else [ "${#_colons}" -le 7 ] || return 1; fi
  _segments=$(printf '%s\n' "$_ip" | awk -F: '{n=0; for(i=1;i<=NF;i++) if($i!="") {if(length($i)>4) exit 1; n++} print n}') || return 1
  if [ "$_double" -eq 0 ]; then [ "$_segments" -eq 8 ]; else [ "$_segments" -lt 8 ]; fi
}
valid_domain() { case $1 in ''|*[!A-Za-z0-9.-]*|*..*|.*|*.) return 1;; esac; return 0; }
valid_addr_for_family() {
  _fam=$1 _addr=$2 _type=$(detect_addr_type "$2")
  case $_fam:$_type in
    v4:ipv4) valid_ipv4 "$_addr";; v4:domain|v6:domain|dual:domain) valid_domain "$_addr";;
    v6:ipv6) valid_ipv6 "$_addr";; *) return 1;;
  esac
}
resolve_ipv4() {
  _addr=$1
  case $(detect_addr_type "$_addr") in
    ipv4) valid_ipv4 "$_addr" || return 1; printf '%s\n' "$_addr";;
    domain)
      _ip=
      if command -v nslookup >/dev/null 2>&1; then _ip=$(nslookup "$_addr" 2>/dev/null | awk '/^Address[[:space:]]+[0-9]+:?[[:space:]]/ {print $NF}' | awk 'index($0,":")==0{v=$0} END{print v}'); fi
      if [ -z "$_ip" ] && command -v getent >/dev/null 2>&1; then _ip=$(getent ahostsv4 "$_addr" 2>/dev/null | awk 'NR==1{print $1}'); fi
      if [ -z "$_ip" ] && command -v ping >/dev/null 2>&1; then _ip=$(ping -c 1 -W 2 "$_addr" 2>/dev/null | sed -n 's/.*(\([0-9.][0-9.]*\)).*/\1/p' | sed -n '1p'); fi
      [ -n "$_ip" ] || return 1; printf '%s\n' "$_ip";; *) return 1;;
  esac
}
resolve_ipv6() {
  _addr=$1
  case $(detect_addr_type "$_addr") in
    ipv6) valid_ipv6 "$_addr" || return 1; printf '%s\n' "$_addr";;
    domain)
      _ip=
      if command -v nslookup >/dev/null 2>&1; then _ip=$(nslookup -type=AAAA "$_addr" 2>/dev/null | awk '/^Address[[:space:]]+[0-9]+:?[[:space:]]/ {print $NF}' | awk 'index($0,":")>0{v=$0} END{print v}'); fi
      if [ -z "$_ip" ] && command -v getent >/dev/null 2>&1; then _ip=$(getent ahostsv6 "$_addr" 2>/dev/null | awk 'index($1,":")>0 {print $1; exit}'); fi
      if [ -z "$_ip" ]; then
        if command -v ping >/dev/null 2>&1 && ping -6 -c 1 -W 2 "$_addr" >/dev/null 2>&1; then _ip=$(ping -6 -c 1 -W 2 "$_addr" 2>/dev/null | sed -n 's/.*(\([0-9a-fA-F:]*\)).*/\1/p' | sed -n '1p')
        elif command -v ping6 >/dev/null 2>&1; then _ip=$(ping6 -c 1 -W 2 "$_addr" 2>/dev/null | sed -n 's/.*(\([0-9a-fA-F:]*\)).*/\1/p' | sed -n '1p'); fi
      fi
      [ -n "$_ip" ] && valid_ipv6 "$_ip" || return 1; printf '%s\n' "$_ip";; *) return 1;;
  esac
}
local_port_used() {
  _fam=$1 _proto=$2 _port=$3
  if command -v ss >/dev/null 2>&1; then
    case $_fam in
      v4) ss -tuln 2>/dev/null | awk -v p="$_port" -v pr="$_proto" '$1 ~ pr && $5 ~ /^[0-9.]+:/ && $5 ~ (":" p "$|\\*:" p "$ ") {f=1} END{exit !f}';;
      v6) ss -tuln 2>/dev/null | awk -v p="$_port" -v pr="$_proto" '$1 ~ pr && ($5 ~ /\[/ || $5 ~ /^\*:/ || $5 ~ /^:::/) && $5 ~ (":" p "$|\\*:" p "$ ") {f=1} END{exit !f}';;
      dual) ss -tuln 2>/dev/null | awk -v p="$_port" -v pr="$_proto" '$1 ~ pr && $5 ~ (":" p "$|\\*:" p "$ ") {f=1} END{exit !f}';;
    esac
  elif command -v netstat >/dev/null 2>&1; then
    case $_fam in
      v4) netstat -tuln 2>/dev/null | awk -v p="$_port" -v pr="$_proto" '$1 ~ pr && $4 ~ /^[0-9.]+:/ && $4 ~ (":" p "$") {f=1} END{exit !f}';;
      v6) netstat -tuln 2>/dev/null | awk -v p="$_port" -v pr="$_proto" '$1 ~ pr && ($1 ~ /6$/ || $4 ~ /\[/) && $4 ~ (":" p "$|\\*:" p "$ ") {f=1} END{exit !f}';;
      dual) netstat -tuln 2>/dev/null | awk -v p="$_port" -v pr="$_proto" '$1 ~ pr && $4 ~ (":" p "$|\\*:" p "$ ") {f=1} END{exit !f}';;
    esac
  else return 1; fi
}
rule_conflict() {
  _nf=$1 _np=$2 _port=$3 _ex=${4:-}
  while IFS='|' read -r _id _fam _proto _lp _addr _tp _enabled _remark; do
    [ "$_id" = "$_ex" ] && continue
    if [ "$_enabled" != 1 ] || [ "$_lp" != "$_port" ]; then continue; fi
    case $_nf:$_fam in v4:v6|v6:v4) continue;; esac
    case "$_np:$_proto" in tcp:udp|udp:tcp) :;; *) return 0;; esac
  done < "$RULES_FILE"
  return 1
}
port_available() {
  _fam=$1 _proto=$2 _port=$3 _ex=${4:-}; case $_proto in both) _protos='tcp udp';; *) _protos=$_proto;; esac
  for _p in $_protos; do rule_conflict "$_fam" "$_p" "$_port" "$_ex" && return 1; local_port_used "$_fam" "$_p" "$_port" && return 1; done
  return 0
}
random_port() {
  _fam=$1 _proto=$2 _ex=${3:-} _i=0
  while [ "$_i" -lt 50 ]; do
    if [ -r /dev/urandom ]; then _port=$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | awk '{print ($1%55536)+10000}'); else _port=$(awk -v s="$(date +%s)$$$_i" 'BEGIN{srand(s);print int(rand()*55536)+10000}'); fi
    if port_available "$_fam" "$_proto" "$_port" "$_ex"; then printf '%s\n' "$_port"; return 0; fi
    _i=$((_i+1))
  done
  err '未能找到可用随机端口'; return 1
}
probe_kernel_features() {
  if command -v modprobe >/dev/null 2>&1 && [ -d "/lib/modules/$(uname -r 2>/dev/null)" ]; then
    modprobe ip_tables >/dev/null 2>&1 || :; modprobe iptable_nat >/dev/null 2>&1 || :; modprobe ip6_tables >/dev/null 2>&1 || :; modprobe ip6table_nat >/dev/null 2>&1 || :; modprobe nf_nat >/dev/null 2>&1 || :; modprobe nf_conntrack >/dev/null 2>&1 || :
  fi
  if iptables -t nat -L -n >/dev/null 2>&1; then IPV4_NAT_OK=1; else IPV4_NAT_OK=0; err '当前内核不支持 iptables nat 表，基础网络环境不满足要求'; return 1; fi
  if command -v ip6tables >/dev/null 2>&1 && ip6tables -t nat -L -n >/dev/null 2>&1; then IPV6_NAT_OK=1; else IPV6_NAT_OK=0; warn '当前环境不支持 ip6tables nat 表，已降级为 IPv4-only'; warn 'LXC 宿主可检查 modprobe ip6table_nat、modprobe nf_nat 及容器 iptables 权限'; fi
  return 0
}
ensure_chains() {
  iptables -t nat -N FWD_PREROUTING 2>/dev/null || :; iptables -t nat -N FWD_OUTPUT 2>/dev/null || :; iptables -t nat -N FWD_POSTROUTING 2>/dev/null || :; iptables -t filter -N FWD_FORWARD 2>/dev/null || :
  iptables -t nat -C PREROUTING -j FWD_PREROUTING 2>/dev/null || iptables -t nat -I PREROUTING 1 -j FWD_PREROUTING || return 1
  iptables -t nat -C OUTPUT -j FWD_OUTPUT 2>/dev/null || iptables -t nat -I OUTPUT 1 -j FWD_OUTPUT || return 1
  iptables -t nat -C POSTROUTING -j FWD_POSTROUTING 2>/dev/null || iptables -t nat -I POSTROUTING 1 -j FWD_POSTROUTING || return 1
  iptables -t filter -C FORWARD -j FWD_FORWARD 2>/dev/null || iptables -t filter -I FORWARD 1 -j FWD_FORWARD || return 1
}
ensure_chains6() {
  ip6tables -t nat -N FWD6_PREROUTING 2>/dev/null || :; ip6tables -t nat -N FWD6_OUTPUT 2>/dev/null || :; ip6tables -t nat -N FWD6_POSTROUTING 2>/dev/null || :; ip6tables -t filter -N FWD6_FORWARD 2>/dev/null || :
  ip6tables -t nat -C PREROUTING -j FWD6_PREROUTING 2>/dev/null || ip6tables -t nat -I PREROUTING 1 -j FWD6_PREROUTING || return 1
  ip6tables -t nat -C OUTPUT -j FWD6_OUTPUT 2>/dev/null || ip6tables -t nat -I OUTPUT 1 -j FWD6_OUTPUT || return 1
  ip6tables -t nat -C POSTROUTING -j FWD6_POSTROUTING 2>/dev/null || ip6tables -t nat -I POSTROUTING 1 -j FWD6_POSTROUTING || return 1
  ip6tables -t filter -C FORWARD -j FWD6_FORWARD 2>/dev/null || ip6tables -t filter -I FORWARD 1 -j FWD6_FORWARD || return 1
}
enable_ip_forward_runtime() {
  if command -v sysctl >/dev/null 2>&1; then
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || :; sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || :; sysctl -w net.ipv6.conf.all.accept_ra=2 >/dev/null 2>&1 || :; sysctl -w net.ipv6.conf.default.accept_ra=2 >/dev/null 2>&1 || :
  fi
  printf '1' > /proc/sys/net/ipv4/ip_forward 2>/dev/null || :; printf '1' > /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || :; printf '2' > /proc/sys/net/ipv6/conf/all/accept_ra 2>/dev/null || :; printf '2' > /proc/sys/net/ipv6/conf/default/accept_ra 2>/dev/null || :
}
persist_ip_forward() {
  mkdir -p /etc/sysctl.d || return 1
  printf 'net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1\nnet.ipv6.conf.all.accept_ra = 2\nnet.ipv6.conf.default.accept_ra = 2\n' > "$SYSCTL_FILE" || return 1
  if command -v rc-update >/dev/null 2>&1; then rc-update add sysctl boot >/dev/null 2>&1 || :; fi
  if command -v sysctl >/dev/null 2>&1; then sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || :; fi
}
apply_rules() {
  require_root || return 1; init_files || return 1; probe_kernel_features || return 1; ensure_chains || return 1; enable_ip_forward_runtime
  iptables -t nat -F FWD_PREROUTING && iptables -t nat -F FWD_OUTPUT && iptables -t nat -F FWD_POSTROUTING && iptables -t filter -F FWD_FORWARD || return 1
  iptables -t filter -A FWD_FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT || return 1
  if [ "$IPV6_NAT_OK" -eq 1 ]; then ensure_chains6 || return 1; ip6tables -t nat -F FWD6_PREROUTING && ip6tables -t nat -F FWD6_OUTPUT && ip6tables -t nat -F FWD6_POSTROUTING && ip6tables -t filter -F FWD6_FORWARD || return 1; ip6tables -t filter -A FWD6_FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT || return 1; fi
  while IFS='|' read -r _id _fam _proto _lp _addr _tp _enabled _remark; do
    case $_id in ''|\#*) continue;; esac; [ "$_enabled" = 1 ] || continue
    case $_proto in both) _protos='tcp udp';; tcp|udp) _protos=$_proto;; *) warn "规则 $_id 协议无效"; continue;; esac
    _target4='' _target6=''
    case $_fam in
      v4) _target4=$(resolve_ipv4 "$_addr") || { warn "规则 $_id 目标 $_addr IPv4 解析失败，已跳过"; continue; };;
      v6) [ "$IPV6_NAT_OK" -eq 1 ] || { warn "规则 $_id IPv6 NAT 不可用，已跳过"; continue; }; _target6=$(resolve_ipv6 "$_addr") || { warn "规则 ID [$_id] 目标域名 [$_addr] 无 AAAA 记录或解析失败，跳过 IPv6 转发"; continue; };;
      dual)
        _target4=$(resolve_ipv4 "$_addr") || :
        if [ "$IPV6_NAT_OK" -eq 1 ]; then _target6=$(resolve_ipv6 "$_addr") || :; fi
        [ -n "$_target4" ] || warn "规则 $_id 目标 $_addr 无 A 记录，跳过 IPv4 转发"
        if [ "$IPV6_NAT_OK" -eq 0 ]; then warn "规则 $_id IPv6 NAT 不可用，跳过双栈规则的 IPv6 部分"; elif [ -z "$_target6" ]; then warn "规则 $_id 目标 $_addr 无 AAAA 记录，跳过 IPv6 转发"; fi
        [ -n "$_target4" ] || [ -n "$_target6" ] || { warn "规则 $_id 双栈目标解析均失败，已跳过"; continue; };;
      *) warn "规则 $_id 地址族无效"; continue;;
    esac
    for _p in $_protos; do
      if [ -n "$_target4" ]; then
        iptables -t nat -A FWD_PREROUTING -p "$_p" --dport "$_lp" -j DNAT --to-destination "$_target4:$_tp" || return 1
        iptables -t nat -A FWD_OUTPUT -p "$_p" -d 127.0.0.1 --dport "$_lp" -j DNAT --to-destination "$_target4:$_tp" || return 1
        iptables -t filter -A FWD_FORWARD -p "$_p" -d "$_target4" --dport "$_tp" -j ACCEPT || return 1
        iptables -t nat -A FWD_POSTROUTING -p "$_p" -d "$_target4" --dport "$_tp" -j MASQUERADE || return 1
      fi
      if [ -n "$_target6" ]; then
        ip6tables -t nat -A FWD6_PREROUTING -p "$_p" --dport "$_lp" -j DNAT --to-destination "[$_target6]:$_tp" || return 1
        ip6tables -t nat -A FWD6_OUTPUT -p "$_p" -d ::1 --dport "$_lp" -j DNAT --to-destination "[$_target6]:$_tp" || return 1
        ip6tables -t filter -A FWD6_FORWARD -p "$_p" -d "$_target6" --dport "$_tp" -j ACCEPT || return 1
        ip6tables -t nat -A FWD6_POSTROUTING -p "$_p" -d "$_target6" --dport "$_tp" -j MASQUERADE || return 1
      fi
    done
  done < "$RULES_FILE"
  return 0
}
flush_rules() {
  require_root || return 1
  iptables -t nat -F FWD_PREROUTING 2>/dev/null || :; iptables -t nat -F FWD_OUTPUT 2>/dev/null || :; iptables -t nat -F FWD_POSTROUTING 2>/dev/null || :; iptables -t filter -F FWD_FORWARD 2>/dev/null || :
  iptables -t nat -D PREROUTING -j FWD_PREROUTING 2>/dev/null || :; iptables -t nat -D OUTPUT -j FWD_OUTPUT 2>/dev/null || :; iptables -t nat -D POSTROUTING -j FWD_POSTROUTING 2>/dev/null || :; iptables -t filter -D FORWARD -j FWD_FORWARD 2>/dev/null || :
  iptables -t nat -X FWD_PREROUTING 2>/dev/null || :; iptables -t nat -X FWD_OUTPUT 2>/dev/null || :; iptables -t nat -X FWD_POSTROUTING 2>/dev/null || :; iptables -t filter -X FWD_FORWARD 2>/dev/null || :
  if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -t nat -D PREROUTING -j FWD6_PREROUTING 2>/dev/null || :; ip6tables -t nat -D OUTPUT -j FWD6_OUTPUT 2>/dev/null || :; ip6tables -t nat -D POSTROUTING -j FWD6_POSTROUTING 2>/dev/null || :; ip6tables -t filter -D FORWARD -j FWD6_FORWARD 2>/dev/null || :
    ip6tables -t nat -F FWD6_PREROUTING 2>/dev/null || :; ip6tables -t nat -X FWD6_PREROUTING 2>/dev/null || :; ip6tables -t nat -F FWD6_OUTPUT 2>/dev/null || :; ip6tables -t nat -X FWD6_OUTPUT 2>/dev/null || :; ip6tables -t nat -F FWD6_POSTROUTING 2>/dev/null || :; ip6tables -t nat -X FWD6_POSTROUTING 2>/dev/null || :; ip6tables -t filter -F FWD6_FORWARD 2>/dev/null || :; ip6tables -t filter -X FWD6_FORWARD 2>/dev/null || :
  fi
}
list_rules() {
  printf '%-4s %-18s %-8s %-7s %-18s %-32s %-6s\n' ID 备注 协议 IP族 监听端口 目标 状态
  printf '%s\n' '---------------------------------------------------------------------------------------------------------------'
  while IFS='|' read -r _id _fam _p _lp _a _tp _en _r; do
    case $_id in ''|\#*) continue;; esac
    case $_p in tcp) _pd=TCP;; udp) _pd=UDP;; both) _pd='TCP+UDP';; *) _pd=$_p;; esac
    case $_fam in v4) _fd=IPv4; _listen="0.0.0.0:$_lp";; v6) _fd=IPv6; _listen="[::]:$_lp";; dual) _fd=双栈; _listen="0.0.0.0+[::]:$_lp";; *) _fd=$_fam; _listen="?::$_lp";; esac
    case $(detect_addr_type "$_a") in ipv6) _target="[$_a]:$_tp";; *) _target="$_a:$_tp";; esac
    [ "$_en" = 1 ] && _st=启用 || _st=禁用
    printf '%-4s %-18s %-8s %-7s %-18s %-32s %-6s\n' "$_id" "$_r" "$_pd" "$_fd" "$_listen" "$_target" "$_st"
  done < "$RULES_FILE"
}
status() {
  printf '内核转发: IPv4:%s | IPv6:%s (RA=%s)\n' "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || printf 未知)" "$(cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || printf 未知)" "$(cat /proc/sys/net/ipv6/conf/all/accept_ra 2>/dev/null || printf 未知)"
  if iptables -t nat -L -n >/dev/null 2>&1; then _v4=正常; else _v4=不可用; fi
  if command -v ip6tables >/dev/null 2>&1 && ip6tables -t nat -L -n >/dev/null 2>&1; then _v6=正常; else _v6='未就绪(已降级)'; fi
  printf 'NAT 支持: IPv4 NAT:%s | IPv6 NAT:%s\n' "$_v4" "$_v6"
  if command -v systemctl >/dev/null 2>&1; then printf '服务状态: '; systemctl is-active iptables-fwd.service 2>/dev/null || printf '未运行\n'; elif command -v rc-service >/dev/null 2>&1; then printf '服务状态: '; rc-service iptables-fwd status 2>/dev/null || printf '未运行\n'; fi
}
next_id() { awk -F'|' '/^[0-9]+\|/ {if($1>m)m=$1} END{print m+1}' "$RULES_FILE"; }
read_family() {
  if [ "$IPV6_NAT_OK" -eq 1 ]; then printf '协议族：1) 纯 IPv4  2) 纯 IPv6  3) 双栈\n选择: ' >&2; read -r _choice; case $_choice in 1) _family=v4;; 2) _family=v6;; 3) _family=dual;; *) return 1;; esac
  else printf '协议族：IPv6 NAT 不可用，已锁定纯 IPv4\n' >&2; _family=v4; fi
  printf '%s\n' "$_family"
}
add_rule() {
  printf '协议：1) 仅TCP  2) 仅UDP  3) TCP+UDP\n选择: '; read -r _c
  case $_c in 1) _p=tcp;; 2) _p=udp;; 3) _p=both;; *) warn '无效输入'; return;; esac
  probe_kernel_features || return 1; _fam=$(read_family) || { warn '协议族选择无效'; return; }
  printf '监听端口 (0或回车随机): '; read -r _lp; if [ -z "$_lp" ] || [ "$_lp" = 0 ]; then _lp=$(random_port "$_fam" "$_p") || return; fi
  if ! valid_port "$_lp" || ! port_available "$_fam" "$_p" "$_lp"; then warn '端口无效或已被占用'; return; fi
  printf '目标地址: '; read -r _a; valid_addr_for_family "$_fam" "$_a" || { warn '目标地址与协议族不匹配或格式不正确'; return; }
  printf '目标端口: '; read -r _tp; valid_port "$_tp" || { warn '端口格式不正确'; return; }
  printf '备注 (不能包含 |): '; read -r _r; case $_r in *'|'*) warn '备注不能包含 |'; return;; esac
  printf '协议: %s  族: %s  监听: %s  目标: %s:%s  备注: %s\n确认添加? [y/N]: ' "$_p" "$_fam" "$_lp" "$_a" "$_tp" "$_r"; read -r _yn
  case $_yn in y|Y) ;; *) warn '已取消'; return;; esac
  _id=$(next_id); _tmp=$RULES_FILE.tmp.$$
  cat "$RULES_FILE" > "$_tmp" && printf '%s|%s|%s|%s|%s|%s|1|%s\n' "$_id" "$_fam" "$_p" "$_lp" "$_a" "$_tp" "$_r" >> "$_tmp" && mv -f "$_tmp" "$RULES_FILE" && apply_rules && ok "规则添加成功 (ID: $_id)"
}
edit_rule() {
  probe_kernel_features || return 1; list_rules; printf '请输入规则ID: '; read -r _id; valid_id "$_id" || { warn 'ID无效'; return; }
  printf '修改：1)协议 2)协议族 3)监听端口 4)目标地址 5)目标端口 6)备注 0)返回\n选择: '; read -r _f; _tmp=$RULES_FILE.tmp.$$; _found=0
  while IFS='|' read -r _rid _fam _p _lp _a _tp _en _r; do
    if [ "$_rid" = "$_id" ]; then
      _found=1
      case $_f in
        1) printf '1)TCP 2)UDP 3)TCP+UDP: '; read -r _c; case $_c in 1) _p=tcp;; 2) _p=udp;; 3) _p=both;; *) rm -f "$_tmp"; return;; esac;;
        2) _fam=$(read_family) || { rm -f "$_tmp"; return; }; valid_addr_for_family "$_fam" "$_a" || { warn '目标不适用于所选协议族'; rm -f "$_tmp"; return; };;
        3) printf '新监听端口: '; read -r _lp; if ! valid_port "$_lp" || ! port_available "$_fam" "$_p" "$_lp" "$_id"; then warn '端口无效或冲突'; rm -f "$_tmp"; return; fi;;
        4) printf '新目标地址: '; read -r _a; valid_addr_for_family "$_fam" "$_a" || { warn '地址无效或与协议族不匹配'; rm -f "$_tmp"; return; };;
        5) printf '新目标端口: '; read -r _tp; valid_port "$_tp" || { warn '端口无效'; rm -f "$_tmp"; return; };;
        6) printf '新备注: '; read -r _r; case $_r in *'|'*) warn '备注不能包含 |'; rm -f "$_tmp"; return;; esac;;
        0) rm -f "$_tmp"; return;; *) warn '无效选项'; rm -f "$_tmp"; return;;
      esac
    fi
    printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$_rid" "$_fam" "$_p" "$_lp" "$_a" "$_tp" "$_en" "$_r" >> "$_tmp"
  done < "$RULES_FILE"
  [ "$_found" = 1 ] || { rm -f "$_tmp"; warn 'ID不存在'; return; }
  mv -f "$_tmp" "$RULES_FILE" && apply_rules && ok '修改成功'
}
delete_rule() {
  list_rules; printf '输入要删除的ID (多个空格分隔): '; read -r _ids; [ -n "$_ids" ] || return
  printf '确认删除 %s? [y/N]: ' "$_ids"; read -r _yn; case $_yn in y|Y) ;; *) return;; esac
  _tmp=$RULES_FILE.tmp.$$; : > "$_tmp"
  while IFS='|' read -r _id _fam _p _lp _a _tp _en _r; do _keep=1; for _d in $_ids; do [ "$_id" = "$_d" ] && _keep=0; done; [ "$_keep" = 1 ] && printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$_id" "$_fam" "$_p" "$_lp" "$_a" "$_tp" "$_en" "$_r" >> "$_tmp"; done < "$RULES_FILE"
  mv -f "$_tmp" "$RULES_FILE" && apply_rules
}
toggle_rule() {
  list_rules; printf '请输入规则ID: '; read -r _id; valid_id "$_id" || return; _tmp=$RULES_FILE.tmp.$$; _found=0
  while IFS='|' read -r _rid _fam _p _lp _a _tp _en _r; do [ "$_rid" = "$_id" ] && { _found=1; [ "$_en" = 1 ] && _en=0 || _en=1; }; printf '%s|%s|%s|%s|%s|%s|%s|%s\n' "$_rid" "$_fam" "$_p" "$_lp" "$_a" "$_tp" "$_en" "$_r" >> "$_tmp"; done < "$RULES_FILE"
  [ "$_found" = 1 ] || { rm -f "$_tmp"; warn 'ID不存在'; return; }; mv -f "$_tmp" "$RULES_FILE" && apply_rules
}
global_settings() {
  printf '当前 forwarding: IPv4='; cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || :; printf ' IPv6='; cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || :; printf '\n1) 开启双栈转发 2) 关闭转发 3) 设置 conntrack 超时 0) 返回\n选择: '; read -r _c
  case $_c in 1) enable_ip_forward_runtime; persist_ip_forward;; 2) printf '0' > /proc/sys/net/ipv4/ip_forward 2>/dev/null || warn 'IPv4 写入失败'; printf '0' > /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || warn 'IPv6 写入失败';;
    3) printf '1) TCP 600s 2) TCP 1800s 3) TCP 7200s 4) UDP 30s 5) UDP 60s 6) UDP 120s\n选择: '; read -r _c; case $_c in 1) _f=/proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established; _v=600;; 2) _f=/proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established; _v=1800;; 3) _f=/proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established; _v=7200;; 4) _f=/proc/sys/net/netfilter/nf_conntrack_udp_timeout; _v=30;; 5) _f=/proc/sys/net/netfilter/nf_conntrack_udp_timeout; _v=60;; 6) _f=/proc/sys/net/netfilter/nf_conntrack_udp_timeout; _v=120;; *) return;; esac; printf '%s' "$_v" > "$_f" 2>/dev/null || warn '内核参数不可写';; esac
}
service_action() { case $1 in start) apply_rules;; stop) flush_rules;; restart|reload) apply_rules;; status) status;; *) return 1;; esac; }
service_menu() {
  while :; do printf '\n===== 服务管理 =====\n  1) 启动\n  2) 停止\n  3) 重启\n  4) 运行状态\n  5) 查看 iptables 实际规则\n  0) 返回\n请选择: '; read -r _c
    case $_c in 1) service_action start;; 2) service_action stop;; 3) service_action restart;; 4) status;; 5) iptables -L -n -v; command -v ip6tables >/dev/null 2>&1 && ip6tables -L -n -v;; 0) return;; *) warn '无效输入';; esac; press_enter
  done
}
write_service() {
  if command -v systemctl >/dev/null 2>&1; then
    cat > "$SERVICE_FILE" <<EOF2
[Unit]
Description=iptables Port Forwarding Service
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$BIN_LINK --apply
ExecStop=$BIN_LINK --flush
ExecReload=$BIN_LINK --apply

[Install]
WantedBy=multi-user.target
EOF2
    systemctl daemon-reload && systemctl enable iptables-fwd.service || return 1
  elif command -v rc-update >/dev/null 2>&1; then
    cat > "$OPENRC_FILE" <<EOF2
#!/sbin/openrc-run
description="iptables Port Forwarding Service"
depend() { need net; after firewall sysctl; }
start() { ebegin "Starting iptables port forwarding"; $BIN_LINK --apply; eend \$?; }
stop() { ebegin "Stopping iptables port forwarding"; $BIN_LINK --flush; eend \$?; }
restart() { ebegin "Reloading iptables port forwarding"; $BIN_LINK --apply; eend \$?; }
EOF2
    chmod +x "$OPENRC_FILE" && rc-update add iptables-fwd default || return 1
  else err '未检测到 systemd 或 OpenRC'; return 1; fi
}
install_environment() {
  require_root || return 1
  if ! command -v iptables >/dev/null 2>&1; then
    if command -v apk >/dev/null 2>&1; then apk add --no-cache iptables || return 1
    elif command -v apt-get >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables || return 1
    else err '请先手动安装 iptables'; return 1; fi
  fi
  init_files || return 1; mkdir -p /usr/local/bin || return 1; ln -sf "$SCRIPT_PATH" "$BIN_LINK" || return 1
  persist_ip_forward || return 1; write_service || return 1; apply_rules
}
backup_rules() { _out=/root/iptables-fwd-backup-$(date +%Y%m%d%H%M%S).tar.gz; tar czf "$_out" -C /etc iptables-fwd && ok "已备份到: $_out"; }
restore_rules() {
  printf '请输入备份文件完整路径: '; read -r _path; [ -f "$_path" ] || { err '文件不存在'; return; }; _td=$(mktemp -d) || return
  if ! tar xzf "$_path" -C "$_td" 2>/dev/null || [ ! -f "$_td/iptables-fwd/rules.conf" ]; then rm -rf "$_td"; err '备份文件格式不正确'; return 1; fi
  awk -F'|' '/^[0-9]+\|/ {if(NF!=8 || $2!~/^(v4|v6|dual)$/ || $3!~/^(tcp|udp|both)$/ || $4<1 || $4>65535 || $6<1 || $6>65535 || $7!~/^[01]$/) exit 1} END{if(NR==0)exit 1}' "$_td/iptables-fwd/rules.conf" || { rm -rf "$_td"; err '规则文件校验失败'; return 1; }
  cp "$_td/iptables-fwd/rules.conf" "$RULES_FILE.tmp.$$" && mv -f "$RULES_FILE.tmp.$$" "$RULES_FILE"; _rc=$?; rm -rf "$_td"; [ "$_rc" -eq 0 ] && apply_rules
}
uninstall_all() {
  printf '确认卸载并清理转发链? [y/N]: '; read -r _yn; case $_yn in y|Y) ;; *) warn '已取消'; return;; esac
  if command -v systemctl >/dev/null 2>&1; then systemctl disable --now iptables-fwd.service >/dev/null 2>&1 || :; rm -f "$SERVICE_FILE"; systemctl daemon-reload >/dev/null 2>&1 || :; fi
  if command -v rc-update >/dev/null 2>&1; then rc-update del iptables-fwd default >/dev/null 2>&1 || :; rc-service iptables-fwd stop >/dev/null 2>&1 || :; rm -f "$OPENRC_FILE"; fi
  flush_rules; rm -f "$BIN_LINK" "$SYSCTL_FILE"; printf '是否保留规则配置? [Y/n]: '; read -r _keep
  case $_keep in n|N) rm -rf "$CONFIG_DIR"; ok '已卸载，规则数据已删除';; *) ok "已卸载，规则数据保留在 $RULES_FILE";; esac
}
main_menu() {
  while :; do
    printf '\033[2J\033[H========================================\n       iptables 端口转发管理脚本 (v2 双栈)\n========================================\n'
    printf '  内核转发: IPv4:%s | IPv6:%s (RA=%s)\n' "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || printf 未知)" "$(cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || printf 未知)" "$(cat /proc/sys/net/ipv6/conf/all/accept_ra 2>/dev/null || printf 未知)"
    if iptables -t nat -L -n >/dev/null 2>&1; then _nat4=正常; else _nat4=不可用; fi
    if command -v ip6tables >/dev/null 2>&1 && ip6tables -t nat -L -n >/dev/null 2>&1; then _nat6=正常; else _nat6='未就绪(已降级)'; fi
    _total=$(awk -F'|' '/^[0-9]+\|/ {n++} END{print n+0}' "$RULES_FILE"); _enabled=$(awk -F'|' '/^[0-9]+\|/ && $7==1{n++} END{print n+0}' "$RULES_FILE")
    _v4c=$(awk -F'|' '/^[0-9]+\|/ && $2=="v4"{n++} END{print n+0}' "$RULES_FILE"); _v6c=$(awk -F'|' '/^[0-9]+\|/ && $2=="v6"{n++} END{print n+0}' "$RULES_FILE"); _dualc=$(awk -F'|' '/^[0-9]+\|/ && $2=="dual"{n++} END{print n+0}' "$RULES_FILE")
    printf '  NAT 支持: IPv4 NAT:%s | IPv6 NAT:%s\n  生效规则: %s 条启用 / 共 %s 条 (IPv4:%s | IPv6:%s | 双栈:%s)\n----------------------------------------\n  1) 新增转发规则\n  2) 查看所有规则\n  3) 修改规则\n  4) 删除规则\n  5) 启用/禁用规则\n  6) 全局网络与内核参数设置\n  7) 服务管理 (启动/停止/重载/状态)\n  8) 环境初始化与依赖重装\n  9) 备份规则\n 10) 恢复规则\n 11) 重新生成配置并重载规则\n 12) 卸载\n  0) 退出\n========================================\n请输入选项: ' "$_nat4" "$_nat6" "$_enabled" "$_total" "$_v4c" "$_v6c" "$_dualc"
    read -r _c || exit 0
    case $_c in 1) add_rule;; 2) list_rules; press_enter;; 3) edit_rule;; 4) delete_rule;; 5) toggle_rule;; 6) global_settings;; 7) service_menu;; 8) install_environment;; 9) backup_rules;; 10) restore_rules;; 11) apply_rules;; 12) uninstall_all;; 0) exit 0;; *) warn '无效输入'; press_enter;; esac
  done
}
case ${1:-} in
  --apply) require_root && init_files && apply_rules; exit $?;;
  --flush) flush_rules; exit $?;;
  --list) init_files && list_rules; exit $?;;
  --status) status; exit $?;;
  --init) install_environment; exit $?;;
  --sync-ddns) require_root && apply_rules; exit $?;;
  '') require_root && init_files || exit 1; main_menu;;
  *) err "未知参数: $1"; exit 2;;
esac
