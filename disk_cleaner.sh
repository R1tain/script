#!/bin/sh
#
# 全脚本使用 local：它虽不在 POSIX 里，但 dash、busybox ash、bash、ksh 全都
# 支持，本仓库的目标发行版（含 Alpine 3.16 与 edge 的 busybox）已逐一实测。
# 在这样一个多层嵌套的脚本里放弃 local，变量互相踩踏的风险远大于收益。
# shellcheck disable=SC3043
#
# disk_cleaner.sh — 跨发行版磁盘清理工具
#
# 原作者: R1tain   https://github.com/R1tain/script
#
# 设计原则：
#   * 纯 POSIX sh —— Alpine 默认没有 bash，原版 #!/bin/bash 在其上无法运行
#   * 只做「确定安全」的清理；有风险的操作（删内核、清 /usr/src、docker -a）
#     一律改为显式开关，默认不做
#   * 计数、字节数都是真实统计，不是摆设
#   * 支持 --dry-run：完整走一遍流程并报告将删除什么，但一个字节都不动
#
# 用法：
#   sudo sh disk_cleaner.sh                 # 默认安全清理
#   sudo sh disk_cleaner.sh -n              # 演练，只报告不删除
#   sudo sh disk_cleaner.sh --only logs,temp
#   sudo sh disk_cleaner.sh --exclude docker
#   sudo sh disk_cleaner.sh --kernels       # 额外清理旧内核（有风险，见下）
#   sudo sh disk_cleaner.sh --cron          # 安装每日定时任务
#   sudo sh disk_cleaner.sh -h
#

# 允许直接用 zsh 执行（zsh 默认不做单词拆分，需切到 sh 仿真模式）
if [ -n "${ZSH_VERSION:-}" ]; then
    emulate sh 2>/dev/null || true
fi

set -u
# 刻意不用 set -e：清理脚本里单个步骤失败不应中断整体流程，
# 每一步都自己判断返回值并降级为 WARN。

# 固定自身的 locale，让 sort / find / awk 的行为不受宿主机设置影响
LC_ALL=C
LANG=C
export LC_ALL LANG

# ---------------------------------------------------------------- 配置

LOG_FILE="${DISK_CLEANER_LOG:-/var/log/disk_cleaner.log}"
LOG_MAX_KB=1024                 # 自身日志超过 1MiB 就截断到最后 1000 行
JOURNAL_KEEP="20M"              # journald 保留大小
TEMP_AGE_DAYS=7                 # /tmp、/var/tmp 中超过 N 天未修改的文件
BACKUP_AGE_DAYS=30              # /etc 下 *.bak / *~ 超过 N 天
LOG_TRUNCATE_KB=2048            # 大于 2MiB 的日志截断到 2MiB
KERNELS_TO_KEEP=2               # --kernels 时保留几个内核（含当前运行的）

SCRIPT_URL="https://raw.githubusercontent.com/R1tain/script/main/disk_cleaner.sh"
INSTALL_PATH="/usr/local/bin/disk_cleaner.sh"

# 全部可选任务 / 默认启用的任务
ALL_TASKS="pkgcache logs journal temp crash backups emptydirs docker snap flatpak kernels usrsrc"
TASKS="pkgcache logs journal temp crash backups emptydirs docker snap flatpak"

DRY_RUN=0
DOCKER_ALL=0
DO_CRON=0
ASSUME_YES=0
USE_COLOR=auto

# ---------------------------------------------------------------- 参数

usage() {
    cat <<'EOF'
用法: disk_cleaner.sh [选项]

选项:
  -n, --dry-run         演练模式：报告将清理什么，但不做任何删除
      --only  <a,b,..>  只执行指定任务
      --exclude <a,b>   排除指定任务
      --kernels         额外清理旧内核（默认关闭，见下方说明）
      --usr-src         额外清理 /usr/src 下的旧内核源码（默认关闭）
      --docker-all      Docker 清理升级为 system prune -a（默认只清悬空镜像和构建缓存）
      --keep-kernels N  --kernels 时保留几个内核，含当前运行的（默认 2）
      --cron            安装每日 03:00 自动清理的定时任务
      --install         把本脚本安装到 /usr/local/bin/disk_cleaner.sh
  -y, --yes             不做任何交互式询问
      --color / --no-color
  -h, --help            显示本帮助

可用任务:
  pkgcache   包管理器缓存与孤立依赖 (apt/dnf/yum/apk/zypper/pacman)
  logs       /var/log 下的轮转日志，以及截断超大日志
  journal    systemd journald 日志
  temp       /tmp、/var/tmp 中的陈旧文件
  crash      /var/crash 下的核心转储
  backups    /etc 下陈旧的 *.bak、*~
  emptydirs  /var/log、/var/cache、/tmp 下的空目录
  docker     Docker 悬空镜像与构建缓存
  snap       已禁用的 snap 版本
  flatpak    未使用的 flatpak 运行时
  kernels    旧内核软件包                （默认关闭）
  usrsrc     /usr/src 下的旧内核源码目录   （默认关闭）

关于 --kernels 的风险:
  容器、OpenVZ/LXC，以及自带内核的 VPS 上，`uname -r` 可能不对应任何已安装的
  内核包。此时「删掉除当前之外的所有内核」等于删光全部内核，系统将无法启动。
  本脚本在这种情况下会拒绝执行并给出提示，而不是照做。
EOF
}

