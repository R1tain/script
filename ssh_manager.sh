#!/usr/bin/env bash
#===============================================================================
# ssh_manager.sh — SSH 密钥登录 / 端口修改 一体化管理脚本
#
# 版本: v1.0
# 兼容: Debian 10+ | Ubuntu 20.04+ | RHEL/Rocky/Alma/Fedora | Alpine 3.x
#
# 由 authorized_keys.sh 与 update_port.sh 合并而来，并修复了两者中会导致
# "静默失效" 或 "远程锁死" 的缺陷：
#
#   - 不再假设 drop-in 一定生效：写入后用 `sshd -T` 读实际生效值，未生效则
#     降级为改主配置（原脚本只判断目录存在，无 Include 时改了等于没改）
#   - 处理 systemd socket 激活：Ubuntu 22.10+/24.04、Fedora 上 sshd_config 的
#     Port 会被 ssh.socket 忽略；且不盲写 /etc/systemd/system 覆盖（那会盖过
#     sshd-socket-generator，把端口焊死）
#   - 备份带时间戳，不再用固定名 sshd_config.bak 把原始备份覆盖掉
#   - 端口占用检测优先 ss，netstat 兜底，两者皆无时明确报"无法检测"
#   - 服务名探测而非写死 sshd（Debian/Ubuntu 是 ssh，Alpine 是 OpenRC）
#   - 改端口时新旧端口同时监听 + 定时自动回滚看门狗，确认后才收口
#   - 公钥用 ssh-keygen -l 校验（支持 ecdsa / sk-* 等原正则漏掉的类型）
#   - 公钥装到显式确认的账户，家目录用 getent 解析而非 ~
#
# 设计文档: docs/superpowers/specs/2026-08-30-ssh-manager-design.md
#===============================================================================

# --- POSIX 引导：被 sh 调用时切换到 bash（Alpine 常见） ------------------------
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

# 说明：此处刻意不启用 `set -e`。脚本会依次尝试 drop-in → 主配置、socket →
# service 等多条路径，任何一步失败都应走后备逻辑或明确回滚，而不是让系统停在
# "配置到一半" 的状态。所有关键步骤均显式检查返回值。
set -uo pipefail

if ((BASH_VERSINFO[0] < 4)); then
  echo "需要 bash 4.0 或更高版本（当前 ${BASH_VERSION}）。" >&2
  exit 1
fi

readonly SCRIPT_VERSION="1.0"

############################### 路径与常量 #####################################

readonly STATE_DIR="/etc/ssh/ssh_manager"
readonly GENESIS_DIR="$STATE_DIR/genesis"
readonly BACKUP_ROOT="$STATE_DIR/backups"
readonly PENDING_FILE="$STATE_DIR/pending"
readonly WATCHDOG_SCRIPT="$STATE_DIR/watchdog.sh"
readonly WATCHDOG_PID_FILE="$STATE_DIR/watchdog.pid"
readonly WATCHDOG_LOG="$STATE_DIR/watchdog.log"

readonly SSHD_CONFIG="/etc/ssh/sshd_config"
readonly SSHD_CONFIG_D="/etc/ssh/sshd_config.d"
readonly DROPIN_FILE="$SSHD_CONFIG_D/99-ssh-manager.conf"
readonly SOCKET_OVERRIDE_DIR="/etc/systemd/system/ssh.socket.d"
readonly SOCKET_OVERRIDE_FILE="$SOCKET_OVERRIDE_DIR/10-ssh-manager.conf"

readonly MARK_BEGIN="# >>> ssh_manager BEGIN <<<"
readonly MARK_END="# >>> ssh_manager END <<<"
readonly DISABLED_TAG="# ssh_manager disabled:"

readonly PORT_MIN=1024
readonly PORT_MAX=65535

################################ 颜色与日志 ####################################

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[1;33m'
  C_BLUE=$'\033[0;36m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_NC=$'\033[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_DIM=""; C_NC=""
fi

info() { printf '%s\n' "${C_BLUE}[*]${C_NC} $*"; }
ok()   { printf '%s\n' "${C_GREEN}[+]${C_NC} $*"; }
warn() { printf '%s\n' "${C_YELLOW}[!]${C_NC} $*"; }
err()  { printf '%s\n' "${C_RED}[x]${C_NC} $*" >&2; }
step() { printf '\n%s\n' "${C_BOLD}== $* ==${C_NC}"; }

pause() {
  if [ -t 0 ]; then
    printf '\n%s' "${C_DIM}按回车继续...${C_NC}"
    read -r _ || true
    printf '\n'
  fi
}

# 是/否询问。$2 为默认值（y 或 n）。非交互时直接返回默认值。
confirm() {
  local prompt="$1" default="${2:-n}" ans hint
  if [ "$default" = "y" ]; then hint="[Y/n]"; else hint="[y/N]"; fi
  printf '%s' "${C_YELLOW}${prompt} ${hint}: ${C_NC}"
  if ! read -r ans; then ans=""; printf '\n'; fi
  ans="${ans:-$default}"
  [[ "$ans" =~ ^[Yy]$ ]]
}

############################### 环境探测 #######################################

OS_ID="unknown"; PKG_MGR=""
INIT_SYS="unknown"
SSHD_BIN=""
SSH_SERVICE=""
SOCKET_ACTIVATED=0
SSH_VER="0.0"

detect_os() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
  fi
  if   command -v apt-get     >/dev/null 2>&1; then PKG_MGR="apt"
  elif command -v dnf         >/dev/null 2>&1; then PKG_MGR="dnf"
  elif command -v yum         >/dev/null 2>&1; then PKG_MGR="yum"
  elif command -v apk         >/dev/null 2>&1; then PKG_MGR="apk"
  elif command -v zypper      >/dev/null 2>&1; then PKG_MGR="zypper"
  elif command -v pacman      >/dev/null 2>&1; then PKG_MGR="pacman"
  fi
}

detect_init() {
  if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    INIT_SYS="systemd"
  elif command -v rc-service >/dev/null 2>&1; then
    INIT_SYS="openrc"
  elif command -v service >/dev/null 2>&1; then
    INIT_SYS="sysv"
  fi
}

detect_sshd_bin() {
  local c
  for c in /usr/sbin/sshd /usr/local/sbin/sshd /sbin/sshd; do
    [ -x "$c" ] && { SSHD_BIN="$c"; return 0; }
  done
  SSHD_BIN="$(command -v sshd 2>/dev/null || true)"
  [ -n "$SSHD_BIN" ]
}

# 探测真实存在的 SSH 服务单元名，不写死（Debian/Ubuntu=ssh，RHEL=sshd）
detect_ssh_service() {
  case "$INIT_SYS" in
    systemd)
      local u
      for u in ssh.service sshd.service; do
        if systemctl list-unit-files "$u" >/dev/null 2>&1 &&
           systemctl cat "$u" >/dev/null 2>&1; then
          SSH_SERVICE="$u"; break
        fi
      done
      [ -n "$SSH_SERVICE" ] || SSH_SERVICE="sshd.service"
      ;;
    openrc) SSH_SERVICE="sshd" ;;
    *)      SSH_SERVICE="ssh" ;;
  esac
}

detect_socket_activation() {
  SOCKET_ACTIVATED=0
  [ "$INIT_SYS" = "systemd" ] || return 0
  if systemctl is-active ssh.socket >/dev/null 2>&1 ||
     systemctl is-enabled ssh.socket >/dev/null 2>&1; then
    SOCKET_ACTIVATED=1
  fi
}

