#!/usr/bin/env bash
# setup-time.sh — v5.8 (geo-aware, interactive timezone menu, UTC default)
#   * 运行时交互选择时区(UTC/美国/德国/日本/新加坡/上海/韩国/荷兰/非洲),默认 UTC
#   * 两阶段延迟探测:
#     1. 优先使用 sntp 查询 NTP(UDP/123)
#     2. 回退到 HTTP 时间 API(HTTP/80 或 HTTPS/443)
#   * NTP 服务器与 HTTP API 随所选时区动态切换
#   * 增强重试机制和错误处理
#   * -t 显式指定时区时跳过菜单,兼容旧调用方式

set -euo pipefail

############################# 默认参数 #############################
TZ_REGION="UTC"
SNTP_TIMEOUT=10      # sntp 查询超时(秒)
HTTP_TIMEOUT=10      # HTTP API 查询超时(秒)
CONNECTIVITY_CHECK_HOST="8.8.8.8" # 基础 ping 测试目标
CONNECTIVITY_TIMEOUT=3 # ping 测试超时
TOP_N=3
MAX_PARALLEL=8       # 并发进程

# 时区到 NTP 服务器的映射(已扩展多地区)
declare -A TZ_NTP_MAP=(
  ["UTC"]="time.cloudflare.com time.google.com pool.ntp.org time.nist.gov time.aws.com"
  ["Asia/Shanghai"]="cn.ntp.org.cn time.pool.aliyun.com ntp1.aliyun.com ntp2.aliyun.com time.asia.apple.com cn.pool.ntp.org"
  ["America/New_York"]="time.nist.gov time.google.com time.cloudflare.com us.pool.ntp.org time.apple.com"
  ["America/Los_Angeles"]="us.pool.ntp.org time.google.com time.cloudflare.com time.nist.gov time.apple.com"
  ["Europe/Berlin"]="ptbtime1.ptb.de ptbtime2.ptb.de de.pool.ntp.org 0.de.pool.ntp.org time.cloudflare.com"
  ["Asia/Tokyo"]="ntp.nict.jp jp.pool.ntp.org time.asia.apple.com time.google.com 0.jp.pool.ntp.org"
  ["Asia/Singapore"]="sg.pool.ntp.org time.google.com time.cloudflare.com 0.asia.pool.ntp.org time.apple.com"
  ["Asia/Seoul"]="time.bora.net kr.pool.ntp.org time.google.com 0.kr.pool.ntp.org time.asia.apple.com"
  ["Europe/Amsterdam"]="ntp.time.nl nl.pool.ntp.org 0.nl.pool.ntp.org time.cloudflare.com time.google.com"
  ["Africa/Johannesburg"]="za.pool.ntp.org 0.africa.pool.ntp.org time.google.com time.cloudflare.com"
  ["default"]="time.google.com time.cloudflare.com time.aws.com time.apple.com pool.ntp.org 0.pool.ntp.org 1.pool.ntp.org"
)

# HTTP 时间 API(运行时由 build_http_apis 按时区填充)
HTTP_APIS=()

# 初始化候选 NTP 服务器
CANDIDATE_NTPS=(${TZ_NTP_MAP["$TZ_REGION"]:-${TZ_NTP_MAP["default"]}})
###################################################################

log() { printf "\033[36m[%s] %s\033[0m\n" "$(date '+%F %T')" "$*" >&2; }
warn() { printf "\033[33m⚠️ %s\033[0m\n" "$*" >&2; }
err() { printf "\033[31m❌ %s\033[0m\n" "$*" >&2; exit 1; }
ok() { printf "\033[32m✅ %s\033[0m\n" "$*"; }
require_root() { [[ $(id -u) -eq 0 ]] || err "请用 root 运行"; }
require_cmd() { command -v "$1" &>/dev/null || err "缺少依赖: $1"; }
has_systemd() { command -v systemctl &>/dev/null; }

detect_pkg_mgr() {
  for m in apt-get dnf5 dnf yum pacman zypper apk; do
    command -v "$m" &>/dev/null && { echo "$m"; return; }
  done
  echo unsupported
}