split_list() { printf '%s' "$1" | tr ',' ' '; }

task_known() {
    case " $ALL_TASKS " in *" $1 "*) return 0 ;; esac
    return 1
}

task_on() {
    case " $TASKS " in *" $1 "*) return 0 ;; esac
    return 1
}

task_add() {
    task_on "$1" || TASKS="$TASKS $1"
}

task_del() {
    local out="" t
    for t in $TASKS; do
        [ "$t" = "$1" ] || out="$out $t"
    done
    TASKS="${out# }"
}

DO_INSTALL=0
while [ $# -gt 0 ]; do
    case "$1" in
        -n|--dry-run)  DRY_RUN=1; shift ;;
        --only)
            [ $# -ge 2 ] || { echo "[错误] $1 需要一个参数" >&2; exit 2; }
            TASKS=""
            for t in $(split_list "$2"); do
                task_known "$t" || { echo "[错误] 未知任务: $t" >&2; exit 2; }
                TASKS="$TASKS $t"
            done
            TASKS="${TASKS# }"; shift 2 ;;
        --exclude)
            [ $# -ge 2 ] || { echo "[错误] $1 需要一个参数" >&2; exit 2; }
            for t in $(split_list "$2"); do
                task_known "$t" || { echo "[错误] 未知任务: $t" >&2; exit 2; }
                task_del "$t"
            done; shift 2 ;;
        --kernels)     task_add kernels; shift ;;
        --usr-src)     task_add usrsrc;  shift ;;
        --docker-all)  DOCKER_ALL=1; task_add docker; shift ;;
        --keep-kernels)
            [ $# -ge 2 ] || { echo "[错误] $1 需要一个参数" >&2; exit 2; }
            case "$2" in
                ''|*[!0-9]*) echo "[错误] --keep-kernels 需要一个数字" >&2; exit 2 ;;
            esac
            [ "$2" -ge 1 ] || { echo "[错误] --keep-kernels 至少为 1" >&2; exit 2; }
            KERNELS_TO_KEEP="$2"; shift 2 ;;
        --cron)        DO_CRON=1; shift ;;
        --install)     DO_INSTALL=1; shift ;;
        -y|--yes)      ASSUME_YES=1; shift ;;
        --color)       USE_COLOR=always; shift ;;
        --no-color)    USE_COLOR=never;  shift ;;
        -h|--help)     usage; exit 0 ;;
        *) echo "[错误] 未知参数: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------- 输出

# 只在输出到终端时着色。原版无条件输出转义码，配合它自己装的
# `... >> $LOG_FILE 2>&1` cron 任务，会把一堆 ANSI 码写进日志文件。
if [ "$USE_COLOR" = always ] || { [ "$USE_COLOR" = auto ] && [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; }; then
    C_RESET=$(printf '\033[0m');   C_GREEN=$(printf '\033[0;32m')
    C_YELLOW=$(printf '\033[0;33m'); C_RED=$(printf '\033[0;31m')
    C_BLUE=$(printf '\033[0;34m');  C_CYAN=$(printf '\033[0;36m')
else
    C_RESET=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_BLUE=''; C_CYAN=''
fi

LOG_READY=0

log() {
    local level="$1"; shift
    local msg="$*"
    local color="$C_RESET" prefix=""
    case "$level" in
        INFO)    color="$C_BLUE";   prefix="[信息] " ;;
        WARN)    color="$C_YELLOW"; prefix="[警告] " ;;
        ERROR)   color="$C_RED";    prefix="[错误] " ;;
        SUCCESS) color="$C_GREEN";  prefix="[成功] " ;;
        ACTION)  color="$C_CYAN";   prefix="[操作] " ;;
        DETAIL)  color="";          prefix="       " ;;
    esac
    printf '%s%s%s%s\n' "$color" "$prefix" "$msg" "$C_RESET"
    # 日志目录只在启动时建一次，不是每写一行都 mkdir -p
    if [ "$LOG_READY" -eq 1 ]; then
        printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$msg" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

logfile_only() {
    [ "$LOG_READY" -eq 1 ] || return 0
    printf '%s [DETAIL] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

die() { log ERROR "$*"; exit 1; }

# KiB -> 人类可读。原版用 numfmt，而 Alpine 的 busybox 没有这个命令。
human_kb() {
    awk -v k="$1" 'BEGIN{
        split("KiB MiB GiB TiB PiB", u, " ")
        i = 1; v = k + 0
        while (v >= 1024 && i < 5) { v /= 1024; i++ }
        if (i == 1) printf "%d%s", v, u[i]; else printf "%.1f%s", v, u[i]
    }'
}

# ---------------------------------------------------------------- 环境准备

[ "$(id -u)" -eq 0 ] || die "请以 root 权限运行（sudo sh $0）"

