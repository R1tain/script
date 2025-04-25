#!/bin/bash
# disk_cleaner_optimized.sh - 自动清理Debian系统磁盘空间 (针对小硬盘优化)
# 作者: R1tain (由 Gemini 优化)
# GitHub: https://github.com/R1tain/script
# 用法: bash -c "$(curl -L https://raw.githubusercontent.com/R1tain/script/main/disk_cleaner.sh)"
# 警告: curl | bash 方法存在安全风险，建议先下载脚本审查后再执行。
#       wget https://raw.githubusercontent.com/R1tain/script/main/disk_cleaner.sh
#       # (审查 disk_cleaner.sh)
#       sudo bash disk_cleaner.sh

# --- 配置 (针对 <1GB 硬盘进行调整) ---
LOG_FILE="/var/log/disk_cleaner.log"
LOG_MAX_SIZE_BYTES=524288 # 限制日志文件最大 512KB
JOURNAL_VACUUM_SIZE="10M"  # journald 日志保留大小 (更小可能导致调试困难)
TEMP_FILE_AGE_DAYS=3       # 清理超过3天的临时文件
BACKUP_FILE_AGE_DAYS=15    # 清理超过15天的备份文件 (*.bak, *~)
KERNELS_TO_KEEP=0          # 仅保留当前正在运行的内核 (最激进)
LOG_TRUNCATE_SIZE="1M"     # 将大于1MB的日志文件截断至1MB
# --- 配置结束 ---

# --- 全局设置 ---
set -e  # 当命令返回非零状态时退出 (谨慎使用, 可考虑移除并单独处理错误)
export DEBIAN_FRONTEND=noninteractive # 避免APT询问问题
SCRIPT_PATH="/usr/local/bin/disk_cleaner.sh" # 脚本保存路径

# --- 工具函数 ---

# 记录日志并输出到控制台
log_message() {
    local message="$1"
    local log_level="${2:-INFO}" # 默认为 INFO, 可以是 WARN, ERROR
    echo "[$log_level] $message"
    # 确保日志目录存在
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "$(date "+%Y-%m-%d %H:%M:%S") [$log_level] $message" >> "$LOG_FILE"
}

# 检查是否为root权限
check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        log_message "错误：请以root权限运行此脚本。" "ERROR"
        echo "用法: 以root用户运行或使用 sudo $0" >&2
        exit 1
    fi
}

# 限制日志文件大小
manage_log_size() {
    if [[ -f "$LOG_FILE" ]] && [[ $(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) -gt "$LOG_MAX_SIZE_BYTES" ]]; then
        log_message "日志文件超过 ${LOG_MAX_SIZE_BYTES} bytes，正在截断..." "WARN"
        # 保留最后 N 行可能更好，但截断更简单
        tail -n 1000 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
        echo "=== 日志文件已截断 $(date "+%Y-%m-%d %H:%M:%S") ===" >> "$LOG_FILE" # 添加标记
    fi
}

# 显示磁盘使用情况
show_disk_usage() {
    local stage="$1" # "清理前" 或 "清理后"
    log_message "当前磁盘使用情况 ($stage):"
    df -h / >> "$LOG_FILE"
    echo -e "\n当前磁盘使用情况 ($stage):"
    df -h /
}

# --- 清理函数 ---

clean_apt() {
    log_message "⏳ 清理APT缓存..."
    apt-get clean -y >> "$LOG_FILE" 2>&1 || log_message "apt-get clean 执行时出现问题 (可能无影响)" "WARN"
    log_message "⏳ 移除不再需要的软件包 (autoremove)..."
    apt-get autoremove -y >> "$LOG_FILE" 2>&1 || log_message "apt-get autoremove 执行时出现问题" "WARN"
    log_message "✅ APT清理完成"
}

clean_logs() {
    log_message "⏳ 清理和压缩旧日志..."
    # 删除常见的旧日志文件模式
    find /var/log -type f \( -name "*.gz" -o -name "*.old" -o -name "*.[0-9]" -o -name "*.[0-9].gz" \) -delete 2>/dev/null || true
    log_message "查找并删除常见的旧日志文件"

    # 截断过大的日志文件 (更安全，避免意外删除重要但过大的日志)
    find /var/log -type f -size "+$LOG_TRUNCATE_SIZE" -exec truncate --size "$LOG_TRUNCATE_SIZE" {} \; 2>/dev/null || true
    log_message "截断 /var/log 中大于 $LOG_TRUNCATE_SIZE 的文件至 $LOG_TRUNCATE_SIZE"

    # 清理 journald 日志
    if command -v journalctl &> /dev/null; then
        journalctl --vacuum-size="$JOURNAL_VACUUM_SIZE" >> "$LOG_FILE" 2>&1 || log_message "Journalctl vacuum 失败 (系统可能未使用 systemd-journald)" "WARN"
        log_message "清理 journald 日志，保留 ${JOURNAL_VACUUM_SIZE}"
    else
        log_message "journalctl 命令不存在，跳过 journald 清理" "INFO"
    fi
    log_message "✅ 日志清理完成"
}

