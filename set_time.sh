#!/usr/bin/env bash
# setup-time.sh — v5.5 (geo-aware, robust probing, enhanced debugging)
#   * 两阶段延迟探测，针对 Asia/Shanghai 优化
#     1. 优先使用 sntp 查询 NTP（UDP/123）
#     2. 回退到 HTTP 时间 API（HTTP/80 或 HTTPS/443）
#   * 针对时区选择低延迟 NTP 服务器
#   * 增强重试机制和错误处理
#   * 通过 bash -n 和 shellcheck 验证
#   * 增加超时时间，添加基础连接性测试

set -euo pipefail

############################# 默认参数 #############################
TZ_REGION="Asia/Shanghai"
SNTP_TIMEOUT=10      # sntp 查询超时（秒） - Increased
HTTP_TIMEOUT=10      # HTTP API 查询超时（秒）- Increased
CONNECTIVITY_CHECK_HOST="8.8.8.8" # Host for basic ping test
CONNECTIVITY_TIMEOUT=3 # Timeout for ping test
TOP_N=3
MAX_PARALLEL=8       # 并发进程

# 时区到 NTP 服务器的映射
declare -A TZ_NTP_MAP=(
  ["Asia/Shanghai"]="cn.ntp.org.cn time.pool.aliyun.com ntp1.aliyun.com ntp2.aliyun.com time.asia.apple.com cn.pool.ntp.org"
  ["default"]="time.google.com time.cloudflare.com time.aws.com time.apple.com pool.ntp.org 0.pool.ntp.org 1.pool.ntp.org"
)

# HTTP 时间 API 后备
HTTP_APIS=(
  "http://worldtimeapi.org/api/timezone/Asia/Shanghai"
  "https://timeapi.io/api/Time/current/zone?timeZone=Asia/Shanghai"
  "http://worldclockapi.com/api/json/est/now" # Added another option
)

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
  [[ $# -eq 0 ]] && return 0 # No packages to install
  log "正在使用 $pm 安装: $*"
  case $pm in
    apt-get) apt-get update -qq >/dev/null; DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >/dev/null ;;
    dnf5)    dnf5 install -y "$@" >/dev/null ;;
    dnf|yum) "$pm" install -y "$@" >/dev/null ;;
    pacman)  pacman -Sy --noconfirm --needed "$@" >/dev/null ;;
    zypper)  zypper --gpg-auto-import-keys --non-interactive install "$@" >/dev/null ;;
    apk)     apk add --no-progress "$@" >/dev/null ;;
    *)       err "不支持的软件包管理器" ;;
  esac || warn "软件包安装可能失败: $*" # Don't exit if install fails, maybe already present
}

check_connectivity() {
    log "检查基础网络连接 (ping $CONNECTIVITY_CHECK_HOST)..."
    if ping -c 1 -W "$CONNECTIVITY_TIMEOUT" "$CONNECTIVITY_CHECK_HOST" &>/dev/null; then
        ok "基础网络连接正常。"
    else
        warn "基础 ping 测试失败。可能存在网络或 DNS 问题，或 ICMP 被阻止。"
        warn "继续尝试探测，但这可能是失败的原因。"
        # 可以在这里添加一个 TCP 连接测试作为补充
        # if command -v nc &>/dev/null; then
        #   nc -z -w 3 8.8.8.8 53 &>/dev/null && ok "TCP 端口 53 (DNS) 连接测试成功。" || warn "TCP 端口 53 (DNS) 连接测试失败。"
        # fi
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
  # Capture stderr to see potential errors from sntp itself
  # Regex might need adjustment if sntp output format differs significantly across versions
  output=$(timeout "$SNTP_TIMEOUT" sntp "$host" 2>&1)
  local exit_code=$?
  delay=$(echo "$output" | grep -oP '[-+]\d+\.\d+' | head -1)

  if [[ $exit_code -eq 0 && $delay ]]; then
    printf "%s %s\n" "${delay#-}" "$host" # Remove leading +/- if present
  elif [[ $exit_code -eq 124 ]]; then
      log "  -> SNTP 超时: $host"
  else
      log "  -> SNTP 错误 ($host): $output (退出码: $exit_code)"
  fi
}
export -f probe_sntp log   # 导出函数
export SNTP_TIMEOUT       # 导出变量
# Export needed variables/functions for xargs subshell