install_pkgs() {
  local pm=$1; shift
  [[ $# -eq 0 ]] && return 0 # 无包可装
  log "正在使用 $pm 安装: $*"
  case $pm in
    apt-get) apt-get update -qq >/dev/null; DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >/dev/null ;;
    dnf5)    dnf5 install -y "$@" >/dev/null ;;
    dnf|yum) "$pm" install -y "$@" >/dev/null ;;
    pacman)  pacman -Sy --noconfirm --needed "$@" >/dev/null ;;
    zypper)  zypper --gpg-auto-import-keys --non-interactive install "$@" >/dev/null ;;
    apk)     apk add --no-progress "$@" >/dev/null ;;
    *)       err "不支持的软件包管理器" ;;
  esac || warn "软件包安装可能失败: $*" # 安装失败不退出,可能已存在
}

# 交互式选择时区。若已通过 -t 显式指定,则跳过菜单。
select_timezone_menu() {
  [[ "$TZ_EXPLICIT" == true ]] && return 0

  # 非交互环境直接用默认,避免脚本卡住
  if [[ ! -t 0 ]]; then
    log "非交互环境,使用默认时区: $TZ_REGION"
    return 0
  fi

  local -a tz_list=(
    "UTC"                   # 0 UTC(默认)
    "America/New_York"      # 1 美国-东部
    "America/Los_Angeles"   # 2 美国-西部
    "Europe/Berlin"         # 3 德国
    "Asia/Tokyo"            # 4 日本
    "Asia/Singapore"        # 5 新加坡
    "Asia/Shanghai"         # 6 上海
    "Asia/Seoul"            # 7 韩国
    "Europe/Amsterdam"      # 8 荷兰
    "Africa/Johannesburg"   # 9 非洲
  )

  printf "\033[36m请选择时区 (回车默认 0 = UTC):\033[0m\n" >&2
  printf "  0) UTC         协调世界时  [默认]\n">&2
  printf "  1) 美国-东部   America/New_York\n"     >&2
  printf "  2) 美国-西部   America/Los_Angeles\n"  >&2
  printf "  3) 德国        Europe/Berlin\n"        >&2
  printf "  4) 日本        Asia/Tokyo\n"           >&2
  printf "  5) 新加坡      Asia/Singapore\n"       >&2
  printf "  6) 上海        Asia/Shanghai\n"        >&2
  printf "  7) 韩国        Asia/Seoul\n"           >&2
  printf "  8) 荷兰        Europe/Amsterdam\n"     >&2
  printf "  9) 非洲        Africa/Johannesburg\n"  >&2

  local choice
  printf "请输入编号 [0]: " >&2
  read -r choice
  choice="${choice:-0}"

  if [[ "$choice" =~ ^[0-9]$ ]]; then
    TZ_REGION="${tz_list[choice]}"
  else
    warn "无效选择 '$choice',使用默认时区 UTC"
    TZ_REGION="UTC"
  fi

  # 依据所选时区刷新候选 NTP 列表
  CANDIDATE_NTPS=(${TZ_NTP_MAP["$TZ_REGION"]:-${TZ_NTP_MAP["default"]}})
  ok "已选择时区: $TZ_REGION"
}

# 根据当前时区动态构建 HTTP 时间 API 后备列表
build_http_apis() {
  HTTP_APIS=(
    "http://worldtimeapi.org/api/timezone/${TZ_REGION}"
    "https://timeapi.io/api/Time/current/zone?timeZone=${TZ_REGION}"
    "https://worldtimeapi.org/api/timezone/${TZ_REGION}"
  )
  log "HTTP 时间 API 后备列表已按时区 ${TZ_REGION} 生成。"
}

check_connectivity() {
    log "检查基础网络连接 (ping $CONNECTIVITY_CHECK_HOST)..."
    if ping -c 1 -W "$CONNECTIVITY_TIMEOUT" "$CONNECTIVITY_CHECK_HOST" &>/dev/null; then
        ok "基础网络连接正常。"
    else
        warn "基础 ping 测试失败。可能存在网络或 DNS 问题,或 ICMP 被阻止。"
        warn "继续尝试探测,但这可能是失败的原因。"
    fi
}

set_timezone() {
  log "设置时区为 $TZ_REGION..."
  if command -v timedatectl &>/dev/null; then
    timedatectl set-timezone "$TZ_REGION"
  else
    ln -sf "/usr/share/zoneinfo/$TZ_REGION" /etc/localtime
  fi
  ok "时区已设置为 $TZ_REGION"
}

