#!/bin/sh
set -e

TARGET_LOCALE="en_US.UTF-8"

echo "[INFO] 检查系统发行版..."
if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO=$(echo "$ID" | tr 'A-Z' 'a-z')
    FAMILY=$(echo "$ID_LIKE" | tr 'A-Z' 'a-z')
else
    echo "[ERROR] 无法检测系统发行版"
    exit 1
fi

echo "[INFO] 发行版: $DISTRO (ID_LIKE=$FAMILY)"

install_locale() {
    case "$DISTRO" in
        debian|ubuntu)
            echo "[INFO] 安装 locales 包..."
            $SUDO apt-get update -y
            $SUDO apt-get install -y locales
            echo "[INFO] 生成 $TARGET_LOCALE..."
            $SUDO locale-gen $TARGET_LOCALE
            $SUDO update-locale LANG=$TARGET_LOCALE
            ;;
        centos|rhel|fedora|rocky|almalinux)
            echo "[INFO] 生成 $TARGET_LOCALE..."
            $SUDO localedef -c -f UTF-8 -i en_US en_US.UTF-8 || true
            ;;
        alpine)
            echo "[INFO] 安装 musl-locales..."
            $SUDO apk add --no-cache musl musl-locales musl-locales-lang || {
                echo "[WARN] musl-locales 安装失败，可能需要切换到 community 源"
            }
            ;;
        arch|manjaro)
            echo "[INFO] 修改 /etc/locale.gen 启用 $TARGET_LOCALE..."
            $SUDO sed -i "s/^#${TARGET_LOCALE}/${TARGET_LOCALE}/" /etc/locale.gen
            $SUDO locale-gen
            ;;
        *)
            echo "[WARN] 未知发行版: $DISTRO, 尝试 localedef..."
            $SUDO localedef -c -f UTF-8 -i en_US en_US.UTF-8 || true
            ;;
    esac
}

# 检查是否需要 sudo
if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    else
        echo "[ERROR] 请用 root 用户执行，或者安装 sudo"
        exit 1
    fi
else
    SUDO=""
fi

install_locale

# 幂等性修改 ~/.profile （sh 默认加载它，Alpine 没有 bashrc）
PROFILE="$HOME/.profile"
grep -q "LANG=" "$PROFILE" && sed -i "s/^export LANG=.*/export LANG=$TARGET_LOCALE/" "$PROFILE" || echo "export LANG=$TARGET_LOCALE" >> "$PROFILE"
grep -q "LC_ALL=" "$PROFILE" && sed -i "s/^export LC_ALL=.*/export LC_ALL=$TARGET_LOCALE/" "$PROFILE" || echo "export LC_ALL=$TARGET_LOCALE" >> "$PROFILE"

echo "[INFO] 已写入 $PROFILE"
echo "[INFO] 立即应用..."
# shellcheck disable=SC1090
. "$PROFILE" || echo "[WARN] 无法自动 source，请手动执行: . ~/.profile"

echo "[INFO] 当前 locale:"
locale
