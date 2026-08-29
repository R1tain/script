#!/usr/bin/env bash
#===============================================================================
# set_time.sh — 时区设置 + NTP 时间同步一键脚本
#
# 版本: v6.0
# 兼容: Debian 10/11/12/13 及后续  |  Ubuntu 20.04 ~ 26.04 及后续  |  Alpine 3.x
#       (RHEL/Rocky/Fedora/Arch/openSUSE 尽力兼容)
#
# v6.0 相对 v5.8 的主要修复:
#   1. [致命] 修复参数解析:原版用外部 getopt 却读取 $OPTARG(只有内建 getopts 才
#      会设置),在 `set -u` 下任何带值选项都会以 "OPTARG: unbound variable" 崩溃。
#      现改为自实现解析器,不再依赖外部 getopt(Alpine/busybox 可能没有)。
#   2. [致命] 修复 Debian 13 / Ubuntu 25.10+ 无法运行:这些版本已移除 sntp 与
#      ntpdate 软件包(仅剩 ntpsec-ntpdate)。原版把它们和 chrony 放在同一条
#      apt install 里,一个包不存在会导致整批安装失败 —— chrony 根本没装上,
#      随后又硬性 err 退出。现改为:逐个探测可用包名 + 单包容错安装 + 探测工具
#      缺失时降级而非退出。
#   3. 去除 GNU 专属依赖(grep -oP / xargs -P / export -f),兼容 Alpine busybox。
#   4. 延迟排序改用 NTP 自身的 root distance(±值),原版取的是时钟偏移量,
#      各服务器几乎相同,排序基本无意义。
#   5. chrony 配置改为“注释 + 标记块/conf.d 落盘”,可重复执行且不破坏原配置。
#   6. 新增:容器环境检测、tzdata 自动安装、时区合法性校验、HTTP Date 兜底校时、
#      chronyc waitsync 精确等待、Alpine(OpenRC + busybox)全流程支持。
#   7. 修复 Ubuntu 24.04+ 把默认 NTP 池挪到 /etc/chrony/sources.d/ 后,只改
#      chrony.conf 关不掉发行版默认池、导致延迟排序形同虚设的问题。
#===============================================================================

# --- POSIX 引导:被 sh 调用时切换到 bash(Alpine 常见) --------------------------
if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1 && [ -f "$0" ]; then
    exec bash "$0" "$@"
  fi
  if command -v apk >/dev/null 2>&1 && [ "$(id -u)" = 0 ] && [ -f "$0" ]; then
    apk add --no-cache bash >/dev/null 2>&1 && exec bash "$0" "$@"
  fi
  echo "本脚本需要 bash 运行。Alpine 请先执行: apk add --no-cache bash" >&2
  exit 1
fi

# 说明:此处刻意不启用 `set -e`。本脚本会依次尝试 chrony → timesyncd → 单次校时
# 等多种方案,任何一步失败都应继续走后备路径,而不是让系统停在“配置到一半”的
# 状态。所有关键步骤均显式检查返回值。
set -uo pipefail

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3))); then
  echo "需要 bash 4.3 或更高版本(当前 ${BASH_VERSION})。" >&2
  exit 1
fi

readonly SCRIPT_VERSION="6.0"

############################### 默认参数 #######################################
TZ_REGION="UTC"           # 目标时区
TZ_EXPLICIT=false         # 是否由 -t 显式指定(显式指定则跳过菜单)
TOP_N=3                   # 选取延迟最低的前 N 个 NTP 服务器
PROBE_TIMEOUT=5           # 单个 NTP 探测超时(秒)
HTTP_TIMEOUT=10           # HTTP 请求超时(秒)
MAX_PARALLEL=8            # 探测并发数
FORCE_TIMESYNCD=false     # -f: 强制使用 systemd-timesyncd
SKIP_INSTALL=false        # --no-install: 不安装任何软件包
ASSUME_YES=false          # -y: 非交互,直接用默认/指定时区
CANDIDATE_FILE=""         # -c: 自定义候选服务器列表文件

# 时区 -> 推荐 NTP 服务器
declare -A TZ_NTP_MAP=(
  ["UTC"]="time.cloudflare.com time.google.com pool.ntp.org time.nist.gov 0.pool.ntp.org"
  ["Asia/Shanghai"]="ntp.aliyun.com ntp1.aliyun.com cn.ntp.org.cn ntp.tencent.com cn.pool.ntp.org time.asia.apple.com"
  ["Asia/Hong_Kong"]="hk.pool.ntp.org time.cloudflare.com time.google.com 0.asia.pool.ntp.org time.asia.apple.com"
  ["Asia/Taipei"]="tw.pool.ntp.org time.stdtime.gov.tw time.google.com time.cloudflare.com"
  ["Asia/Tokyo"]="ntp.nict.jp jp.pool.ntp.org time.asia.apple.com time.google.com 0.jp.pool.ntp.org"
  ["Asia/Seoul"]="time.bora.net kr.pool.ntp.org time.google.com 0.kr.pool.ntp.org time.asia.apple.com"
  ["Asia/Singapore"]="sg.pool.ntp.org time.google.com time.cloudflare.com 0.asia.pool.ntp.org time.apple.com"
  ["America/New_York"]="time.nist.gov time.cloudflare.com time.google.com us.pool.ntp.org time.apple.com"
  ["America/Los_Angeles"]="us.pool.ntp.org time.google.com time.cloudflare.com time.nist.gov time.apple.com"
  ["Europe/Berlin"]="ptbtime1.ptb.de ptbtime2.ptb.de de.pool.ntp.org time.cloudflare.com 0.de.pool.ntp.org"
  ["Europe/Amsterdam"]="ntp.time.nl nl.pool.ntp.org time.cloudflare.com time.google.com 0.nl.pool.ntp.org"
  ["Europe/London"]="uk.pool.ntp.org time.cloudflare.com time.google.com 0.uk.pool.ntp.org"
  ["Australia/Sydney"]="au.pool.ntp.org time.cloudflare.com time.google.com 0.oceania.pool.ntp.org"
  ["Africa/Johannesburg"]="za.pool.ntp.org 0.africa.pool.ntp.org time.cloudflare.com time.google.com"
  ["default"]="time.cloudflare.com time.google.com pool.ntp.org 0.pool.ntp.org 1.pool.ntp.org time.apple.com"
)