detect_chrony_conf() {
  [[ -f /etc/chrony/chrony.conf ]] && echo /etc/chrony/chrony.conf || echo /etc/chrony.conf
}

probe_sntp() {
  local host=$1 delay output
  log "  -> 探测 SNTP: $host (超时 ${SNTP_TIMEOUT}s)"
  output=$(timeout "$SNTP_TIMEOUT" sntp "$host" 2>&1)
  local exit_code=$?
  delay=$(echo "$output" | grep -oP '[-+]\d+\.\d+' | head -1)

  if [[ $exit_code -eq 0 && $delay ]]; then
    printf "%s %s\n" "${delay#-}" "$host" # 去掉前导 +/-
  elif [[ $exit_code -eq 124 ]]; then
      log "  -> SNTP 超时: $host"
  else
      log "  -> SNTP 错误 ($host): $output (退出码: $exit_code)"
  fi
}
export -f probe_sntp log   # 导出函数
export SNTP_TIMEOUT       # 导出变量

probe_http() {
  local api=$1 delay output http_code
  log "  -> 探测 HTTP: $api (超时 ${HTTP_TIMEOUT}s)"
  output=$(curl -sSL --fail -w '%{time_total} %{http_code}' -o /dev/null --connect-timeout "$HTTP_TIMEOUT" --max-time "$HTTP_TIMEOUT" "$api" 2>/dev/null)
  local exit_code=$?
  delay=$(echo "$output" | awk '{print $1}')
  http_code=$(echo "$output" | awk '{print $2}')

  if [[ $exit_code -eq 0 && $delay =~ ^[0-9.]+$ && $http_code -eq 200 ]]; then
    printf "%s %s\n" "$delay" "$api"
  elif [[ $exit_code -ne 0 ]]; then
    log "  -> HTTP 错误 ($api): curl 退出码 $exit_code"
  elif [[ $http_code -ne 200 ]]; then
    log "  -> HTTP 错误 ($api): HTTP 状态码 $http_code"
  else
    log "  -> HTTP 错误 ($api): 无法获取有效延迟 (输出: '$output')"
  fi
}
export -f probe_http log   # 导出函数
export HTTP_TIMEOUT       # 导出变量