# --install：把脚本装到系统路径。
# 原版的做法是把自己整份复制进 heredoc 再写出来，导致 853 行里有一半是副本，
# 改一处要改两处。这里改成直接复制自身；若是 curl | sh 方式运行（$0 不是真实
# 文件），则重新下载。
do_install() {
    local src=""
    if [ "$DRY_RUN" -eq 1 ]; then
        log DETAIL "[演练] 将把脚本安装到 $INSTALL_PATH"
        return 0
    fi
    # 必须确认 $0 确实是本脚本再复制：通过管道执行时 $0 往往是 "sh"，
    # 若当前目录恰好有个同名文件，只判断 -f 就会把无关文件装进系统路径。
    if [ -f "$0" ] && [ -r "$0" ] && grep -q '^# disk_cleaner.sh — 跨发行版磁盘清理工具$' "$0" 2>/dev/null; then
        src="$0"
    fi
    if [ -n "$src" ]; then
        cp "$src" "$INSTALL_PATH" || die "无法写入 $INSTALL_PATH"
    else
        log INFO "通过管道运行，正在从上游重新下载脚本 ..."
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL "$SCRIPT_URL" -o "$INSTALL_PATH" || die "下载失败: $SCRIPT_URL"
        elif command -v wget >/dev/null 2>&1; then
            wget -qO "$INSTALL_PATH" "$SCRIPT_URL" || die "下载失败: $SCRIPT_URL"
        else
            die "既无法读取自身（$0），也没有 curl/wget 可用于下载"
        fi
    fi
    chmod 0755 "$INSTALL_PATH"
    log SUCCESS "脚本已安装到 $INSTALL_PATH"
}

# 日志文件：/var/log 不可写时降级到 /tmp，而不是每行 log 都静默失败
init_log() {
    local dir
    dir=$(dirname "$LOG_FILE")
    if mkdir -p "$dir" 2>/dev/null && : >> "$LOG_FILE" 2>/dev/null; then
        LOG_READY=1
    else
        LOG_FILE="/tmp/disk_cleaner.log"
        if : >> "$LOG_FILE" 2>/dev/null; then
            LOG_READY=1
            log WARN "无法写入原日志路径，已改用 $LOG_FILE"
        else
            log WARN "无法写入任何日志文件，本次仅输出到控制台"
        fi
    fi
}

# 限制自身日志大小
manage_log_size() {
    [ "$LOG_READY" -eq 1 ] || return 0
    local size_kb tmp
    size_kb=$(( $(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) / 1024 ))
    [ "$size_kb" -gt "$LOG_MAX_KB" ] || return 0
    log WARN "日志文件超过 $(human_kb "$LOG_MAX_KB")，截断为最后 1000 行"
    tmp="${LOG_FILE}.tmp.$$"
    if tail -n 1000 "$LOG_FILE" > "$tmp" 2>/dev/null; then
        cat "$tmp" > "$LOG_FILE" && rm -f "$tmp"
    else
        rm -f "$tmp"
    fi
}

# ---------------------------------------------------------------- 发行版识别

DISTRO=""; LIKE=""; PRETTY=""; PM=""

lower() { printf '%s' "$1" | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz'; }

detect_distro() {
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        DISTRO=$(lower "${ID:-}")
        LIKE=$(lower "${ID_LIKE:-}")
        PRETTY="${PRETTY_NAME:-$DISTRO}"
    elif [ -r /etc/redhat-release ]; then
        DISTRO="centos"; PRETTY="$(cat /etc/redhat-release)"
    elif [ -r /etc/alpine-release ]; then
        DISTRO="alpine"; PRETTY="Alpine $(cat /etc/alpine-release)"
    elif [ -r /etc/debian_version ]; then
        DISTRO="debian"; PRETTY="Debian $(cat /etc/debian_version)"
    else
        DISTRO="unknown"; PRETTY="未知发行版"
    fi
}

# 归到「家族」；未知 ID 时回退到 ID_LIKE
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

detect_pm() {
    local c
    # dnf 优先于 yum：RHEL9 上两者都在，但 yum 只是 dnf 的软链
    for c in apt-get dnf yum microdnf apk zypper pacman; do
        if command -v "$c" >/dev/null 2>&1; then PM="$c"; return 0; fi
    done
    PM=""
}

# ---------------------------------------------------------------- 执行封装

# 执行一条命令，输出进日志；dry-run 时只打印不执行
run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log DETAIL "[演练] 将执行: $*"
        return 0
    fi
    logfile_only "执行: $*"
    if [ "$LOG_READY" -eq 1 ]; then
        "$@" >> "$LOG_FILE" 2>&1
    else
        "$@" >/dev/null 2>&1
    fi
}

TOTAL_FREED_KB=0
TMPDIR_SELF=""

# 经 trap 调用，shellcheck 看不出来
# shellcheck disable=SC2329
cleanup_self() {
    [ -n "$TMPDIR_SELF" ] && rm -rf "$TMPDIR_SELF"
    return 0
}
trap cleanup_self EXIT HUP INT TERM

# 交互式执行且未指定 -y / -n 时，先确认再动手。
# 非交互场景（cron、curl | sh、CI）直接放行，不会卡住 —— 这也是脚本安装的
# cron 任务行里带 -y 的原因。
confirm_start() {
    [ "$DRY_RUN"    -eq 1 ] && return 0
    [ "$ASSUME_YES" -eq 1 ] && return 0
    [ -t 0 ] || return 0

    printf '%s即将在 %s 上执行删除操作，任务: %s%s\n' \
        "$C_YELLOW" "${PRETTY:-$DISTRO}" "$TASKS" "$C_RESET"
    printf '%s继续？[y/N] %s' "$C_YELLOW" "$C_RESET"
    local ans=""
    read -r ans || ans=""
    case "$ans" in
        [Yy]|[Yy][Ee][Ss]) return 0 ;;
        *) log INFO "已取消。可加 -n 先做演练。"; exit 0 ;;
    esac
}