# 交互菜单条目:显示名 与 时区一一对应
readonly TZ_MENU_NAMES=(
  "UTC 协调世界时 [默认]" "上海 (中国大陆)"    "香港"                "台北"
  "东京 (日本)"           "首尔 (韩国)"        "新加坡"              "美国-东部"
  "美国-西部"             "柏林 (德国)"        "阿姆斯特丹 (荷兰)"   "伦敦 (英国)"
  "悉尼 (澳大利亚)"       "约翰内斯堡 (南非)"
)
readonly TZ_MENU_ZONES=(
  "UTC"                   "Asia/Shanghai"      "Asia/Hong_Kong"      "Asia/Taipei"
  "Asia/Tokyo"            "Asia/Seoul"         "Asia/Singapore"      "America/New_York"
  "America/Los_Angeles"   "Europe/Berlin"      "Europe/Amsterdam"    "Europe/London"
  "Australia/Sydney"      "Africa/Johannesburg"
)

# 连通性检查 / HTTP Date 兜底校时使用的站点(NTP 的 UDP/123 被封锁时启用)。
# 特意混入中国大陆可达的站点,避免只放 Cloudflare/Google 导致国内机器全军覆没。
readonly HTTP_TIME_URLS=(
  "https://www.cloudflare.com/"
  "https://www.baidu.com/"
  "https://www.google.com/"
  "http://www.msftconnecttest.com/connecttest.txt"
)

# 运行期状态
CANDIDATE_NTPS=()
BEST=()
PM=""            # 包管理器
INIT_SYS=""      # systemd / openrc / unknown
OS_ID=""; OS_PRETTY=""
PROBE_TOOL=""    # sntp / ntpdig / ntpdate / chronyd / none
CHRONY_SERVICE="" # chrony 服务单元名
IN_CONTAINER=false
APT_UPDATED=false
TMPDIR_WORK=""
BACKUPS=()
###############################################################################

#--------------------------------- 日志输出 -----------------------------------
if [[ -t 2 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
  C_INFO=$'\033[36m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_OK=$'\033[32m'; C_OFF=$'\033[0m'
else
  C_INFO=""; C_WARN=""; C_ERR=""; C_OK=""; C_OFF=""
fi

log()  { printf '%s[%s] %s%s\n' "$C_INFO" "$(date '+%F %T')" "$*" "$C_OFF" >&2; }
warn() { printf '%s[warn] %s%s\n' "$C_WARN" "$*" "$C_OFF" >&2; }
ok()   { printf '%s[ ok ] %s%s\n' "$C_OK" "$*" "$C_OFF" >&2; }
die()  { printf '%s[fail] %s%s\n' "$C_ERR" "$*" "$C_OFF" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# shellcheck disable=SC2317  # 通过 trap 调用
cleanup() { [[ -n "$TMPDIR_WORK" && -d "$TMPDIR_WORK" ]] && rm -rf "$TMPDIR_WORK"; }
trap cleanup EXIT

# 统一的超时执行:GNU timeout 超时返回 124,busybox 被 TERM 杀死返回 143
run_timeout() {
  local secs=$1; shift
  if have timeout; then timeout "$secs" "$@"; else "$@"; fi
}

#------------------------------ 环境探测 --------------------------------------
# 不用 `. /etc/os-release`:那会把 ID/NAME/VERSION 等一堆变量灌进当前命名空间,
# 并与本脚本的只读变量冲突(实测会报 "VERSION: readonly variable")。
os_release_get() {
  [[ -r /etc/os-release ]] || return 1
  awk -v k="$1" -F= '
    $1 == k {
      v = substr($0, index($0, "=") + 1)
      gsub(/^[\047"]|[\047"]$/, "", v)
      print v; exit
    }' /etc/os-release
}

detect_os() {
  OS_ID=$(os_release_get ID); OS_ID="${OS_ID:-unknown}"
  OS_PRETTY=$(os_release_get PRETTY_NAME)
  [[ -n "$OS_PRETTY" ]] || OS_PRETTY="$OS_ID $(os_release_get VERSION_ID)"
}

detect_init() {
  if [[ -d /run/systemd/system ]] && have systemctl; then
    INIT_SYS="systemd"
  elif have rc-service || [[ -d /etc/init.d && -f /sbin/openrc ]]; then
    INIT_SYS="openrc"
  else
    INIT_SYS="unknown"
  fi
}

detect_pkg_mgr() {
  local m
  for m in apt-get apk dnf5 dnf yum pacman zypper; do
    have "$m" && { PM="$m"; return 0; }
  done
  PM="none"; return 1
}

detect_container() {
  if [[ -f /.dockerenv || -f /run/.containerenv ]]; then
    IN_CONTAINER=true
  elif have systemd-detect-virt && systemd-detect-virt --container --quiet 2>/dev/null; then
    IN_CONTAINER=true
  elif [[ -r /proc/1/environ ]] && grep -qa 'container=' /proc/1/environ 2>/dev/null; then
    IN_CONTAINER=true
  fi
}

#------------------------------ 软件包安装 ------------------------------------
apt_update_once() {
  $APT_UPDATED && return 0
  APT_UPDATED=true
  log "刷新 apt 软件包索引…"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 \
    || warn "apt-get update 失败,继续使用现有索引。"
}

# 判断某个包在当前源里是否真的可安装(未知的包管理器则假定可装,直接尝试)
pkg_exists() {
  local p=$1
  case "$PM" in
    # 注意:`apt-cache show sntp` 在 Debian 13 上仍返回 0(存在被依赖引用的幽灵
    # 记录),必须看 policy 的 Candidate 是否为 (none)。
    apt-get) apt_update_once
             apt-cache policy "$p" 2>/dev/null \
               | awk '/Candidate:/ { if ($2 != "(none)") found = 1 } END { exit !found }' ;;
    apk)     apk info --description "$p" >/dev/null 2>&1 || apk search -x "$p" 2>/dev/null | grep -q . ;;
    dnf5|dnf|yum) "$PM" info "$p" >/dev/null 2>&1 ;;
    pacman)  pacman -Si "$p" >/dev/null 2>&1 ;;
    zypper)  zypper --non-interactive info "$p" >/dev/null 2>&1 ;;
    *)       return 0 ;;
  esac
}

