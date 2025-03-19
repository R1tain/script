#!/bin/bash
# disk_cleaner.sh - 自动清理Debian系统磁盘空间
# 作者: R1tain
# GitHub: https://github.com/R1tain/script
# 用法: bash -c "$(curl -L https://raw.githubusercontent.com/R1tain/script/main/disk_cleaner.sh)"

# 检查是否为root权限
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请以root权限运行此脚本。"
    echo "用法: 以root用户运行或使用 sudo $0"
    exit 1
fi

# 保存脚本到本地
LOCAL_SCRIPT="/usr/local/bin/disk_cleaner.sh"
if [ "$0" = "bash" ] || [ "$(basename $0)" = "bash" ]; then
    # 当通过curl运行时，保存到本地
    echo "首次运行，正在保存脚本到本地: $LOCAL_SCRIPT"
    cat > "$LOCAL_SCRIPT" << 'EOFSCRIPT'
#!/bin/bash
# disk_cleaner.sh - 自动清理Debian系统磁盘空间
# 作者: R1tain
# GitHub: https://github.com/R1tain/script

set -e  # 当命令返回非零状态时退出
export DEBIAN_FRONTEND=noninteractive  # 避免APT询问问题

# 检查是否为root权限
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请以root权限运行此脚本。"
    echo "用法: 以root用户运行或使用 sudo $0"
    exit 1
fi

# 设置日志文件
LOG_FILE="/var/log/disk_cleaner.log"
DATE=$(date "+%Y-%m-%d %H:%M:%S")

# 限制日志文件大小，如果超过1MB则截断
if [ -f "$LOG_FILE" ] && [ $(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) -gt 1048576 ]; then
    echo "=== 日志文件过大，正在截断 $(date "+%Y-%m-%d %H:%M:%S") ===" > $LOG_FILE
fi

# 显示清理前的磁盘使用情况
echo -e "\n当前磁盘使用情况 (清理前):"
df -h /

echo -e "\n开始系统清理...\n"
echo "=== 开始清理 $DATE ===" >> $LOG_FILE

# 1. 清理APT缓存
echo "⏳ 清理APT缓存..."
echo "清理APT缓存..." >> $LOG_FILE
apt-get clean -y >> $LOG_FILE 2>&1
apt-get autoremove -y >> $LOG_FILE 2>&1
echo "✅ APT缓存清理完成"

# 2. 清理日志文件
echo "⏳ 清理和压缩旧日志..."
echo "清理和压缩旧日志..." >> $LOG_FILE
find /var/log -type f -name "*.gz" -delete 2>/dev/null || true
find /var/log -type f -name "*.???" -delete 2>/dev/null || true
find /var/log -type f -size +5M -exec truncate -s 5M {} \; 2>/dev/null || true
journalctl --vacuum-size=10M >> $LOG_FILE 2>&1 || true
echo "✅ 日志清理完成"

# 3. 清理临时文件
echo "⏳ 清理临时文件..."
echo "清理临时文件..." >> $LOG_FILE
find /tmp -type f -atime +7 -delete 2>/dev/null || true
find /var/tmp -type f -atime +7 -delete 2>/dev/null || true
echo "✅ 临时文件清理完成"

# 4. 清理Core转储文件
echo "⏳ 清理Core转储文件..."
echo "清理Core转储文件..." >> $LOG_FILE
if [ -d "/var/crash" ]; then
    find /var/crash -type f -delete 2>/dev/null || true
    echo "✅ Core转储文件清理完成"
else
    echo "✅ 无Core转储文件目录，跳过"
fi

# 5. 清理旧的备份文件
echo "⏳ 清理备份文件..."
echo "清理备份文件..." >> $LOG_FILE
find /etc -name "*.bak" -o -name "*~" -type f -atime +30 -delete 2>/dev/null || true
echo "✅ 备份文件清理完成"

# 6. 清理旧内核
echo "⏳ 清理旧内核..."
echo "清理旧内核..." >> $LOG_FILE
# 保留当前内核和最近的一个旧内核
CURRENT_KERNEL=$(uname -r)
OLD_KERNELS=$(dpkg-query -f '${binary:Package}\n' -W 'linux-image-*' 2>/dev/null | grep -v "$CURRENT_KERNEL" | head -n -1)
if [ -n "$OLD_KERNELS" ]; then
    apt-get purge $OLD_KERNELS -y >> $LOG_FILE 2>&1 || true
    echo "✅ 旧内核清理完成"
else
    echo "✅ 无旧内核需要清理"
fi

# 7. 清理空目录
echo "⏳ 清理空目录..."
echo "清理空目录..." >> $LOG_FILE
find /var -type d -empty -delete 2>/dev/null || true
echo "✅ 空目录清理完成"

# 输出磁盘使用情况
echo -e "\n清理后磁盘使用情况:"
df -h /
echo "清理后磁盘使用情况:" >> $LOG_FILE
df -h / >> $LOG_FILE

echo "=== 清理完成 $DATE ===" >> $LOG_FILE
echo "" >> $LOG_FILE

echo -e "\n🎉 系统清理完成! 查看日志: $LOG_FILE\n"

# 提供设置定时任务的选项
if [ ! -f "/etc/cron.d/disk_cleaner" ]; then
    echo -e "\n是否要设置每天凌晨3点自动运行清理? (y/n)"
    read -r -t 30 setup_cron || setup_cron="n"  # 添加超时，避免卡在这里

    if [[ "$setup_cron" =~ ^[Yy]$ ]]; then
        CRON_JOB="0 3 * * * root /usr/local/bin/disk_cleaner.sh"
        
        echo "$CRON_JOB" > /etc/cron.d/disk_cleaner
        chmod 644 /etc/cron.d/disk_cleaner
        
        echo -e "\n✅ 定时任务已设置。系统将在每天凌晨3点自动清理磁盘。"
        echo -e "   配置文件: /etc/cron.d/disk_cleaner"
    else
        echo -e "\n❌ 未设置定时任务。您可以稍后手动添加:"
        echo -e "   echo \"0 3 * * * root /usr/local/bin/disk_cleaner.sh\" > /etc/cron.d/disk_cleaner"
    fi