measure_ntp() {
  local mode="SNTP" ntp_res=()

  # 阶段 1:SNTP 探测
  log "① 通过 sntp 测试 UDP/123 延迟…"
  if ! command -v sntp &>/dev/null; then
      warn "未找到 sntp 命令,跳过 SNTP 探测阶段。"
  else
      mapfile -t ntp_res < <(printf '%s\n' "${CANDIDATE_NTPS[@]}" | xargs -P "$MAX_PARALLEL" -I{} bash -c 'probe_sntp "$1"' _ {})
  fi

  # 阶段 2:HTTP API 探测(如果 SNTP 失败或跳过)
  if (( ${#ntp_res[@]} == 0 )); then
    if [[ $mode == "SNTP" ]]; then
        warn "全部 SNTP 查询失败、超时或被跳过,切换到 HTTP API 测试 (端口 80/443)..."
    fi
    mode="HTTP"
    mapfile -t ntp_res < <(printf '%s\n' "${HTTP_APIS[@]}" | xargs -P "$MAX_PARALLEL" -I{} bash -c 'probe_http "$1"' _ {})
  fi

  # 最终回退
  if (( ${#ntp_res[@]} == 0 )); then
    warn "所有探测方式 (SNTP 和 HTTP) 均失败。网络/防火墙可能阻止 UDP/123 和 TCP/80,443 出站。"
    warn "退回使用所选时区的默认 NTP 服务器。"
    BEST=(${TZ_NTP_MAP["$TZ_REGION"]:-${TZ_NTP_MAP["default"]}})
    BEST=("${BEST[@]:0:$TOP_N}")
    return
  fi

  # 排序并选择前 TOP_N
  mapfile -t sorted < <(printf '%s\n' "${ntp_res[@]}" | sort -n)
  BEST=()
  if [[ $mode == "HTTP" ]]; then
      BEST=(${TZ_NTP_MAP["$TZ_REGION"]:-${TZ_NTP_MAP["default"]}})
      BEST=("${BEST[@]:0:$TOP_N}")
      log "HTTP 探测成功,但需要 NTP 服务器。选用时区默认 NTP: ${BEST[*]}"
  else
      for ((i=0; i<${TOP_N} && i<${#sorted[@]}; i++)); do
        host=$(awk '{print $2}' <<<"${sorted[i]}")
        BEST+=("$host")
      done
      if [[ ${#BEST[@]} -eq 0 ]]; then
        BEST=(${TZ_NTP_MAP["$TZ_REGION"]:-${TZ_NTP_MAP["default"]}})
        BEST=("${BEST[@]:0:$TOP_N}")
      fi
  fi

  # 显示结果
  log "探测结果 ($mode 模式):"
  printf "%-3s %-35s %12s\n" "#" "服务器/API" "延迟(s)"
  printf -- "-------------------------------------------------------------\n"
  local idx=1
  for l in "${sorted[@]}"; do
    printf "%-3d %-35s %12.3f\n" "$idx" "$(awk '{print $2}' <<<"$l")" "$(awk '{print $1}' <<<"$l")"
    ((idx++))
  done | tee /dev/stderr
  ok "最终选用 NTP 源: ${BEST[*]}"
}

backup_file() {
  local f=$1 bak_ts
  if [[ -f $f ]]; then
      bak_ts=$(date +%Y%m%d_%H%M%S)
      log "备份 $f -> ${f}.bak.${bak_ts}"
      cp -a "$f" "${f}.bak.${bak_ts}" || warn "备份文件 $f 失败!"
  fi
}

stop_timesyncd() {
  has_systemd && {
    log "停止并禁用 systemd-timesyncd..."
    systemctl stop systemd-timesyncd &>/dev/null || true
    systemctl disable systemd-timesyncd &>/dev/null || true
  }
}

start_chronyd() {
  log "启动/重启并启用 chrony 服务..."
  local service_name="chrony"
  if systemctl list-unit-files | grep -q chronyd.service; then
      service_name="chronyd"
  fi

  if has_systemd; then
    systemctl restart "${service_name}.service" &>/dev/null || warn "${service_name} 重启失败"
    systemctl enable "${service_name}.service" &>/dev/null || warn "${service_name} 启用失败"
  else
    rc-service chronyd restart &>/dev/null || /etc/init.d/chronyd restart &>/dev/null || warn "chrony (OpenRC) 重启失败"
    rc-update add chronyd default &>/dev/null || true
  fi
}

config_chrony() {
  local conf
  conf=$(detect_chrony_conf)
  if [[ ! -f "$conf" && "$PM" == "apt-get" && -f "/etc/chrony/chrony.conf" ]]; then
      conf="/etc/chrony/chrony.conf"
  elif [[ ! -f "$conf" ]]; then
      warn "chrony 配置文件 ($conf) 未找到。尝试创建..."
      mkdir -p "$(dirname "$conf")"
      {
          echo "# Basic chrony config generated by setup-time.sh"
          echo "driftfile /var/lib/chrony/drift"
          echo "makestep 1.0 3"
          echo "rtcsync"
          [[ -d /var/log/chrony ]] && echo "logdir /var/log/chrony"
      } > "$conf" || { warn "创建 $conf 失败!"; return 1; }
  fi

  if [[ ! -f "$conf" ]]; then
      warn "无法找到或创建 chrony 配置文件。跳过 chrony 配置。"
      return 1
  fi

  log "配置 chrony ($conf) 使用服务器: ${BEST[*]}"
  backup_file "$conf"
  local marker="# ---- setup-time.sh"
  sed -i -e "/^\\s*\(server\|pool\)\\s\+/d" -e "/^${marker} begin/,/^${marker} end/d" "$conf"

  {
    echo "${marker} begin ----"
    for s in "${BEST[@]}"; do echo "server $s iburst"; done
    echo "# Use pool as a fallback"
    echo "pool pool.ntp.org iburst"
    echo "${marker} end ----"
  } >>"$conf"
  log "已更新 $conf"
  stop_timesyncd
  start_chronyd
  return 0
}

retry_tracking() {
  log "等待 chrony 与源同步..."
  local attempts=5 wait_times=(2 4 8 15 30)
  for ((a=1; a<=attempts; a++)); do
    local d=${wait_times[a-1]:-30}
    log "  尝试 $a/$attempts: 等待 ${d} 秒..."
    sleep "$d"
    if ! command -v chronyc &>/dev/null; then
         warn "chronyc 命令不存在,无法检查同步状态。"
         return 1
    fi
    local tracking_output
    tracking_output=$(chronyc tracking 2>&1)
    local exit_code=$?

    if [[ $exit_code -eq 0 ]] && echo "$tracking_output" | grep -q "^\(Reference ID\|Stratum\)"; then
        log "Chrony 追踪信息:"
        echo "$tracking_output" | tee /dev/stderr
        local stratum
        stratum=$(echo "$tracking_output" | grep '^Stratum' | awk '{print $3}')
        if [[ "$stratum" =~ ^[0-9]+$ && "$stratum" -gt 0 && "$stratum" -lt 16 ]]; then
            ok "Chrony 已同步 (层级 $stratum)。"
            return 0
        else
            warn "Chrony 正在追踪,但层级为 ${stratum:-未找到} (可能未完全同步或未连接)。"
        fi
    else
        warn "chronyc tracking 命令失败或未返回有效信息 (退出码 $exit_code)。输出: $tracking_output"
    fi
  done
  warn "Chrony 在 ${attempts} 次尝试后未能确认成功同步。"
  return 1
}

enable_timesyncd() {
  has_systemd || return 1
  log "回退到配置 systemd-timesyncd..."
  local conf_path="/etc/systemd/timesyncd.conf"
  backup_file "$conf_path"
  mkdir -p "$(dirname "$conf_path")"
  {
    echo "[Time]"
    echo "NTP=$(printf '%s ' "${BEST[@]}")"
    echo "FallbackNTP=pool.ntp.org time.cloudflare.com"
  } >"$conf_path" || { warn "写入 $conf_path 失败!"; return 1; }
  log "已写入 $conf_path"
  log "重启并启用 systemd-timesyncd..."
  systemctl restart systemd-timesyncd.service &>/dev/null || warn "systemd-timesyncd 重启失败"
  systemctl enable systemd-timesyncd.service &>/dev/null || warn "systemd-timesyncd 启用失败"
  return 0
}

sync_once() {
  log "尝试使用 ntpdate 进行一次性同步 (服务器: ${BEST[0]:-pool.ntp.org})"
  local ntp_server="${BEST[0]:-pool.ntp.org}"
  if ! command -v ntpdate &>/dev/null; then
      warn "ntpdate 命令不存在,跳过一次性同步。"
      return 1
  fi
  if ntpdate -u "$ntp_server"; then
      ok "ntpdate 同步成功 ($ntp_server)。"
      return 0
  else
      warn "ntpdate 同步失败 ($ntp_server)。"
      return 1
  fi
}

usage() {
  cat <<EOF
用法: $0 [选项]
  -t TZ      指定时区(跳过交互菜单)
               例如: UTC, Asia/Shanghai, Europe/London, America/New_York
  -n NUM     选取延迟最低的 NTP 数(默认 $TOP_N)
  -c FILE    使用文件中的 NTP 服务器列表替换默认列表 (每行一个服务器)
  -f         强制使用 systemd-timesyncd (如果可用) 而不是 chrony
  --sntp-timeout SEC   设置 sntp 探测超时时间 (默认 $SNTP_TIMEOUT)
  --http-timeout SEC   设置 HTTP 探测超时时间 (默认 $HTTP_TIMEOUT)
  -h         显示此帮助

增强版 v5.8: 运行时交互选择时区 (UTC/美国/德国/日本/新加坡/上海/韩国/荷兰/非洲),
            未指定 -t 时弹出菜单,默认 UTC。
EOF
  exit 0
}

# --- 解析命令行选项 ---
FORCE_TIMESYNCD=false
TZ_EXPLICIT=false        # 标记用户是否显式指定了 -t
ARGS=$(getopt -o t:n:c:fh -l "sntp-timeout:,http-timeout:,help" -n "$0" -- "$@") || exit 1
eval set -- "$ARGS"

while true; do
  case "$1" in
    -t) TZ_REGION=$OPTARG
        TZ_EXPLICIT=true          # 用户显式指定,跳过菜单
        CANDIDATE_NTPS=(${TZ_NTP_MAP["$TZ_REGION"]:-${TZ_NTP_MAP["default"]}})
        shift 2 ;;
    -n) if [[ "$OPTARG" =~ ^[1-9][0-9]*$ ]]; then TOP_N=$OPTARG; else err "选项 -n 需要一个正整数"; fi; shift 2 ;;
    -c) if [[ -r "$OPTARG" ]]; then mapfile -t CANDIDATE_NTPS < "$OPTARG"; else err "无法读取候选列表文件: $OPTARG"; fi; shift 2 ;;
    -f) FORCE_TIMESYNCD=true; shift ;;
    --sntp-timeout) if [[ "$OPTARG" =~ ^[1-9][0-9]*$ ]]; then SNTP_TIMEOUT=$OPTARG; else err "选项 --sntp-timeout 需要一个正整数"; fi; shift 2 ;;
    --http-timeout) if [[ "$OPTARG" =~ ^[1-9][0-9]*$ ]]; then HTTP_TIMEOUT=$OPTARG; else err "选项 --http-timeout 需要一个正整数"; fi; shift 2 ;;
    -h|--help) usage ;;
    --) shift; break ;;
    *) err "内部错误!"; exit 1 ;;
  esac
done

# --- 主流程 ---
log "启动 setup-time.sh v5.8..."
require_root
PM=$(detect_pkg_mgr)
[[ $PM == unsupported ]] && err "未识别发行版或不支持的包管理器"
log "检测到包管理器: $PM"

# 基础软件包
PKGS_BASE=("curl" "util-linux")
# Chrony 软件包
PKGS_CHRONY=("chrony")

# 为 sntp/ntpdate 命令确定候选软件包名称
PKGS_SNTP_TOOLS_CANDIDATES=()
case "$PM" in
    apt-get) PKGS_SNTP_TOOLS_CANDIDATES=("sntp" "ntpdate") ;;
    dnf|dnf5|yum) PKGS_SNTP_TOOLS_CANDIDATES=("sntp" "ntpdate") ;;
    pacman) PKGS_SNTP_TOOLS_CANDIDATES=("ntp" "ntpdate") ;;
    apk) PKGS_SNTP_TOOLS_CANDIDATES=("sntp" "ntp") ;;
    zypper) PKGS_SNTP_TOOLS_CANDIDATES=("sntp" "ntpdate") ;;
    *) PKGS_SNTP_TOOLS_CANDIDATES=("sntp" "ntpdate" "ntp") ;;