# 统计一份文件清单占用的 KiB。
# 用 xargs -0 + du -ck，每批会输出一行 total，全部相加即为总量。
list_size_kb() {
    tr '\n' '\0' < "$1" | xargs -0 -r du -ck 2>/dev/null \
        | awk '/total$/ { s += $1 } END { print s + 0 }'
}

# 按 find 表达式删除，并真实统计数量与释放空间。
#
# 走两趟：第一趟只 -print 出清单（用于计数、日志与 dry-run），第二趟才真正删除。
#   * 调用方传入的表达式**不要**带结尾的 -print，由本函数按用途补上
#     -print / -exec，从而保证两趟命中的是完全相同的集合；
#   * 删除用 find -exec 而不是 xargs，文件名含空格或换行也安全；
#   * 原版把计数写在 `find | while read` 的管道里，while 跑在子 shell 中，
#     计数出了循环就丢了 —— 所以它报告的「删除了 N 个」永远是 0。
#
# 用法: sweep <说明> <模式> <find 的路径与表达式...>
#   模式 file     普通文件      -> rm -f
#   模式 tree     目录或混合    -> rm -rf
#   模式 emptydir 空目录        -> rmdir（只删仍然为空的，比 rm -rf 安全：
#                                 列表生成到实际删除之间目录若被写入，
#                                 rmdir 会失败而不是连内容一起删掉）
sweep() {
    local desc="$1" mode="$2"; shift 2
    local list count size_kb
    list="$TMPDIR_SELF/sweep.$$"

    find "$@" -print > "$list" 2>/dev/null || true
    count=$(wc -l < "$list" 2>/dev/null | tr -d ' ')
    [ -n "$count" ] || count=0

    if [ "$count" -eq 0 ]; then
        log DETAIL "$desc: 没有符合条件的项目"
        rm -f "$list"
        return 0
    fi

    size_kb=$(list_size_kb "$list")
    while IFS= read -r f; do logfile_only "$desc -> $f"; done < "$list"

    if [ "$DRY_RUN" -eq 1 ]; then
        log DETAIL "$desc: [演练] 将删除 $count 项，约 $(human_kb "$size_kb")"
    else
        case "$mode" in
            file)     find "$@" -exec rm -f  {} + 2>/dev/null || true ;;
            tree)     find "$@" -exec rm -rf {} + 2>/dev/null || true ;;
            emptydir) find "$@" -exec rmdir  {} + 2>/dev/null || true ;;
        esac
        log DETAIL "$desc: 已删除 $count 项，释放约 $(human_kb "$size_kb")"
        TOTAL_FREED_KB=$(( TOTAL_FREED_KB + size_kb ))
    fi
    rm -f "$list"
}

# ---------------------------------------------------------------- 清理任务

clean_pkgcache() {
    log ACTION "清理包管理器缓存与孤立依赖 ..."
    case "$PM" in
        apt-get)
            export DEBIAN_FRONTEND=noninteractive
            run apt-get clean       || log WARN "apt-get clean 返回非 0"
            run apt-get autoclean -y || true
            run apt-get autoremove -y --purge \
                || log WARN "apt-get autoremove 返回非 0（详见 $LOG_FILE）"
            ;;
        dnf|microdnf)
            run "$PM" clean all     || log WARN "$PM clean all 返回非 0"
            # microdnf 没有 autoremove
            if [ "$PM" = dnf ]; then
                run dnf autoremove -y || log WARN "dnf autoremove 返回非 0"
            fi
            ;;
        yum)
            run yum clean all       || log WARN "yum clean all 返回非 0"
            run yum autoremove -y   || log WARN "yum autoremove 返回非 0"
            ;;
        apk)
            run apk cache clean     || true
            # 未启用 apk 缓存时 cache clean 无事可做，索引仍占空间
            sweep "apk 索引缓存" tree /var/cache/apk -mindepth 1 -maxdepth 1
            ;;
        zypper)
            run zypper --non-interactive clean -a || log WARN "zypper clean 返回非 0"
            ;;
        pacman)
            run pacman -Sc --noconfirm || log WARN "pacman -Sc 返回非 0"
            ;;
        *)
            log WARN "未识别的包管理器，跳过缓存清理"
            return 0 ;;
    esac
    log SUCCESS "包管理器缓存清理完成"
}