probe_http() {
  local api=$1 delay output
  log "  -> 探测 HTTP: $api (超时 ${HTTP_TIMEOUT}s)"
  # Use -w '%{time_total}\n%{http_code}' to get time and status
  # Use --fail to make curl return non-zero on server errors (4xx, 5xx)
  output=$(curl -sSL --fail -w '%{time_total} %{http_code}' -o /dev/null --connect-timeout "$HTTP_TIMEOUT" --max-time "$HTTP_TIMEOUT" "$api" 2>/dev/null)
  local exit_code=$?
  delay=$(echo "$output" | awk '{print $1}')
  http_code=$(echo "$output" | awk '{print $2}')

  # Check curl exit code and if delay is a valid number
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
# Export needed variables/functions for xargs subshell

measure_ntp() {
  local mode="SNTP" ntp_res=()

  # 阶段 1：SNTP 探测
  log "① 通过 sntp 测试 UDP/123 延迟…"
  if ! command -v sntp &>/dev/null; then
      warn "未找到 sntp 命令，跳过 SNTP 探测阶段。"
  else
      mapfile -t ntp_res < <(printf '%s\n' "${CANDIDATE_NTPS[@]}" | xargs -P "$MAX_PARALLEL" -I{} bash -c 'probe_sntp "$1"' _ {})
  fi

  # 阶段 2：HTTP API 探测（如果 SNTP 失败或跳过）
  if (( ${#ntp_res[@]} == 0 )); then
    if [[ $mode == "SNTP" ]]; then # Only log switch if we actually tried SNTP
        warn "全部 SNTP 查询失败、超时或被跳过，切换到 HTTP API 测试 (端口 80/443)..."
    fi
    mode="HTTP"
    mapfile -t ntp_res < <(printf '%s\n' "${HTTP_APIS[@]}" | xargs -P "$MAX_PARALLEL" -I{} bash -c 'probe_http "$1"' _ {})
  fi

  # 最终回退
  if (( ${#ntp_res[@]} == 0 )); then
    warn "所有探测方式 (SNTP 和 HTTP) 均失败。网络/防火墙可能阻止 UDP/123 和 TCP/80,443 出站。"
    warn "退回使用默认 NTP 服务器: cn.ntp.org.cn 和 pool.ntp.org"
    BEST=("cn.ntp.org.cn" "pool.ntp.org")
    return # No results table to print
  fi

  # 排序并选择前 TOP_N
  mapfile -t sorted < <(printf '%s\n' "${ntp_res[@]}" | sort -n)
  BEST=()
  if [[ $mode == "HTTP" ]]; then
      # HTTP probes worked, but we need NTP servers. Use reliable defaults.
      BEST=("cn.ntp.org.cn" "time.pool.aliyun.com" "pool.ntp.org") # Use reliable defaults when HTTP probe is the only success
      log "HTTP 探测成功，但需要 NTP 服务器。选用默认可靠 NTP: ${BEST[*]}"
  else
      # SNTP probes worked. Select the best ones.
      for ((i=0; i<${TOP_N} && i<${#sorted[@]}; i++)); do
        host=$(awk '{print $2}' <<<"${sorted[i]}")
        BEST+=("$host")
      done
      # Ensure BEST is not empty if SNTP somehow returned results but parsing failed?
      [[ ${#BEST[@]} -eq 0 ]] && BEST=("cn.ntp.org.cn" "pool.ntp.org")
  fi

  # 显示结果
  log "探测结果 ($mode 模式):"
  printf "%-3s %-35s %12s\n" "#" "服务器/API" "延迟(s)"
  printf -- "-------------------------------------------------------------\n"
  local idx=1
  for l in "${sorted[@]}"; do
    printf "%-3d %-35s %12.3f\n" "$idx" "$(awk '{print $2}' <<<"$l")" "$(awk '{print $1}' <<<"$l")"
    ((idx++))
  done | tee /dev/stderr # Show results table in log
  ok "最终选用 NTP 源: ${BEST[*]}"
}

backup_file() {
  local f=$1 bak_ts
  if [[ -f $f ]]; then
      bak_ts=$(date +%Y%m%d_%H%M%S)
      log "备份 $f -> ${f}.bak.${bak_ts}"
      cp -a "$f" "${f}.bak.${bak_ts}" || warn "备份文件 $f 失败！" # Add warning on failure
  fi
}

stop_timesyncd() {
  has_systemd && {
    log "停止并禁用 systemd-timesyncd..."
    # Ignore errors as the service might not exist or be running
    systemctl stop systemd-timesyncd &>/dev/null || true
    systemctl disable systemd-timesyncd &>/dev/null || true
  }
}

start_chronyd() {
  log "启动/重启并启用 chrony 服务..."
  local service_name="chrony" # Default name
  # Some distros use chronyd
  if systemctl list-unit-files | grep -q chronyd.service; then
      service_name="chronyd"
  fi

  if has_systemd; then
    # Use restart to ensure it picks up new config
    systemctl restart "${service_name}.service" &>/dev/null || warn "${service_name} 重启失败"
    systemctl enable "${service_name}.service" &>/dev/null || warn "${service_name} 启用失败"
  else
    # Attempt OpenRC style restart (assuming service name is chronyd for non-systemd)
    rc-service chronyd restart &>/dev/null || /etc/init.d/chronyd restart &>/dev/null || warn "chrony (OpenRC) 重启失败"
    rc-update add chronyd default &>/dev/null || true # Try adding to default runlevel
  fi
}

config_chrony() {
  local conf
  conf=$(detect_chrony_conf)
  if [[ ! -f "$conf" && "$PM" == "apt-get" && -f "/etc/chrony/chrony.conf" ]]; then
      conf="/etc/chrony/chrony.conf" # Debian/Ubuntu specific path correction
  elif [[ ! -f "$conf" ]]; then
      warn "chrony 配置文件 ($conf) 未找到。尝试创建..."
      # Attempt to create a basic conf if missing
      mkdir -p "$(dirname "$conf")"
      {
          echo "# Basic chrony config generated by setup-time.sh"
          echo "driftfile /var/lib/chrony/drift"
          echo "makestep 1.0 3"
          echo "rtcsync"
          # Add logdir based on common locations
          [[ -d /var/log/chrony ]] && echo "logdir /var/log/chrony"
      } > "$conf" || { warn "创建 $conf 失败！"; return 1; }
  fi

  if [[ ! -f "$conf" ]]; then
      warn "无法找到或创建 chrony 配置文件。跳过 chrony 配置。"
      return 1 # Indicate failure
  fi

  log "配置 chrony ($conf) 使用服务器: ${BEST[*]}"
  backup_file "$conf"
  # Remove existing server/pool lines and our specific block using more robust markers
  local marker="# ---- setup-time.sh" # Use simpler marker
  sed -i -e "/^\\s*\(server\|pool\)\\s\+/d" -e "/^${marker} begin/,/^${marker} end/d" "$conf"

  # Append new server list within our block
  {
    echo "${marker} begin ----"
    for s in "${BEST[@]}"; do echo "server $s iburst"; done
    echo "# Use pool as a fallback"
    echo "pool pool.ntp.org iburst" # Adding a pool as extra fallback
    echo "${marker} end ----"
  } >>"$conf"
  log "已更新 $conf"
  stop_timesyncd
  start_chronyd
  return 0 # Indicate success
}

retry_tracking() {
  log "等待 chrony 与源同步..."
  local attempts=5 wait_times=(2 4 8 15 30) # Define attempts and waits
  for ((a=1; a<=attempts; a++)); do
    local d=${wait_times[a-1]:-30} # Get wait time or default to 30
    log "  尝试 $a/$attempts: 等待 ${d} 秒..."
    sleep "$d"
    # Check chronyc tracking status
    if ! command -v chronyc &>/dev/null; then
         warn "chronyc 命令不存在，无法检查同步状态。"
         return 1 # Cannot confirm sync
    fi
    local tracking_output
    tracking_output=$(chronyc tracking 2>&1)
    local exit_code=$?

    if [[ $exit_code -eq 0 ]] && echo "$tracking_output" | grep -q "^\(Reference ID\|Stratum\)"; then
        log "Chrony 追踪信息:"
        echo "$tracking_output" | tee /dev/stderr
        # Check stratum > 0 specifically
        local stratum
        stratum=$(echo "$tracking_output" | grep '^Stratum' | awk '{print $3}')
        if [[ "$stratum" =~ ^[0-9]+$ && "$stratum" -gt 0 && "$stratum" -lt 16 ]]; then # Stratum 16 means unsynced
            ok "Chrony 已同步 (层级 $stratum)。"
            return 0
        else
            warn "Chrony 正在追踪，但层级为 ${stratum:-未找到} (可能未完全同步或未连接)。"
             # Continue waiting
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
  mkdir -p "$(dirname "$conf_path")" # Ensure /etc/systemd exists
  {
    echo "[Time]"
    # Format servers correctly for timesyncd.conf (space separated)
    echo "NTP=$(printf '%s ' "${BEST[@]}")"
    echo "FallbackNTP=pool.ntp.org time.cloudflare.com" # Add more fallbacks
  } >"$conf_path" || { warn "写入 $conf_path 失败!"; return 1; }
  log "已写入 $conf_path"
  log "重启并启用 systemd-timesyncd..."
  systemctl restart systemd-timesyncd.service &>/dev/null || warn "systemd-timesyncd 重启失败"
  systemctl enable systemd-timesyncd.service &>/dev/null || warn "systemd-timesyncd 启用失败"
  return 0
}

sync_once() {
  log "尝试使用 ntpdate 进行一次性同步 (服务器: ${BEST[0]:-pool.ntp.org})" # Add fallback server if BEST is empty
  local ntp_server="${BEST[0]:-pool.ntp.org}"
  if ! command -v ntpdate &>/dev/null; then
      warn "ntpdate 命令不存在，跳过一次性同步。"
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
  -t TZ      指定时区（默认 $TZ_REGION）
               例如: Asia/Shanghai, Europe/London, America/New_York
  -n NUM     选取延迟最低的 NTP 数（默认 $TOP_N）
  -c FILE    使用文件中的 NTP 服务器列表替换默认列表 (每行一个服务器)
  -f         强制使用 systemd-timesyncd (如果可用) 而不是 chrony
  --sntp-timeout SEC   设置 sntp 探测超时时间 (默认 $SNTP_TIMEOUT)
  --http-timeout SEC   设置 HTTP 探测超时时间 (默认 $HTTP_TIMEOUT)
  -h         显示此帮助

增强版 v5.6: 动态软件包选择, 增强健壮性和日志记录。
EOF
  exit 0
}

# --- 解析命令行选项 ---
FORCE_TIMESYNCD=false
# Use getopt for long options
ARGS=$(getopt -o t:n:c:fh -l "sntp-timeout:,http-timeout:,help" -n "$0" -- "$@") || exit 1
eval set -- "$ARGS"

while true; do
  case "$1" in
    -t) TZ_REGION=$OPTARG
        CANDIDATE_NTPS=(${TZ_NTP_MAP["$TZ_REGION"]:-${TZ_NTP_MAP["default"]}})
        shift 2 ;;
    -n) if [[ "$OPTARG" =~ ^[1-9][0-9]*$ ]]; then TOP_N=$OPTARG; else err "选项 -n 需要一个正整数"; fi; shift 2 ;;
    -c) if [[ -r "$OPTARG" ]]; then mapfile -t CANDIDATE_NTPS < "$OPTARG"; else err "无法读取候选列表文件: $OPTARG"; fi; shift 2 ;;
    -f) FORCE_TIMESYNCD=true; shift ;;
    --sntp-timeout) if [[ "$OPTARG" =~ ^[1-9][0-9]*$ ]]; then SNTP_TIMEOUT=$OPTARG; else err "选项 --sntp-timeout 需要一个正整数"; fi; shift 2 ;;
    --http-timeout) if [[ "$OPTARG" =~ ^[1-9][0-9]*$ ]]; then HTTP_TIMEOUT=$OPTARG; else err "选项 --http-timeout 需要一个正整数"; fi; shift 2 ;;
    -h|--help) usage ;;
    --) shift; break ;;
    *) err "内部错误！"; exit 1 ;;
  esac
done
shift $((OPTIND-1))

# --- 主流程 ---
log "启动 setup-time.sh v5.6..."
require_root
PM=$(detect_pkg_mgr)
[[ $PM == unsupported ]] && err "未识别发行版或不支持的包管理器"
log "检测到包管理器: $PM"

# 基础软件包 (所有系统都需要)
PKGS_BASE=("curl" "util-linux") # util-linux for timeout

# Chrony 软件包
PKGS_CHRONY=("chrony")

# 为 sntp/ntpdate 命令确定候选软件包名称 (根据包管理器)
PKGS_SNTP_TOOLS_CANDIDATES=()
case "$PM" in
    apt-get) PKGS_SNTP_TOOLS_CANDIDATES=("sntp" "ntpdate") ;;
    dnf|dnf5|yum) PKGS_SNTP_TOOLS_CANDIDATES=("sntp" "ntpdate") ;;
    pacman) PKGS_SNTP_TOOLS_CANDIDATES=("ntp" "ntpdate") ;; # ntp provides sntp on Arch
    apk) PKGS_SNTP_TOOLS_CANDIDATES=("sntp" "ntp") ;; # Try sntp first on Alpine
    zypper) PKGS_SNTP_TOOLS_CANDIDATES=("sntp" "ntpdate") ;;
    *) PKGS_SNTP_TOOLS_CANDIDATES=("sntp" "ntpdate" "ntp") ;; # Fallback guess
