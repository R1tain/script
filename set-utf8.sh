#!/bin/sh
#
# set-utf8.sh — 在主流 Linux 发行版上启用 UTF-8 locale
#
# 特点：
#   * 系统级 + 用户级同时生效，sh / bash / zsh 三种 shell 全覆盖
#   * 幂等：用标记块管理配置，重复执行不会产生重复内容
#   * 失败即报错，绝不"假装成功"；结尾有真实的 locale 可用性验证
#   * 写入时保留原文件的 inode / 符号链接 / 属主
#
# 用法：
#   sudo sh set-utf8.sh                     # 默认 en_US.UTF-8
#   sudo sh set-utf8.sh -l zh_CN.UTF-8      # 指定 locale
#   sudo sh set-utf8.sh --no-lc-all         # 只设 LANG，不设 LC_ALL
#
# 注：默认设置 LC_ALL，这是最不容易乱码的做法（能压掉 SSH 客户端透传过来的
#     LANG/LC_*）。副作用是用户无法再用 `LANG=xx cmd` 临时切换，介意就加
#     --no-lc-all。
#

# 允许直接用 zsh 执行本脚本（zsh 默认不做单词拆分，需切到 sh 仿真模式）
if [ -n "${ZSH_VERSION:-}" ]; then
    emulate sh 2>/dev/null || true
fi

set -eu

# 本脚本恰恰是在"当前 locale 有问题"的机器上运行的，因此把自身固定在 C locale，
# 让 sed / grep / tr 的行为完全确定（字符区间按 ASCII 解释，不受系统设置影响）。
# 需要用目标 locale 求值的地方（locale charmap / 末尾展示）都会就地覆盖。
LC_ALL=C
LANG=C
export LC_ALL LANG

# ---------------------------------------------------------------- 参数

TARGET_LOCALE="${TARGET_LOCALE:-en_US.UTF-8}"
SET_LC_ALL=1

MARK_BEGIN="# >>> set-utf8 >>>"
MARK_END="# <<< set-utf8 <<<"
# 必须排在发行版自带的片段之后才能生效：RHEL 的 /etc/profile.d/lang.sh 会在
# LC_ALL 与 LANG 相同时主动 unset LC_ALL。glob 按字典序展开，数字前缀（00-、
# 99-）都排在字母前面，所以这里用 zz- 前缀确保最后加载。
PROFILE_D="/etc/profile.d/zz-locale.sh"
PROFILE_D_LEGACY="/etc/profile.d/00-locale.sh"

usage() {
    cat <<'EOF'
用法: set-utf8.sh [选项]

选项:
  -l, --locale <LOCALE>   目标 locale，默认 en_US.UTF-8（如 zh_CN.UTF-8）
      --no-lc-all         只设置 LANG，不设置 LC_ALL
  -h, --help              显示本帮助
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -l|--locale)
            [ $# -ge 2 ] || { echo "[ERROR] $1 需要一个参数" >&2; exit 2; }
            TARGET_LOCALE="$2"; shift 2 ;;
        --no-lc-all) SET_LC_ALL=0; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "[ERROR] 未知参数: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# en_US.UTF-8 -> LOCALE_LANG=en_US  LOCALE_CHARSET=UTF-8  LOCALE_LANGUAGE=en_US:en
LOCALE_LANG="${TARGET_LOCALE%%.*}"
case "$TARGET_LOCALE" in
    *.*) LOCALE_CHARSET="${TARGET_LOCALE#*.}" ;;
    *)   LOCALE_CHARSET="UTF-8" ;;
esac
LOCALE_CHARSET="${LOCALE_CHARSET%%@*}"          # 去掉 @euro 之类的修饰符
LOCALE_LANGUAGE="${LOCALE_LANG}:${LOCALE_LANG%%_*}"

# ---------------------------------------------------------------- 通用工具