# 安装一组包。整体失败时退化为逐包安装,避免“一个包不存在导致全批失败”
pkg_install() {
  (($# == 0)) && return 0
  $SKIP_INSTALL && { log "--no-install:跳过安装 $*"; return 0; }

  local -a pkgs=("$@")
  log "安装软件包: ${pkgs[*]}"
  if _pkg_install_batch "${pkgs[@]}"; then
    return 0
  fi
  (($# == 1)) && return 1

  # 关键:一整批里只要有一个包不存在,apt/dnf 会整批失败、一个都装不上
  # (原版 v5.8 在 Debian 13 上就是这样把 chrony 和 curl 一起弄丢的)。
  warn "批量安装失败,改为逐个安装以尽量装上可用的包…"
  local p rc=1
  for p in "${pkgs[@]}"; do
    if _pkg_install_batch "$p"; then rc=0; else warn "安装失败(已跳过): $p"; fi
  done
  return $rc
}

_pkg_install_batch() {
  case "$PM" in
    apt-get)
      apt_update_once
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        --no-install-recommends \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
        "$@" >/dev/null 2>&1
      ;;
    apk)          apk add --no-cache "$@" >/dev/null 2>&1 ;;
    dnf5|dnf|yum) "$PM" install -y "$@" >/dev/null 2>&1 ;;
    pacman)       pacman -Sy --noconfirm --needed "$@" >/dev/null 2>&1 ;;
    zypper)       zypper --gpg-auto-import-keys --non-interactive install -y "$@" >/dev/null 2>&1 ;;
    *)            return 1 ;;
  esac
}

# 从候选包名里安装第一个存在的(用于 sntp / ntpdig / ntpdate 这类改名的包)
pkg_install_first_available() {
  local p
  for p in "$@"; do
    if pkg_exists "$p"; then
      log "候选包 $p 可用,尝试安装…"
      pkg_install "$p" && return 0
    fi
  done
  return 1
}

#------------------------------ 服务管理 --------------------------------------
unit_exists() {
  [[ "$INIT_SYS" == systemd ]] || return 1
  [[ "$(systemctl show -p LoadState --value "$1" 2>/dev/null)" == "loaded" ]]
}

svc_restart() {
  local s=$1
  case "$INIT_SYS" in
    systemd) systemctl restart "$s" >/dev/null 2>&1 ;;
    openrc)  rc-service "$s" restart >/dev/null 2>&1 || /etc/init.d/"$s" restart >/dev/null 2>&1 ;;
    *)       [[ -x /etc/init.d/$s ]] && /etc/init.d/"$s" restart >/dev/null 2>&1 ;;
  esac
}

svc_enable() {
  local s=$1
  case "$INIT_SYS" in
    systemd) systemctl enable "$s" >/dev/null 2>&1 ;;
    openrc)  rc-update add "$s" default >/dev/null 2>&1 ;;
    *)       return 0 ;;
  esac
}

svc_disable_now() {
  local s=$1
  case "$INIT_SYS" in
    systemd) unit_exists "$s" && systemctl disable --now "$s" >/dev/null 2>&1 ;;
    openrc)  rc-service "$s" stop >/dev/null 2>&1; rc-update del "$s" default >/dev/null 2>&1 ;;
    *)       return 0 ;;
  esac
  return 0
}

svc_active() {
  local s=$1
  case "$INIT_SYS" in
    systemd) systemctl is-active --quiet "$s" ;;
    openrc)  rc-service "$s" status >/dev/null 2>&1 ;;
    *)       return 1 ;;
  esac
}