clean_logs() {
    log ACTION "清理 /var/log 下的轮转日志 ..."
    [ -d /var/log ] || { log INFO "/var/log 不存在，跳过"; return 0; }

    # 排除本脚本自己的日志：原版会把 disk_cleaner.log 的轮转副本一起删掉，
    # 甚至在写日志的同时把它截断。
    local self_name
    self_name=$(basename "$LOG_FILE")

    sweep "轮转日志" file /var/log -xdev -type f \
        ! -name "$self_name" ! -name "$self_name.*" \
        \( -name '*.gz' -o -name '*.bz2' -o -name '*.xz' -o -name '*.zst' \
           -o -name '*.old' -o -name '*.[0-9]' -o -name '*.[0-9][0-9]' \
           -o -name '*-20[0-9][0-9][0-9][0-9][0-9][0-9]' \)

    log ACTION "截断大于 $(human_kb "$LOG_TRUNCATE_KB") 的日志 ..."
    local list count
    list="$TMPDIR_SELF/trunc.$$"
    # busybox 的 find 不认 -size +2M，只认 k/c 后缀；原版写的正是 +2M，
    # 所以这一步在 Alpine 上是坏的。
    find /var/log -xdev -type f -size "+${LOG_TRUNCATE_KB}k" \
        ! -name "$self_name" ! -name "$self_name.*" -print > "$list" 2>/dev/null || true
    count=$(wc -l < "$list" 2>/dev/null | tr -d ' '); [ -n "$count" ] || count=0

    if [ "$count" -eq 0 ]; then
        log DETAIL "没有超过阈值的日志文件"
    elif [ "$DRY_RUN" -eq 1 ]; then
        log DETAIL "[演练] 将截断 $count 个大日志文件"
        while IFS= read -r f; do logfile_only "将截断: $f"; done < "$list"
    else
        local before after freed=0
        while IFS= read -r f; do
            before=$(stat -c%s "$f" 2>/dev/null || echo 0)
            # busybox 的 truncate 不认 --size 长选项，只认 -s；原版用的是 --size
            if truncate -s "${LOG_TRUNCATE_KB}k" "$f" 2>/dev/null; then
                after=$(stat -c%s "$f" 2>/dev/null || echo 0)
                freed=$(( freed + (before - after) / 1024 ))
                logfile_only "已截断: $f"
            else
                log WARN "无法截断: $f"
            fi
        done < "$list"
        log DETAIL "已截断 $count 个日志文件，释放约 $(human_kb "$freed")"
        TOTAL_FREED_KB=$(( TOTAL_FREED_KB + freed ))
    fi
    rm -f "$list"
    log SUCCESS "日志清理完成"
}

clean_journal() {
    if ! command -v journalctl >/dev/null 2>&1; then
        log INFO "没有 journalctl，跳过 journald 清理"
        return 0
    fi
    if [ ! -d /var/log/journal ] && [ ! -d /run/log/journal ]; then
        log INFO "未使用 systemd-journald，跳过"
        return 0
    fi
    log ACTION "清理 journald 日志，保留 $JOURNAL_KEEP ..."
    run journalctl --vacuum-size="$JOURNAL_KEEP" \
        || log WARN "journalctl vacuum 返回非 0（容器内常见）"
    log SUCCESS "journald 清理完成"
}

clean_temp() {
    log ACTION "清理超过 $TEMP_AGE_DAYS 天未修改的临时文件 ..."
    # 用 -mtime 而非原版的 -atime：绝大多数系统以 relatime/noatime 挂载，
    # atime 不可靠，会导致该删的不删、不该删的被删。
    local d
    for d in /tmp /var/tmp; do
        [ -d "$d" ] || continue
        sweep "临时文件 $d" file "$d" -xdev \
            \( -path "$d/.X11-unix" -o -path "$d/.ICE-unix" -o -path "$d/.font-unix" \
               -o -path "$d/.Test-unix" -o -path "$d/.XIM-unix" \
               -o -name 'systemd-private-*' -o -name 'snap-private-tmp' \
               -o -path "$TMPDIR_SELF" \) -prune -o \
            -type f -mtime "+$TEMP_AGE_DAYS"
    done
    log SUCCESS "临时文件清理完成"
}

clean_crash() {
    if [ ! -d /var/crash ]; then
        log INFO "/var/crash 不存在，跳过"
        return 0
    fi
    log ACTION "清理 /var/crash 下的核心转储 ..."
    sweep "核心转储" file /var/crash -xdev -type f
    log SUCCESS "核心转储清理完成"
}

clean_backups() {
    [ -d /etc ] || return 0
    log ACTION "清理 /etc 下超过 $BACKUP_AGE_DAYS 天的备份文件 ..."
    sweep "/etc 备份文件" file /etc -xdev -type f \
        \( -name '*.bak' -o -name '*~' -o -name '*.dpkg-old' -o -name '*.dpkg-dist' \
           -o -name '*.rpmsave' -o -name '*.rpmorig' -o -name '*.ucf-old' \) \
        -mtime "+$BACKUP_AGE_DAYS"
    log SUCCESS "备份文件清理完成"
}

clean_emptydirs() {
    log ACTION "清理空目录 ..."
    local d
    for d in /var/log /var/cache /tmp; do
        [ -d "$d" ] || continue
        # 这些空目录是系统正常运作所需的，删掉会破坏 X11 / systemd 服务。
        # 原版无差别删除 /tmp 下的空目录，正会命中 .X11-unix、.ICE-unix。
        #
        # 这里用 ! -path 排除而不是 -prune：-prune 对 -depth 遍历无效
        # （-depth 下目录在其内容之后才被处理，剪枝已经来不及）。
        sweep "空目录 $d" emptydir "$d" -xdev -depth -mindepth 1 \
            -type d -empty \
            ! -path "$d/.X11-unix" ! -path "$d/.ICE-unix" ! -path "$d/.font-unix" \
            ! -path "$d/.Test-unix" ! -path "$d/.XIM-unix" \
            ! -name 'systemd-private-*' ! -name 'snap-private-tmp' \
            ! -path "$TMPDIR_SELF" ! -path "$TMPDIR_SELF/*"
    done
    log SUCCESS "空目录清理完成"
}