detect_ssh_version() {
  local v
  v=$(ssh -V 2>&1 | sed -n 's/^OpenSSH_\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -1)
  if [ -z "$v" ] && [ -n "$SSHD_BIN" ]; then
    v=$("$SSHD_BIN" -V 2>&1 | sed -n 's/^OpenSSH_\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -1)
  fi
  SSH_VER="${v:-0.0}"
}

# OpenSSH >= 8.7 起 ChallengeResponseAuthentication 已被 KbdInteractive 取代
ssh_ver_lt_87() {
  local maj="${SSH_VER%%.*}" min="${SSH_VER##*.}"
  [[ "$maj" =~ ^[0-9]+$ ]] || return 1
  [[ "$min" =~ ^[0-9]+$ ]] || min=0
  ((maj < 8)) && return 0
  ((maj == 8 && min < 7)) && return 0
  return 1
}

############################ sshd 生效配置读取 #################################

# 唯一权威来源：直接问 sshd 实际生效值，不 grep 配置文件。
# 这是修复 P4/P5/A1 的核心 —— drop-in、Include 顺序、Match 块的影响全都体现在这里。
sshd_dump() {
  [ -n "$SSHD_BIN" ] || return 1
  "$SSHD_BIN" -T 2>/dev/null
}

effective_value() {
  local key="${1,,}"
  sshd_dump | awk -v k="$key" 'tolower($1)==k {$1=""; sub(/^ /,""); print; exit}'
}

effective_ports() {
  sshd_dump | awk 'tolower($1)=="port" {print $2}'
}

first_effective_port() {
  local p
  p=$(effective_ports | head -1)
  # sshd -T 不可用时退回读配置，再退回默认 22
  if [ -z "$p" ]; then
    p=$(awk 'tolower($1)=="port" && $0 !~ /^[[:space:]]*#/ {print $2; exit}' "$SSHD_CONFIG" 2>/dev/null)
  fi
  printf '%s' "${p:-22}"
}

############################### 端口工具 #######################################

# 返回 0=在监听 1=未监听 2=无工具可检测
port_listening() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -tln 2>/dev/null | grep -qE "[:.]${p}[[:space:]]" && return 0 || return 1
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tln 2>/dev/null | grep -qE "[:.]${p}[[:space:]]" && return 0 || return 1
  fi
  return 2
}

valid_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  ((p >= PORT_MIN && p <= PORT_MAX))
}

############################## 备份与快照 ######################################

timestamp() { date +%Y%m%d-%H%M%S; }

# 把当前 SSH 相关配置整体复制到 $1
snapshot_to() {
  local dst="$1"
  mkdir -p "$dst" || return 1
  cp -a "$SSHD_CONFIG" "$dst/sshd_config" 2>/dev/null || return 1
  if [ -d "$SSHD_CONFIG_D" ]; then
    rm -rf "$dst/sshd_config.d"
    cp -a "$SSHD_CONFIG_D" "$dst/sshd_config.d" 2>/dev/null || return 1
  fi
  if [ -d "$SOCKET_OVERRIDE_DIR" ]; then
    rm -rf "$dst/ssh.socket.d"
    cp -a "$SOCKET_OVERRIDE_DIR" "$dst/ssh.socket.d" 2>/dev/null || return 1
  fi
  {
    printf 'created=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'created_epoch=%s\n' "$(date +%s)"
    printf 'hostname=%s\n' "$(hostname 2>/dev/null || echo unknown)"
    printf 'port=%s\n' "$(first_effective_port)"
    printf 'passwordauthentication=%s\n' "$(effective_value passwordauthentication)"
    printf 'permitrootlogin=%s\n' "$(effective_value permitrootlogin)"
    printf 'openssh=%s\n' "$SSH_VER"
    printf 'socket_activated=%s\n' "$SOCKET_ACTIVATED"
  } > "$dst/meta"
  return 0
}

# 从快照目录还原（genesis 与 backups 共用）
restore_from() {
  local src="$1"
  [ -d "$src" ] || { err "快照目录不存在: $src"; return 1; }
  [ -f "$src/sshd_config" ] || { err "快照不完整，缺少 sshd_config"; return 1; }

  cp -a "$src/sshd_config" "$SSHD_CONFIG" || return 1

  # sshd_config.d：快照里没有就说明当时不存在，应删除现有的
  rm -rf "$SSHD_CONFIG_D"
  [ -d "$src/sshd_config.d" ] && cp -a "$src/sshd_config.d" "$SSHD_CONFIG_D"

  rm -rf "$SOCKET_OVERRIDE_DIR"
  [ -d "$src/ssh.socket.d" ] && cp -a "$src/ssh.socket.d" "$SOCKET_OVERRIDE_DIR"

  return 0
}

new_backup() {
  local dir n=1
  dir="$BACKUP_ROOT/$(timestamp)"
  # 同秒内重复调用时加后缀，避免覆盖
  while [ -e "$dir" ]; do dir="$BACKUP_ROOT/$(timestamp)-$n"; n=$((n + 1)); done
  snapshot_to "$dir" >/dev/null || return 1
  printf '%s' "$dir"
}

latest_backup() {
  [ -d "$BACKUP_ROOT" ] || return 1
  local d
  # 跳过已被回滚消费过的备份，否则连按菜单 4 会反复还原同一份，
  # 表面提示"已回滚"实际毫无变化。
  d=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d \
        '!' -exec test -e '{}/.restored' ';' -print 2>/dev/null | sort | tail -1)
  [ -n "$d" ] || return 1
  printf '%s' "$d"
}

# 备份从不删除，只打标记：既保留现场供人工排查，又让回滚能逐级往回走
mark_backup_restored() {
  [ -d "$1" ] && : > "$1/.restored"
}

# 首次运行时创建原始快照，之后永不覆盖
ensure_genesis() {
  [ -d "$GENESIS_DIR" ] && return 0
  info "首次运行，正在保存原始配置快照..."
  if ! snapshot_to "$GENESIS_DIR"; then
    err "原始快照创建失败"
    rm -rf "$GENESIS_DIR"
    return 1
  fi
  mkdir -p "$GENESIS_DIR/authorized_keys"
  cat > "$GENESIS_DIR/README" <<'EOF'
本目录是 ssh_manager.sh 首次运行前的 SSH 原始配置快照。

用途：菜单 "6) 还原到最初配置" 会读取本目录，把 SSH 配置退回到脚本从未
      运行过的状态。

请勿删除或修改本目录。一旦删除，脚本下次运行时会把"当时已被修改过的
配置"当作原始配置重新保存，还原功能将失去意义（meta 中的 created 时间
可用于人工判别是否发生过这种情况）。
EOF
  ok "原始快照已保存至 $GENESIS_DIR"
}

# 懒惰快照：首次修改某用户的 authorized_keys 之前存一份原件
snapshot_authorized_keys() {
  local user="$1" ak="$2"
  local dst="$GENESIS_DIR/authorized_keys/$user"
  mkdir -p "$GENESIS_DIR/authorized_keys"
  [ -e "$dst" ] && return 0
  [ -e "$dst.absent" ] && return 0
  if [ -f "$ak" ]; then
    cp -a "$ak" "$dst" 2>/dev/null
  else
    # 原本就没有该文件，记一个标记，还原时据此删除
    : > "$dst.absent"
  fi
}

############################ 配置写入（核心机制） ###############################
#
# 写入 → 用 sshd -T 验证生效 → 未生效则降级改主配置。
# 不去推理 Include 在第几行、谁覆盖谁 —— 直接以 sshd 的实际生效值为准。
#

# 注释掉主配置中指定指令（跳过 Match 块内的，避免改变条件配置的语义）
comment_out_directive() {
  local kw="$1" tmp
  tmp=$(mktemp) || return 1
  awk -v kw="${kw,,}" -v tag="$DISABLED_TAG" '
    BEGIN { inmatch = 0 }
    {
      line = $0
      first = ""
      if (NF > 0) first = tolower($1)
      if (first == "match") inmatch = 1
      if (!inmatch && first == kw && line !~ /^[[:space:]]*#/) {
        print tag " " line
      } else {
        print line
      }
    }
  ' "$SSHD_CONFIG" > "$tmp" || { rm -f "$tmp"; return 1; }
  cat "$tmp" > "$SSHD_CONFIG" && rm -f "$tmp"
}

remove_marker_block() {
  local tmp
  tmp=$(mktemp) || return 1
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip   { print }
  ' "$SSHD_CONFIG" > "$tmp" || { rm -f "$tmp"; return 1; }
  cat "$tmp" > "$SSHD_CONFIG" && rm -f "$tmp"
}

# 提取配置块中出现的指令关键字
block_keywords() {
  printf '%s\n' "$1" | awk 'NF > 0 && $0 !~ /^[[:space:]]*#/ {print $1}' | sort -u
}

write_dropin() {
  local content="$1"
  [ -d "$SSHD_CONFIG_D" ] || return 1
  {
    printf '%s\n' "# 由 ssh_manager.sh v$SCRIPT_VERSION 生成于 $(date '+%Y-%m-%d %H:%M:%S')"
    printf '%s\n' "# 手工修改可能在下次运行脚本时被覆盖。"
    printf '%s\n' "$content"
  } > "$DROPIN_FILE" 2>/dev/null || return 1
  chmod 644 "$DROPIN_FILE" 2>/dev/null
  return 0
}

