#!/bin/sh
#===============================================================================
# gen_ed25519.sh — 生成一次性 ed25519 密钥对，用于给新 VPS 安装 authorized_keys
#
# 设计文档: docs/superpowers/specs/2026-08-30-gen-ed25519-design.md
#
# 用法: sh gen_ed25519.sh [-d DIR] [-f FILE] [-C COMMENT] [-p] [-q] [-y] [-h]
#===============================================================================
set -eu

DEFAULT_SUBDIR=keys

if [ -t 1 ]; then
  C_R=$(printf '\033[0;31m'); C_B=$(printf '\033[1m'); C_N=$(printf '\033[0m')
else
  C_R=''; C_B=''; C_N=''
fi

OPT_DIR=''
OPT_FILE=''
OPT_COMMENT=''
OPT_PASS=0
OPT_QUIET=0
OPT_YES=0

die() {
  printf '%s错误:%s %s\n' "$C_R" "$C_N" "$1" >&2
  exit 1
}

usage() {
  cat <<'EOF'
用法: gen_ed25519.sh [选项]

生成一把一次性 ed25519 密钥对，默认落在 ~/keys/，并打印公钥、私钥，
以及可直接粘贴到新 VPS 的 authorized_keys 安装片段。

选项:
  -d, --dir PATH        输出目录（默认 ~/keys）
  -f, --file PATH       完整输出路径，覆盖 -d 与自动命名
  -C, --comment TEXT    密钥注释（默认 user@shorthost-YYYYMMDD）
  -p, --passphrase      交互式设置口令（默认无口令）
  -q, --quiet           仅输出私钥路径一行，便于脚本调用
  -y, --yes             非交互：自动安装依赖、允许覆盖已存在文件
  -h, --help            显示此帮助

示例:
  gen_ed25519.sh                        # 默认，落到 ~/keys/
  gen_ed25519.sh -d /tmp/k -C ci-key    # 指定目录与注释
  gen_ed25519.sh -q                     # 仅输出私钥路径
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -d|--dir)
        if [ $# -lt 2 ]; then die "$1 需要一个参数"; fi
        OPT_DIR=$2; shift 2 ;;
      -f|--file)
        if [ $# -lt 2 ]; then die "$1 需要一个参数"; fi
        OPT_FILE=$2; shift 2 ;;
      -C|--comment)
        if [ $# -lt 2 ]; then die "$1 需要一个参数"; fi
        OPT_COMMENT=$2; shift 2 ;;
      -p|--passphrase) OPT_PASS=1; shift ;;
      -q|--quiet)      OPT_QUIET=1; shift ;;
      -y|--yes)        OPT_YES=1; shift ;;
      -h|--help)       usage; exit 0 ;;
      *)               die "未知选项: $1（用 -h 查看帮助）" ;;
    esac
  done

  if [ "$OPT_PASS" -eq 1 ] && [ "$OPT_QUIET" -eq 1 ]; then
    die "-q 与 -p 互斥：静默模式下无法提示输入口令"
  fi
}