clean_temp() {
    log_message "⏳ 清理临时文件 (超过 $TEMP_FILE_AGE_DAYS 天)..."
    find /tmp -type f -atime "+$TEMP_FILE_AGE_DAYS" -delete 2>/dev/null || true
    find /var/tmp -type f -atime "+$TEMP_FILE_AGE_DAYS" -delete 2>/dev/null || true
    log_message "✅ 临时文件清理完成"
}

clean_crash() {
    log_message "⏳ 清理Core转储文件..."
    if [[ -d "/var/crash" ]]; then
        find /var/crash -type f -delete 2>/dev/null || true
        log_message "✅ Core转储文件清理完成"
    else
        log_message "✅ 无Core转储文件目录 (/var/crash)，跳过"
    fi
}

clean_backups() {
    log_message "⏳ 清理旧的备份文件 (*.bak, *~) (超过 $BACKUP_FILE_AGE_DAYS 天)..."
    # 主要清理 /etc 下的，可以根据需要扩展路径
    find /etc -type f \( -name "*.bak" -o -name "*~" \) -atime "+$BACKUP_FILE_AGE_DAYS" -delete 2>/dev/null || true
    log_message "✅ 备份文件清理完成"
}

clean_kernels() {
    log_message "⏳ 清理旧内核 (仅保留当前运行版本)..."
    CURRENT_KERNEL=$(uname -r)
    # 使用dpkg-query查找所有已安装的linux-image包，排除当前运行的内核
    OLD_KERNELS=$(dpkg-query -f '${binary:Package}\n' -W 'linux-image-*' 2>/dev/null | grep -v "^linux-image-generic$" | grep -v "^linux-image-virtual$" | grep -v "$CURRENT_KERNEL")

    if [[ -n "$OLD_KERNELS" ]]; then
        log_message "准备清理以下旧内核: $OLD_KERNELS"
        apt-get purge $OLD_KERNELS -y >> "$LOG_FILE" 2>&1 || log_message "清理旧内核时出错 (可能部分成功)" "WARN"

        # 尝试清理关联的 headers (可能不存在或名称不同)
        OLD_HEADERS=$(dpkg-query -f '${binary:Package}\n' -W 'linux-headers-*' 2>/dev/null | grep -v "$CURRENT_KERNEL" | grep -E "$(echo "$OLD_KERNELS" | sed 's/linux-image-//g' | paste -sd'|')")
        if [[ -n "$OLD_HEADERS" ]]; then
             log_message "准备清理以下旧内核头文件: $OLD_HEADERS"
             apt-get purge $OLD_HEADERS -y >> "$LOG_FILE" 2>&1 || log_message "清理旧内核头文件时出错" "WARN"
        fi
        # 再次运行 autoremove 可能移除因卸载内核而产生的孤立包
        apt-get autoremove -y >> "$LOG_FILE" 2>&1 || true
        log_message "✅ 旧内核清理尝试完成"
    else
        log_message "✅ 未发现需要清理的旧内核"
    fi
}

clean_empty_dirs() {
    log_message "⏳ 清理 /var 下的空目录..."
    # 谨慎操作，只清理 /var 下比较安全
    find /var -type d -empty -delete 2>/dev/null || true
    log_message "✅ 空目录清理完成"
}

# --- 定时任务 ---

setup_cron() {
    local cron_file="/etc/cron.d/disk_cleaner"
    if [[ ! -f "$cron_file" ]]; then
        echo -e "\n是否要设置每天凌晨3点自动运行清理? (y/n) (30秒后默认 n)"
        read -r -t 30 setup_cron_answer || setup_cron_answer="n" # 添加超时

        if [[ "$setup_cron_answer" =~ ^[Yy]$ ]]; then
            CRON_JOB="0 3 * * * root $SCRIPT_PATH >> $LOG_FILE 2>&1" # 将cron的输出也追加到日志
            echo "$CRON_JOB" > "$cron_file"
            chmod 644 "$cron_file"
            log_message "定时任务已设置: $cron_file" "INFO"
            echo -e "\n✅ 定时任务已设置。系统将在每天凌晨3点自动清理磁盘。"
            echo -e "   配置文件: $cron_file"
        else
            log_message "用户选择不设置定时任务" "INFO"
            echo -e "\n❌ 未设置定时任务。您可以稍后手动添加:"
            echo -e "   echo \"0 3 * * * root $SCRIPT_PATH >> $LOG_FILE 2>&1\" > $cron_file && chmod 644 $cron_file"
        fi
    else
        log_message "定时任务文件 $cron_file 已存在，跳过设置。" "INFO"
        echo -e "\nℹ️  定时任务已存在: $cron_file"
    fi
}