fi
EOFSCRIPT

    chmod +x "$LOCAL_SCRIPT"
    echo "脚本已保存到 $LOCAL_SCRIPT，执行中..."
    exec "$LOCAL_SCRIPT"
    exit 0
fi

# 以下是主脚本内容，当直接运行本地脚本时会执行
set -e  # 当命令返回非零状态时退出
export DEBIAN_FRONTEND=noninteractive  # 避免APT询问问题

# 设置日志文件
LOG_FILE="/var/log/disk_cleaner.log"
DATE=$(date "+%Y-%m-%d %H:%M:%S")

# 限制日志文件大小，如果超过1MB则截断
if [ -f "$LOG_FILE" ] && [ $(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) -gt 1048576 ]; then
    echo "=== 日志文件过大，正在截断 $(date "+%Y-%m-%d %H:%M:%S") ===" > $LOG_FILE
fi

# 显示清理前的磁盘使用情况
echo -e "\n当前磁盘使用情况 (清理前):"
df -h /

echo -e "\n开始系统清理...\n"
echo "=== 开始清理 $DATE ===" >> $LOG_FILE

# 1. 清理APT缓存
echo "⏳ 清理APT缓存..."
echo "清理APT缓存..." >> $LOG_FILE
apt-get clean -y >> $LOG_FILE 2>&1
apt-get autoremove -y >> $LOG_FILE 2>&1
echo "✅ APT缓存清理完成"

# 2. 清理日志文件
echo "⏳ 清理和压缩旧日志..."
echo "清理和压缩旧日志..." >> $LOG_FILE
find /var/log -type f -name "*.gz" -delete 2>/dev/null || true
find /var/log -type f -name "*.???" -delete 2>/dev/null || true
find /var/log -type f -size +5M -exec truncate -s 5M {} \; 2>/dev/null || true
journalctl --vacuum-size=10M >> $LOG_FILE 2>&1 || true
echo "✅ 日志清理完成"

# 3. 清理临时文件
echo "⏳ 清理临时文件..."
echo "清理临时文件..." >> $LOG_FILE
find /tmp -type f -atime +7 -delete 2>/dev/null || true
find /var/tmp -type f -atime +7 -delete 2>/dev/null || true
echo "✅ 临时文件清理完成"

# 4. 清理Core转储文件
echo "⏳ 清理Core转储文件..."
echo "清理Core转储文件..." >> $LOG_FILE
if [ -d "/var/crash" ]; then
    find /var/crash -type f -delete 2>/dev/null || true
    echo "✅ Core转储文件清理完成"
else
    echo "✅ 无Core转储文件目录，跳过"
fi

# 5. 清理旧的备份文件
echo "⏳ 清理备份文件..."
echo "清理备份文件..." >> $LOG_FILE
find /etc -name "*.bak" -o -name "*~" -type f -atime +30 -delete 2>/dev/null || true
echo "✅ 备份文件清理完成"

# 6. 清理旧内核
echo "⏳ 清理旧内核..."
echo "清理旧内核..." >> $LOG_FILE
# 保留当前内核和最近的一个旧内核
CURRENT_KERNEL=$(uname -r)
OLD_KERNELS=$(dpkg-query -f '${binary:Package}\n' -W 'linux-image-*' 2>/dev/null | grep -v "$CURRENT_KERNEL" | head -n -1)
if [ -n "$OLD_KERNELS" ]; then
    apt-get purge $OLD_KERNELS -y >> $LOG_FILE 2>&1 || true
    echo "✅ 旧内核清理完成"
else
    echo "✅ 无旧内核需要清理"
fi

# 7. 清理空目录
echo "⏳ 清理空目录..."
echo "清理空目录..." >> $LOG_FILE
find /var -type d -empty -delete 2>/dev/null || true
echo "✅ 空目录清理完成"

# 输出磁盘使用情况
echo -e "\n清理后磁盘使用情况:"
df -h /
echo "清理后磁盘使用情况:" >> $LOG_FILE
df -h / >> $LOG_FILE

echo "=== 清理完成 $DATE ===" >> $LOG_FILE
echo "" >> $LOG_FILE

echo -e "\n🎉 系统清理完成! 查看日志: $LOG_FILE\n"

# 提供设置定时任务的选项
if [ ! -f "/etc/cron.d/disk_cleaner" ]; then
    echo -e "\n是否要设置每天凌晨3点自动运行清理? (y/n)"
    read -r -t 30 setup_cron || setup_cron="n"  # 添加超时，避免卡在这里

    if [[ "$setup_cron" =~ ^[Yy]$ ]]; then
        CRON_JOB="0 3 * * * root /usr/local/bin/disk_cleaner.sh"
        
        echo "$CRON_JOB" > /etc/cron.d/disk_cleaner
        chmod 644 /etc/cron.d/disk_cleaner
        
        echo -e "\n✅ 定时任务已设置。系统将在每天凌晨3点自动清理磁盘。"
        echo -e "   配置文件: /etc/cron.d/disk_cleaner"
    else
        echo -e "\n❌ 未设置定时任务。您可以稍后手动添加:"
        echo -e "   echo \"0 3 * * * root /usr/local/bin/disk_cleaner.sh\" > /etc/cron.d/disk_cleaner"
    fi
fi
