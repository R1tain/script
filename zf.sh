#!/bin/bash

# 1. 创建 to 文件夹
mkdir -p to
cd to

# 2. 下载原始脚本
wget https://raw.githubusercontent.com/R1tain/script/main/socat.py

# 3. 创建新的配置脚本
chmod +x socat.py

# 首次运行配置
./socat.py --init

# 4. 创建 crontab 定时任务
(crontab -l 2>/dev/null; echo "* * * * * cd $(pwd) && ./socat.py") | crontab -

echo "设置和初始配置已完成！"