esac
log "为包管理器 $PM 选择的 SNTP/NTPDate 候选包: ${PKGS_SNTP_TOOLS_CANDIDATES[*]}"

# --- 决定最终需要安装的软件包列表 ---
INSTALL_PKGS=("${PKGS_BASE[@]}")
USE_CHRONY=true

if $FORCE_TIMESYNCD && has_systemd; then
    log "选项 -f: 强制使用 systemd-timesyncd"
    USE_CHRONY=false
    INSTALL_PKGS+=("${PKGS_SNTP_TOOLS_CANDIDATES[@]}")
elif command -v chronyd &>/dev/null || [[ $PM != "unsupported" ]]; then
    log "优先尝试使用 chrony"
    INSTALL_PKGS+=("${PKGS_CHRONY[@]}" "${PKGS_SNTP_TOOLS_CANDIDATES[@]}")
elif has_systemd; then
    log "未找到 chrony, 回退到 systemd-timesyncd"
    USE_CHRONY=false
    INSTALL_PKGS+=("${PKGS_SNTP_TOOLS_CANDIDATES[@]}")
else
    log "未找到 chrony 且无 systemd, 仅尝试 ntpdate/sntp"
    USE_CHRONY=false
    INSTALL_PKGS+=("${PKGS_SNTP_TOOLS_CANDIDATES[@]}")