#------------------------------ 时区处理 --------------------------------------
tz_valid() { [[ -n "$1" && "$1" != */../* && -f "/usr/share/zoneinfo/$1" ]]; }

select_timezone() {
  $TZ_EXPLICIT && return 0
  if $ASSUME_YES || [[ ! -t 0 ]]; then
    log "非交互模式,使用默认时区: $TZ_REGION"
    return 0
  fi

  printf '%s请选择时区(直接回车 = 0 = UTC,也可直接输入完整时区名如 Asia/Chongqing):%s\n' \
    "$C_INFO" "$C_OFF" >&2
  local i
  for i in "${!TZ_MENU_NAMES[@]}"; do
    printf '  %2d) %-22s %s\n' "$i" "${TZ_MENU_NAMES[i]}" "${TZ_MENU_ZONES[i]}" >&2
  done

  local choice=""
  printf '请输入编号或时区名 [0]: ' >&2
  read -r choice || choice=""
  choice="${choice// /}"
  choice="${choice:-0}"

  if [[ "$choice" =~ ^[0-9]+$ ]]; then
    if ((choice < ${#TZ_MENU_ZONES[@]})); then
      TZ_REGION="${TZ_MENU_ZONES[choice]}"
    else
      warn "编号 $choice 超出范围,使用默认 UTC"
      TZ_REGION="UTC"
    fi
  elif tz_valid "$choice"; then
    TZ_REGION="$choice"
  else
    warn "无效输入 '$choice',使用默认 UTC"
    TZ_REGION="UTC"
  fi
  ok "已选择时区: $TZ_REGION"
}

apply_timezone() {
  if ! tz_valid "$TZ_REGION"; then
    warn "时区 '$TZ_REGION' 在 /usr/share/zoneinfo 中不存在,尝试安装 tzdata…"
    pkg_install tzdata
    if ! tz_valid "$TZ_REGION"; then
      warn "时区 '$TZ_REGION' 仍不可用,回退到 UTC"
      TZ_REGION="UTC"
      tz_valid "$TZ_REGION" || { warn "系统缺少 tzdata,跳过时区设置。"; return 1; }
    fi
  fi

  log "设置时区为 $TZ_REGION …"
  if [[ "$INIT_SYS" == systemd ]] && have timedatectl \
     && timedatectl set-timezone "$TZ_REGION" >/dev/null 2>&1; then
    ok "时区已设置: $TZ_REGION (timedatectl)"
    return 0
  fi

  # 无 systemd(Alpine / 容器)时手工落盘
  if ln -sf "/usr/share/zoneinfo/$TZ_REGION" /etc/localtime 2>/dev/null; then
    printf '%s\n' "$TZ_REGION" > /etc/timezone 2>/dev/null || true
    ok "时区已设置: $TZ_REGION (/etc/localtime)"
    return 0
  fi

  warn "时区设置失败(只读文件系统或权限不足?)"
  return 1
}

#------------------------------ 网络与探测 ------------------------------------
load_candidates() {
  local list
  if [[ -n "$CANDIDATE_FILE" ]]; then
    mapfile -t CANDIDATE_NTPS < <(sed -e 's/#.*//' -e 's/[[:space:]]\+//g' "$CANDIDATE_FILE" | grep -v '^$')
    ((${#CANDIDATE_NTPS[@]})) || die "候选列表文件为空: $CANDIDATE_FILE"
    log "使用自定义候选列表(${#CANDIDATE_NTPS[@]} 项): $CANDIDATE_FILE"
    return 0
  fi
  list="${TZ_NTP_MAP[$TZ_REGION]:-${TZ_NTP_MAP[default]}}"
  read -r -a CANDIDATE_NTPS <<<"$list"
}

# 探测失败时的兜底服务器:直接取候选列表前 N 个
# (候选列表可能来自 -c 指定的文件,所以不能写死回 TZ_NTP_MAP)
default_servers() {
  printf '%s\n' "${CANDIDATE_NTPS[@]:0:$TOP_N}"
}

check_connectivity() {
  log "检查网络连通性…"
  local u
  if have curl; then
    for u in "${HTTP_TIME_URLS[@]}"; do
      if curl -fsS --max-time 6 -o /dev/null "$u" 2>/dev/null; then
        ok "HTTPS 出站正常($u)。"
        return 0
      fi
    done
  fi
  if have ping && ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
    ok "ICMP 出站正常。"
    return 0
  fi
  warn "未能确认外网连通性(可能被防火墙拦截),继续尝试。"
  return 1
}

# 选择可用的 NTP 探测工具。注意:Debian 13 / Ubuntu 25.10+ 已删除 sntp、ntpdate,
# 仅保留 ntpsec-ntpdate(提供 /usr/sbin/ntpdate)与 ntpsec-ntpdig(/usr/bin/ntpdig)。
pick_probe_tool() {
  local t
  for t in sntp ntpdig ntpdate; do
    have "$t" && { PROBE_TOOL="$t"; log "使用 $t 进行 NTP 延迟探测。"; return 0; }
  done
  if have chronyd; then
    PROBE_TOOL="chronyd"
    log "未找到 sntp/ntpdig/ntpdate,使用 chronyd -Q 进行探测。"
    return 0
  fi
  PROBE_TOOL="none"
  warn "无可用的 NTP 探测工具,将直接使用所选时区的推荐服务器。"
  return 1
}

# 探测单个服务器,成功时输出 "<指标> <主机名>"。指标越小越好。
# sntp/ntpdig/ntpdate -q 输出格式一致:
#   2026-08-29 10:18:33.337 (+0000) +0.002708 +/- 0.001574 host 1.2.3.4 s3 no-leap
# 其中 "+/-" 后的 root distance 才是可用于排序的距离/延迟指标;
# 原版 v5.8 取的是 +0.002708(时钟偏移),各服务器几乎相同,排序无意义。
probe_server() {
  local host=$1 out rc metric start end elapsed=""

  if [[ -n "${EPOCHREALTIME:-}" ]]; then start="${EPOCHREALTIME/,/.}"; fi

  case "$PROBE_TOOL" in
    sntp)    out=$(run_timeout "$PROBE_TIMEOUT" sntp -t "$PROBE_TIMEOUT" "$host" 2>&1) ;;
    ntpdig)  out=$(run_timeout "$PROBE_TIMEOUT" ntpdig -t "$PROBE_TIMEOUT" "$host" 2>&1) ;;
    ntpdate) out=$(run_timeout "$PROBE_TIMEOUT" ntpdate -q "$host" 2>&1) ;;
    chronyd) out=$(run_timeout "$((PROBE_TIMEOUT + 3))" chronyd -Q -t "$PROBE_TIMEOUT" \
                     "server $host iburst maxsamples 1" 2>&1) ;;
    *)       return 1 ;;
  esac
  rc=$?

  if [[ -n "${EPOCHREALTIME:-}" && -n "$start" ]]; then
    end="${EPOCHREALTIME/,/.}"
    elapsed=$(awk -v a="$start" -v b="$end" 'BEGIN{printf "%.6f", b-a}')
  fi

  if ((rc != 0)) && [[ "$PROBE_TOOL" != chronyd ]]; then
    return 1
  fi

  # 排序指标:优先用 NTP 自己给出的 root distance(sntp / ntpdig / ntpdate -q)
  metric=$(printf '%s\n' "$out" | awk '
    $5 == "+/-" && $6 ~ /^[0-9.]+$/ { printf "%.6f\n", $6 + 0; found = 1; exit }
    END { if (!found) exit 1 }
  ' 2>/dev/null)

  # chronyd -Q 只报得出"时钟偏移"。而系统时间本来就不准时,所有服务器报的偏移
  # 都是同一个大数字(Alpine 真机实测:时钟差 8 分钟时,5 个服务器排出来是
  # 480.627 / 480.629 / 480.631 / 480.633 / 480.639 —— 差异纯属噪声,排序等于
  # 随机)。所以这里只拿它确认"探测成功",排序改用实测往返耗时。
  if [[ -z "$metric" ]] && printf '%s\n' "$out" | grep -q 'System clock wrong by'; then
    metric="${elapsed:-1.000000}"
  fi

  # 兜底:输出格式不认识但进程正常退出,用实测耗时
  [[ -z "$metric" && $rc -eq 0 && -n "$elapsed" ]] && metric="$elapsed"
  [[ -z "$metric" ]] && return 1

  printf '%s %s\n' "$metric" "$host"
}

# 并发探测所有候选服务器(用 bash 作业控制,不依赖 GNU xargs -P)
measure_ntp() {
  BEST=()

  if [[ "$PROBE_TOOL" == none ]]; then
    mapfile -t BEST < <(default_servers)
    log "跳过探测,使用推荐服务器: ${BEST[*]}"
    return 0
  fi

  log "探测 ${#CANDIDATE_NTPS[@]} 个候选 NTP 服务器(并发 $MAX_PARALLEL,超时 ${PROBE_TIMEOUT}s)…"
  TMPDIR_WORK=$(mktemp -d 2>/dev/null) || TMPDIR_WORK="/tmp/set_time.$$"
  mkdir -p "$TMPDIR_WORK"

  local host i=0 running=0
  for host in "${CANDIDATE_NTPS[@]}"; do
    while ((running >= MAX_PARALLEL)); do
      wait -n 2>/dev/null
      ((running--))
    done
    probe_server "$host" >"$TMPDIR_WORK/r$i" 2>/dev/null &
    ((running++)); ((i++))
  done
  wait

  local -a results=()
  mapfile -t results < <(cat "$TMPDIR_WORK"/r* 2>/dev/null | grep -E '^[0-9.]+ ' | sort -n)

  if ((${#results[@]} == 0)); then
    warn "所有 NTP 探测均失败(UDP/123 可能被防火墙拦截)。"
    warn "回退使用时区 $TZ_REGION 的推荐服务器。"
    mapfile -t BEST < <(default_servers)
    return 1
  fi

  printf '%s%-3s %-34s %12s%s\n' "$C_INFO" "#" "NTP 服务器" "指标(秒)" "$C_OFF" >&2
  printf -- '------------------------------------------------------------\n' >&2
  local idx=1 line
  for line in "${results[@]}"; do
    printf '%-3d %-34s %12s\n' "$idx" "${line#* }" "${line%% *}" >&2
    ((idx++))
  done

  for line in "${results[@]:0:$TOP_N}"; do BEST+=("${line#* }"); done
  ok "选用 NTP 源: ${BEST[*]}"
  return 0
}

#------------------------------ chrony 配置 -----------------------------------
backup_file() {
  local f=$1 bak
  [[ -f "$f" ]] || return 0

  # 内容与最近一次备份相同就不再重复备份,避免反复执行堆出一堆 .bak。
  # 备份名是 .bak.YYYYmmdd_HHMMSS,字典序即时间序。
  local -a baks=()
  mapfile -t baks < <(printf '%s\n' "${f}".bak.* | sort -r)
  [[ -f "${baks[0]:-}" ]] && cmp -s "$f" "${baks[0]}" && return 0

  bak="${f}.bak.$(date +%Y%m%d_%H%M%S)"
  if cp -a "$f" "$bak" 2>/dev/null; then
    BACKUPS+=("$bak")
    log "已备份 $f -> $bak"
  else
    warn "备份 $f 失败"
  fi
}

chrony_conf_path() {
  local f
  for f in /etc/chrony/chrony.conf /etc/chrony.conf; do
    [[ -f "$f" ]] && { printf '%s\n' "$f"; return 0; }
  done
  # 未找到则按发行版惯例给出应创建的位置
  case "$OS_ID" in
    debian|ubuntu|linuxmint|raspbian|pop|devuan|alpine) printf '/etc/chrony/chrony.conf\n' ;;
    *) printf '/etc/chrony.conf\n' ;;
  esac
}

resolve_chrony_service() {
  case "$INIT_SYS" in
    systemd)
      local u
      for u in chrony.service chronyd.service; do
        unit_exists "$u" && { CHRONY_SERVICE="$u"; return 0; }
      done
      ;;
    openrc)
      local s
      for s in chronyd chrony; do
        [[ -x /etc/init.d/$s ]] && { CHRONY_SERVICE="$s"; return 0; }
      done
      ;;
  esac
  CHRONY_SERVICE=""
  return 1
}