write_main_block() {
  local content="$1"
  {
    printf '\n%s\n' "$MARK_BEGIN"
    printf '%s\n' "# 由 ssh_manager.sh v$SCRIPT_VERSION 生成于 $(date '+%Y-%m-%d %H:%M:%S')"
    printf '%s\n' "$content"
    printf '%s\n' "$MARK_END"
  } >> "$SSHD_CONFIG" || return 1
  return 0
}

# apply_config <配置内容> <验证函数名>
# 验证函数返回 0 表示期望状态已生效。
apply_config() {
  local content="$1" verifier="$2" kw

  # 关键：先把主配置里的同名指令注释掉，再考虑写 drop-in。
  #
  # drop-in 只能"追加"，无法删除主配置中已存在的指令。对 PasswordAuthentication
  # 这类"首个取值胜出"的关键字，drop-in 靠 Include 的位置还能压过去；但 Port 是
  # 可累加关键字 —— 主配置里的 Port 55566 会和 drop-in 里的 Port 2222 同时生效，
  # sshd 两个端口都监听，旧端口永远关不掉。
  remove_marker_block || return 1
  while IFS= read -r kw; do
    [ -n "$kw" ] && comment_out_directive "$kw"
  done < <(block_keywords "$content")

  if [ -d "$SSHD_CONFIG_D" ]; then
    if write_dropin "$content"; then
      if "$SSHD_BIN" -t 2>/dev/null && "$verifier"; then
        info "配置经 drop-in 生效: $DROPIN_FILE"
        return 0
      fi
      warn "drop-in 未生效（主配置可能缺少 Include，或被前置指令覆盖），改用主配置"
      rm -f "$DROPIN_FILE"
    fi
  fi

  if ! write_main_block "$content"; then
    err "写入主配置失败"
    return 1
  fi
  if ! "$SSHD_BIN" -t 2>/dev/null; then
    err "主配置语法校验失败"
    return 1
  fi
  if ! "$verifier"; then
    err "改写主配置后期望值仍未生效"
    return 1
  fi
  info "配置经主配置标记块生效: $SSHD_CONFIG"
  return 0
}

########################## systemd socket 激活处理 #############################
#
# Ubuntu 24.04 带 sshd-socket-generator，会从 sshd_config 的 Port 自动生成
# /run/systemd/generator/ssh.socket.d/addresses.conf。
# /etc/systemd/system/ssh.socket.d/ 优先级高于 generator —— 无条件写那里会把
# 端口焊死，导致以后改 Port 全部失效。所以：先让 generator 试，不行才手写。
#

socket_has_port() {
  local p="$1"
  systemctl cat ssh.socket 2>/dev/null |
    grep -E '^[[:space:]]*ListenStream=' | grep -qE "[:=]${p}[[:space:]]*$"
}

# $@ = 需要监听的端口列表
sync_socket_ports() {
  [ "$SOCKET_ACTIVATED" -eq 1 ] || return 0
  local ports=("$@") p all_ok=1

  # 先撤掉我们自己的覆盖，让 generator 有机会重新生效
  rm -f "$SOCKET_OVERRIDE_FILE"
  rmdir "$SOCKET_OVERRIDE_DIR" 2>/dev/null
  systemctl daemon-reload 2>/dev/null

  for p in "${ports[@]}"; do
    socket_has_port "$p" || { all_ok=0; break; }
  done

  if [ "$all_ok" -eq 1 ]; then
    info "ssh.socket 已由 sshd-socket-generator 自动同步端口"
    return 0
  fi

  warn "本系统无 sshd-socket-generator，改为写入 ssh.socket 覆盖文件"
  mkdir -p "$SOCKET_OVERRIDE_DIR" || return 1
  {
    printf '%s\n' "# 由 ssh_manager.sh v$SCRIPT_VERSION 生成于 $(date '+%Y-%m-%d %H:%M:%S')"
    printf '[Socket]\n'
    printf 'ListenStream=\n'
    for p in "${ports[@]}"; do
      printf 'ListenStream=0.0.0.0:%s\n' "$p"
      printf 'ListenStream=[::]:%s\n' "$p"
    done
  } > "$SOCKET_OVERRIDE_FILE" || return 1
  systemctl daemon-reload 2>/dev/null
  return 0
}

################################ 服务控制 #####################################

ssh_restart() {
  case "$INIT_SYS" in
    systemd)
      if [ "$SOCKET_ACTIVATED" -eq 1 ]; then
        systemctl daemon-reload 2>/dev/null
        systemctl restart ssh.socket 2>/dev/null || return 1
        # ssh.service 若在跑也要重启，否则仍持有旧配置
        systemctl try-restart "$SSH_SERVICE" 2>/dev/null
        return 0
      fi
      systemctl restart "$SSH_SERVICE" 2>/dev/null
      ;;
    openrc)
      rc-service "$SSH_SERVICE" restart >/dev/null 2>&1
      ;;
    *)
      service "$SSH_SERVICE" restart >/dev/null 2>&1
      ;;
  esac
}

# 重启并逐个验证端口确实在监听；任一不通即返回非 0
restart_and_verify() {
  local ports=("$@") p rc

  if ! ssh_restart; then
    err "SSH 服务重启失败"
    return 1
  fi

  # 给 socket / 服务一点时间完成绑定
  sleep 1

  for p in "${ports[@]}"; do
    port_listening "$p"; rc=$?
    case "$rc" in
      0) ok "端口 $p 已在监听" ;;
      1) err "端口 $p 未在监听"; return 1 ;;
      2) warn "无 ss/netstat，无法验证端口 $p 是否在监听" ;;
    esac
  done
  return 0
}

################################ SELinux ######################################

selinux_enforcing() {
  command -v getenforce >/dev/null 2>&1 || return 1
  [ "$(getenforce 2>/dev/null)" = "Enforcing" ]
}

# RHEL 系上不给新端口打 ssh_port_t 标签，sshd 会起不来
selinux_allow_port() {
  local p="$1"
  selinux_enforcing || return 0

  if ! command -v semanage >/dev/null 2>&1; then
    warn "SELinux 处于 Enforcing，但未找到 semanage 命令"
    info "尝试安装 policycoreutils-python-utils ..."
    case "$PKG_MGR" in
      dnf) dnf install -y policycoreutils-python-utils >/dev/null 2>&1 ;;
      yum) yum install -y policycoreutils-python-utils >/dev/null 2>&1 ;;
    esac
  fi

  if ! command -v semanage >/dev/null 2>&1; then
    err "无法获得 semanage，新端口不会被 SELinux 放行，sshd 很可能无法绑定"
    if confirm "仍要继续吗？（继续则很可能失败并自动回滚）" "n"; then
      return 0
    fi
    return 1
  fi

  if semanage port -a -t ssh_port_t -p tcp "$p" 2>/dev/null; then
    ok "SELinux: 已为端口 $p 添加 ssh_port_t"
  elif semanage port -m -t ssh_port_t -p tcp "$p" 2>/dev/null; then
    ok "SELinux: 已为端口 $p 修改为 ssh_port_t"
  else
    warn "SELinux: 端口 $p 可能已属于其他类型，semanage 未能设置"
  fi
  return 0
}

############################### 看门狗（防锁死） ###############################
#
# 生成一个自包含的看门狗脚本并 setsid 派生。不依赖 at / systemd-run，
# OpenRC 系统同样可用；主脚本退出、SSH 会话断开都不影响它。
#

has_pending() { [ -f "$PENDING_FILE" ]; }

pending_get() {
  local key="$1"
  [ -f "$PENDING_FILE" ] || return 1
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$PENDING_FILE"
}

pending_remaining() {
  local dl now
  dl=$(pending_get deadline) || return 1
  [ -n "$dl" ] || return 1
  now=$(date +%s)
  local r=$((dl - now))
  ((r < 0)) && r=0
  printf '%s' "$r"
}

fmt_mmss() {
  local s="$1"
  printf '%02d:%02d' $((s / 60)) $((s % 60))
}