# --- 主程序 ---

main() {
    check_root

    # --- curl | bash 处理 ---
    # 当通过curl运行时 ($0是"bash"或类似)，将脚本内容写入本地文件并重新执行
    if [[ "$0" = "bash" ]] || [[ "$(basename "$0")" = "bash" ]] || [[ "$0" = "-bash" ]]; then
        log_message "首次运行或通过管道执行，正在保存脚本到本地: $SCRIPT_PATH"
        # 使用 cat 和 heredoc 将整个脚本（包括这里的逻辑）写入文件
        # **重要**: 确保这里的 'EOFSCRIPT' 前后没有空格，并且内部的变量/命令替换已正确处理
        # 为了避免内部变量被当前shell替换，使用 'EOFSCRIPT' (带引号)
        cat > "$SCRIPT_PATH" << 'EOFSCRIPT'
#!/bin/bash
# disk_cleaner_optimized.sh - 自动清理Debian系统磁盘空间 (针对小硬盘优化)
# 作者: R1tain (由 Gemini 优化)
# GitHub: https://github.com/R1tain/script
# 用法: bash -c "$(curl -L https://raw.githubusercontent.com/R1tain/script/main/disk_cleaner.sh)"
# 警告: curl | bash 方法存在安全风险，建议先下载脚本审查后再执行。
#       wget https://raw.githubusercontent.com/R1tain/script/main/disk_cleaner.sh
#       # (审查 disk_cleaner.sh)
#       sudo bash disk_cleaner.sh

# --- 配置 (针对 <1GB 硬盘进行调整) ---
LOG_FILE="/var/log/disk_cleaner.log"
LOG_MAX_SIZE_BYTES=524288 # 限制日志文件最大 512KB
JOURNAL_VACUUM_SIZE="10M"  # journald 日志保留大小 (更小可能导致调试困难)
TEMP_FILE_AGE_DAYS=3       # 清理超过3天的临时文件
BACKUP_FILE_AGE_DAYS=15    # 清理超过15天的备份文件 (*.bak, *~)
KERNELS_TO_KEEP=0          # 仅保留当前正在运行的内核 (最激进)
LOG_TRUNCATE_SIZE="1M"     # 将大于1MB的日志文件截断至1MB
# --- 配置结束 ---

# --- 全局设置 ---
set -e  # 当命令返回非零状态时退出 (谨慎使用, 可考虑移除并单独处理错误)
export DEBIAN_FRONTEND=noninteractive # 避免APT询问问题
SCRIPT_PATH="/usr/local/bin/disk_cleaner.sh" # 脚本保存路径

# --- 工具函数 ---

# 记录日志并输出到控制台
log_message() {
    local message="$1"
    local log_level="${2:-INFO}" # 默认为 INFO, 可以是 WARN, ERROR
    echo "[$log_level] $message"
    # 确保日志目录存在
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "$(date "+%Y-%m-%d %H:%M:%S") [$log_level] $message" >> "$LOG_FILE"
}

# 检查是否为root权限
check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        log_message "错误：请以root权限运行此脚本。" "ERROR"
        echo "用法: 以root用户运行或使用 sudo $0" >&2
        exit 1
    fi
}

# 限制日志文件大小
manage_log_size() {
    if [[ -f "$LOG_FILE" ]] && [[ $(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) -gt "$LOG_MAX_SIZE_BYTES" ]]; then
        log_message "日志文件超过 ${LOG_MAX_SIZE_BYTES} bytes，正在截断..." "WARN"
        # 保留最后 N 行可能更好，但截断更简单
        tail -n 1000 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
        echo "=== 日志文件已截断 $(date "+%Y-%m-%d %H:%M:%S") ===" >> "$LOG_FILE" # 添加标记
    fi
}

# 显示磁盘使用情况
show_disk_usage() {
    local stage="$1" # "清理前" 或 "清理后"
    log_message "当前磁盘使用情况 ($stage):"
    df -h / >> "$LOG_FILE"
    echo -e "\n当前磁盘使用情况 ($stage):"
    df -h /
}