clean_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        log INFO "未检测到 Docker，跳过"
        return 0
    fi
    if ! docker info >/dev/null 2>&1; then
        log WARN "Docker 已安装但守护进程不可用，跳过"
        return 0
    fi

    if [ "$DOCKER_ALL" -eq 1 ]; then
        log ACTION "Docker: system prune -a（将删除所有未被运行中容器使用的镜像）"
        run docker system prune -a -f || log WARN "docker system prune 返回非 0"
    else
        # 默认只清真正无主的东西。原版无条件跑 `system prune -a -f`，会把所有
        # 未被「运行中」容器使用的镜像全部删掉 —— 已停止的容器将再也无法启动。
        log ACTION "Docker: 清理悬空镜像与构建缓存（如需更激进请加 --docker-all）"
        run docker image prune -f    || log WARN "docker image prune 返回非 0"
        run docker builder prune -f  || true
    fi
    log SUCCESS "Docker 清理完成"
}

clean_snap() {
    if ! command -v snap >/dev/null 2>&1; then
        log INFO "未检测到 Snap，跳过"
        return 0
    fi
    log ACTION "清理已禁用的 snap 版本 ..."
    run snap set system refresh.retain=2 || log WARN "设置 snap refresh.retain 失败"

    local list count removed=0
    list="$TMPDIR_SELF/snap.$$"
    # Notes 列（第 6 列）标记 disabled 才是旧版本；原版用 /disabled/ 匹配整行，
    # 任何一列出现该词都会误命中。
    snap list --all 2>/dev/null | awk 'NR>1 && $6 ~ /disabled/ { print $1, $3 }' > "$list" 2>/dev/null || true
    count=$(wc -l < "$list" 2>/dev/null | tr -d ' '); [ -n "$count" ] || count=0

    if [ "$count" -eq 0 ]; then
        log DETAIL "没有已禁用的 snap 版本"
    elif [ "$DRY_RUN" -eq 1 ]; then
        log DETAIL "[演练] 将移除 $count 个已禁用的 snap 版本"
    else
        # 循环体放在主 shell 里（重定向而非管道），计数才不会丢
        while read -r name rev; do
            [ -n "$name" ] || continue
            if run snap remove "$name" --revision="$rev"; then
                removed=$(( removed + 1 ))
            else
                log WARN "移除 $name 版本 $rev 失败"
            fi
        done < "$list"
        log DETAIL "已移除 $removed 个 snap 旧版本"
    fi
    rm -f "$list"
    log SUCCESS "Snap 清理完成"
}

clean_flatpak() {
    if ! command -v flatpak >/dev/null 2>&1; then
        log INFO "未检测到 Flatpak，跳过"
        return 0
    fi
    log ACTION "移除未使用的 flatpak 运行时 ..."
    run flatpak uninstall --unused -y || log WARN "flatpak uninstall --unused 返回非 0"
    log SUCCESS "Flatpak 清理完成"
}

# --- 旧内核 -------------------------------------------------------------
#
# 这是整个脚本里最危险的操作，因此默认关闭，且带一道硬性护栏：
# 如果当前运行的内核根本不对应任何已安装的内核包（容器、OpenVZ/LXC、
# 自带内核的 VPS 都是这种情况），说明「保留当前内核」这个前提不成立，
# 此时照原版逻辑执行会把所有内核包一次性删光，系统直接失去引导能力。