# arm_watchdog <备份目录> <类型> <摘要> <过渡端口(可空)> <验证命令>
arm_watchdog() {
  local backup="$1" kind="$2" summary="$3" trans_port="$4" verify_cmd="$5"
  local minutes deadline

  minutes=$(ask_rollback_minutes)
  deadline=$(( $(date +%s) + minutes * 60 ))

  {
    printf 'kind=%s\n'            "$kind"
    printf 'backup=%s\n'          "$backup"
    printf 'deadline=%s\n'        "$deadline"
    printf 'minutes=%s\n'         "$minutes"
    printf 'summary=%s\n'         "$summary"
    printf 'transitional_port=%s\n' "$trans_port"
    printf 'verify_cmd=%s\n'      "$verify_cmd"
  } > "$PENDING_FILE" || return 1
  chmod 600 "$PENDING_FILE" 2>/dev/null

  generate_watchdog "$backup" "$deadline" || return 1

  setsid nohup bash "$WATCHDOG_SCRIPT" >>"$WATCHDOG_LOG" 2>&1 &
  printf '%s' "$!" > "$WATCHDOG_PID_FILE"
  disown 2>/dev/null || true

  ok "自动回滚看门狗已启动（${minutes} 分钟后未确认即自动还原）"
}

ask_rollback_minutes() {
  local ans
  if [ ! -t 0 ]; then printf '10'; return 0; fi
  printf '%s' "${C_YELLOW}自动回滚时限 [1) 5 分钟  2) 10 分钟(默认)  3) 30 分钟]: ${C_NC}" >&2
  read -r ans || ans=""
  case "$ans" in
    1) printf '5' ;;
    3) printf '30' ;;
    *) printf '10' ;;
  esac
}

# 生成自包含看门狗。这里刻意把还原命令烤进脚本，而不是回调主脚本 ——
# 主脚本被移动或删除时看门狗仍须能救场。
generate_watchdog() {
  local backup="$1" deadline="$2" restart_cmd

  case "$INIT_SYS" in
    systemd)
      if [ "$SOCKET_ACTIVATED" -eq 1 ]; then
        restart_cmd='systemctl daemon-reload; systemctl restart ssh.socket; systemctl try-restart '"$SSH_SERVICE"
      else
        restart_cmd="systemctl restart $SSH_SERVICE"
      fi
      ;;
    openrc) restart_cmd="rc-service $SSH_SERVICE restart" ;;
    *)      restart_cmd="service $SSH_SERVICE restart" ;;
  esac

  cat > "$WATCHDOG_SCRIPT" <<EOF || return 1
#!/usr/bin/env bash
# 由 ssh_manager.sh 自动生成 —— SSH 变更自动回滚看门狗
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
#
# 到达 DEADLINE 时若 PENDING 文件仍存在（= 用户未确认变更），
# 则把 BACKUP 中的配置还原并重启 SSH。
set -u

DEADLINE=$deadline
PENDING="$PENDING_FILE"
BACKUP="$backup"
SSHD_CONFIG="$SSHD_CONFIG"
SSHD_CONFIG_D="$SSHD_CONFIG_D"
SOCKET_OVERRIDE_DIR="$SOCKET_OVERRIDE_DIR"
PIDFILE="$WATCHDOG_PID_FILE"

log() { printf '[%s] %s\n' "\$(date '+%Y-%m-%d %H:%M:%S')" "\$*"; }

while [ "\$(date +%s)" -lt "\$DEADLINE" ]; do
  if [ ! -f "\$PENDING" ]; then
    log "变更已确认或已回滚，看门狗退出"
    rm -f "\$PIDFILE"
    exit 0
  fi
  sleep 5
done

if [ ! -f "\$PENDING" ]; then
  log "变更已确认，看门狗退出"
  rm -f "\$PIDFILE"
  exit 0
fi

log "超时未确认，开始自动回滚: \$BACKUP"

if [ -f "\$BACKUP/sshd_config" ]; then
  cp -a "\$BACKUP/sshd_config" "\$SSHD_CONFIG"
  rm -rf "\$SSHD_CONFIG_D"
  [ -d "\$BACKUP/sshd_config.d" ] && cp -a "\$BACKUP/sshd_config.d" "\$SSHD_CONFIG_D"
  rm -rf "\$SOCKET_OVERRIDE_DIR"
  [ -d "\$BACKUP/ssh.socket.d" ] && cp -a "\$BACKUP/ssh.socket.d" "\$SOCKET_OVERRIDE_DIR"
  $restart_cmd
  : > "\$BACKUP/.restored"
  log "已还原并重启 SSH"
else
  log "错误: 备份不完整，无法还原"
fi

rm -f "\$PENDING" "\$PIDFILE"
exit 0
EOF
  chmod 700 "$WATCHDOG_SCRIPT"
}

disarm_watchdog() {
  local pid
  if [ -f "$WATCHDOG_PID_FILE" ]; then
    pid=$(cat "$WATCHDOG_PID_FILE" 2>/dev/null)
    [[ "$pid" =~ ^[0-9]+$ ]] && kill "$pid" 2>/dev/null
    rm -f "$WATCHDOG_PID_FILE"
  fi
  rm -f "$PENDING_FILE"
}

############################### 提醒（不动手） #################################
#
# 按设计约定：脚本不修改任何防火墙 / fail2ban 规则，只检测并打印现成命令。
#

resolve_service_port() {
  local name="$1"
  [[ "$name" =~ ^[0-9]+$ ]] && { printf '%s' "$name"; return 0; }
  local p
  p=$(getent services "$name" 2>/dev/null | awk '{print $2}' | cut -d/ -f1 | head -1)
  printf '%s' "${p:-}"
}

fail2ban_jail_port() {
  command -v fail2ban-client >/dev/null 2>&1 || return 1
  local raw
  raw=$(grep -rhE '^[[:space:]]*port[[:space:]]*=' \
        /etc/fail2ban/jail.local /etc/fail2ban/jail.d/ 2>/dev/null |
        head -1 | sed 's/.*=[[:space:]]*//' | tr -d '[:space:]')
  [ -n "$raw" ] || return 1
  printf '%s' "$raw"
}

fail2ban_active() {
  if [ "$INIT_SYS" = "systemd" ]; then
    systemctl is-active fail2ban >/dev/null 2>&1 && return 0
  fi
  pgrep -x fail2ban-server >/dev/null 2>&1
}

# 端口变更后提示需要用户自己处理的外部组件
print_external_reminders() {
  local new_port="$1"

  if fail2ban_active; then
    local raw resolved
    raw=$(fail2ban_jail_port || printf '')
    resolved=$(resolve_service_port "${raw%%,*}")
    if [ -n "$resolved" ] && [ "$resolved" != "$new_port" ]; then
      printf '\n%s\n' "${C_YELLOW}fail2ban 的封禁端口与新 SSH 端口不一致${C_NC}"
      printf '  jail 配置 port = %s（解析为 %s），新 SSH 端口为 %s\n' "$raw" "$resolved" "$new_port"
      printf '  %s\n' "${C_DIM}封禁动作会打在 ${resolved} 上，对 ${new_port} 不生效。${C_NC}"
      printf '  修复命令:\n'
      printf '    %s\n' "${C_GREEN}sed -i 's/^port *=.*/port = $new_port/' /etc/fail2ban/jail.local${C_NC}"
      printf '    %s\n' "${C_GREEN}systemctl reload fail2ban${C_NC}"
    fi
  fi

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    printf '\n%s\n' "${C_YELLOW}检测到 ufw 处于启用状态，需自行放行新端口${C_NC}"
    printf '    %s\n' "${C_GREEN}ufw allow ${new_port}/tcp${C_NC}"
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && [ "$(firewall-cmd --state 2>/dev/null)" = "running" ]; then
    printf '\n%s\n' "${C_YELLOW}检测到 firewalld 正在运行，需自行放行新端口${C_NC}"
    printf '    %s\n' "${C_GREEN}firewall-cmd --permanent --add-port=${new_port}/tcp && firewall-cmd --reload${C_NC}"
  fi

  printf '\n%s\n' "${C_YELLOW}若使用云服务器，请确认安全组 / 网络 ACL 已放行端口 ${new_port}${C_NC}"
  return 0
}

########################### 功能 1：配置密钥登录 ###############################

PUBKEY_FINGERPRINT=""

validate_pubkey() {
  local key="$1" tmp rc
  PUBKEY_FINGERPRINT=""
  tmp=$(mktemp) || return 1
  printf '%s\n' "$key" > "$tmp"
  if command -v ssh-keygen >/dev/null 2>&1; then
    # 用临时文件而非进程替换：部分 ssh-keygen 版本会对 /dev/fd/N 做二次 open，
    # 进程替换的管道无法重读。
    PUBKEY_FINGERPRINT=$(ssh-keygen -l -f "$tmp" 2>/dev/null)
    rc=$?
    rm -f "$tmp"
    return $rc
  fi
  rm -f "$tmp"
  warn "未找到 ssh-keygen，降级为正则校验"
  [[ "$key" =~ ^(ssh-rsa|ssh-ed25519|ssh-dss|ecdsa-sha2-[A-Za-z0-9-]+|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-[A-Za-z0-9-]+@openssh\.com)[[:space:]]+[A-Za-z0-9+/]+=*([[:space:]].*)?$ ]]
}

