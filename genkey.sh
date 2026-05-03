#!/usr/bin/env bash

set -e

# 随机文件名
KEY_NAME=$(openssl rand -hex 8)

# 生成 ed25519 密钥
ssh-keygen -t ed25519 -N "" -f "${KEY_NAME}" >/dev/null 2>&1

echo "=================================="
echo "ED25519 密钥生成成功"
echo "=================================="
echo "私钥文件: ${KEY_NAME}"
echo "公钥文件: ${KEY_NAME}.pub"
echo

echo "========== 私钥 =========="
cat "${KEY_NAME}"
echo

echo "========== 公钥 =========="
cat "${KEY_NAME}.pub"
echo