clean_kernels() {
    local current list keep_list purge_list count
    current=$(uname -r)
    list="$TMPDIR_SELF/kern.$$"
    purge_list="$TMPDIR_SELF/kpurge.$$"
    : > "$list"; : > "$purge_list"

    log ACTION "检查旧内核（当前运行: $current，保留 $KERNELS_TO_KEEP 个）..."

    case "$FAMILY" in
        debian)
            command -v dpkg-query >/dev/null 2>&1 || { log WARN "没有 dpkg-query，跳过"; return 0; }
            # 只取带版本号的实际内核包，meta 包（linux-image-amd64/generic）不动
            dpkg-query -W -f='${Package}\n' 2>/dev/null \
                | grep -E '^linux-image-[0-9]' | sort -V > "$list" || true
            ;;
        rhel)
            command -v rpm >/dev/null 2>&1 || { log WARN "没有 rpm，跳过"; return 0; }
            rpm -q kernel --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null \
                | grep -v 'not installed' | sort -V > "$list" || true
            ;;
        alpine)
            log INFO "Alpine 不通过包管理器维护多内核，跳过"
            return 0 ;;
        *)
            log INFO "该发行版未实现内核清理，跳过"
            return 0 ;;
    esac

    count=$(wc -l < "$list" | tr -d ' '); [ -n "$count" ] || count=0
    if [ "$count" -eq 0 ]; then
        log INFO "未发现由包管理器安装的内核，跳过"
        rm -f "$list" "$purge_list"; return 0
    fi

    # 护栏：当前内核必须在已安装列表里
    # 用 -F 固定字符串匹配：内核版本里的 . 和 + 若按正则解释会误命中
    if ! grep -qF -- "$current" "$list"; then
        log WARN "当前运行的内核 $current 不对应任何已安装的内核包。"
        log WARN "这通常意味着运行在容器 / OpenVZ / 自带内核的 VPS 上。"
        log WARN "此时删除「除当前之外的内核」会删光全部内核，已跳过该步骤。"
        rm -f "$list" "$purge_list"; return 0
    fi

    if [ "$count" -le "$KERNELS_TO_KEEP" ]; then
        log INFO "已安装 $count 个内核，不超过保留数 $KERNELS_TO_KEEP，无需清理"
        rm -f "$list" "$purge_list"; return 0
    fi

    # 保留最新的 N 个（sort -V 已升序），当前内核无论多旧都强制保留
    keep_list="$TMPDIR_SELF/kkeep.$$"
    tail -n "$KERNELS_TO_KEEP" "$list" > "$keep_list"
    grep -F -- "$current" "$list" >> "$keep_list" 2>/dev/null || true

    while IFS= read -r k; do
        [ -n "$k" ] || continue
        grep -qxF -- "$k" "$keep_list" || printf '%s\n' "$k" >> "$purge_list"
    done < "$list"

    count=$(wc -l < "$purge_list" | tr -d ' '); [ -n "$count" ] || count=0
    if [ "$count" -eq 0 ]; then
        log INFO "没有需要清理的旧内核"
        rm -f "$list" "$keep_list" "$purge_list"; return 0
    fi

    log DETAIL "将清理 $count 个旧内核:"
    while IFS= read -r k; do log DETAIL "  $k"; done < "$purge_list"

    if [ "$DRY_RUN" -eq 1 ]; then
        log DETAIL "[演练] 未实际删除"
        rm -f "$list" "$keep_list" "$purge_list"; return 0
    fi

    # 逐个删除，避免一次失败导致整批未处理
    while IFS= read -r k; do
        [ -n "$k" ] || continue
        case "$FAMILY" in
            debian)
                run apt-get purge -y "$k" || log WARN "移除 $k 失败"
                # 同版本的 headers 一并清理
                local ver
                ver=${k#linux-image-}
                run apt-get purge -y "linux-headers-$ver" 2>/dev/null || true
                ;;
            rhel)
                run "$PM" remove -y "kernel-$k" "kernel-core-$k" "kernel-modules-$k" \
                    || log WARN "移除 kernel-$k 失败"
                ;;
        esac
    done < "$purge_list"

    [ "$FAMILY" = debian ] && { run apt-get autoremove -y --purge || true; }
    rm -f "$list" "$keep_list" "$purge_list"
    log SUCCESS "旧内核清理完成"
}