log()  { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

# 下面几处刻意用 'A-Z'/'a-z' 而非 [:upper:]/[:lower:]：处理对象是 locale 名和
# 发行版 ID，均为纯 ASCII；且脚本已固定在 C locale（见开头），字符区间的含义
# 是确定的。用字符类反而会让结果依赖运行时 locale。
# shellcheck disable=SC2018,SC2019
lower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

# locale 名归一化：en_US.UTF-8 与 locale -a 输出的 en_US.utf8 视为同一个
# shellcheck disable=SC2018,SC2019
norm_locale() { printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -d '-'; }

# 转义成可安全用于 sed BRE 的字符串
regex_escape() { printf '%s' "$1" | sed 's/[][\.*^$/]/\\&/g'; }

# 目标 locale 是否已真实存在（glibc）
locale_present() {
    command -v locale >/dev/null 2>&1 || return 1
    # shellcheck disable=SC2018,SC2019
    locale -a 2>/dev/null | tr 'A-Z' 'a-z' | tr -d '-' \
        | grep -qx "$(norm_locale "$TARGET_LOCALE")"
}

read_file()  { if [ -n "$SUDO" ]; then $SUDO cat "$1"; else cat "$1"; fi; }

# 从 stdin 写入文件。用 tee / 重定向而非 mv，以保留 inode、符号链接和权限。
write_file() { if [ -n "$SUDO" ]; then $SUDO tee "$1" >/dev/null; else cat > "$1"; fi; }

# 通过 sudo 运行时，新建的用户级文件不能变成 root 所有
fix_owner() {
    _d=$(dirname "$1")
    _own=$(stat -c '%u:%g' "$_d" 2>/dev/null || true)
    if [ -n "$_own" ]; then
        $SUDO chown "$_own" "$1" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------- 权限

if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
        log "非 root 用户，特权操作将通过 sudo 执行"
    else
        die "请用 root 执行，或先安装 sudo"
    fi
else
    SUDO=""
fi

# ---------------------------------------------------------------- 发行版识别

DISTRO=""; LIKE=""; CODENAME=""; DISTRO_VERSION=""; PRETTY=""

detect_distro() {
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        DISTRO=$(lower "${ID:-}")
        LIKE=$(lower "${ID_LIKE:-}")
        CODENAME="${VERSION_CODENAME:-}"
        DISTRO_VERSION="${VERSION_ID:-}"
        PRETTY="${PRETTY_NAME:-$DISTRO}"
    elif [ -r /etc/alpine-release ]; then
        DISTRO="alpine"; PRETTY="Alpine $(cat /etc/alpine-release)"
    elif [ -r /etc/redhat-release ]; then
        DISTRO="centos"; PRETTY="$(cat /etc/redhat-release)"
    elif [ -r /etc/debian_version ]; then
        DISTRO="debian"; PRETTY="Debian $(cat /etc/debian_version)"
    else
        die "无法识别当前发行版（缺少 /etc/os-release）"
    fi

    # 老 Debian 没有 VERSION_CODENAME，从 /etc/debian_version 推断
    if [ -z "$CODENAME" ] && [ -r /etc/debian_version ]; then
        case "$(cat /etc/debian_version)" in
            8.*)  CODENAME="jessie"   ;;
            9.*)  CODENAME="stretch"  ;;
            10.*) CODENAME="buster"   ;;
            11.*) CODENAME="bullseye" ;;
        esac
    fi
}

# 归到"家族"；未知 ID 时回退到 ID_LIKE（原脚本算出 ID_LIKE 却从没用过）
distro_family() {
    case "$DISTRO" in
        debian|ubuntu|raspbian|kali|deepin|linuxmint|pop|devuan|armbian|zorin|elementary)
            echo debian ;;
        centos|rhel|fedora|rocky|almalinux|ol|oracle|amzn|anolis|opencloudos|tencentos|openeuler|euleros|kylin|uos|circle)
            echo rhel ;;
        alpine)                                   echo alpine ;;
        arch|manjaro|endeavouros|cachyos|garuda)  echo arch ;;
        opensuse*|suse*|sles|sled)                echo suse ;;
        *)
            case " $LIKE " in
                *debian*|*ubuntu*)         echo debian ;;
                *rhel*|*fedora*|*centos*)  echo rhel ;;
                *alpine*)                  echo alpine ;;
                *arch*)                    echo arch ;;
                *suse*)                    echo suse ;;
                *)                         echo unknown ;;
            esac ;;
    esac
}

# musl（Alpine）没有 glibc 那套 locale 数据，char 恒按 UTF-8 处理
is_musl() {
    if [ "$FAMILY" = "alpine" ]; then return 0; fi
    for _f in /lib/ld-musl-*.so.1; do
        if [ -e "$_f" ]; then return 0; fi
    done
    return 1
}

# ---------------------------------------------------------------- 安装：Debian 系

