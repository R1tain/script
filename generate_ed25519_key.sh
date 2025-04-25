#!/bin/bash
# Ed25519 密钥生成器
# 修复版本：自动安装 uuidgen

# 检查系统是否安装了 ssh-keygen
if ! command -v ssh-keygen &> /dev/null; then
    echo "错误：未找到 ssh-keygen 命令。请安装 OpenSSH。"
    exit 1
fi

# 检查系统是否安装了 uuidgen
if ! command -v uuidgen &> /dev/null; then
    echo "错误：未找到 uuidgen 命令。"
    echo "尝试自动安装 uuid-runtime..."
    # 更新软件包列表并安装 uuid-runtime
    sudo apt-get update
    if sudo apt-get install -y uuid-runtime; then
        echo "uuid-runtime 安装成功。"
    else
        echo "错误：安装 uuid-runtime 失败。请手动安装后再试。"
        exit 1
    fi
fi

# 获取当前目录
current_dir=$(pwd)

# 生成随机文件名并确保不重复
random_filename=$(uuidgen)
while [ -e "${current_dir}/${random_filename}" ]; do
    random_filename=$(uuidgen)
done

# 设置密钥路径
key_path="${current_dir}/${random_filename}"

# 提示用户输入密钥的密码（可选）
echo "请输入密钥的密码（可选，直接按回车则无密码）："
read -s passphrase

# 生成 Ed25519 密钥对
ssh-keygen -t ed25519 -f "$key_path" -N "$passphrase"
if [ $? -ne 0 ]; then
    echo "错误：密钥生成失败。"
    exit 1
fi

# 显示生成的密钥指纹
ssh-keygen -lvf "$key_path"

# 提示密钥生成成功
echo "密钥已生成，保存在：${key_path}"