# 8 个 [0-9a-f] 字符，三级降级：od → openssl → PID+时间
rand_hex8() {
  h=''
  if [ -r /dev/urandom ] && command -v od >/dev/null 2>&1; then
    h=$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n') || h=''
  fi
  if [ ${#h} -ne 8 ] && command -v openssl >/dev/null 2>&1; then
    h=$(openssl rand -hex 4 2>/dev/null | tr -d '\n') || h=''
  fi
  if [ ${#h} -ne 8 ]; then
    h=$(printf '%08d' $(( ($$ * 7919 + $(date +%s)) % 100000000 )))
  fi
  printf '%s' "$h"
}

default_comment() {
  u=${USER:-}
  if [ -z "$u" ]; then u=$(id -un 2>/dev/null) || u=user; fi
  hn=$(uname -n 2>/dev/null | cut -d. -f1) || hn=''
  if [ -z "$hn" ]; then hn=unknown; fi
  printf '%s@%s-%s' "$u" "$hn" "$(date +%Y%m%d)"
}

# 在 KEY_DIR 下挑一个不冲突的文件名，最多重试 5 次
pick_name() {
  i=0
  while [ $i -lt 5 ]; do
    n="$(date +%Y%m%d)-$(rand_hex8)"
    if [ ! -e "$KEY_DIR/$n" ] && [ ! -e "$KEY_DIR/$n.pub" ]; then
      printf '%s' "$KEY_DIR/$n"
      return 0
    fi
    i=$((i + 1))
  done
  die "连续 5 次文件名冲突，请检查 $KEY_DIR"
}

# 设置 KEY_DIR / KEY_PATH / EXPLICIT
resolve_target() {
  if [ -n "$OPT_FILE" ]; then
    EXPLICIT=1
    KEY_PATH=$OPT_FILE
    KEY_DIR=$(dirname "$KEY_PATH")
  else
    EXPLICIT=0
    if [ -n "$OPT_DIR" ]; then
      KEY_DIR=$OPT_DIR
    else
      if [ -z "${HOME:-}" ]; then
        die "HOME 未设置，无法确定默认目录；请用 -d 或 -f 显式指定"
      fi
      KEY_DIR="$HOME/$DEFAULT_SUBDIR"
    fi
  fi

  # 只在目录由本脚本创建时设 700；绝不修改已存在目录的权限
  # （否则 -d /tmp 会把 /tmp 改成 700，后果严重）
  if [ ! -d "$KEY_DIR" ]; then
    mkdir -p "$KEY_DIR" || die "无法创建目录: $KEY_DIR"
    chmod 700 "$KEY_DIR" || die "无法设置目录权限: $KEY_DIR"
  fi

  if [ "$EXPLICIT" -eq 0 ]; then
    KEY_PATH=$(pick_name)
  else
    if [ -e "$KEY_PATH" ] || [ -e "$KEY_PATH.pub" ]; then
      if [ "$OPT_YES" -ne 1 ]; then
        die "目标已存在: $KEY_PATH（加 -y 覆盖）"
      fi
      rm -f "$KEY_PATH" "$KEY_PATH.pub"
    fi
  fi
}

# 回显 apt / apk / rpm / unknown
detect_pkg_mgr() {
  id_=''
  like=''
  if [ -r /etc/os-release ]; then
    # shellcheck source=/dev/null
    id_=$( . /etc/os-release 2>/dev/null; printf '%s' "${ID:-}" ) || id_=''
    # shellcheck source=/dev/null
    like=$( . /etc/os-release 2>/dev/null; printf '%s' "${ID_LIKE:-}" ) || like=''
  fi

  case " $id_ $like " in
    *debian*|*ubuntu*)
      printf 'apt'; return 0 ;;
    *alpine*)
      printf 'apk'; return 0 ;;
    *rhel*|*fedora*|*centos*|*rocky*|*almalinux*|*' ol '*)
      printf 'rpm'; return 0 ;;
  esac

  if command -v apt-get  >/dev/null 2>&1; then printf 'apt'; return 0; fi
  if command -v apk      >/dev/null 2>&1; then printf 'apk'; return 0; fi
  if command -v dnf      >/dev/null 2>&1; then printf 'rpm'; return 0; fi
  if command -v yum      >/dev/null 2>&1; then printf 'rpm'; return 0; fi
  if command -v microdnf >/dev/null 2>&1; then printf 'rpm'; return 0; fi

  printf 'unknown'
}

ensure_ssh_keygen() {
  if command -v ssh-keygen >/dev/null 2>&1; then return 0; fi

  mgr=$(detect_pkg_mgr)
  case "$mgr" in
    apt) inst='apt-get update -qq && apt-get install -y openssh-client' ;;
    apk) inst='apk add --no-cache openssh-keygen' ;;
    rpm)
      inst=''
      for c in dnf yum microdnf; do
        if command -v "$c" >/dev/null 2>&1; then inst="$c install -y openssh"; break; fi
      done
      if [ -z "$inst" ]; then
        die "未找到 ssh-keygen，也未找到可用的 rpm 系包管理器，请手动安装 openssh"
      fi
      ;;
    *)
      die "未找到 ssh-keygen，且无法识别包管理器，请手动安装后重试"
      ;;
  esac

  if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
      inst="sudo sh -c '$inst'"
    else
      die "未找到 ssh-keygen，当前非 root 且无 sudo。请手动执行：$inst"
    fi
  fi

  if [ "$OPT_YES" -ne 1 ]; then
    if [ ! -t 0 ]; then
      die "未找到 ssh-keygen。非交互环境请加 -y 自动安装，或手动执行：$inst"
    fi
    printf '未找到 ssh-keygen，需要执行：\n  %s\n继续？[y/N] ' "$inst" >&2
    read -r ans || ans=''
    case "$ans" in
      y|Y|yes|YES) : ;;
      *) die "已取消。请手动执行：$inst" ;;
    esac
  fi

  if ! eval "$inst" >/dev/null 2>&1; then
    die "安装 ssh-keygen 失败，请手动执行：$inst"
  fi
  if ! command -v ssh-keygen >/dev/null 2>&1; then
    die "安装完成但仍未找到 ssh-keygen，请手动检查"
  fi
}