# apt-get 安装；官方源不可用时（EOL 版本）临时回退到 archive.debian.org。
# 回退只作用于本次调用，不会改动 /etc/apt/sources.list。
apt_install() {
    export DEBIAN_FRONTEND=noninteractive

    if $SUDO apt-get update -qq >/dev/null 2>&1; then
        $SUDO apt-get install -y -qq --no-install-recommends "$@" >/dev/null \
            || die "apt-get install $* 失败"
        return 0
    fi

    warn "apt-get update 失败（该版本可能已 EOL，官方源已下线）"
    [ "$DISTRO" = "debian" ] || die "无法从官方源安装 $*，请先修复 apt 源后重试"
    [ -n "$CODENAME" ]       || die "无法确定 Debian 代号，不能回退到 archive.debian.org"

    log "临时回退到 archive.debian.org ($CODENAME)，不会修改你的 sources.list"
    _lst="/tmp/set-utf8-archive.list"
    printf 'deb [trusted=yes] http://archive.debian.org/debian %s main\n' "$CODENAME" \
        | write_file "$_lst"

    # EOL 仓库的 Release 文件 Valid-Until 已过期，必须关掉时间校验
    _apt() {
        $SUDO apt-get \
            -o Dir::Etc::sourcelist="$_lst" \
            -o Dir::Etc::sourceparts=/dev/null \
            -o Acquire::Check-Valid-Until=false \
            -o APT::Get::List-Cleanup=0 \
            "$@"
    }

    if ! _apt update -qq >/dev/null 2>&1; then
        $SUDO rm -f "$_lst"; die "回退到 archive.debian.org 后仍无法更新索引"
    fi
    if ! _apt install -y -qq --no-install-recommends "$@" >/dev/null; then
        $SUDO rm -f "$_lst"; die "从 archive.debian.org 安装 $* 失败"
    fi
    $SUDO rm -f "$_lst"
}

# 确保 /etc/locale.gen 里目标 locale 处于启用状态。
#
# 关键点：Debian 的 locale-gen 只读 /etc/locale.gen，完全忽略命令行参数（只认
# --keep-existing），所以 `locale-gen en_US.UTF-8` 在 Debian 上什么都不会生成，
# 必须先改文件。Ubuntu 打过补丁能收参数，但改文件对两者都有效。
ensure_locale_gen_entry() {
    _gen="/etc/locale.gen"
    if [ ! -f "$_gen" ]; then
        printf '%s %s\n' "$TARGET_LOCALE" "$LOCALE_CHARSET" | write_file "$_gen"
        return 0
    fi

    _esc=$(regex_escape "$TARGET_LOCALE")

    if grep -qE "^[[:space:]]*${_esc}[[:space:]]" "$_gen"; then
        return 0                                    # 已启用
    fi
    if grep -qE "^[[:space:]]*#[[:space:]]*${_esc}[[:space:]]" "$_gen"; then
        $SUDO sed -i "s/^[[:space:]]*#[[:space:]]*\(${_esc}[[:space:]]\)/\1/" "$_gen"
        return 0                                    # 取消注释
    fi
    _tmp=$(mktemp)                                  # 追加
    { read_file "$_gen"; printf '%s %s\n' "$TARGET_LOCALE" "$LOCALE_CHARSET"; } > "$_tmp"
    write_file "$_gen" < "$_tmp"
    rm -f "$_tmp"
}

install_debian() {
    if ! command -v locale-gen >/dev/null 2>&1 || [ ! -f /etc/locale.gen ]; then
        log "安装 locales 包 ..."
        apt_install locales
    fi
    log "在 /etc/locale.gen 中启用 $TARGET_LOCALE ..."
    ensure_locale_gen_entry
    log "生成 locale 数据 ..."
    $SUDO locale-gen
}

# ---------------------------------------------------------------- 安装：RHEL 系

