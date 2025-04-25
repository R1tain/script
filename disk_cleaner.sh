#!/bin/bash
# disk_cleaner_final_v3.sh - 自动清理Debian/Ubuntu系统磁盘空间 (修复结构和heredoc)
# 作者: R1tain (由 Gemini 优化)
# GitHub: https://github.com/R1tain/script
# 用法: bash -c "$(curl -L [您的脚本URL]/disk_cleaner_final_v3.sh)"
# 警告: curl | bash 方法存在安全风险，建议先下载脚本审查后再执行。
#       wget [您的脚本URL]/disk_cleaner_final_v3.sh -O disk_cleaner.sh
#       # (审查 disk_cleaner.sh)
#       sudo bash disk_cleaner.sh

# --- 配置 (针对小硬盘优化，可按需调整) ---
LOG_FILE="/var/log/disk_cleaner.log"          # 日志文件路径
LOG_MAX_SIZE_BYTES=1048576                    # 限制日志文件最大 1MB (1024*1024)
JOURNAL_VACUUM_SIZE="20M"                     # journald 日志保留大小 (建议保留一些以便排错)
TEMP_FILE_AGE_DAYS=7                          # 清理超过7天的临时文件 (/tmp, /var/tmp)
BACKUP_FILE_AGE_DAYS=30                       # 清理超过30天的备份文件 (*.bak, *~) in /etc
KERNELS_TO_KEEP=0                             # 仅保留当前正在运行的内核 (0表示最激进)
LOG_TRUNCATE_SIZE="2M"                        # 将大于2MB的日志文件截断至2MB
# --- 配置结束 ---

# --- 全局设置 ---
# set -e # 移除全局 set -e，进行更细致的错误处理
export DEBIAN_FRONTEND=noninteractive         # 避免APT询问问题
SCRIPT_PATH="/usr/local/bin/disk_cleaner.sh"  # 脚本保存路径

# --- 颜色定义 ---
COLOR_RESET='\033[0m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_RED='\033[0;31m'
COLOR_BLUE='\033[0;34m'
COLOR_CYAN='\033[0;36m'

# --- 工具函数 ---

# 记录日志并输出到控制台 (带颜色)
log_message() {
    local message="$1"
    local log_level="${2:-INFO}" # 默认为 INFO
    local color="$COLOR_RESET"
    local console_prefix=""

    case "$log_level" in
        INFO)    color="$COLOR_BLUE";   console_prefix="[信息] ";;
        WARN)    color="$COLOR_YELLOW"; console_prefix="[警告] ";;
        ERROR)   color="$COLOR_RED";    console_prefix="[错误] ";;
        SUCCESS) color="$COLOR_GREEN";  console_prefix="[成功] ";;
        ACTION)  color="$COLOR_CYAN";   console_prefix="[操作] ";;
        DETAIL)  color="$COLOR_RESET";  console_prefix="       ";; # 用于输出细节, 控制台默认色
    esac

    # 输出到控制台 (带颜色)
    echo -e "${color}${console_prefix}${message}${COLOR_RESET}"
    # 写入日志文件 (不带颜色)
    mkdir -p "$(dirname "$LOG_FILE")" # 确保日志目录存在
    echo "$(date "+%Y-%m-%d %H:%M:%S") [${log_level}] ${message}" >> "$LOG_FILE"
}

# 检查是否为root权限
check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        log_message "错误：请以root权限运行此脚本。" "ERROR"
        echo -e "${COLOR_RED}用法: 以root用户运行或使用 sudo bash $0${COLOR_RESET}" >&2
        exit 1
    fi
}

# 限制日志文件大小
manage_log_size() {
    if [[ -f "$LOG_FILE" ]] && [[ $(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) -gt "$LOG_MAX_SIZE_BYTES" ]]; then
        local human_readable_size=$(numfmt --to=iec-i --suffix=B $LOG_MAX_SIZE_BYTES)
        log_message "日志文件超过 ${human_readable_size}，正在截断 (保留最后1000行)..." "WARN"
        tail -n 1000 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
        echo "$(date "+%Y-%m-%d %H:%M:%S") [WARN] === 日志文件因超出大小而被截断 ===" >> "$LOG_FILE"
    fi
}

# 显示磁盘使用情况
show_disk_usage() {
    local stage="$1" # "清理前" 或 "清理后"
    log_message "当前磁盘使用情况 ($stage):" "INFO"
    echo "$(date "+%Y-%m-%d %H:%M:%S") [INFO] Disk usage ($stage):" >> "$LOG_FILE"
    df -h / >> "$LOG_FILE"
    echo -e "${COLOR_GREEN}" # 开始绿色块
    df -h /
    echo -e "${COLOR_RESET}" # 结束绿色块
}

# --- 清理函数 ---

clean_apt() {
    log_message "清理APT缓存..." "ACTION"
    apt-get clean -y >> "$LOG_FILE" 2>&1
    if [[ $? -ne 0 ]]; then
         log_message "apt-get clean 执行时报告错误 (可能无影响)" "WARN"
    fi

    log_message "移除不再需要的软件包 (autoremove)..." "ACTION"
    apt-get autoremove -y >> "$LOG_FILE" 2>&1
    if [[ $? -ne 0 ]]; then
         log_message "apt-get autoremove 执行时报告错误" "WARN"
    else
         log_message "Autoremove 完成 (详情请查看 /var/log/apt/history.log)" "DETAIL"
    fi
    log_message "APT清理完成" "SUCCESS"
}