# --- 清理函数 ---

clean_apt() {
    log_message "⏳ 清理APT缓存..."
    apt-get clean -y >> "$LOG_FILE" 2>&1 || log_message "apt-get clean 执行时出现问题 (可能无影响)" "WARN"
    log_message "⏳ 移除不再需要的软件包 (autoremove)..."
    apt-get autoremove -y >> "$LOG_FILE" 2>&1 || log_message "apt-get autoremove 执行时出现问题" "WARN"
    log_message "✅ APT清理完成"
}

clean_logs() {
    log_message "⏳ 清理和压缩旧日志..."
    # 删除常见的旧日志文件模式
    find /var/log -type f \( -name "*.gz" -o -name "*.old" -o -name "*.[0-9]" -o -name "*.[0-9].gz" \) -delete 2>/dev/null || true
    log_message "查找并删除常见的旧日志文件"

    # 截断过大的日志文件 (更安全，避免意外删除重要但过大的日志)
    find /var/log -type f -size "+$LOG_TRUNCATE_SIZE" -exec truncate --size "$LOG_TRUNCATE_SIZE" {} \; 2>/dev/null || true
    log_message "截断 /var/log 中大于 $LOG_TRUNCATE_SIZE 的文件至 $LOG_TRUNCATE_SIZE"

    # 清理 journald 日志
    if command -v journalctl &> /dev/null; then
        journalctl --vacuum-size="$JOURNAL_VACUUM_SIZE" >> "$LOG_FILE" 2>&1 || log_message "Journalctl vacuum 失败 (系统可能未使用 systemd-journald)" "WARN"
        log_message "清理 journald 日志，保留 ${JOURNAL_VACUUM_SIZE}"
    else
        log_message "journalctl 命令不存在，跳过 journald 清理" "INFO"
    fi
    log_message "✅ 日志清理完成"
}

clean_temp() {
    log_message "⏳ 清理临时文件 (超过 $TEMP_FILE_AGE_DAYS 天)..."
    find /tmp -type f -atime "+$TEMP_FILE_AGE_DAYS" -delete 2>/dev/null || true
    find /var/tmp -type f -atime "+$TEMP_FILE_AGE_DAYS" -delete 2>/dev/null || true
    log_message "✅ 临时文件清理完成"
}

clean_crash() {
    log_message "⏳ 清理Core转储文件..."
    if [[ -d "/var/crash" ]]; then
        find /var/crash -type f -delete 2>/dev/null || true
        log_message "✅ Core转储文件清理完成"
    else
        log_message "✅ 无Core转储文件目录 (/var/crash)，跳过"
    fi
}

clean_backups() {
    log_message "⏳ 清理旧的备份文件 (*.bak, *~) (超过 $BACKUP_FILE_AGE_DAYS 天)..."
    # 主要清理 /etc 下的，可以根据需要扩展路径
    find /etc -type f \( -name "*.bak" -o -name "*~" \) -atime "+$BACKUP_FILE_AGE_DAYS" -delete 2>/dev/null || true
    log_message "✅ 备份文件清理完成"
}

clean_kernels() {
    log_message "⏳ 清理旧内核 (仅保留当前运行版本)..."
    CURRENT_KERNEL=$(uname -r)
    # 使用dpkg-query查找所有已安装的linux-image包，排除当前运行的内核
    # 同时排除 meta-packages 如 linux-image-generic
    OLD_KERNELS=$(dpkg-query -f '${binary:Package}\n' -W 'linux-image-[0-9]*' 2>/dev/null | grep -v "$CURRENT_KERNEL")

    if [[ -n "$OLD_KERNELS" ]]; then
        log_message "准备清理以下旧内核: $OLD_KERNELS"
        apt-get purge $OLD_KERNELS -y >> "$LOG_FILE" 2>&1 || log_message "清理旧内核时出错 (可能部分成功)" "WARN"

        # 尝试清理关联的 headers (可能不存在或名称不同)
        # 构造一个正则表达式来匹配旧内核版本号部分
        kernel_versions_regex=$(echo "$OLD_KERNELS" | sed -n 's/^linux-image-\(.*\)/\1/p' | paste -sd'|')
        if [[ -n "$kernel_versions_regex" ]]; then
            OLD_HEADERS=$(dpkg-query -f '${binary:Package}\n' -W 'linux-headers-*' 2>/dev/null | grep -E "($kernel_versions_regex)")
            if [[ -n "$OLD_HEADERS" ]]; then
                 log_message "准备清理以下旧内核头文件: $OLD_HEADERS"
                 apt-get purge $OLD_HEADERS -y >> "$LOG_FILE" 2>&1 || log_message "清理旧内核头文件时出错" "WARN"
            fi
        fi
        # 再次运行 autoremove 可能移除因卸载内核而产生的孤立包
        log_message "再次运行 autoremove 以清理可能残留的依赖..."
        apt-get autoremove -y >> "$LOG_FILE" 2>&1 || true
        log_message "✅ 旧内核清理尝试完成"
    else
        log_message "✅ 未发现需要清理的旧内核"
    fi
}