install_rhel() {
    # 先试不需要联网的 localedef —— CentOS 7 的 glibc-common 自带 locale 源文件，
    # 这条直接成功，从而完全绕开已经搬去 vault 的 yum 源。
    log "尝试用 localedef 直接生成 ..."
    if $SUDO localedef -c -f "$LOCALE_CHARSET" -i "$LOCALE_LANG" "$TARGET_LOCALE" >/dev/null 2>&1 \
       && locale_present; then
        return 0
    fi

    # RHEL 8/9 最小安装不带 locale 源文件，localedef 会报
    # "character map file `UTF-8' not found"，必须装 langpack。
    _pm=""
    for _c in dnf microdnf yum; do
        if command -v "$_c" >/dev/null 2>&1; then _pm="$_c"; break; fi
    done
    [ -n "$_pm" ] || die "未找到 dnf/yum，无法安装 locale 数据"

    _langpack="glibc-langpack-${LOCALE_LANG%%_*}"
    log "localedef 缺少数据，改用 $_pm 安装 $_langpack ..."
    if $SUDO "$_pm" install -y "$_langpack" >/dev/null 2>&1 && locale_present; then
        return 0
    fi

    log "退而安装 glibc-locale-source 后重新 localedef ..."
    $SUDO "$_pm" install -y glibc-locale-source glibc-minimal-langpack >/dev/null 2>&1 \
        || die "安装 locale 数据包失败（若为 CentOS 7 等 EOL 版本，请先把 yum 源切到 vault.centos.org）"
    $SUDO localedef -c -f "$LOCALE_CHARSET" -i "$LOCALE_LANG" "$TARGET_LOCALE" \
        || die "localedef 生成 $TARGET_LOCALE 失败"
}

# ---------------------------------------------------------------- 安装：Alpine

install_alpine() {
    # musl 不实现 glibc 那套 locale，字符处理恒为 UTF-8。
    # 装 musl-locales 只是让 `locale` 命令存在并能回显设置。
    log "安装 musl-locales（让 locale 命令可用）..."
    if $SUDO apk add --no-cache musl-locales musl-locales-lang >/dev/null 2>&1; then
        return 0
    fi

    # 本机 /etc/apk/repositories 配置不全时，临时指定仓库地址重试
    #（不修改 /etc/apk/repositories）。musl-locales 在 3.16 及更早属于
    # community，3.19 起挪到了 main，所以两个都得试。
    _ver=$(printf '%s' "${DISTRO_VERSION:-}" | cut -d. -f1,2)
    case "$_ver" in
        [0-9]*.[0-9]*) _base="https://dl-cdn.alpinelinux.org/alpine/v$_ver" ;;
        *)             _base="https://dl-cdn.alpinelinux.org/alpine/edge"   ;;
    esac
    for _r in main community; do
        log "默认仓库中没有，尝试 $_base/$_r ..."
        if $SUDO apk add --no-cache --repository "$_base/$_r" \
                musl-locales musl-locales-lang >/dev/null 2>&1; then
            return 0
        fi
    done
    warn "musl-locales 安装失败；musl libc 始终按 UTF-8 处理字符，功能不受影响，只是没有 locale 命令"
}

# ---------------------------------------------------------------- 安装：其它

install_arch() {
    log "在 /etc/locale.gen 中启用 $TARGET_LOCALE ..."
    ensure_locale_gen_entry
    $SUDO locale-gen
}

install_suse() {
    if command -v zypper >/dev/null 2>&1; then
        $SUDO zypper --non-interactive install glibc-locale >/dev/null 2>&1 || true
    fi
    if locale_present; then return 0; fi
    $SUDO localedef -c -f "$LOCALE_CHARSET" -i "$LOCALE_LANG" "$TARGET_LOCALE" \
        || die "localedef 生成 $TARGET_LOCALE 失败"
}

install_unknown() {
    warn "未知发行版 $DISTRO（ID_LIKE=${LIKE:-空}），尝试通用 localedef"
    command -v localedef >/dev/null 2>&1 || die "系统没有 localedef，无法自动生成 locale"
    $SUDO localedef -c -f "$LOCALE_CHARSET" -i "$LOCALE_LANG" "$TARGET_LOCALE" \
        || die "localedef 生成 $TARGET_LOCALE 失败，请手动安装该发行版的 locale 数据包"
}

# ---------------------------------------------------------------- 写入配置

# shell 启动文件用的配置块（带 export，sh/bash/zsh 通用语法）
emit_exports() {
    echo "$MARK_BEGIN"
    echo "# 由 set-utf8.sh 生成，重新运行脚本即可更新；删除整块即可移除。"
    echo "export LANG=$TARGET_LOCALE"
    echo "export LANGUAGE=$LOCALE_LANGUAGE"
    if [ "$SET_LC_ALL" -eq 1 ]; then
        echo "export LC_ALL=$TARGET_LOCALE"
    fi
    echo "$MARK_END"
}

