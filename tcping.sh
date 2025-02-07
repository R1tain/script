#!/bin/bash

# 所有功能来自 https://github.com/pouriyajamshidi/tcping 
# 只是为了自己方便使用

# 检查系统架构并下载相应的 .deb 包
ARCH=$(uname -m)
if [ "$ARCH" == "x86_64" ]; then
    wget https://github.com/pouriyajamshidi/tcping/releases/latest/download/tcping-amd64.deb -O /tmp/tcping.deb
elif [ "$ARCH" == "aarch64" ]; then
    wget https://github.com/pouriyajamshidi/tcping/releases/latest/download/tcping-arm64.deb -O /tmp/tcping.deb
else
    echo "不支持的架构: $ARCH"
    exit 1
fi

# 安装 tcping
sudo apt install -y /tmp/tcping.deb

# 清理临时文件
rm /tmp/tcping.deb

echo "tcping 安装完成！"
echo "使用示例："

# 输出使用示例
echo "1. 基本用法："
echo "   tcping www.example.com 443"

echo -e "\n2. 指定探测间隔和超时，以及源接口："
echo "   tcping www.example.com 443 -i 2 -t 5 -I eth2"

echo -e "\n3. 强制使用 IPv4："
echo "   tcping www.example.com 443 -4"

echo -e "\n4. 强制使用 IPv6："
echo "   tcping www.example.com 443 -6"

echo -e "\n5. 显示探测时间戳："
echo "   tcping www.example.com 443 -D"

echo -e "\n6. 在 5 次失败后重试解析主机名："
echo "   tcping www.example.com 443 -r 5"

echo -e "\n7. 在 5 次探测后停止："
echo "   tcping www.example.com 443 -c 5"