clean_empty_dirs() {
    log_message "⏳ 清理 /var 下的空目录..."
    # 谨慎操作，只清理 /var 下比较安全
    find /var -type d -empty -delete 2>/dev/null || true
    log_message "✅ 空目录清理完成"
}

# --- 定时任务 ---

setup_cron() {
    local cron_file="/etc/cron.d/disk_cleaner"
    if [[ ! -f "$cron_file" ]]; then
        echo -e "\n是否要设置每天凌晨3点自动运行清理? (y/n) (30秒后默认 n)"
        read -r -t 30 setup_cron_answer || setup_cron_answer="n" # 添加超时

        if [[ "$setup_cron_answer" =~ ^[Yy]$ ]]; then
            CRON_JOB="0 3 * * * root $SCRIPT_PATH >> $LOG_FILE 2>&1" # 将cron的输出也追加到日志
            echo "$CRON_JOB" > "$cron_file"
            chmod 644 "$cron_file"
            log_message "定时任务已设置: $cron_file" "INFO"
            echo -e "\n✅ 定时任务已设置。系统将在每天凌晨3点自动清理磁盘。"
            echo -e "   配置文件: $cron_file"
        else
            log_message "用户选择不设置定时任务" "INFO"
            echo -e "\n❌ 未设置定时任务。您可以稍后手动添加:"
            echo -e "   echo \"0 3 * * * root $SCRIPT_PATH >> $LOG_FILE 2>&1\" > $cron_file && chmod 644 $cron_file"
        fi
    else
        log_message "定时任务文件 $cron_file 已存在，跳过设置。" "INFO"
        echo -e "\nℹ️  定时任务已存在: $cron_file"
    fi
}

# --- 主程序 ---

main() {
    check_root
    manage_log_size # 管理日志大小（放在开头避免日志自身过大）

    log_message "=== 开始系统清理 ===" "INFO"
    show_disk_usage "清理前"

    # 执行清理
    clean_apt
    clean_logs
    clean_temp
    clean_crash
    clean_backups
    clean_kernels # 清理旧内核是关键步骤
    clean_empty_dirs

    show_disk_usage "清理后"
    log_message "=== 系统清理完成 ===" "INFO"
    echo "" >> "$LOG_FILE" # 日志中添加空行分隔

    echo -e "\n🎉 系统清理完成! 查看日志: $LOG_FILE\n"

    # 设置定时任务
    setup_cron
}

# --- 脚本入口 ---
# 将所有主要逻辑放入 main 函数，然后在脚本末尾调用它
# 这使得 curl | bash 保存并执行本地副本的逻辑更清晰
main

exit 0 # 确保脚本成功退出

EOFSCRIPT
        # --- curl | bash 处理 (续) ---
        chmod +x "$SCRIPT_PATH"
        log_message "脚本已保存到 $SCRIPT_PATH，将执行本地副本..." "INFO"
        # 使用 exec 替换当前进程，避免重复执行后续代码
        exec "$SCRIPT_PATH"
        # exec 失败时退出
        exit 1
    fi

    # --- 如果不是通过 curl | bash 运行，直接执行 main 函数 ---
    manage_log_size # 管理日志大小（放在开头避免日志自身过大）
    log_message "=== 开始系统清理 (直接运行) ===" "INFO"
    show_disk_usage "清理前"

    # 执行清理
    clean_apt
    clean_logs
    clean_temp
    clean_crash
    clean_backups
    clean_kernels
    clean_empty_dirs

    show_disk_usage "清理后"
    log_message "=== 系统清理完成 (直接运行) ===" "INFO"
    echo "" >> "$LOG_FILE" # 日志中添加空行分隔

    echo -e "\n🎉 系统清理完成! 查看日志: $LOG_FILE\n"

    # 设置定时任务
    setup_cron
}

# --- 脚本入口 ---
# 只有在不是 curl | bash 的情况下，下面的 main 调用才会执行
# curl | bash 的情况已经在上面的 if 块中通过 exec 处理了
main "$@" # 传递可能存在的参数给 main 函数 (虽然本版本未使用参数)

exit 0