fi

# 去重最终列表
mapfile -t INSTALL_PKGS < <(printf "%s\n" "${INSTALL_PKGS[@]}" | sort -u | grep -v '^\s*$')
log "最终尝试安装的软件包列表: ${INSTALL_PKGS[*]}"

# --- 安装软件包 ---
if [[ ${#INSTALL_PKGS[@]} -gt 0 ]]; then
    install_pkgs "$PM" "${INSTALL_PKGS[@]}"
else
    log "没有需要安装的软件包。"
fi

# --- 强制验证关键命令 ---
require_cmd curl

sntp_found=false
ntpdate_found=false
command -v sntp &>/dev/null && sntp_found=true
command -v ntpdate &>/dev/null && ntpdate_found=true

if ! $sntp_found && ! $ntpdate_found; then
    warn "sntp 和 ntpdate 命令在首次安装尝试后均不可用。尝试再次安装候选包..."
    if [[ ${#PKGS_SNTP_TOOLS_CANDIDATES[@]} -gt 0 ]]; then
        install_pkgs "$PM" "${PKGS_SNTP_TOOLS_CANDIDATES[@]}"
        command -v sntp &>/dev/null && sntp_found=true
        command -v ntpdate &>/dev/null && ntpdate_found=true
    fi
    if ! $sntp_found && ! $ntpdate_found; then
        err "安装后仍缺少 sntp 和 ntpdate 命令。请检查 '$PM' 的安装日志或手动安装 (${PKGS_SNTP_TOOLS_CANDIDATES[*]})。"
    fi
fi
log "依赖命令检查通过 (curl 及 sntp 或 ntpdate)。"

# --- 后续步骤 ---
select_timezone_menu   # 运行时交互选择时区(已用 -t 则跳过)
build_http_apis        # 依据最终时区生成 HTTP 时间 API
set_timezone
check_connectivity
measure_ntp

FINAL_SYNC_OK=false
if $USE_CHRONY; then
    log "尝试配置并启动 chrony..."
    if config_chrony; then
        if retry_tracking; then
            log "Chrony 运行并同步中。最终源状态:"
            chronyc sources -v || true
            FINAL_SYNC_OK=true
        else
            warn "Chrony 启动但未能确认同步状态。可能需要更多时间或检查配置/网络。"
        fi
    else
        warn "Chrony 配置失败。尝试回退..."
        USE_CHRONY=false
    fi
fi

# 回退到 timesyncd
if ! $FINAL_SYNC_OK && ! $USE_CHRONY && has_systemd; then
    log "尝试配置并启动 systemd-timesyncd..."
    if enable_timesyncd; then
        log "等待 systemd-timesyncd 同步 (最多 15 秒)..."
        sync_status_cmd="timedatectl timesync-status"
        end=$((SECONDS+15))
        while [[ $SECONDS -lt $end ]]; do
           if $sync_status_cmd &>/dev/null && $sync_status_cmd | grep -q "Status: Synchronized"; then
                ok "systemd-timesyncd 已同步。"
                $sync_status_cmd || true
                FINAL_SYNC_OK=true
                break
            fi
            sleep 3
        done
        if ! $FINAL_SYNC_OK; then
             warn "systemd-timesyncd 启动但未能确认同步状态。"
             $sync_status_cmd &>/dev/null && $sync_status_cmd || warn "无法获取 timesync-status"
        fi
    else
        warn "systemd-timesyncd 配置失败。"
    fi
fi

# 最终回退:ntpdate 单次同步
if ! $FINAL_SYNC_OK; then
    if $ntpdate_found; then
        warn "主要同步方法 (chrony/timesyncd) 未能确认同步。最后尝试 ntpdate 单次同步。"
        if sync_once; then
            FINAL_SYNC_OK=true
        fi
    else
         warn "主要同步方法失败,且 ntpdate 命令不可用,无法进行最后的回退同步。"
    fi
fi

# --- 最终状态 ---
if $FINAL_SYNC_OK; then
    ok "时间同步配置完成并已确认至少一种方法同步成功。"
    log "当前时间: $(date)"
    exit 0
else
    if $USE_CHRONY && command -v chronyc &>/dev/null ; then
         warn "时间同步配置完成,但未能确认 chrony 是否已同步。它可能会在稍后同步。"
         exit 0
    elif ! $USE_CHRONY && has_systemd && systemctl is-active systemd-timesyncd &>/dev/null; then
         warn "时间同步配置完成,但未能确认 systemd-timesyncd 是否已同步。它可能会在稍后同步。"
         exit 0
    fi
    err "所有时间同步方法均失败或无法确认状态。请检查网络连接、防火墙设置以及 /var/log/syslog 或 journalctl 的详细错误。"
    exit 1
fi