clean_logs() {
    log_message "清理旧日志文件..." "ACTION"
    local deleted_files=0
    local truncated_files=0

    log_message "查找并删除常见的旧日志文件..." "DETAIL"
    find /var/log -type f \( -name "*.gz" -o -name "*.old" -o -name "*.[0-9]" -o -name "*.[0-9].gz" \) -print0 2>/dev/null | while IFS= read -r -d $'\0' file; do
        echo "$(date "+%Y-%m-%d %H:%M:%S") [DETAIL] 删除日志: $file" >> "$LOG_FILE"
        rm -f "$file"
        ((deleted_files++))
    done
    log_message "删除了 $deleted_files 个旧日志文件。" "DETAIL"

    log_message "查找并截断大于 $LOG_TRUNCATE_SIZE 的日志文件..." "DETAIL"
    find /var/log -type f -size "+$LOG_TRUNCATE_SIZE" -print0 2>/dev/null | while IFS= read -r -d $'\0' file; do
         echo "$(date "+%Y-%m-%d %H:%M:%S") [DETAIL] 截断日志: $file 至 $LOG_TRUNCATE_SIZE" >> "$LOG_FILE"
         truncate --size "$LOG_TRUNCATE_SIZE" "$file" || log_message "无法截断文件 (可能权限问题): $file" "WARN"
         ((truncated_files++))
    done
    log_message "截断了 $truncated_files 个大型日志文件。" "DETAIL"

    if command -v journalctl &> /dev/null; then
        log_message "清理 journald 日志，保留 ${JOURNAL_VACUUM_SIZE}..." "ACTION"
        journalctl --vacuum-size="$JOURNAL_VACUUM_SIZE" >> "$LOG_FILE" 2>&1
        if [[ $? -ne 0 ]]; then
            log_message "Journalctl vacuum 失败 (系统可能未使用 systemd-journald 或其他错误)" "WARN"
        fi
    else
        log_message "journalctl 命令不存在，跳过 journald 清理" "INFO"
    fi
    log_message "日志清理完成" "SUCCESS"
}

clean_temp() {
    log_message "清理临时文件 (/tmp, /var/tmp) (超过 $TEMP_FILE_AGE_DAYS 天)..." "ACTION"
    local deleted_files=0
    find /tmp /var/tmp -type f -atime "+$TEMP_FILE_AGE_DAYS" -print0 2>/dev/null | while IFS= read -r -d $'\0' file; do
        echo "$(date "+%Y-%m-%d %H:%M:%S") [DETAIL] 删除临时文件: $file" >> "$LOG_FILE"
        rm -f "$file"
        ((deleted_files++))
    done
    log_message "删除了 $deleted_files 个临时文件。" "DETAIL"
    log_message "临时文件清理完成" "SUCCESS"
}

clean_crash() {
    log_message "清理Core转储文件 (/var/crash)..." "ACTION"
    if [[ -d "/var/crash" ]]; then
        local deleted_files=0
        find /var/crash -type f -print0 2>/dev/null | while IFS= read -r -d $'\0' file; do
            echo "$(date "+%Y-%m-%d %H:%M:%S") [DETAIL] 删除转储文件: $file" >> "$LOG_FILE"
            rm -f "$file"
            ((deleted_files++))
        done
        log_message "删除了 $deleted_files 个 Core 转储文件。" "DETAIL"
        log_message "Core转储文件清理完成" "SUCCESS"
    else
        log_message "无Core转储文件目录 (/var/crash)，跳过" "INFO"
    fi
}

clean_backups() {
    log_message "清理 /etc 下旧的备份文件 (*.bak, *~) (超过 $BACKUP_FILE_AGE_DAYS 天)..." "ACTION"
    local deleted_files=0
    find /etc -type f \( -name "*.bak" -o -name "*~" \) -atime "+$BACKUP_FILE_AGE_DAYS" -print0 2>/dev/null | while IFS= read -r -d $'\0' file; do
        echo "$(date "+%Y-%m-%d %H:%M:%S") [DETAIL] 删除备份文件: $file" >> "$LOG_FILE"
        rm -f "$file"
        ((deleted_files++))
    done
    log_message "删除了 $deleted_files 个旧备份文件。" "DETAIL"
    log_message "备份文件清理完成" "SUCCESS"
}