user_home() { getent passwd "$1" 2>/dev/null | cut -d: -f6; }
user_group() { id -gn "$1" 2>/dev/null; }

# StrictModes 会因家目录可被 group/other 写而拒绝公钥登录
check_strictmodes() {
  local home="$1" perm g o
  perm=$(stat -c '%a' "$home" 2>/dev/null) || return 0
  # stat 失败或权限位不足三位时不做判断，避免算术展开报错
  [ "${#perm}" -ge 3 ] || return 0
  g=${perm: -2:1}; o=${perm: -1:1}
  [[ "$g" =~ ^[0-7]$ ]] || return 0
  [[ "$o" =~ ^[0-7]$ ]] || return 0
  if [ $((g & 2)) -ne 0 ] || [ $((o & 2)) -ne 0 ]; then
    warn "家目录 $home 权限为 $perm，可被同组或其他用户写入"
    warn "sshd 的 StrictModes 会因此拒绝公钥登录"
    if confirm "是否收紧为 750？" "y"; then
      chmod 750 "$home" && ok "已将 $home 改为 750"
    else
      warn "未修改，公钥登录可能失败"
    fi
  fi
}

verify_passwordauth_off() { [ "$(effective_value passwordauthentication)" = "no" ]; }

feature_pubkey_login() {
  step "配置 SSH 密钥登录"

  # --- 目标账户 ---
  local default_user target_user home grp
  default_user="${SUDO_USER:-$(id -un)}"
  printf '%s' "${C_YELLOW}要为哪个账户配置密钥登录？[默认 ${default_user}]: ${C_NC}"
  read -r target_user || target_user=""
  target_user="${target_user:-$default_user}"

  if ! getent passwd "$target_user" >/dev/null 2>&1; then
    err "系统中不存在用户: $target_user"
    return 1
  fi
  home=$(user_home "$target_user")
  if [ -z "$home" ] || [ ! -d "$home" ]; then
    err "无法解析 $target_user 的家目录（得到: '${home}'）"
    return 1
  fi
  grp=$(user_group "$target_user")
  info "目标账户: ${C_BOLD}${target_user}${C_NC}  家目录: ${home}"

  # --- 读取并校验公钥 ---
  local pubkey
  printf '%s\n' "${C_YELLOW}请粘贴公钥（ssh-rsa / ssh-ed25519 / ecdsa-* / sk-* 均可）：${C_NC}"
  read -r pubkey || pubkey=""
  if [ -z "$pubkey" ]; then
    err "未输入内容，已取消"
    return 1
  fi
  if ! validate_pubkey "$pubkey"; then
    err "这不是一个有效的 SSH 公钥"
    warn "常见原因：粘贴的是私钥、内容被换行截断、或复制时缺失了开头的类型字段"
    if ! confirm "仍要写入吗？" "n"; then
      info "已取消"
      return 1
    fi
  else
    ok "公钥格式校验通过: ${PUBKEY_FINGERPRINT:-(指纹不可用)}"
  fi

  # --- 写入 authorized_keys ---
  local ssh_dir="$home/.ssh" ak="$home/.ssh/authorized_keys"
  snapshot_authorized_keys "$target_user" "$ak"

  mkdir -p "$ssh_dir" || { err "无法创建 $ssh_dir"; return 1; }
  touch "$ak"        || { err "无法创建 $ak"; return 1; }

  if grep -qxF "$pubkey" "$ak" 2>/dev/null; then
    info "该公钥已存在于 $ak，未重复添加"
  else
    printf '%s\n' "$pubkey" >> "$ak" || { err "写入 $ak 失败"; return 1; }
    ok "公钥已追加到 $ak"
  fi

  chmod 700 "$ssh_dir"
  chmod 600 "$ak"
  chown -R "$target_user:$grp" "$ssh_dir" 2>/dev/null
  ok "权限已修正（.ssh=700  authorized_keys=600  属主=$target_user:$grp）"

  check_strictmodes "$home"

  # --- 是否禁用密码登录 ---
  printf '\n'
  local cur_pwauth
  cur_pwauth=$(effective_value passwordauthentication)
  info "当前密码登录状态: ${C_BOLD}${cur_pwauth:-unknown}${C_NC}"

  if [ "$cur_pwauth" = "no" ]; then
    ok "密码登录已处于禁用状态，无需改动 sshd 配置"
    printf '\n%s\n' "${C_GREEN}完成。未修改 sshd 配置，无需确认收口。${C_NC}"
    return 0
  fi

  printf '\n%s\n' "${C_DIM}提示：仅添加公钥不会造成锁死；禁用密码登录才会，届时会启动自动回滚保护。${C_NC}"
  if ! confirm "是否禁用密码登录（改为仅密钥登录）？" "n"; then
    printf '\n%s\n' "${C_GREEN}完成。仅添加了公钥，未修改 sshd 配置，无需确认收口。${C_NC}"
    return 0
  fi

  if has_pending; then
    err "已有一个待确认的变更（$(pending_get summary)）"
    warn "请先用菜单 3 确认，或用菜单 4 回滚，再执行本操作"
    return 1
  fi

  # --- 应用配置 ---
  local backup
  backup=$(new_backup) || { err "备份失败，已中止"; return 1; }
  ok "已备份当前配置到 $backup"

  local content="PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no"
  if ssh_ver_lt_87; then
    content="$content
ChallengeResponseAuthentication no"
  fi
  # 仅当目标账户是 root 时才动 PermitRootLogin，避免意外锁掉 root
  if [ "$target_user" = "root" ]; then
    content="$content
PermitRootLogin prohibit-password"
  fi

  if ! apply_config "$content" verify_passwordauth_off; then
    err "配置未能生效，正在还原..."
    restore_from "$backup" && ssh_restart
    return 1
  fi

  local port
  port=$(first_effective_port)
  if ! restart_and_verify "$port"; then
    err "重启或端口验证失败，正在还原..."
    restore_from "$backup" && ssh_restart
    return 1
  fi

  local verify_cmd="ssh -o PasswordAuthentication=no -o PreferredAuthentications=publickey -p $port ${target_user}@<服务器IP>"
  arm_watchdog "$backup" "passwordauth" "禁用密码登录（账户 $target_user）" "" "$verify_cmd"

  print_lockout_guide "$verify_cmd" "密码登录已禁用"
  return 0
}

########################### 功能 2：修改 SSH 端口 ##############################

declare -a EXPECTED_PORTS=()

# 精确匹配端口集合，而不是"新端口在不在"。
# 只查存在会漏掉收口失败的情况：旧端口仍在监听时新端口同样存在，检查会误判成功。
verify_ports_exact() {
  local got want
  [ "${#EXPECTED_PORTS[@]}" -gt 0 ] || return 1
  got=$(effective_ports | sort -n | tr '\n' ' ')
  want=$(printf '%s\n' "${EXPECTED_PORTS[@]}" | sort -n | tr '\n' ' ')
  [ "$got" = "$want" ]
}