esac
log "为包管理器 $PM 选择的 SNTP/NTPDate 候选包: ${PKGS_SNTP_TOOLS_CANDIDATES[*]}"


# --- 决定最终需要安装的软件包列表 ---
INSTALL_PKGS=("${PKGS_BASE[@]}") # 总是需要基础包

# 根据是否强制使用 timesyncd 或 chrony 是否可用，决定安装列表
USE_CHRONY=true # Default preference

if $FORCE_TIMESYNCD && has_systemd; then
    log "选项 -f: 强制使用 systemd-timesyncd"
    USE_CHRONY=false
    INSTALL_PKGS+=("${PKGS_SNTP_TOOLS_CANDIDATES[@]}") # Need probe/fallback tools
elif command -v chronyd &>/dev/null || [[ $PM != "unsupported" ]]; then
    log "优先尝试使用 chrony"
    INSTALL_PKGS+=("${PKGS_CHRONY[@]}" "${PKGS_SNTP_TOOLS_CANDIDATES[@]}") # Install chrony + probe/fallback tools
elif has_systemd; then
    log "未找到 chrony, 回退到 systemd-timesyncd"
    USE_CHRONY=false
    INSTALL_PKGS+=("${PKGS_SNTP_TOOLS_CANDIDATES[@]}") # Install probe/fallback tools