# /etc/environment 用的配置（pam_env 读取，KEY=VALUE，不能带 export）
emit_plain() {
    echo "LANG=$TARGET_LOCALE"
    echo "LANGUAGE=$LOCALE_LANGUAGE"
    if [ "$SET_LC_ALL" -eq 1 ]; then
        echo "LC_ALL=$TARGET_LOCALE"
    fi
}

strip_block() {
    sed "/^$(regex_escape "$MARK_BEGIN")\$/,/^$(regex_escape "$MARK_END")\$/d"
}

# 幂等写入：先删掉旧的标记块，再追加新块
upsert_block() {
    _f="$1"
    if [ ! -e "$_f" ]; then write_file "$_f" < /dev/null; fi
    _tmp=$(mktemp)
    { read_file "$_f" | strip_block; emit_exports; } > "$_tmp"
    write_file "$_f" < "$_tmp"
    rm -f "$_tmp"
    fix_owner "$_f"
    log "  已更新 $_f"
}

write_environment() {
    _f="/etc/environment"
    if [ ! -e "$_f" ]; then write_file "$_f" < /dev/null; fi
    _tmp=$(mktemp)
    {
        read_file "$_f" | grep -vE '^[[:space:]]*(LANG|LANGUAGE|LC_ALL|LC_CTYPE)=' || true
        emit_plain
    } > "$_tmp"
    write_file "$_f" < "$_tmp"
    rm -f "$_tmp"
    log "  已更新 $_f"
}

persist_system() {
    log "写入系统级配置 ..."

    # 1) sh / bash 登录 shell
    $SUDO mkdir -p "$(dirname "$PROFILE_D")"
    emit_exports | write_file "$PROFILE_D"
    $SUDO chmod 0644 "$PROFILE_D"
    log "  已更新 $PROFILE_D"
    # 清理本脚本早期版本留下的文件，避免两份配置并存
    if [ -f "$PROFILE_D_LEGACY" ] && grep -q "^$MARK_BEGIN\$" "$PROFILE_D_LEGACY" 2>/dev/null; then
        $SUDO rm -f "$PROFILE_D_LEGACY"
        log "  已移除旧文件 $PROFILE_D_LEGACY"
    fi

    # 2) PAM 会话（SSH、cron、systemd user session）
    write_environment

    # 3) zsh —— zsh 不读 /etc/profile.d，必须单独写。
    #    zshenv 对登录/交互/脚本三种调用方式都生效。
    if [ -d /etc/zsh ]; then
        upsert_block /etc/zsh/zshenv
    elif command -v zsh >/dev/null 2>&1; then
        upsert_block /etc/zshenv
    fi

    # 4) systemd 系发行版的标准 locale 配置
    if [ "$FAMILY" = "rhel" ] || [ "$FAMILY" = "arch" ] || [ "$FAMILY" = "suse" ] \
       || [ -d /run/systemd/system ]; then
        printf 'LANG=%s\n' "$TARGET_LOCALE" | write_file /etc/locale.conf
        log "  已更新 /etc/locale.conf"
    fi

    # 5) Debian/Ubuntu 的标准位置
    if [ "$FAMILY" = "debian" ] && command -v update-locale >/dev/null 2>&1; then
        if $SUDO update-locale "LANG=$TARGET_LOCALE" "LANGUAGE=$LOCALE_LANGUAGE"; then
            log "  已更新 /etc/default/locale"
        else
            warn "update-locale 失败，但其余配置已写入"
        fi
    fi
}

user_homes() {
    echo "${HOME:-/root}"
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        if command -v getent >/dev/null 2>&1; then
            getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6
        else
            awk -F: -v u="$SUDO_USER" '$1==u{print $6}' /etc/passwd 2>/dev/null
        fi
    fi
}