feature_change_port() {
  step "修改 SSH 端口"

  if has_pending; then
    err "已有一个待确认的变更（$(pending_get summary)）"
    warn "请先用菜单 3 确认，或用菜单 4 回滚，再执行本操作"
    return 1
  fi

  local cur_port
  cur_port=$(first_effective_port)
  info "当前生效端口: ${C_BOLD}${cur_port}${C_NC}"

  local all_ports
  all_ports=$(effective_ports | tr '\n' ' ')
  [ -n "${all_ports// /}" ] && info "sshd 报告的全部端口: ${all_ports}"

  # --- 选新端口 ---
  local new_port rc
  while true; do
    printf '%s' "${C_YELLOW}请输入新的 SSH 端口号 (${PORT_MIN}-${PORT_MAX}): ${C_NC}"
    read -r new_port || { info "已取消"; return 1; }
    [ -z "$new_port" ] && { info "已取消"; return 1; }

    if ! valid_port "$new_port"; then
      err "无效端口号，需为 ${PORT_MIN}-${PORT_MAX} 之间的数字"
      continue
    fi
    if [ "$new_port" = "$cur_port" ]; then
      err "新端口与当前端口相同"
      continue
    fi

    port_listening "$new_port"; rc=$?
    case "$rc" in
      0) err "端口 $new_port 已被占用，请换一个"; continue ;;
      2) warn "系统中没有 ss 也没有 netstat，无法检测端口占用"
         confirm "确定端口 $new_port 未被占用并继续吗？" "n" || continue ;;
    esac
    break
  done

  printf '\n'
  info "将采用双端口过渡：新端口 ${C_BOLD}${new_port}${C_NC} 与旧端口 ${C_BOLD}${cur_port}${C_NC} 同时监听"
  info "你验证新端口可用并选择菜单 3 之后，旧端口才会关闭"

  # --- SELinux ---
  if ! selinux_allow_port "$new_port"; then
    info "已中止"
    return 1
  fi

  # --- 备份 ---
  local backup
  backup=$(new_backup) || { err "备份失败，已中止"; return 1; }
  ok "已备份当前配置到 $backup"

  # --- 写配置（新旧端口并存） ---
  local content="Port $new_port
Port $cur_port"

  EXPECTED_PORTS=("$new_port" "$cur_port")
  if ! apply_config "$content" verify_ports_exact; then
    err "端口配置未能生效，正在还原..."
    restore_from "$backup" && ssh_restart
    return 1
  fi

  # --- socket 激活同步 ---
  if ! sync_socket_ports "$new_port" "$cur_port"; then
    err "ssh.socket 端口同步失败，正在还原..."
    restore_from "$backup" && ssh_restart
    return 1
  fi

  # --- 重启并实测 ---
  if ! restart_and_verify "$new_port" "$cur_port"; then
    err "重启或端口验证失败，正在还原..."
    restore_from "$backup"
    sync_socket_ports "$cur_port"
    ssh_restart
    return 1
  fi

  local verify_cmd="ssh -p $new_port ${SUDO_USER:-$(id -un)}@<服务器IP>"
  arm_watchdog "$backup" "port" "SSH 端口 ${cur_port} → ${new_port}" "$cur_port" "$verify_cmd"

  print_external_reminders "$new_port"
  print_lockout_guide "$verify_cmd" "端口已改为 $new_port（旧端口 $cur_port 仍开着）"
  return 0
}

########################### 功能 3：确认并收口 #################################

feature_confirm() {
  step "确认变更并解除自动回滚"

  if ! has_pending; then
    info "当前没有待确认的变更"
    return 0
  fi

  local kind summary trans_port
  kind=$(pending_get kind)
  summary=$(pending_get summary)
  trans_port=$(pending_get transitional_port)

  info "待确认变更: ${C_BOLD}${summary}${C_NC}"
  printf '\n%s\n' "${C_RED}请确保你已经在另一个终端验证过新配置可以正常登录。${C_NC}"
  printf '%s\n' "${C_DIM}验证命令: $(pending_get verify_cmd)${C_NC}"
  if ! confirm "已验证成功，现在收口？" "n"; then
    info "已取消，自动回滚仍在计时"
    return 0
  fi

  if [ -z "$trans_port" ]; then
    disarm_watchdog
    ok "已解除自动回滚。变更保持生效。"
    return 0
  fi

  # 端口类变更：移除过渡期保留的旧端口
  local keep_port
  keep_port=$(effective_ports | grep -vx "$trans_port" | head -1)
  if [ -z "$keep_port" ]; then
    err "无法确定收口后应保留的端口，取消收口（自动回滚仍在计时）"
    return 1
  fi

  info "移除过渡端口 ${trans_port}，仅保留 ${keep_port}"

  local backup
  backup=$(new_backup) || { err "备份失败，取消收口"; return 1; }

  EXPECTED_PORTS=("$keep_port")
  if ! apply_config "Port $keep_port" verify_ports_exact; then
    err "收口配置未生效，正在还原并重新武装看门狗"
    restore_from "$backup" && ssh_restart
    return 1
  fi

  if ! sync_socket_ports "$keep_port"; then
    err "ssh.socket 同步失败，正在还原"
    restore_from "$backup" && ssh_restart
    return 1
  fi

  if ! restart_and_verify "$keep_port"; then
    err "收口后端口验证失败，正在还原"
    restore_from "$backup"
    sync_socket_ports "$trans_port" "$keep_port"
    ssh_restart
    return 1
  fi

  # 收口的意义就在于旧端口真的关闭了，必须实测确认。
  # 已建立的会话处于 ESTABLISHED 而非 LISTEN，不会干扰这个判断。
  port_listening "$trans_port"
  case $? in
    0) err "过渡端口 $trans_port 仍在监听，收口未真正完成，正在还原"
       restore_from "$backup"
       sync_socket_ports "$trans_port" "$keep_port"
       ssh_restart
       return 1 ;;
    1) ok "过渡端口 $trans_port 已关闭" ;;
    2) warn "无 ss/netstat，无法确认端口 $trans_port 是否已关闭" ;;
  esac

  disarm_watchdog
  ok "收口完成。SSH 现在仅监听端口 ${C_BOLD}${keep_port}${C_NC}，自动回滚已解除。"
  return 0
}

########################### 功能 4：回滚上一次变更 #############################

feature_rollback() {
  step "回滚上一次变更"

  local backup
  if has_pending; then
    backup=$(pending_get backup)
    info "将回滚待确认的变更: $(pending_get summary)"
  else
    backup=$(latest_backup) || { err "没有可用的备份"; return 1; }
    info "没有待确认变更，将回滚到最近一次备份"
  fi

  [ -d "$backup" ] || { err "备份目录不存在: $backup"; return 1; }
  info "备份: $backup"
  [ -f "$backup/meta" ] && printf '%s\n' "${C_DIM}$(grep -E '^(created|port|passwordauthentication)=' "$backup/meta" | sed 's/^/    /')${C_NC}"

  confirm "确定回滚吗？" "n" || { info "已取消"; return 0; }

  if ! restore_from "$backup"; then
    err "还原失败"
    return 1
  fi

  local target_port
  target_port=$(awk -F= '$1=="port"{print $2; exit}' "$backup/meta" 2>/dev/null)
  [ -n "$target_port" ] || target_port=$(first_effective_port)

  sync_socket_ports "$target_port"

  if restart_and_verify "$target_port"; then
    ok "已回滚，SSH 监听端口 ${C_BOLD}${target_port}${C_NC}"
  else
    err "回滚后重启或端口验证失败，请立即人工检查"
  fi

  mark_backup_restored "$backup"
  disarm_watchdog
  return 0
}

########################### 功能 6：还原到最初配置 #############################

genesis_differs() {
  [ -d "$GENESIS_DIR" ] || return 1
  local g_port g_pw c_port c_pw
  g_port=$(awk -F= '$1=="port"{print $2; exit}' "$GENESIS_DIR/meta" 2>/dev/null)
  g_pw=$(awk -F= '$1=="passwordauthentication"{print $2; exit}' "$GENESIS_DIR/meta" 2>/dev/null)
  c_port=$(first_effective_port)
  c_pw=$(effective_value passwordauthentication)
  [ "$g_port" != "$c_port" ] || [ "$g_pw" != "$c_pw" ]
}