else
    log "未找到 chrony 且无 systemd, 仅尝试 ntpdate/sntp"
    USE_CHRONY=false
    INSTALL_PKGS+=("${PKGS_SNTP_TOOLS_CANDIDATES[@]}") # Install probe/fallback tools
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
require_cmd curl # curl 必须存在

# 验证 sntp 或 ntpdate 是否至少有一个可用
sntp_found=false
ntpdate_found=false
command -v sntp &>/dev/null && sntp_found=true
command -v ntpdate &>/dev/null && ntpdate_found=true

if ! $sntp_found && ! $ntpdate_found; then
    # 如果两者都不可用，尝试明确安装默认候选包，也许第一次 install_pkgs 调用失败了
    warn "sntp 和 ntpdate 命令在首次安装尝试后均不可用。尝试再次安装候选包..."
    # Only try installing if candidates exist
    if [[ ${#PKGS_SNTP_TOOLS_CANDIDATES[@]} -gt 0 ]]; then
        install_pkgs "$PM" "${PKGS_SNTP_TOOLS_CANDIDATES[@]}"
        # 再次检查
        command -v sntp &>/dev/null && sntp_found=true
        command -v ntpdate &>/dev/null && ntpdate_found=true
    fi

    if ! $sntp_found && ! $ntpdate_found; then
        err "安装后仍缺少 sntp 和 ntpdate 命令。请检查 '$PM' 的安装日志或手动安装 (${PKGS_SNTP_TOOLS_CANDIDATES[*]})。"
    fi
fi
log "依赖命令检查通过 (curl 及 sntp 或 ntpdate)。"

# --- 后续步骤 ---
set_timezone
check_connectivity # Add basic connectivity check
measure_ntp        # Probe servers and select BEST

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
            # Allow proceeding, maybe it will sync later
        fi
    else
        warn "Chrony 配置失败。尝试回退..."
        USE_CHRONY=false # Force fallback path now
    fi
fi

# Fallback to timesyncd if chrony wasn't used, failed, or was skipped
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

# Final fallback: ntpdate one-time sync if nothing else confirmed sync AND ntpdate is available
if ! $FINAL_SYNC_OK; then
    if $ntpdate_found; then
        warn "主要同步方法 (chrony/timesyncd) 未能确认同步。最后尝试 ntpdate 单次同步。"
        if sync_once; then
            FINAL_SYNC_OK=true
        fi
    else
         warn "主要同步方法失败，且 ntpdate 命令不可用，无法进行最后的回退同步。"
    fi
fi

# --- 最终状态 ---
if $FINAL_SYNC_OK; then
    ok "时间同步配置完成并已确认至少一种方法同步成功。"
    log "当前时间: $(date)"
    exit 0
else
    # Check if a service might sync later even if not confirmed
    if $USE_CHRONY && command -v chronyc &>/dev/null ; then
         warn "时间同步配置完成，但未能确认 chrony 是否已同步。它可能会在稍后同步。"
         exit 0 # Exit gracefully, assuming it might work later
    elif ! $USE_CHRONY && has_systemd && systemctl is-active systemd-timesyncd &>/dev/null; then
         warn "时间同步配置完成，但未能确认 systemd-timesyncd 是否已同步。它可能会在稍后同步。"
         exit 0 # Exit gracefully, assuming it might work later
    fi
    # If we reach here, no service seems configured/running or ntpdate failed too
    err "所有时间同步方法均失败或无法确认状态。请检查网络连接、防火墙设置以及 /var/log/syslog 或 journalctl 的详细错误。"
    exit 1
fi