clean_usrsrc() {
    if [ ! -d /usr/src ]; then
        log INFO "/usr/src 不存在，跳过"
        return 0
    fi
    log ACTION "清理 /usr/src 下的旧内核源码目录 ..."
    local current list count
    current="linux-headers-$(uname -r)"
    list="$TMPDIR_SELF/usrsrc.$$"
    : > "$list"

    # DKMS 依赖 /usr/src 下的模块源码目录（如 zfs-2.1.5、wireguard-1.0），
    # 删掉会导致后续内核升级无法重建模块。原版只按名字前缀判断，会一并删除。
    for d in /usr/src/*; do
        [ -d "$d" ] || continue
        local name; name=$(basename "$d")
        case "$name" in
            "$current"|linux-headers-*generic*|linux-kbuild-*) continue ;;
        esac
        # 保留所有非 linux-headers-* 的目录（几乎都是 DKMS 模块源码）
        case "$name" in
            linux-headers-*) ;;
            *) log DETAIL "保留（疑似 DKMS 源码）: $name"; continue ;;
        esac
        if command -v dkms >/dev/null 2>&1 && dkms status 2>/dev/null | grep -q "$name"; then
            log DETAIL "保留（DKMS 正在使用）: $name"
            continue
        fi
        printf '%s\n' "$d" >> "$list"
    done

    count=$(wc -l < "$list" 2>/dev/null | tr -d ' '); [ -n "$count" ] || count=0
    if [ "$count" -eq 0 ]; then
        log DETAIL "没有可清理的目录"
    else
        local size_kb; size_kb=$(list_size_kb "$list")
        if [ "$DRY_RUN" -eq 1 ]; then
            log DETAIL "[演练] 将删除 $count 个目录，约 $(human_kb "$size_kb")"
            while IFS= read -r d; do log DETAIL "  $d"; done < "$list"
        else
            while IFS= read -r d; do
                logfile_only "删除 /usr/src 目录: $d"
                rm -rf "$d" || log WARN "删除 $d 失败"
            done < "$list"
            log DETAIL "已删除 $count 个目录，释放约 $(human_kb "$size_kb")"
            TOTAL_FREED_KB=$(( TOTAL_FREED_KB + size_kb ))
        fi
    fi
    rm -f "$list"
    log SUCCESS "/usr/src 清理完成"
}

# ---------------------------------------------------------------- 定时任务

setup_cron() {
    local target="$INSTALL_PATH"
    if [ ! -x "$target" ]; then
        # 回退到当前脚本自身；cron 里必须是绝对路径，相对路径到点会找不到文件
        case "$0" in
            /*) target="$0" ;;
            *)  target="$(pwd)/$0" ;;
        esac
    fi
    if [ ! -f "$target" ]; then
        log WARN "找不到可用于定时任务的脚本路径，请先执行 --install"
        return 0
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        log DETAIL "[演练] 将安装每日 03:00 的定时任务"
        return 0
    fi

    # 各发行版的 cron 布局完全不同。原版无条件写 /etc/cron.d/disk_cleaner，
    # 而 Alpine 的 busybox crond 根本不读这个目录 —— 任务会被静默忽略。
    if [ -d /etc/periodic/daily ]; then
        cat > /etc/periodic/daily/disk_cleaner <<EOF
#!/bin/sh
exec "$target" -y --no-color >> "$LOG_FILE" 2>&1
EOF
        chmod 0755 /etc/periodic/daily/disk_cleaner
        log SUCCESS "定时任务已安装: /etc/periodic/daily/disk_cleaner（busybox crond 每日执行）"
    elif [ -d /etc/cron.d ]; then
        printf '0 3 * * * root %s -y --no-color >> %s 2>&1\n' "$target" "$LOG_FILE" \
            > /etc/cron.d/disk_cleaner
        chmod 0644 /etc/cron.d/disk_cleaner
        log SUCCESS "定时任务已安装: /etc/cron.d/disk_cleaner（每日 03:00）"
    elif command -v crontab >/dev/null 2>&1; then
        local tmp; tmp="$TMPDIR_SELF/cron.$$"
        crontab -l 2>/dev/null | grep -v 'disk_cleaner' > "$tmp" || true
        printf '0 3 * * * %s -y --no-color >> %s 2>&1\n' "$target" "$LOG_FILE" >> "$tmp"
        if crontab "$tmp"; then
            log SUCCESS "定时任务已写入 root 的 crontab（每日 03:00）"
        else
            log WARN "写入 crontab 失败"
        fi
        rm -f "$tmp"
    else
        log WARN "系统上没有找到可用的 cron，未安装定时任务。可手动添加："
        log DETAIL "  0 3 * * * $target -y --no-color >> $LOG_FILE 2>&1"
    fi
}

# ---------------------------------------------------------------- 磁盘用量

avail_kb() { df -Pk / 2>/dev/null | awk 'NR==2 { print $4 }'; }

show_disk_usage() {
    log INFO "磁盘使用情况（$1）:"
    if [ "$LOG_READY" -eq 1 ]; then
        { printf '%s [INFO] 磁盘使用情况 (%s):\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
          df -h / 2>/dev/null; } >> "$LOG_FILE" 2>/dev/null || true
    fi
    df -h / 2>/dev/null | while IFS= read -r line; do
        printf '%s       %s%s\n' "$C_GREEN" "$line" "$C_RESET"
    done
}

# ---------------------------------------------------------------- 主流程

detect_distro
FAMILY=$(distro_family)
detect_pm
init_log
manage_log_size

TMPDIR_SELF=$(mktemp -d 2>/dev/null) || die "无法创建临时目录"

[ "$DO_INSTALL" -eq 1 ] && do_install

log INFO "=== 开始磁盘清理 ==="
log INFO "系统: ${PRETTY:-$DISTRO}"
log INFO "识别: DISTRO=$DISTRO FAMILY=$FAMILY 包管理器=${PM:-无}"
log INFO "任务: $TASKS"
[ "$DRY_RUN" -eq 1 ] && log WARN "演练模式：不会删除任何内容"

confirm_start

AVAIL_BEFORE=$(avail_kb); [ -n "$AVAIL_BEFORE" ] || AVAIL_BEFORE=0
show_disk_usage "清理前"

# 顺序固定：先包管理器（会产生新的日志），再文件级清理，空目录放最后
for t in pkgcache logs journal temp crash backups kernels usrsrc docker snap flatpak emptydirs; do
    task_on "$t" || continue
    echo
    case "$t" in
        pkgcache)  clean_pkgcache  ;;
        logs)      clean_logs      ;;
        journal)   clean_journal   ;;
        temp)      clean_temp      ;;
        crash)     clean_crash     ;;
        backups)   clean_backups   ;;
        emptydirs) clean_emptydirs ;;
        docker)    clean_docker    ;;
        snap)      clean_snap      ;;
        flatpak)   clean_flatpak   ;;
        kernels)   clean_kernels   ;;
        usrsrc)    clean_usrsrc    ;;
    esac
done

echo
AVAIL_AFTER=$(avail_kb); [ -n "$AVAIL_AFTER" ] || AVAIL_AFTER=0
show_disk_usage "清理后"

if [ "$DRY_RUN" -eq 0 ]; then
    DELTA=$(( AVAIL_AFTER - AVAIL_BEFORE ))
    if [ "$DELTA" -gt 0 ]; then
        log SUCCESS "根分区可用空间增加 $(human_kb "$DELTA")（本脚本统计删除量约 $(human_kb "$TOTAL_FREED_KB")）"
    else
        log INFO "根分区可用空间无明显变化（本脚本统计删除量约 $(human_kb "$TOTAL_FREED_KB")）"
    fi
fi

[ "$DO_CRON" -eq 1 ] && { echo; setup_cron; }

echo
log SUCCESS "清理流程结束。详细记录: $LOG_FILE"
exit 0