restore_genesis_keys() {
  local d="$GENESIS_DIR/authorized_keys" f user home ak
  [ -d "$d" ] || return 0
  for f in "$d"/*; do
    [ -e "$f" ] || continue
    user=$(basename "$f")
    case "$user" in
      *.absent) user="${user%.absent}" ;;
    esac
    home=$(user_home "$user")
    [ -n "$home" ] || continue
    ak="$home/.ssh/authorized_keys"
    if [ -e "$d/$user.absent" ]; then
      rm -f "$ak" && info "已删除 $ak（原始状态下该文件不存在）"
    elif [ -f "$d/$user" ]; then
      cp -a "$d/$user" "$ak" && chown "$user:$(user_group "$user")" "$ak" 2>/dev/null
      chmod 600 "$ak"
      info "已还原 $ak"
    fi
  done
}

feature_restore_genesis() {
  step "还原到最初配置"

  if [ ! -d "$GENESIS_DIR" ]; then
    err "找不到原始快照 $GENESIS_DIR"
    return 1
  fi

  local g_created g_port g_pw c_port c_pw
  g_created=$(awk -F= '$1=="created"{sub(/^[^=]*=/,""); print; exit}' "$GENESIS_DIR/meta" 2>/dev/null)
  g_port=$(awk -F= '$1=="port"{print $2; exit}' "$GENESIS_DIR/meta" 2>/dev/null)
  g_pw=$(awk -F= '$1=="passwordauthentication"{print $2; exit}' "$GENESIS_DIR/meta" 2>/dev/null)
  c_port=$(first_effective_port)
  c_pw=$(effective_value passwordauthentication)

  printf '  原始快照创建于 : %s\n' "${g_created:-未知}"
  printf '  端口           : %s  →  %s\n' "$c_port" "$g_port"
  printf '  密码登录       : %s  →  %s\n' "${c_pw:-未知}" "${g_pw:-未知}"

  if ! genesis_differs; then
    printf '\n'
    ok "当前配置与原始快照一致，无需还原"
    return 0
  fi

  if has_pending; then
    err "已有一个待确认的变更（$(pending_get summary)）"
    warn "请先用菜单 3 确认，或用菜单 4 回滚，再执行本操作"
    return 1
  fi

  printf '\n%s\n' "${C_RED}这会丢弃脚本首次运行以来的全部 SSH 配置变更。${C_NC}"
  local ans
  printf '%s' "${C_YELLOW}确认请输入完整的 yes: ${C_NC}"
  read -r ans || ans=""
  if [ "$ans" != "yes" ]; then
    info "已取消"
    return 0
  fi

  local restore_keys=0
  printf '\n%s\n' "${C_DIM}默认不还原 authorized_keys：若原始配置本身就禁用了密码登录，删掉现有公钥会直接锁死。${C_NC}"
  if confirm "是否同时还原 authorized_keys？" "n"; then
    restore_keys=1
  fi

  # 还原动作本身也要可回滚
  local backup
  backup=$(new_backup) || { err "备份失败，已中止"; return 1; }
  ok "已备份当前配置到 $backup"

  if ! restore_from "$GENESIS_DIR"; then
    err "还原失败，正在恢复"
    restore_from "$backup" && ssh_restart
    return 1
  fi

  [ "$restore_keys" -eq 1 ] && restore_genesis_keys

  # 双端口过渡：额外保留当前端口，否则原始端口不通就没有退路
  local trans_port=""
  if [ "$g_port" != "$c_port" ]; then
    trans_port="$c_port"
    info "双端口过渡：原始端口 ${g_port} 与当前端口 ${c_port} 同时监听"
    EXPECTED_PORTS=("$g_port" "$c_port")
    if ! apply_config "Port $g_port
Port $c_port" verify_ports_exact; then
      err "过渡配置未生效，正在恢复"
      restore_from "$backup" && ssh_restart
      return 1
    fi
    if ! sync_socket_ports "$g_port" "$c_port"; then
      err "ssh.socket 同步失败，正在恢复"
      restore_from "$backup" && ssh_restart
      return 1
    fi
    if ! restart_and_verify "$g_port" "$c_port"; then
      err "重启或端口验证失败，正在恢复"
      restore_from "$backup"
      sync_socket_ports "$c_port"
      ssh_restart
      return 1
    fi
  else
    sync_socket_ports "$g_port"
    if ! restart_and_verify "$g_port"; then
      err "重启或端口验证失败，正在恢复"
      restore_from "$backup" && ssh_restart
      return 1
    fi
  fi

  local verify_cmd="ssh -p $g_port ${SUDO_USER:-$(id -un)}@<服务器IP>"
  arm_watchdog "$backup" "genesis" "还原到最初配置（端口 ${c_port} → ${g_port}）" "$trans_port" "$verify_cmd"

  print_external_reminders "$g_port"
  print_lockout_guide "$verify_cmd" "已还原到最初配置"
  return 0
}

############################# 功能 5：状态查看 #################################

feature_status() {
  step "当前 SSH 状态"

  printf '%s\n' "${C_BOLD}生效配置${C_NC}"
  printf '  端口             : %s\n' "$(effective_ports | tr '\n' ' ')"
  printf '  PasswordAuth     : %s\n' "$(effective_value passwordauthentication)"
  printf '  PubkeyAuth       : %s\n' "$(effective_value pubkeyauthentication)"
  printf '  PermitRootLogin  : %s\n' "$(effective_value permitrootlogin)"
  printf '  OpenSSH 版本     : %s\n' "$SSH_VER"
  printf '  发行版           : %s\n' "$OS_ID"

  printf '\n%s\n' "${C_BOLD}服务${C_NC}"
  printf '  init 系统        : %s\n' "$INIT_SYS"
  printf '  服务单元         : %s\n' "$SSH_SERVICE"
  if [ "$SOCKET_ACTIVATED" -eq 1 ]; then
    printf '  socket 激活      : %s\n' "${C_YELLOW}是（ssh.socket 决定监听端口）${C_NC}"
    if [ -f "$SOCKET_OVERRIDE_FILE" ]; then
      printf '  socket 覆盖      : %s\n' "$SOCKET_OVERRIDE_FILE（由本脚本写入）"
    else
      printf '  socket 覆盖      : %s\n' "无（由 sshd-socket-generator 自动同步）"
    fi
  else
    printf '  socket 激活      : 否\n'
  fi

  printf '\n%s\n' "${C_BOLD}实际监听${C_NC}"
  local p rc
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    port_listening "$p"; rc=$?
    case "$rc" in
      0) printf '  端口 %-6s : %s\n' "$p" "${C_GREEN}监听中${C_NC}" ;;
      1) printf '  端口 %-6s : %s\n' "$p" "${C_RED}未监听（配置与实际不符）${C_NC}" ;;
      2) printf '  端口 %-6s : %s\n' "$p" "${C_DIM}无 ss/netstat，无法检测${C_NC}" ;;
    esac
  done < <(effective_ports)

  printf '\n%s\n' "${C_BOLD}原始快照${C_NC}"
  if [ -d "$GENESIS_DIR" ]; then
    printf '  创建于           : %s\n' "$(awk -F= '$1=="created"{sub(/^[^=]*=/,""); print; exit}' "$GENESIS_DIR/meta" 2>/dev/null)"
    printf '  原始端口         : %s\n' "$(awk -F= '$1=="port"{print $2; exit}' "$GENESIS_DIR/meta" 2>/dev/null)"
    printf '  原始密码登录     : %s\n' "$(awk -F= '$1=="passwordauthentication"{print $2; exit}' "$GENESIS_DIR/meta" 2>/dev/null)"
    if genesis_differs; then
      printf '  与当前配置       : %s\n' "${C_YELLOW}存在差异（可用菜单 6 还原）${C_NC}"
    else
      printf '  与当前配置       : %s\n' "${C_GREEN}一致${C_NC}"
    fi
  else
    printf '  %s\n' "${C_DIM}尚未创建${C_NC}"
  fi

  printf '\n%s\n' "${C_BOLD}待确认变更${C_NC}"
  if has_pending; then
    printf '  变更内容         : %s\n' "$(pending_get summary)"
    printf '  距自动回滚       : %s\n' "$(fmt_mmss "$(pending_remaining)")"
    printf '  验证命令         : %s\n' "$(pending_get verify_cmd)"
  else
    printf '  %s\n' "${C_DIM}无${C_NC}"
  fi

  printf '\n%s\n' "${C_BOLD}备份${C_NC}"
  local n=0 b
  [ -d "$BACKUP_ROOT" ] && n=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
  if [ "$n" -eq 0 ]; then
    printf '  %s\n' "${C_DIM}尚无备份（还没有执行过会修改配置的操作）${C_NC}"
  else
    printf '  共 %s 份，最近 5 份：\n' "$n"
    while IFS= read -r b; do
      [ -n "$b" ] || continue
      if [ -e "$b/.restored" ]; then
        printf '    %s %s\n' "$b" "${C_DIM}(已回滚消费)${C_NC}"
      else
        printf '    %s\n' "$b"
      fi
    done < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -5)
    if latest_backup >/dev/null 2>&1; then
      printf '  菜单 4 下一次将回滚到: %s\n' "$(latest_backup)"
    else
      printf '  %s\n' "${C_DIM}备份均已被回滚消费，如需退到底请用菜单 6${C_NC}"
    fi
  fi

  # fail2ban 端口一致性
  if fail2ban_active; then
    printf '\n%s\n' "${C_BOLD}fail2ban${C_NC}"
    local raw resolved cur
    raw=$(fail2ban_jail_port || printf '')
    resolved=$(resolve_service_port "${raw%%,*}")
    cur=$(first_effective_port)
    printf '  jail port        : %s\n' "${raw:-未设置}"
    if [ -n "$resolved" ] && [ "$resolved" != "$cur" ]; then
      printf '  一致性           : %s\n' "${C_RED}不一致：封禁打在 ${resolved}，SSH 在 ${cur}${C_NC}"
      printf '  %s\n' "${C_DIM}封禁对实际 SSH 端口不生效，等于没有防护${C_NC}"
    else
      printf '  一致性           : %s\n' "${C_GREEN}与 SSH 端口一致${C_NC}"
    fi
  fi
}

############################### 锁死防护指引 ###################################

print_lockout_guide() {
  local verify_cmd="$1" what="$2"
  printf '\n'
  printf '%s\n' "${C_GREEN}${C_BOLD}${what}${C_NC}"
  printf '%s\n' "${C_RED}────────────────  请勿关闭当前终端  ────────────────${C_NC}"
  printf '%s\n' "  当前会话是你的退路。自动回滚会退回到它所使用的配置。"
  printf '\n'
  printf '%s\n' "  ${C_BOLD}1.${C_NC} 另开一个终端，执行："
  printf '     %s\n' "${C_GREEN}${verify_cmd}${C_NC}"
  printf '%s\n' "  ${C_BOLD}2.${C_NC} 能正常登录 → 回到本脚本选 ${C_BOLD}3${C_NC} 收口"
  printf '%s\n' "  ${C_BOLD}3.${C_NC} 登录失败   → 选 ${C_BOLD}4${C_NC} 立即回滚，或什么都不做等自动回滚"
  printf '\n'
  printf '%s\n' "  ${C_DIM}退出脚本不会取消自动回滚，随时重新运行本脚本选 3 即可。${C_NC}"
  printf '%s\n' "${C_RED}────────────────────────────────────────────────────${C_NC}"
}

################################### 菜单 ######################################

COUNTDOWN_ROWS_BELOW=0

draw_menu() {
  local below=""
  clear 2>/dev/null || true

  printf '%s\n' "${C_BOLD}╔══════════════════════════════════════════════════════╗${C_NC}"
  printf '%s\n' "${C_BOLD}║  SSH 管理器  v${SCRIPT_VERSION}                                     ║${C_NC}"
  printf '%s\n' "${C_BOLD}╚══════════════════════════════════════════════════════╝${C_NC}"
  printf '  当前端口: %s    密码登录: %s\n' \
    "${C_BOLD}$(first_effective_port)${C_NC}" \
    "${C_BOLD}$(effective_value passwordauthentication)${C_NC}"
  if [ "$SOCKET_ACTIVATED" -eq 1 ]; then
    printf '  服务: %s (socket 激活)\n' "$SSH_SERVICE"
  else
    printf '  服务: %s\n' "$SSH_SERVICE"
  fi

  if has_pending; then
    printf '\n%s\n' "${C_YELLOW}⚠  待确认变更: $(pending_get summary)${C_NC}"
    printf '   距自动回滚: %s\n' "${C_BOLD}$(fmt_mmss "$(pending_remaining)")${C_NC}"
    below="   新终端验证: $(pending_get verify_cmd)
   验证成功选 3 收口 / 失败选 4 立即回滚 / 不管它则到点自动回滚
"
    printf '%s' "$below"
  fi

  printf '\n'
  printf '  1) 配置 SSH 密钥登录\n'
  if has_pending; then
    printf '  2) 修改 SSH 端口            %s\n' "${C_DIM}[待确认期间不可用]${C_NC}"
    printf '  3) 确认变更并解除自动回滚   %s\n' "${C_YELLOW}★${C_NC}"
  else
    printf '  2) 修改 SSH 端口\n'
    printf '  3) 确认变更并解除自动回滚\n'
  fi
  printf '  4) 回滚上一次变更           %s\n' "${C_DIM}（撤销最近一次，退一步）${C_NC}"
  printf '  5) 查看当前 SSH 状态\n'
  if has_pending; then
    printf '  6) 还原到最初配置           %s\n' "${C_DIM}[待确认期间不可用]${C_NC}"
  else
    printf '  6) 还原到最初配置           %s\n' "${C_DIM}（回到脚本首次运行前，退到底）${C_NC}"
  fi
  printf '  0) 退出\n\n'

  # 倒计时行到光标行的距离：below 的行数 + 菜单区固定行数
  local below_lines=0
  [ -n "$below" ] && below_lines=$(printf '%s' "$below" | grep -c '' )
  COUNTDOWN_ROWS_BELOW=$((below_lines + 10))
}

refresh_countdown() {
  has_pending || return 0
  [ -t 1 ] || return 0
  local r
  r=$(pending_remaining) || return 0
  printf '\033[s'
  printf '\033[%dA' "$COUNTDOWN_ROWS_BELOW"
  printf '\r\033[K'
  if [ "$r" -le 0 ]; then
    printf '   距自动回滚: %s' "${C_RED}已到期，正在自动回滚${C_NC}"
  else
    printf '   距自动回滚: %s' "${C_BOLD}$(fmt_mmss "$r")${C_NC}"
  fi
  printf '\033[u'
}

# 有待确认变更且是 TTY 时，用单键读取 + 每秒刷新倒计时。
# 单键而非整行，是为了避免 `read -t` 超时丢弃用户已敲入的半截输入。
read_choice() {
  local prompt="请选择 [0-6]: "
  printf '%s' "${C_YELLOW}${prompt}${C_NC}"

  if [ ! -t 0 ] || ! has_pending; then
    read -r CHOICE || CHOICE="0"
    return 0
  fi

  local key r
  while true; do
    if read -rsn1 -t 1 key; then
      CHOICE="$key"
      printf '%s\n' "$key"
      return 0
    fi
    # 看门狗可能已在超时后回滚并清掉哨兵，此时直接重绘菜单
    if ! has_pending; then
      CHOICE=""
      printf '\n'
      return 0
    fi
    r=$(pending_remaining 2>/dev/null) || r=0
    [[ "$r" =~ ^[0-9]+$ ]] || r=0
    if [ "$r" -le 0 ]; then
      refresh_countdown
      sleep 2
      if ! has_pending; then
        CHOICE=""
        printf '\n'
        return 0
      fi
      continue
    fi
    refresh_countdown
  done
}

CHOICE=""

main_menu() {
  while true; do
    draw_menu
    read_choice
    case "$CHOICE" in
      1) feature_pubkey_login; pause ;;
      2) if has_pending; then
           err "存在待确认变更，请先用菜单 3 确认或菜单 4 回滚"
         else
           feature_change_port
         fi
         pause ;;
      3) feature_confirm; pause ;;
      4) feature_rollback; pause ;;
      5) feature_status; pause ;;
      6) if has_pending; then
           err "存在待确认变更，请先用菜单 3 确认或菜单 4 回滚"
         else
           feature_restore_genesis
         fi
         pause ;;
      0) printf '\n'
         if has_pending; then
           warn "仍有待确认变更，自动回滚计时继续（剩余 $(fmt_mmss "$(pending_remaining)")）"
           warn "验证成功后请重新运行本脚本选 3 收口"
         fi
         info "已退出"
         exit 0 ;;
      "") ;;  # 倒计时到期重绘
      *) err "无效选项: $CHOICE"; sleep 1 ;;
    esac
  done
}

################################## 入口 #######################################

main() {
  if [ "$(id -u)" -ne 0 ]; then
    err "本脚本需要 root 权限（要修改 /etc/ssh 下的配置）"
    info "请使用: sudo bash $0"
    exit 1
  fi

  detect_os
  detect_init
  if ! detect_sshd_bin; then
    err "找不到 sshd 可执行文件，请确认已安装 openssh-server"
    exit 1
  fi
  detect_ssh_service
  detect_socket_activation
  detect_ssh_version

  if [ ! -f "$SSHD_CONFIG" ]; then
    err "找不到 $SSHD_CONFIG"
    exit 1
  fi

  mkdir -p "$STATE_DIR" "$BACKUP_ROOT" || {
    err "无法创建状态目录 $STATE_DIR"
    exit 1
  }
  chmod 700 "$STATE_DIR"

  if ! sshd_dump >/dev/null 2>&1; then
    warn "sshd -T 无法执行（配置可能有误或缺少主机密钥）"
    warn "部分状态显示会退回到直接读配置文件"
  fi

  ensure_genesis || exit 1

  main_menu
}

main "$@"
