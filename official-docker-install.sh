#!/bin/bash

# 下载 Docker 安装脚本
curl -fsSL https://get.docker.com -o install-docker.sh

# 验证脚本内容并以蓝色字体输出
echo -e "\033[34m$(cat install-docker.sh)\033[0m"

# 赋予脚本执行权限
chmod +x install-docker.sh

# 运行脚本以进行干运行验证
sh install-docker.sh --dry-run

# 以 root 用户或使用 sudo 运行脚本进行安装
sh install-docker.sh