clean_kernels() {
    log_message "清理旧内核 (仅保留当前运行版本)..." "ACTION"
    CURRENT_KERNEL=$(uname -r)
    PACKAGES_TO_PURGE=() # 初始化用于存储待清理包名的数组

    # --- 使用 mapfile 读取旧内核列表 ---
    local old_kernels_list=()
    mapfile -t old_kernels_list < <(dpkg-query -f '${binary:Package}\n' -W 'linux-image-[0-9]*' 2>/dev/null | grep -v "$CURRENT_KERNEL" || true)
    if [[ ${#old_kernels_list[@]} -gt 0 ]]; then
        log_message "发现以下旧内核将被尝试清理:" "DETAIL"
        for pkg in "${old_kernels_list[@]}"; do
            log_message "$pkg" "DETAIL"
            PACKAGES_TO_PURGE+=("$pkg")
        done
    fi

    # --- 查找关联的旧内核头文件 ---
    local old_headers_list=()
    if [[ ${#old_kernels_list[@]} -gt 0 ]]; then
        local kernel_versions_regex=$(printf '%s\n' "${old_kernels_list[@]}" | sed -n 's/^linux-image-\(.*\)/\1/p' | paste -sd'|')
        if [[ -n "$kernel_versions_regex" ]]; then
             mapfile -t old_headers_list < <(dpkg-query -f '${binary:Package}\n' -W 'linux-headers-*' 2>/dev/null | grep -E "($kernel_versions_regex)" || true)
             if [[ ${#old_headers_list[@]} -gt 0 ]]; then
                log_message "发现以下旧内核头文件将被尝试清理:" "DETAIL"
                for pkg in "${old_headers_list[@]}"; do
                    log_message "$pkg" "DETAIL"
                    PACKAGES_TO_PURGE+=("$pkg")
                done
            fi
        fi
    fi

    # --- 执行清理 ---
    if [[ ${#PACKAGES_TO_PURGE[@]} -gt 0 ]]; then
        log_message "准备执行清理命令: apt-get purge -y ${PACKAGES_TO_PURGE[*]}" "ACTION"
        apt-get purge -y "${PACKAGES_TO_PURGE[@]}" >> "$LOG_FILE" 2>&1
        local purge_status=$?
        if [[ $purge_status -eq 0 ]]; then
            log_message "旧内核及头文件清理成功。" "SUCCESS"
        else
            log_message "旧内核及头文件清理过程中出错 (状态码: $purge_status)。请检查日志 $LOG_FILE 获取 apt 输出详情。" "WARN"
        fi

        log_message "再次运行 autoremove 清理可能残留的依赖..." "ACTION"
        apt-get autoremove -y >> "$LOG_FILE" 2>&1 || log_message "后续 autoremove 执行时报告错误" "WARN"
    else
        log_message "未发现需要清理的旧内核或头文件。" "INFO"
    fi
     log_message "内核清理过程结束。" "SUCCESS"
}

clean_usr_src() {
    log_message "清理 /usr/src 下旧的内核相关源文件 (保留当前运行版本对应目录)..." "ACTION"
    local current_headers_dir="linux-headers-$(uname -r)"
    local deleted_dirs=0

    if [[ -d "/usr/src" ]]; then
        find /usr/src -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | while IFS= read -r -d $'\0' dir; do
            local dirname=$(basename "$dir")
            if [[ "$dirname" != "$current_headers_dir" && "$dirname" != "linux-headers-generic"* && "$dirname" != "linux-kbuild"* ]]; then
                 log_message "准备删除旧源目录: $dir" "DETAIL"
                 echo "$(date "+%Y-%m-%d %H:%M:%S") [DETAIL] 删除 /usr/src 目录: $dir" >> "$LOG_FILE"
                 rm -rf "$dir"
                 if [[ $? -eq 0 ]]; then
                     ((deleted_dirs++))
                 else
                      log_message "删除 $dir 失败 (可能权限问题或目录非空？)" "WARN"
                 fi
            else
                 log_message "保留 /usr/src/ 目录: $dirname" "DETAIL"
            fi
        done
        log_message "从 /usr/src/ 删除了 $deleted_dirs 个旧目录。" "DETAIL"
    else
        log_message "/usr/src 目录不存在，跳过。" "INFO"
    fi
    log_message "/usr/src 清理完成。" "SUCCESS"
}


clean_docker() {
    if command -v docker &> /dev/null; then
        log_message "检测到 Docker，尝试清理未使用的数据..." "ACTION"
        log_message "警告: 这将移除所有停止的容器、未使用的网络、悬空镜像和构建缓存。" "WARN"
        log_message "注意: 默认不清理未使用的 Volumes，以免丢失数据。如需清理请手动运行 'docker volume prune'。" "WARN"
        log_message "运行: docker system prune -a -f" "DETAIL"
        docker system prune -a -f >> "$LOG_FILE" 2>&1
        local prune_status=$?
        if [[ $prune_status -eq 0 ]]; then
             log_message "Docker system prune 完成。" "SUCCESS"
        elif [[ $prune_status -eq 1 ]]; then
             log_message "Docker system prune 未发现可清理的数据或执行时出现小问题。" "INFO"
        else
             log_message "Docker system prune 执行时出错 (状态码: $prune_status)。请检查 Docker 服务状态和日志。" "WARN"
        fi
    else
        log_message "未检测到 Docker，跳过 Docker 清理。" "INFO"
    fi
}

clean_snaps() {
    if command -v snap &> /dev/null; then
        log_message "检测到 Snap，尝试清理旧版本..." "ACTION"

        log_message "设置 Snap 系统保留最近 2 个版本 (refresh.retain=2)..." "DETAIL"
        snap set system refresh.retain=2 >> "$LOG_FILE" 2>&1 || log_message "设置 snap refresh.retain=2 失败 (可能是权限不足或snapd问题)。" "WARN"

        log_message "查找并移除当前已禁用的 Snap 版本..." "DETAIL"
        local removed_snaps=0
        snap list --all | awk '/disabled/{print $1, $3}' | while read -r snapname revision; do
            log_message "准备移除 $snapname 版本 $revision" "DETAIL"
            echo "$(date "+%Y-%m-%d %H:%M:%S") [DETAIL] 删除 snap: $snapname 版本 $revision" >> "$LOG_FILE"
            snap remove "$snapname" --revision="$revision" >> "$LOG_FILE" 2>&1
            if [[ $? -eq 0 ]]; then
                 ((removed_snaps++))
            else
                 log_message "移除 $snapname 版本 $revision 失败。" "WARN"
            fi
        done
        log_message "移除了 $removed_snaps 个旧的 Snap 版本。" "DETAIL"
        log_message "Snap 清理完成。" "SUCCESS"
    else
         log_message "未检测到 Snap，跳过 Snap 清理。" "INFO"
    fi
}

clean_flatpak() {
     if command -v flatpak &> /dev/null; then
        log_message "检测到 Flatpak，尝试移除未使用的运行时..." "ACTION"
        flatpak uninstall --unused -y >> "$LOG_FILE" 2>&1
        if [[ $? -eq 0 ]]; then
            log_message "Flatpak 未使用运行时清理完成。" "SUCCESS"
        else
             log_message "Flatpak 清理执行时出错 (可能没有未使用的运行时或权限问题)。" "WARN"
        fi
    else
        log_message "未检测到 Flatpak，跳过 Flatpak 清理。" "INFO"
    fi
}

clean_empty_dirs() {
    log_message "清理特定路径下的空目录 (/var/log, /var/cache, /tmp, /var/tmp)..." "ACTION"
    local deleted_dirs=0
    local target_dirs=("/var/log" "/var/cache" "/tmp" "/var/tmp")

    for target_dir in "${target_dirs[@]}"; do
        if [[ -d "$target_dir" ]]; then
            find "$target_dir" -mindepth 1 -depth -type d -empty -print0 2>/dev/null | while IFS= read -r -d $'\0' dir; do
                echo "$(date "+%Y-%m-%d %H:%M:%S") [DETAIL] 删除空目录: $dir" >> "$LOG_FILE"
                rmdir "$dir" || log_message "无法删除空目录 (可能已被占用或权限问题): $dir" "WARN"
                if [[ $? -eq 0 ]]; then
                    ((deleted_dirs++))
                fi
            done
        fi
    done
    log_message "尝试删除了 $deleted_dirs 个空目录。" "DETAIL"
    log_message "空目录清理完成。" "SUCCESS"
}


# --- 定时任务 ---

setup_cron() {
    local cron_file="/etc/cron.d/disk_cleaner"
    if [[ ! -f "$cron_file" ]]; then
        echo -e "\n${COLOR_YELLOW}是否要设置每天凌晨3点自动运行清理? (y/n) (30秒后默认 n)${COLOR_RESET}"
        read -r -t 30 setup_cron_answer || setup_cron_answer="n"

        if [[ "$setup_cron_answer" =~ ^[Yy]$ ]]; then
            CRON_JOB="0 3 * * * root $SCRIPT_PATH >> $LOG_FILE 2>&1"
            echo "$CRON_JOB" > "$cron_file"
            if [[ $? -eq 0 ]]; then
                chmod 644 "$cron_file"
                log_message "定时任务已设置: $cron_file" "SUCCESS"
                echo -e "${COLOR_GREEN}✅ 定时任务已设置。系统将在每天凌晨3点自动清理磁盘。"
                echo -e "   配置文件: ${COLOR_CYAN}$cron_file${COLOR_RESET}"
            else
                 log_message "无法创建 cron 文件 $cron_file (权限问题?)" "ERROR"
                 echo -e "${COLOR_RED}❌ 创建 cron 文件失败，请检查权限。"
            fi
        else
            log_message "用户选择不设置定时任务" "INFO"
            echo -e "${COLOR_YELLOW}ℹ️ 未设置定时任务。您可以稍后手动添加:${COLOR_RESET}"
            echo -e "   echo \"0 3 * * * root $SCRIPT_PATH >> $LOG_FILE 2>&1\" | sudo tee $cron_file > /dev/null && sudo chmod 644 $cron_file"
        fi
    else
        log_message "定时任务文件 $cron_file 已存在，跳过设置。" "INFO"
        echo -e "${COLOR_YELLOW}ℹ️ 定时任务已存在: ${COLOR_CYAN}$cron_file${COLOR_RESET}"
    fi
}

# --- 主程序 ---

main() {
    # 检查权限和管理日志是前置操作
    check_root
    manage_log_size

    log_message "=== 开始系统清理 ===" "INFO"
    show_disk_usage "清理前"

    # --- 执行各项清理任务 (按顺序) ---
    # 基础系统清理
    clean_apt
    clean_logs
    clean_temp
    clean_crash
    clean_backups
    # 内核相关清理
    clean_kernels
    clean_usr_src
    # 应用/容器相关清理 (如果存在)
    clean_docker
    clean_snaps
    clean_flatpak
    # 其他文件系统清理
    clean_empty_dirs

    log_message "=== 系统清理完成 ===" "INFO"
    show_disk_usage "清理后" # 显示最终结果

    echo "" >> "$LOG_FILE" # 日志中添加空行

    log_message "系统清理流程结束! 查看日志获取详细信息: $LOG_FILE" "SUCCESS"

    # 最后设置定时任务
    setup_cron
}


# --- 脚本入口与 curl | bash 处理 ---

# 检查脚本是否通过管道 (如 curl | bash) 执行
if [[ "$0" = "bash" ]] || [[ "$(basename "$0")" = "bash" ]] || [[ "$0" = "-bash" ]]; then
    # 如果是通过管道执行，则先将脚本自身完整地写入本地文件
    log_message "首次运行或通过管道执行，正在保存脚本到本地: $SCRIPT_PATH" "INFO"

    # 使用 cat 和 'heredoc' 将脚本内容写入文件
    # **重要**: heredoc 内容是下面从 #!/bin/bash 开始，直到 EOFSCRIPT 前一行的所有代码
    cat > "$SCRIPT_PATH" << 'EOFSCRIPT'
#!/bin/bash
# disk_cleaner_final_v3.sh - 自动清理Debian/Ubuntu系统磁盘空间 (修复结构和heredoc)
# 作者: R1tain (由 Gemini 优化)
# GitHub: https://github.com/R1tain/script
# 用法: bash -c "$(curl -L [您的脚本URL]/disk_cleaner_final_v3.sh)"
# 警告: curl | bash 方法存在安全风险，建议先下载脚本审查后再执行。
#       wget [您的脚本URL]/disk_cleaner_final_v3.sh -O disk_cleaner.sh
#       # (审查 disk_cleaner.sh)
#       sudo bash disk_cleaner.sh

# --- 配置 (针对小硬盘优化，可按需调整) ---
LOG_FILE="/var/log/disk_cleaner.log"          # 日志文件路径
LOG_MAX_SIZE_BYTES=1048576                    # 限制日志文件最大 1MB (1024*1024)
JOURNAL_VACUUM_SIZE="20M"                     # journald 日志保留大小 (建议保留一些以便排错)
TEMP_FILE_AGE_DAYS=7                          # 清理超过7天的临时文件 (/tmp, /var/tmp)
BACKUP_FILE_AGE_DAYS=30                       # 清理超过30天的备份文件 (*.bak, *~) in /etc
KERNELS_TO_KEEP=0                             # 仅保留当前正在运行的内核 (0表示最激进)
LOG_TRUNCATE_SIZE="2M"                        # 将大于2MB的日志文件截断至2MB
# --- 配置结束 ---

# --- 全局设置 ---
# set -e # 移除全局 set -e，进行更细致的错误处理
export DEBIAN_FRONTEND=noninteractive         # 避免APT询问问题
SCRIPT_PATH="/usr/local/bin/disk_cleaner.sh"  # 脚本保存路径

# --- 颜色定义 ---
COLOR_RESET='\033[0m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_RED='\033[0;31m'
COLOR_BLUE='\033[0;34m'
COLOR_CYAN='\033[0;36m'

# --- 工具函数 ---

# 记录日志并输出到控制台 (带颜色)
log_message() {
    local message="$1"
    local log_level="${2:-INFO}" # 默认为 INFO
    local color="$COLOR_RESET"
    local console_prefix=""

    case "$log_level" in
        INFO)    color="$COLOR_BLUE";   console_prefix="[信息] ";;
        WARN)    color="$COLOR_YELLOW"; console_prefix="[警告] ";;
        ERROR)   color="$COLOR_RED";    console_prefix="[错误] ";;
        SUCCESS) color="$COLOR_GREEN";  console_prefix="[成功] ";;
        ACTION)  color="$COLOR_CYAN";   console_prefix="[操作] ";;
        DETAIL)  color="$COLOR_RESET";  console_prefix="       ";; # 用于输出细节, 控制台默认色
    esac

    # 输出到控制台 (带颜色)
    echo -e "${color}${console_prefix}${message}${COLOR_RESET}"
    # 写入日志文件 (不带颜色)
    mkdir -p "$(dirname "$LOG_FILE")" # 确保日志目录存在
    echo "$(date "+%Y-%m-%d %H:%M:%S") [${log_level}] ${message}" >> "$LOG_FILE"
}

# 检查是否为root权限
check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        log_message "错误：请以root权限运行此脚本。" "ERROR"
        echo -e "${COLOR_RED}用法: 以root用户运行或使用 sudo bash $0${COLOR_RESET}" >&2
        exit 1
    fi
}

# 限制日志文件大小
manage_log_size() {
    if [[ -f "$LOG_FILE" ]] && [[ $(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) -gt "$LOG_MAX_SIZE_BYTES" ]]; then
        local human_readable_size=$(numfmt --to=iec-i --suffix=B $LOG_MAX_SIZE_BYTES)
        log_message "日志文件超过 ${human_readable_size}，正在截断 (保留最后1000行)..." "WARN"
        tail -n 1000 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
        echo "$(date "+%Y-%m-%d %H:%M:%S") [WARN] === 日志文件因超出大小而被截断 ===" >> "$LOG_FILE"
    fi
}

# 显示磁盘使用情况
show_disk_usage() {
    local stage="$1" # "清理前" 或 "清理后"
    log_message "当前磁盘使用情况 ($stage):" "INFO"
    echo "$(date "+%Y-%m-%d %H:%M:%S") [INFO] Disk usage ($stage):" >> "$LOG_FILE"
    df -h / >> "$LOG_FILE"
    echo -e "${COLOR_GREEN}" # 开始绿色块
    df -h /
    echo -e "${COLOR_RESET}" # 结束绿色块
}

# --- 清理函数 ---

clean_apt() {
    log_message "清理APT缓存..." "ACTION"
    apt-get clean -y >> "$LOG_FILE" 2>&1
    if [[ $? -ne 0 ]]; then
         log_message "apt-get clean 执行时报告错误 (可能无影响)" "WARN"
    fi

    log_message "移除不再需要的软件包 (autoremove)..." "ACTION"
    apt-get autoremove -y >> "$LOG_FILE" 2>&1
    if [[ $? -ne 0 ]]; then
         log_message "apt-get autoremove 执行时报告错误" "WARN"
    else
         log_message "Autoremove 完成 (详情请查看 /var/log/apt/history.log)" "DETAIL"
    fi
    log_message "APT清理完成" "SUCCESS"
}

clean_logs() {
    log_message "清理旧日志文件..." "ACTION"
    local deleted_files=0
    local truncated_files=0

    log_message "查找并删除常见的旧日志文件..." "DETAIL"
    find /var/log -type f \( -name "*.gz" -o -name "*.old" -o -name "*.[0-9]" -o -name "*.[0-9].gz" \) -print0 2>/dev/null | while IFS= read -r -d $'\0' file; do
        echo "$(date "+%Y-%m-%d %H:%M:%S") [DETAIL] 删除日志: $file" >> "$LOG_FILE"
        rm -f "$file"
        ((deleted_files++))
    done
    log_message "删除了 $deleted_files 个旧日志文件。" "DETAIL"

    log_message "查找并截断大于 $LOG_TRUNCATE_SIZE 的日志文件..." "DETAIL"
    find /var/log -type f -size "+$LOG_TRUNCATE_SIZE" -print0 2>/dev/null | while IFS= read -r -d $'\0' file; do
         echo "$(date "+%Y-%m-%d %H:%M:%S") [DETAIL] 截断日志: $file 至 $LOG_TRUNCATE_SIZE" >> "$LOG_FILE"
         truncate --size "$LOG_TRUNCATE_SIZE" "$file" || log_message "无法截断文件 (可能权限问题): $file" "WARN"
         ((truncated_files++))
    done
    log_message "截断了 $truncated_files 个大型日志文件。" "DETAIL"

    if command -v journalctl &> /dev/null; then
        log_message "清理 journald 日志，保留 ${JOURNAL_VACUUM_SIZE}..." "ACTION"
        journalctl --vacuum-size="$JOURNAL_VACUUM_SIZE" >> "$LOG_FILE" 2>&1
        if [[ $? -ne 0 ]]; then
            log_message "Journalctl vacuum 失败 (系统可能未使用 systemd-journald 或其他错误)" "WARN"
        fi
    else
        log_message "journalctl 命令不存在，跳过 journald 清理" "INFO"
    fi
    log_message "日志清理完成" "SUCCESS"
}

clean_temp() {
    log_message "清理临时文件 (/tmp, /var/tmp) (超过 $TEMP_FILE_AGE_DAYS 天)..." "ACTION"
    local deleted_files=0
    find /tmp /var/tmp -type f -atime "+$TEMP_FILE_AGE_DAYS" -print0 2>/dev/null | while IFS= read -r -d $'\0' file; do
        echo "$(date "+%Y-%m-%d %H:%M:%S") [DETAIL] 删除临时文件: $file" >> "$LOG_FILE"
        rm -f "$file"
        ((deleted_files++))
    done
    log_message "删除了 $deleted_files 个临时文件。" "DETAIL"
    log_message "临时文件清理完成" "SUCCESS"
}

clean_crash() {
    log_message "清理Core转储文件 (/var/crash)..." "ACTION"
    if [[ -d "/var/crash" ]]; then
        local deleted_files=0
        find /var/crash -type f -print0 2>/dev/null | while IFS= read -r -d $'\0' file; do
            echo "$(date "+%Y-%m-%d %H:%M:%S") [DETAIL] 删除转储文件: $file" >> "$LOG_FILE"
            rm -f "$file"
            ((deleted_files++))
        done
        log_message "删除了 $deleted_files 个 Core 转储文件。" "DETAIL"
        log_message "Core转储文件清理完成" "SUCCESS"
    else
        log_message "无Core转储文件目录 (/var/crash)，跳过" "INFO"
    fi
}

clean_backups() {
    log_message "清理 /etc 下旧的备份文件 (*.bak, *~) (超过 $BACKUP_FILE_AGE_DAYS 天)..." "ACTION"
    local deleted_files=0
    find /etc -type f \( -name "*.bak" -o -name "*~" \) -atime "+$BACKUP_FILE_AGE_DAYS" -print0 2>/dev/null | while IFS= read -r -d $'\0' file; do
        echo "$(date "+%Y-%m-%d %H:%M:%S") [DETAIL] 删除备份文件: $file" >> "$LOG_FILE"
        rm -f "$file"
        ((deleted_files++))
    done
    log_message "删除了 $deleted_files 个旧备份文件。" "DETAIL"
    log_message "备份文件清理完成" "SUCCESS"
}

clean_kernels() {
    log_message "清理旧内核 (仅保留当前运行版本)..." "ACTION"
    CURRENT_KERNEL=$(uname -r)
    PACKAGES_TO_PURGE=() # 初始化用于存储待清理包名的数组

    # --- 使用 mapfile 读取旧内核列表 ---
    local old_kernels_list=()
    mapfile -t old_kernels_list < <(dpkg-query -f '${binary:Package}\n' -W 'linux-image-[0-9]*' 2>/dev/null | grep -v "$CURRENT_KERNEL" || true)
    if [[ ${#old_kernels_list[@]} -gt 0 ]]; then
        log_message "发现以下旧内核将被尝试清理:" "DETAIL"
        for pkg in "${old_kernels_list[@]}"; do
            log_message "$pkg" "DETAIL"
            PACKAGES_TO_PURGE+=("$pkg")
        done
    fi

    # --- 查找关联的旧内核头文件 ---
    local old_headers_list=()
    if [[ ${#old_kernels_list[@]} -gt 0 ]]; then
        local kernel_versions_regex=$(printf '%s\n' "${old_kernels_list[@]}" | sed -n 's/^linux-image-\(.*\)/\1/p' | paste -sd'|')
        if [[ -n "$kernel_versions_regex" ]]; then
             mapfile -t old_headers_list < <(dpkg-query -f '${binary:Package}\n' -W 'linux-headers-*' 2>/dev/null | grep -E "($kernel_versions_regex)" || true)
             if [[ ${#old_headers_list[@]} -gt 0 ]]; then
                log_message "发现以下旧内核头文件将被尝试清理:" "DETAIL"
                for pkg in "${old_headers_list[@]}"; do
                    log_message "$pkg" "DETAIL"
                    PACKAGES_TO_PURGE+=("$pkg")
                done
            fi
        fi
    fi

    # --- 执行清理 ---
    if [[ ${#PACKAGES_TO_PURGE[@]} -gt 0 ]]; then
        log_message "准备执行清理命令: apt-get purge -y ${PACKAGES_TO_PURGE[*]}" "ACTION"
        apt-get purge -y "${PACKAGES_TO_PURGE[@]}" >> "$LOG_FILE" 2>&1
        local purge_status=$?
        if [[ $purge_status -eq 0 ]]; then
            log_message "旧内核及头文件清理成功。" "SUCCESS"
        else
            log_message "旧内核及头文件清理过程中出错 (状态码: $purge_status)。请检查日志 $LOG_FILE 获取 apt 输出详情。" "WARN"
        fi

        log_message "再次运行 autoremove 清理可能残留的依赖..." "ACTION"
        apt-get autoremove -y >> "$LOG_FILE" 2>&1 || log_message "后续 autoremove 执行时报告错误" "WARN"
    else
        log_message "未发现需要清理的旧内核或头文件。" "INFO"
    fi
     log_message "内核清理过程结束。" "SUCCESS"
}

clean_usr_src() {
    log_message "清理 /usr/src 下旧的内核相关源文件 (保留当前运行版本对应目录)..." "ACTION"
    local current_headers_dir="linux-headers-$(uname -r)"
    local deleted_dirs=0

    if [[ -d "/usr/src" ]]; then
        find /usr/src -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | while IFS= read -r -d $'\0' dir; do
            local dirname=$(basename "$dir")
            if [[ "$dirname" != "$current_headers_dir" && "$dirname" != "linux-headers-generic"* && "$dirname" != "linux-kbuild"* ]]; then
                 log_message "准备删除旧源目录: $dir" "DETAIL"
                 echo "$(date "+%Y-%m-%d %H:%M:%S") [DETAIL] 删除 /usr/src 目录: $dir" >> "$LOG_FILE"
                 rm -rf "$dir"
                 if [[ $? -eq 0 ]]; then
                     ((deleted_dirs++))
                 else
                      log_message "删除 $dir 失败 (可能权限问题或目录非空？)" "WARN"
                 fi
            else
                 log_message "保留 /usr/src/ 目录: $dirname" "DETAIL"
            fi
        done
        log_message "从 /usr/src/ 删除了 $deleted_dirs 个旧目录。" "DETAIL"
    else
        log_message "/usr/src 目录不存在，跳过。" "INFO"
    fi
    log_message "/usr/src 清理完成。" "SUCCESS"
}


clean_docker() {
    if command -v docker &> /dev/null; then
        log_message "检测到 Docker，尝试清理未使用的数据..." "ACTION"
        log_message "警告: 这将移除所有停止的容器、未使用的网络、悬空镜像和构建缓存。" "WARN"
        log_message "注意: 默认不清理未使用的 Volumes，以免丢失数据。如需清理请手动运行 'docker volume prune'。" "WARN"
        log_message "运行: docker system prune -a -f" "DETAIL"
        docker system prune -a -f >> "$LOG_FILE" 2>&1
        local prune_status=$?
        if [[ $prune_status -eq 0 ]]; then
             log_message "Docker system prune 完成。" "SUCCESS"
        elif [[ $prune_status -eq 1 ]]; then
             log_message "Docker system prune 未发现可清理的数据或执行时出现小问题。" "INFO"
        else
             log_message "Docker system prune 执行时出错 (状态码: $prune_status)。请检查 Docker 服务状态和日志。" "WARN"
        fi
    else
        log_message "未检测到 Docker，跳过 Docker 清理。" "INFO"
    fi
}

clean_snaps() {
    if command -v snap &> /dev/null; then
        log_message "检测到 Snap，尝试清理旧版本..." "ACTION"

        log_message "设置 Snap 系统保留最近 2 个版本 (refresh.retain=2)..." "DETAIL"
        snap set system refresh.retain=2 >> "$LOG_FILE" 2>&1 || log_message "设置 snap refresh.retain=2 失败 (可能是权限不足或snapd问题)。" "WARN"

        log_message "查找并移除当前已禁用的 Snap 版本..." "DETAIL"
        local removed_snaps=0
        snap list --all | awk '/disabled/{print $1, $3}' | while read -r snapname revision; do
            log_message "准备移除 $snapname 版本 $revision" "DETAIL"
            echo "$(date "+%Y-%m-%d %H:%M:%S") [DETAIL] 删除 snap: $snapname 版本 $revision" >> "$LOG_FILE"
            snap remove "$snapname" --revision="$revision" >> "$LOG_FILE" 2>&1
            if [[ $? -eq 0 ]]; then
                 ((removed_snaps++))
            else
                 log_message "移除 $snapname 版本 $revision 失败。" "WARN"
            fi
        done
        log_message "移除了 $removed_snaps 个旧的 Snap 版本。" "DETAIL"
        log_message "Snap 清理完成。" "SUCCESS"
    else
         log_message "未检测到 Snap，跳过 Snap 清理。" "INFO"
    fi
}

clean_flatpak() {
     if command -v flatpak &> /dev/null; then
        log_message "检测到 Flatpak，尝试移除未使用的运行时..." "ACTION"
        flatpak uninstall --unused -y >> "$LOG_FILE" 2>&1
        if [[ $? -eq 0 ]]; then
            log_message "Flatpak 未使用运行时清理完成。" "SUCCESS"
        else
             log_message "Flatpak 清理执行时出错 (可能没有未使用的运行时或权限问题)。" "WARN"
        fi
    else
        log_message "未检测到 Flatpak，跳过 Flatpak 清理。" "INFO"
    fi
}

clean_empty_dirs() {
    log_message "清理特定路径下的空目录 (/var/log, /var/cache, /tmp, /var/tmp)..." "ACTION"
    local deleted_dirs=0
    local target_dirs=("/var/log" "/var/cache" "/tmp" "/var/tmp")

    for target_dir in "${target_dirs[@]}"; do
        if [[ -d "$target_dir" ]]; then
            find "$target_dir" -mindepth 1 -depth -type d -empty -print0 2>/dev/null | while IFS= read -r -d $'\0' dir; do
                echo "$(date "+%Y-%m-%d %H:%M:%S") [DETAIL] 删除空目录: $dir" >> "$LOG_FILE"
                rmdir "$dir" || log_message "无法删除空目录 (可能已被占用或权限问题): $dir" "WARN"
                if [[ $? -eq 0 ]]; then
                    ((deleted_dirs++))
                fi
            done
        fi
    done
    log_message "尝试删除了 $deleted_dirs 个空目录。" "DETAIL"
    log_message "空目录清理完成。" "SUCCESS"
}


# --- 定时任务 ---

setup_cron() {
    local cron_file="/etc/cron.d/disk_cleaner"
    if [[ ! -f "$cron_file" ]]; then
        echo -e "\n${COLOR_YELLOW}是否要设置每天凌晨3点自动运行清理? (y/n) (30秒后默认 n)${COLOR_RESET}"
        read -r -t 30 setup_cron_answer || setup_cron_answer="n"

        if [[ "$setup_cron_answer" =~ ^[Yy]$ ]]; then
            CRON_JOB="0 3 * * * root $SCRIPT_PATH >> $LOG_FILE 2>&1"
            echo "$CRON_JOB" > "$cron_file"
            if [[ $? -eq 0 ]]; then
                chmod 644 "$cron_file"
                log_message "定时任务已设置: $cron_file" "SUCCESS"
                echo -e "${COLOR_GREEN}✅ 定时任务已设置。系统将在每天凌晨3点自动清理磁盘。"
                echo -e "   配置文件: ${COLOR_CYAN}$cron_file${COLOR_RESET}"
            else
                 log_message "无法创建 cron 文件 $cron_file (权限问题?)" "ERROR"
                 echo -e "${COLOR_RED}❌ 创建 cron 文件失败，请检查权限。"
            fi
        else
            log_message "用户选择不设置定时任务" "INFO"
            echo -e "${COLOR_YELLOW}ℹ️ 未设置定时任务。您可以稍后手动添加:${COLOR_RESET}"
            echo -e "   echo \"0 3 * * * root $SCRIPT_PATH >> $LOG_FILE 2>&1\" | sudo tee $cron_file > /dev/null && sudo chmod 644 $cron_file"
        fi
    else
        log_message "定时任务文件 $cron_file 已存在，跳过设置。" "INFO"
        echo -e "${COLOR_YELLOW}ℹ️ 定时任务已存在: ${COLOR_CYAN}$cron_file${COLOR_RESET}"
    fi
}

# --- 主程序 ---

main() {
    # 检查权限和管理日志是前置操作
    check_root
    manage_log_size

    log_message "=== 开始系统清理 ===" "INFO"
    show_disk_usage "清理前"

    # --- 执行各项清理任务 (按顺序) ---
    # 基础系统清理
    clean_apt
    clean_logs
    clean_temp
    clean_crash
    clean_backups
    # 内核相关清理
    clean_kernels
    clean_usr_src
    # 应用/容器相关清理 (如果存在)
    clean_docker
    clean_snaps
    clean_flatpak
    # 其他文件系统清理
    clean_empty_dirs

    log_message "=== 系统清理完成 ===" "INFO"
    show_disk_usage "清理后" # 显示最终结果

    echo "" >> "$LOG_FILE" # 日志中添加空行

    log_message "系统清理流程结束! 查看日志获取详细信息: $LOG_FILE" "SUCCESS"

    # 最后设置定时任务
    setup_cron
}

# --- 脚本入口 ---
# 这个 main 调用只在 heredoc 内部的脚本被执行时调用
main "$@" # 直接调用 main 函数
exit 0    # 脚本成功结束

EOFSCRIPT

    # --- curl | bash 处理 (续) ---
    # 赋予脚本执行权限
    chmod +x "$SCRIPT_PATH"
    log_message "脚本已保存到 $SCRIPT_PATH，将执行本地副本..." "INFO"
    # 使用 exec 执行新保存的脚本, 替换当前进程
    exec "$SCRIPT_PATH"
    # 如果 exec 失败 (例如权限问题)，则退出
    exit 1
fi

# --- 如果不是通过 curl | bash 运行 (即直接运行本地脚本)，则直接调用 main 函数 ---
# 这个调用只在直接运行 'bash disk_cleaner.sh' 时执行
main "$@" # 传递命令行参数给 main 函数 (虽然当前版本未使用参数)

exit 0 # 脚本成功结束