persist_user() {
    log "写入用户级配置 ..."
    # zsh 的三个文件缺一不可：
    #   .zshenv   —— 所有调用方式（含 `zsh -c`）
    #   .zprofile —— 登录但非交互（`zsh -lc`、SSH 执行远程命令），不读 .zshrc
    #   .zshrc    —— 交互式，且排在 /etc/profile 之后，能压过发行版默认设置
    _want_zsh=0
    if command -v zsh >/dev/null 2>&1; then _want_zsh=1; fi

    _seen=""
    for _h in $(user_homes); do
        [ -d "$_h" ] || continue
        case " $_seen " in *" $_h "*) continue ;; esac
        _seen="$_seen $_h"

        upsert_block "$_h/.profile"     # sh 登录 shell
        upsert_block "$_h/.bashrc"      # bash 交互式 shell
        for _z in .zshenv .zprofile .zshrc; do
            # 没装 zsh 就不去创建这些文件，除非它们本来就在
            if [ "$_want_zsh" -eq 1 ] || [ -f "$_h/$_z" ]; then
                upsert_block "$_h/$_z"
            fi
        done
    done
}

# ---------------------------------------------------------------- 验证

verify() {
    log "验证 ..."

    if is_musl; then
        log "  musl libc：字符处理恒为 UTF-8，无需生成 locale 数据"
    else
        locale_present || die "验证失败：$TARGET_LOCALE 仍未出现在 locale -a 中"
        log "  locale -a 中已存在 $TARGET_LOCALE"
    fi

    if command -v locale >/dev/null 2>&1; then
        _cm=$(LC_ALL="$TARGET_LOCALE" locale charmap 2>/dev/null || true)
        case "$(lower "$_cm")" in
            utf-8|utf8) log "  实测字符集: $_cm" ;;
            "")         warn "  locale charmap 无输出（musl 上属正常）" ;;
            *)          die "验证失败：实际字符集为 '$_cm'，不是 UTF-8" ;;
        esac
    fi

    # 语法检查只针对"我们自己生成的内容"。绝不能去 parse 用户原有的 dotfile：
    # 例如 Kali 自带的 /root/.zshrc 是 259 行 zsh 专用语法，用 sh -n 必然报错，
    # 那样会在配置已经写完之后才误报失败。
    _tmp=$(mktemp)
    emit_exports > "$_tmp"
    for _sh in sh bash zsh; do
        command -v "$_sh" >/dev/null 2>&1 || continue
        "$_sh" -n "$_tmp" 2>/dev/null || { rm -f "$_tmp"; die "验证失败：生成的配置块在 $_sh 下语法非法"; }
        log "  配置块通过 $_sh 语法检查"
    done
    rm -f "$_tmp"

    # $PROFILE_D 整个文件都是本脚本生成的，可以整体检查
    if [ -f "$PROFILE_D" ]; then
        sh -n "$PROFILE_D" 2>/dev/null || die "验证失败：$PROFILE_D 存在语法错误"
    fi
}

# ---------------------------------------------------------------- 主流程

detect_distro
FAMILY=$(distro_family)

log "系统: ${PRETTY:-$DISTRO}"
log "识别: DISTRO=$DISTRO FAMILY=$FAMILY ID_LIKE=${LIKE:-空}"
if [ "$SET_LC_ALL" -eq 1 ]; then
    log "目标: $TARGET_LOCALE（同时设置 LANG 与 LC_ALL）"
else
    log "目标: $TARGET_LOCALE（只设置 LANG）"
fi

if locale_present; then
    log "$TARGET_LOCALE 已存在，跳过生成"
else
    case "$FAMILY" in
        debian) install_debian  ;;
        rhel)   install_rhel    ;;
        alpine) install_alpine  ;;
        arch)   install_arch    ;;
        suse)   install_suse    ;;
        *)      install_unknown ;;
    esac
fi

persist_system
persist_user
verify

echo
log "完成。当前 shell 尚未生效，请任选其一："
log "  · 重新登录 / 新开终端        （推荐，bash、zsh、sh 都会生效）"
log "  · 或执行: . $PROFILE_D"
echo
log "生效后的 locale："
# 直接 source 刚生成的配置来展示，而不是手工拼环境变量——这样打印出来的
# 就是新登录 shell 真正会拿到的结果（含 LANGUAGE，且 --no-lc-all 时不会
# 误显示 LC_ALL）。
if [ -f "$PROFILE_D" ]; then
    # 先清掉脚本开头为自身固定的 C locale，否则 --no-lc-all 时残留的 LC_ALL=C
    # 会盖住 LANG，把展示结果全变成 C
    unset LC_ALL LANG LANGUAGE
    # shellcheck disable=SC1090
    . "$PROFILE_D"
fi
locale 2>/dev/null || true
