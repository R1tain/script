#!/usr/bin/env bash
#
# install-tmux.sh — 通用 Linux 一键安装 / 更新 tmux
# 支持包管理器：apt、dnf、yum、pacman、zypper、apk、emerge
# 若无法找到二进制包则自动编译安装最新版
# Author: Lilja Peltola (@emmanuelthalie35)
set -euo pipefail

NEED_SUDO=false
# 判断是否 root
if [[ $EUID -ne 0 ]]; then
  NEED_SUDO=true
  # 检查 sudo 是否存在
  if ! command -v sudo &>/dev/null; then
    echo "请以 root 身份运行，或先安装 sudo。" >&2
    exit 1
  fi
fi

run() {
  if $NEED_SUDO; then
    sudo "$@"
  else
    "$@"
  fi
}

install_from_pkg() {
  local pkg="$1"
  echo "正在使用系统包管理器安装 $pkg ..."
  run "${INSTALL_CMD[@]}" "$pkg"
}

build_from_source() {
  echo "仓库中未找到 tmux，转为源码编译安装..."
  local deps=(automake pkg-config libevent-dev libncurses-dev build-essential bison git)
  case "$PM" in
    apt)        run apt-get update && run apt-get install -y "${deps[@]}";;
    dnf|yum)    run "$PM" install -y "@development-tools" libevent-devel ncurses-devel pkgconfig automake bison git;;
    pacman)     run pacman -Syu --noconfirm base-devel libevent ncurses git;;
    zypper)     run zypper install -y -t pattern devel_basis && run zypper install -y libevent-devel ncurses-devel git automake pkg-config bison gcc make;;
    apk)        run apk add --no-cache build-base libevent-dev ncurses-dev git automake pkgconf bison;; 
    emerge)     run emerge --ask --quiet libevent ncurses git automake pkgconfig bison gcc make;;
  esac

  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  git clone --depth=1 https://github.com/tmux/tmux.git "$TMP/tmux"
  cd "$TMP/tmux"
  sh autogen.sh
  ./configure && make
  run make install
  echo "tmux 已成功通过源码安装到 /usr/local/bin。"
}

# 检测包管理器
if command -v apt-get &>/dev/null;      then PM=apt;      INSTALL_CMD=(apt-get install -y)
elif command -v dnf &>/dev/null;        then PM=dnf;      INSTALL_CMD=(dnf install -y)
elif command -v yum &>/dev/null;        then PM=yum;      INSTALL_CMD=(yum install -y)
elif command -v pacman &>/dev/null;     then PM=pacman;   INSTALL_CMD=(pacman -Syu --noconfirm)
elif command -v zypper &>/dev/null;     then PM=zypper;   INSTALL_CMD=(zypper install -y)
elif command -v apk &>/dev/null;        then PM=apk;      INSTALL_CMD=(apk add --no-cache)
elif command -v emerge &>/dev/null;     then PM=emerge;   INSTALL_CMD=(emerge --ask --quiet)
else
  echo "无法识别的包管理器，尝试源码编译安装。" >&2
  build_from_source
  exit $?
fi

echo "检测到包管理器：$PM"

# 优先用系统包安装
if ! install_from_pkg tmux 2>/dev/null; then
  build_from_source
fi

echo -e "\ntmux 安装完成！版本信息如下："
tmux -V