# 生成我们自己的服务器配置块
render_server_block() {
  local s
  printf '# ---- managed by set_time.sh v%s (%s) ----\n' "$SCRIPT_VERSION" "$(date '+%F %T')"
  for s in "${BEST[@]}"; do printf 'server %s iburst\n' "$s"; done
  printf '# 兜底 pool\npool pool.ntp.org iburst\nmakestep 1.0 3\nrtcsync\n'
}

# Ubuntu 24.04+ 把发行版默认 NTP 池挪到了 /etc/chrony/sources.d/*.sources,
# 只改 chrony.conf 是关不掉的 —— 那样我们挑出来的最优服务器会和发行版默认池
# 混在一起,延迟排序就白做了。这里把它们注释掉(有备份,可回滚)。
neutralize_source_dirs() {
  local conf=$1 dir f
  while read -r dir; do
    [[ -n "$dir" && -d "$dir" ]] || continue
    # /run/chrony-dhcp 由 DHCP 下发(通常是云厂商的本地 NTP,质量很好),
    # 且重启即重建,不去动它。
    case "$dir" in /run/*|/var/run/*) continue ;; esac
    for f in "$dir"/*.sources; do
      [[ -f "$f" ]] || continue
      grep -qE '^[[:space:]]*(server|pool|peer)[[:space:]]' "$f" || continue
      backup_file "$f"
      sed -i -E 's/^([[:space:]]*(server|pool|peer)[[:space:]]+)/#\1/' "$f" 2>/dev/null \
        && log "已注释发行版默认时间源: $f"
    done
  done < <(awk '/^[[:space:]]*sourcedir[[:space:]]+/ { print $2 }' "$conf" 2>/dev/null)
}

configure_chrony() {
  have chronyd || { warn "未安装 chronyd,跳过 chrony 配置。"; return 1; }

  local conf; conf=$(chrony_conf_path)
  local confdir="" marker="# ---- managed by set_time.sh"

  if [[ ! -f "$conf" ]]; then
    log "chrony 配置 $conf 不存在,创建最小配置。"
    mkdir -p "$(dirname "$conf")" 2>/dev/null
    {
      printf '# generated by set_time.sh v%s\n' "$SCRIPT_VERSION"
      printf 'driftfile /var/lib/chrony/drift\nlogdir /var/log/chrony\n'
    } >"$conf" 2>/dev/null || { warn "创建 $conf 失败。"; return 1; }
    mkdir -p /var/lib/chrony 2>/dev/null
  fi

  backup_file "$conf"

  # Debian 12+/Ubuntu 24.04+ 的 chrony.conf 带 `confdir /etc/chrony/conf.d`,
  # 优先写入 drop-in 目录,升级安全且不污染发行版配置。
  if grep -qE '^[[:space:]]*confdir[[:space:]]+' "$conf" 2>/dev/null; then
    confdir=$(awk '/^[[:space:]]*confdir[[:space:]]+/ { print $2; exit }' "$conf")
  fi

  # 1) 清掉本脚本上一次写入的标记块(保证可重复执行、不叠加)
  sed -i "/^${marker}/,/^# ---- end set_time.sh/d" "$conf" 2>/dev/null
  # 兼容旧版:一并清掉 v5.x(setup-time.sh)留下的标记块
  sed -i '/^# ---- setup-time\.sh begin/,/^# ---- setup-time\.sh end/d' "$conf" 2>/dev/null

  # 2) 注释掉(而非删除)发行版自带的 server/pool/peer,便于回滚
  sed -i -E 's/^([[:space:]]*(server|pool|peer)[[:space:]]+)/#\1/' "$conf" 2>/dev/null

  # 3) 同样处理 sourcedir 指向的 *.sources(Ubuntu 24.04+ 默认池藏在这里)
  neutralize_source_dirs "$conf"

  if [[ -n "$confdir" ]] && mkdir -p "$confdir" 2>/dev/null; then
    local dropin="$confdir/99-set-time.conf"
    { render_server_block; } >"$dropin" 2>/dev/null || { warn "写入 $dropin 失败。"; return 1; }
    log "已写入 chrony drop-in: $dropin"
  else
    { render_server_block; printf '# ---- end set_time.sh ----\n'; } >>"$conf" 2>/dev/null \
      || { warn "写入 $conf 失败。"; return 1; }
    log "已更新 $conf"
  fi

  # 与 systemd-timesyncd 互斥,避免两个守护进程抢时钟
  svc_disable_now systemd-timesyncd.service

  # 无 init 的容器里启动守护进程没有意义(也没有 CAP_SYS_TIME),配置写好即可
  if $IN_CONTAINER && [[ "$INIT_SYS" == unknown ]]; then
    log "容器环境且无 init 系统:配置已写入,跳过守护进程启动。"
    return 0
  fi

  if ! resolve_chrony_service; then
    warn "未找到 chrony 服务单元,尝试直接以 chronyd 启动。"
    chronyd >/dev/null 2>&1 && { ok "chronyd 已后台启动。"; return 0; }
    return 1
  fi

  log "重启并启用 $CHRONY_SERVICE …"
  svc_restart "$CHRONY_SERVICE" || { warn "$CHRONY_SERVICE 启动失败。"; return 1; }
  svc_enable "$CHRONY_SERVICE" || warn "$CHRONY_SERVICE 开机自启设置失败。"

  # systemd 上让 timedated 也认可(chrony 的 ntp-units.d 优先于 timesyncd)
  [[ "$INIT_SYS" == systemd ]] && have timedatectl && \
    timedatectl set-ntp true >/dev/null 2>&1
  return 0
}

verify_chrony() {
  have chronyc || { warn "缺少 chronyc,无法验证同步状态。"; return 1; }

  # 先确认 chronyd 真的在跑:否则 waitsync 会白白空等几十秒
  local i
  for i in 1 2 3 4 5; do
    chronyc -n tracking >/dev/null 2>&1 && break
    if ((i == 5)); then
      warn "chronyd 未在运行(chronyc 无法连接),跳过同步验证。"
      return 1
    fi
    sleep 1
  done

  log "等待 chrony 完成首次同步(最多 ~30 秒)…"
  # chronyc waitsync <最大次数> <最大偏移> <最大 skew> <间隔秒>
  local out rc
  out=$(chronyc waitsync 30 0.5 0 1 2>&1); rc=$?
  if ((rc == 0)); then
    ok "chrony 已同步。"
    chronyc tracking 2>/dev/null | sed 's/^/    /' >&2
    return 0
  fi

  # 极老版本的 chrony 没有 waitsync,退化为轮询 tracking
  if [[ "$out" == *nknown*command* || "$out" == *"Invalid command"* ]]; then
    local stratum
    for i in 1 2 3 4 5; do
      stratum=$(chronyc tracking 2>/dev/null | awk '/^Stratum/ { print $3; exit }')
      if [[ "$stratum" =~ ^[0-9]+$ ]] && ((stratum > 0 && stratum < 16)); then
        ok "chrony 已同步(stratum $stratum)。"
        chronyc tracking 2>/dev/null | sed 's/^/    /' >&2
        return 0
      fi
      sleep 3
    done
  fi

  warn "chrony 已运行,但暂未确认同步(可能需要更多时间)。"
  chronyc sources 2>/dev/null | sed 's/^/    /' >&2
  return 1
}

#--------------------------- systemd-timesyncd --------------------------------
configure_timesyncd() {
  [[ "$INIT_SYS" == systemd ]] || return 1

  if ! unit_exists systemd-timesyncd.service; then
    log "systemd-timesyncd 未安装,尝试安装…"
    pkg_install systemd-timesyncd
    systemctl daemon-reload >/dev/null 2>&1
    unit_exists systemd-timesyncd.service || { warn "systemd-timesyncd 不可用。"; return 1; }
  fi

  # 用 drop-in 而不是覆盖主配置,升级安全
  local dir=/etc/systemd/timesyncd.conf.d
  mkdir -p "$dir" 2>/dev/null || { warn "无法创建 $dir"; return 1; }
  {
    printf '# generated by set_time.sh v%s\n[Time]\n' "$SCRIPT_VERSION"
    printf 'NTP=%s\n' "${BEST[*]}"
    printf 'FallbackNTP=pool.ntp.org time.cloudflare.com\n'
  } >"$dir/99-set-time.conf" 2>/dev/null || { warn "写入 timesyncd drop-in 失败。"; return 1; }
  log "已写入 $dir/99-set-time.conf"

  svc_disable_now chrony.service
  svc_disable_now chronyd.service
  systemctl enable systemd-timesyncd.service >/dev/null 2>&1
  systemctl restart systemd-timesyncd.service >/dev/null 2>&1 \
    || { warn "systemd-timesyncd 启动失败。"; return 1; }
  have timedatectl && timedatectl set-ntp true >/dev/null 2>&1
  return 0
}

verify_timesyncd() {
  have timedatectl || return 1
  log "等待 systemd-timesyncd 同步(最多 20 秒)…"
  local deadline=$((SECONDS + 20))
  while ((SECONDS < deadline)); do
    if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -qi '^yes$'; then
      ok "systemd-timesyncd 已同步。"
      timedatectl timesync-status 2>/dev/null | sed 's/^/    /' >&2
      return 0
    fi
    sleep 2
  done
  warn "systemd-timesyncd 已启动,但暂未确认同步。"
  return 1
}

#------------------------------ 兜底校时 --------------------------------------
# 1) chronyc makestep(chronyd 已在跑时)2) chronyd -q  3) ntpdate/ntpdig
# 4) HTTP Date 响应头
oneshot_sync() {
  local server="${BEST[0]:-pool.ntp.org}"

  # chronyd 已经在运行时,端口被占着,chronyd -q 是起不来的;
  # 这种情况正确的做法是让在跑的实例立刻跨步校正。
  if have chronyc && chronyc -n tracking >/dev/null 2>&1; then
    log "chronyd 正在运行,请求立即校正(chronyc makestep)…"
    chronyc makestep >/dev/null 2>&1
    if chronyc waitsync 10 0.5 0 1 >/dev/null 2>&1; then
      ok "chrony 已完成校正。"
      return 0
    fi
  elif have chronyd; then
    log "尝试 chronyd -q 单次校时($server)…"
    if run_timeout 20 chronyd -q "server $server iburst" >/dev/null 2>&1; then
      ok "chronyd 单次校时成功。"
      return 0
    fi
  fi

  if have ntpdate; then
    log "尝试 ntpdate 单次校时($server)…"
    run_timeout 20 ntpdate -u "$server" >/dev/null 2>&1 && { ok "ntpdate 校时成功。"; return 0; }
  fi
  if have ntpdig; then
    log "尝试 ntpdig -S 单次校时($server)…"
    run_timeout 20 ntpdig -S "$server" >/dev/null 2>&1 && { ok "ntpdig 校时成功。"; return 0; }
  fi

  set_clock_from_http
}

# UDP/123 被完全封锁时,用 HTTPS 响应头里的 Date 粗略校时(精度 ~1 秒)
set_clock_from_http() {
  have curl || return 1
  local url http_date rc
  for url in "${HTTP_TIME_URLS[@]}"; do
    http_date=$(curl -fsSI --max-time "$HTTP_TIMEOUT" "$url" 2>/dev/null \
      | awk 'tolower($1) == "date:" { sub(/^[^:]*:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit }')
    [[ -n "$http_date" ]] || continue
    log "从 $url 取得时间: $http_date"
    _date_set "$http_date"; rc=$?
    if ((rc == 0)); then
      ok "已按 HTTP Date 校时(精度约 1 秒)。"
      have hwclock && hwclock --systohc >/dev/null 2>&1
      return 0
    fi
    # 无权限时换个 URL 也没用,直接放弃
    ((rc == 2)) && { warn "无权限修改系统时钟,放弃 HTTP 兜底校时。"; return 1; }
  done
  warn "HTTP Date 兜底校时失败。"
  return 1
}

# 设置系统时间。注意:busybox 的 `date -s` 失败时仍然返回 0(只往 stderr 写
# "can't set date"),所以这里以 stderr 是否为空来判定成败,不能只看退出码。
# 返回值:0 成功 / 2 无权限(容器) / 1 其它失败
_date_set() {
  local when=$1 err1 err2
  err1=$(date -u -s "$when" 2>&1 >/dev/null)
  [[ -z "$err1" ]] && return 0
  case "$err1" in
    *"not permitted"*|*"Permission denied"*) warn "写入系统时钟失败: $err1"; return 2 ;;
  esac

  # GNU date 解析失败时再试 busybox 的 -D 形式(GNU date 没有 -D,会报 invalid option)
  err2=$(date -u -D '%a, %d %b %Y %H:%M:%S' -s "${when% GMT}" 2>&1 >/dev/null)
  [[ -z "$err2" ]] && return 0
  case "$err2" in
    *"not permitted"*|*"Permission denied"*) warn "写入系统时钟失败: $err2"; return 2 ;;
  esac

  warn "写入系统时钟失败: $err1"
  return 1
}

#------------------------------ 依赖准备 --------------------------------------
install_dependencies() {
  $SKIP_INSTALL && { log "--no-install:跳过全部软件包安装。"; return 0; }

  local -a base=(ca-certificates tzdata)
  have curl || base+=(curl)
  pkg_install "${base[@]}"

  if ! $FORCE_TIMESYNCD && ! have chronyd; then
    pkg_install chrony || warn "chrony 安装失败,稍后将尝试其它方案。"
  fi

  # 探测工具:各发行版包名随版本变化很大,逐个尝试第一个存在的
  if ! have sntp && ! have ntpdig && ! have ntpdate; then
    local -a cands
    case "$PM" in
      # Debian 13 / Ubuntu 25.10+ 已删除 sntp、ntpdate,只剩 ntpsec-*
      apt-get) cands=(sntp ntpsec-ntpdig ntpsec-ntpdate ntpdate) ;;
      apk)     cands=(chrony) ;;   # Alpine 无 sntp/ntpdate,靠 chronyd -Q 探测
      dnf5|dnf|yum) cands=(sntp ntpsec-ntpdig ntpstat ntpdate) ;;
      pacman)  cands=(ntp) ;;
      zypper)  cands=(sntp ntp ntpdate) ;;
      *)       cands=(sntp ntpdate) ;;
    esac
    pkg_install_first_available "${cands[@]}" \
      || log "未能安装独立探测工具,将使用 chronyd -Q 或直接采用推荐服务器。"
  fi
}

#------------------------------ 参数与帮助 ------------------------------------
usage() {
  cat >&2 <<EOF
用法: $0 [选项]

  -t, --timezone TZ    指定时区并跳过交互菜单(如 UTC / Asia/Shanghai)
  -n, --top N          选取延迟最低的 NTP 服务器数量(默认 $TOP_N)
  -c, --candidates F   从文件读取候选 NTP 服务器(每行一个,支持 # 注释)
  -f, --timesyncd      强制使用 systemd-timesyncd 而不是 chrony
      --probe-timeout S  单个 NTP 探测超时秒数(默认 $PROBE_TIMEOUT)
      --http-timeout S   HTTP 请求超时秒数(默认 $HTTP_TIMEOUT)
      --parallel N     探测并发数(默认 $MAX_PARALLEL)
      --no-install     不安装任何软件包,只用系统现有工具
  -y, --yes            非交互模式(不弹时区菜单,使用默认/指定时区)
  -h, --help           显示帮助
  -V, --version        显示版本

示例:
  $0                              # 交互选择时区
  $0 -y -t Asia/Shanghai          # 全自动,设为上海时区
  $0 -t UTC -n 4 --no-install     # 只用现有工具,选 4 个最优 NTP 源

兼容: Debian 10-13+ / Ubuntu 20.04-26.04+ / Alpine 3.x
EOF
  exit "${1:-0}"
}

need_value() { [[ -n "${2:-}" ]] || die "选项 $1 需要一个参数"; }
need_posint() { [[ "$2" =~ ^[1-9][0-9]*$ ]] || die "选项 $1 需要一个正整数,收到 '$2'"; }

parse_args() {
  # 把 --opt=value 归一化成 --opt value,简化后续处理
  local -a argv=()
  local a
  for a in "$@"; do
    case "$a" in
      --*=*) argv+=("${a%%=*}" "${a#*=}") ;;
      *)     argv+=("$a") ;;
    esac
  done
  set -- ${argv[@]+"${argv[@]}"}

  while (($#)); do
    case "$1" in
      -t|--timezone)  need_value "$1" "${2:-}"; TZ_REGION="$2"; TZ_EXPLICIT=true; shift 2 ;;
      -n|--top)       need_value "$1" "${2:-}"; need_posint "$1" "$2"; TOP_N="$2"; shift 2 ;;
      -c|--candidates)
                      need_value "$1" "${2:-}"
                      [[ -r "$2" ]] || die "无法读取候选列表文件: $2"
                      CANDIDATE_FILE="$2"; shift 2 ;;
      -f|--timesyncd) FORCE_TIMESYNCD=true; shift ;;
      --probe-timeout) need_value "$1" "${2:-}"; need_posint "$1" "$2"; PROBE_TIMEOUT="$2"; shift 2 ;;
      --http-timeout)  need_value "$1" "${2:-}"; need_posint "$1" "$2"; HTTP_TIMEOUT="$2"; shift 2 ;;
      --parallel)      need_value "$1" "${2:-}"; need_posint "$1" "$2"; MAX_PARALLEL="$2"; shift 2 ;;
      --no-install)   SKIP_INSTALL=true; shift ;;
      -y|--yes)       ASSUME_YES=true; shift ;;
      -h|--help)      usage 0 ;;
      -V|--version)   printf 'set_time.sh v%s\n' "$SCRIPT_VERSION"; exit 0 ;;
      --)             shift; break ;;
      -*)             printf '未知选项: %s\n\n' "$1" >&2; usage 1 ;;
      *)              printf '多余的参数: %s\n\n' "$1" >&2; usage 1 ;;
    esac
  done
}

#--------------------------------- 主流程 -------------------------------------
main() {
  parse_args "$@"

  [[ $(id -u) -eq 0 ]] || die "请以 root 身份运行(sudo $0 ...)"

  detect_os
  detect_init
  detect_container
  detect_pkg_mgr || warn "未识别到受支持的包管理器,将只使用系统现有工具。"

  log "set_time.sh v$SCRIPT_VERSION 启动"
  log "系统: ${OS_PRETTY} | 包管理器: ${PM} | init: ${INIT_SYS}"
  if $IN_CONTAINER; then
    warn "检测到容器环境:容器通常共享宿主机时钟,无法独立修改系统时间。"
    warn "时区设置仍然有效;时间同步请在宿主机上配置。"
  fi

  if $FORCE_TIMESYNCD && [[ "$INIT_SYS" != systemd ]]; then
    warn "-f/--timesyncd 需要 systemd,当前系统的 init 是 ${INIT_SYS},改用 chrony。"
    FORCE_TIMESYNCD=false
  fi

  install_dependencies

  select_timezone
  apply_timezone
  load_candidates
  check_connectivity
  pick_probe_tool
  measure_ntp

  ((${#BEST[@]})) || mapfile -t BEST < <(default_servers)

  local synced=false method=""

  if ! $FORCE_TIMESYNCD && have chronyd; then
    if configure_chrony; then
      method="chrony"
      verify_chrony && synced=true
    else
      if [[ "$INIT_SYS" == systemd ]]; then
        warn "chrony 配置失败,回退到 systemd-timesyncd。"
      else
        warn "chrony 配置失败,改为尝试单次校时。"
      fi
    fi
  fi

  if [[ -z "$method" ]] && [[ "$INIT_SYS" == systemd ]]; then
    if configure_timesyncd; then
      method="systemd-timesyncd"
      verify_timesyncd && synced=true
    fi
  fi

  if [[ -z "$method" ]]; then
    warn "未能配置常驻时间同步服务,尝试单次校时。"
    oneshot_sync && { synced=true; method="单次校时"; }
  elif ! $synced; then
    # 服务已配置但未确认同步,先做一次强制校时把时钟拉正
    oneshot_sync && synced=true
  fi

  #--------------------------------- 总结 ------------------------------------
  printf '\n' >&2
  log "================= 配置结果 ================="
  log "时区        : $TZ_REGION"
  log "当前时间    : $(date '+%F %T %Z')"
  log "同步方案    : ${method:-无}"
  case "$method" in
    chrony)            svc_active "$CHRONY_SERVICE" && log "服务状态    : $CHRONY_SERVICE 运行中" ;;
    systemd-timesyncd) svc_active systemd-timesyncd.service && log "服务状态    : systemd-timesyncd 运行中" ;;
  esac
  log "NTP 服务器  : ${BEST[*]}"
  ((${#BACKUPS[@]})) && log "配置备份    : ${BACKUPS[*]}"
  case "$method" in
    chrony)            log "查看状态    : chronyc sources -v && chronyc tracking" ;;
    systemd-timesyncd) log "查看状态    : timedatectl timesync-status" ;;
  esac

  if $synced; then
    ok "时间同步已完成。"
    exit 0
  fi

  if $IN_CONTAINER; then
    warn "容器内无法修改系统时钟(需要 CAP_SYS_TIME),当前时间由宿主机决定。"
    warn "时区与 NTP 配置已写入,在宿主机或虚拟机上运行本脚本才能真正校时。"
    exit 0
  fi

  if [[ -n "$method" ]]; then
    warn "同步服务($method)已配置并运行,但尚未确认完成首次同步,稍后会自动完成。"
    exit 0
  fi

  die "所有时间同步方式均失败。请检查防火墙是否放行 UDP/123 与 TCP/443,以及 DNS 是否可用。"
}

main "$@"