generate() {
  umask 077
  if [ "$OPT_PASS" -eq 1 ]; then
    # 不传 -N：让 ssh-keygen 自己在 /dev/tty 上提示口令。它自带两次确认、
    # 不回显、不匹配即重试，且口令全程不经过本脚本、不进管道、不进 argv。
    #
    # 不要改成用管道喂口令：readpassphrase() 会优先打开 /dev/tty，并在
    # tcsetattr(TCSAFLUSH) 关回显时丢弃管道里已排队的数据，随后永久等待。
    printf '接下来由 ssh-keygen 提示输入口令（需输入两次，输入时不回显）\n' >&2
    if ! ssh-keygen -t ed25519 -f "$KEY_PATH" -C "$COMMENT" >/dev/null; then
      rm -f "$KEY_PATH" "$KEY_PATH.pub"
      die "ssh-keygen 执行失败"
    fi
    # 直接回车会得到一把无口令密钥。不静默接受：删掉并报错。
    if ssh-keygen -y -P '' -f "$KEY_PATH" >/dev/null 2>&1; then
      rm -f "$KEY_PATH" "$KEY_PATH.pub"
      die "-p 要求设置口令，但收到的是空口令；已删除刚生成的密钥。不需要口令请去掉 -p"
    fi
  else
    if ! ssh-keygen -t ed25519 -N '' -f "$KEY_PATH" -C "$COMMENT" >/dev/null 2>&1; then
      rm -f "$KEY_PATH" "$KEY_PATH.pub"
      die "ssh-keygen 执行失败"
    fi
  fi
  chmod 600 "$KEY_PATH"
  chmod 644 "$KEY_PATH.pub"
}

report() {
  if [ "$OPT_QUIET" -eq 1 ]; then
    printf '%s\n' "$KEY_PATH"
    return 0
  fi

  fp=$(ssh-keygen -l -f "$KEY_PATH.pub" 2>/dev/null | awk '{print $2}') || fp=''
  publine=$(cat "$KEY_PATH.pub")

  printf '%s==================================%s\n' "$C_B" "$C_N"
  printf '%sED25519 密钥生成成功%s\n' "$C_B" "$C_N"
  printf '%s==================================%s\n' "$C_B" "$C_N"
  printf '私钥：%s\n' "$KEY_PATH"
  printf '公钥：%s.pub\n' "$KEY_PATH"
  printf '指纹：%s\n' "$fp"
  printf '\n'

  printf '========== 公钥 ==========\n'
  printf '%s\n\n' "$publine"

  printf '========== 私钥 ==========\n'
  cat "$KEY_PATH"
  printf '\n'

  printf '%s===== 在新 VPS 上执行 =====%s\n' "$C_B" "$C_N"
  printf 'mkdir -p ~/.ssh && chmod 700 ~/.ssh\n'
  printf "echo '%s' >> ~/.ssh/authorized_keys\n" "$publine"
  printf 'chmod 600 ~/.ssh/authorized_keys\n'
  printf '\n'

  printf '%s===== 本机连接 =====%s\n' "$C_B" "$C_N"
  printf 'ssh -i %s root@<新机IP>\n' "$KEY_PATH"
}

main() {
  parse_args "$@"
  ensure_ssh_keygen

  # -p 需要控制终端：ssh-keygen 要在 /dev/tty 上提示。非交互环境下若放行，
  # 它会退回读 stdin 并可能拿到空口令，用户却以为密钥受保护。
  # 这个检查必须早于 resolve_target，失败时不留下任何目录或文件。
  if [ "$OPT_PASS" -eq 1 ] && [ ! -t 0 ]; then
    die "-p 需要交互式终端；非交互环境请去掉 -p（否则会静默生成无口令密钥）"
  fi

  COMMENT=$OPT_COMMENT
  if [ -z "$COMMENT" ]; then COMMENT=$(default_comment); fi

  resolve_target
  generate
  report
}

main "$@"
