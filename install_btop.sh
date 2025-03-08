#!/bin/bash

# 顏色輸出函數
print_info() {
  echo -e "\033[1;34m[INFO]\033[0m $1"
}

print_success() {
  echo -e "\033[1;32m[SUCCESS]\033[0m $1"
}

print_error() {
  echo -e "\033[1;31m[ERROR]\033[0m $1"
}

print_warning() {
  echo -e "\033[1;33m[WARNING]\033[0m $1"
}

# 檢查是否以 root 執行
check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    print_error "此腳本必須以 root 權限執行"
    exit 1
  fi
}

# 檢測包管理器
detect_package_manager() {
  if command -v apt &> /dev/null; then
    package_manager="apt"
  elif command -v dnf &> /dev/null; then
    package_manager="dnf"
  elif command -v yum &> /dev/null; then
    package_manager="yum"
  elif command -v pacman &> /dev/null; then
    package_manager="pacman"
  elif command -v zypper &> /dev/null; then
    package_manager="zypper"
  elif command -v apk &> /dev/null; then
    package_manager="apk"
  else
    package_manager="source"
  fi
}

# 安裝依賴項
install_dependencies() {
  print_info "安裝必要的依賴項..."
  case $package_manager in
    apt)
      apt-get update
      apt-get install -y git build-essential cmake libncurses-dev
      ;;
    dnf)
      dnf install -y git gcc-c++ cmake ncurses-devel
      ;;
    yum)
      yum install -y git gcc-c++ cmake ncurses-devel
      ;;
    pacman)
      pacman -S --noconfirm git base-devel cmake ncurses
      ;;
    zypper)
      zypper install -y git gcc-c++ cmake ncurses-devel
      ;;
    apk)
      apk add git g++ make cmake ncurses-dev
      ;;
    *)
      print_info "無法確定包管理器。請手動安裝 git、gcc/g++、make 和 cmake。"
      ;;
  esac
}

# 從包管理器安裝 btop
install_from_package() {
  print_info "嘗試從包管理器安裝 btop..."
  case $package_manager in
    apt)
      apt-get install -y btop
      ;;
    dnf)
      dnf install -y btop
      ;;
    yum)
      yum install -y btop
      ;;
    pacman)
      pacman -S --noconfirm btop
      ;;
    zypper)
      zypper install -y btop
      ;;
    apk)
      apk add btop
      ;;
    *)
      return 1
      ;;
  esac
  
  if command -v btop &> /dev/null; then
    return 0
  else
    return 1
  fi
}

# 從源碼安裝 btop
install_from_source() {
  print_info "從源碼安裝 btop..."
  
  temp_dir=$(mktemp -d)
  cd "$temp_dir"
  
  print_info "克隆 btop 儲存庫..."
  git clone https://github.com/aristocratos/btop.git
  
  cd btop
  print_info "編譯 btop..."
  make
  print_info "安裝 btop..."
  make install
  
  cd /
  rm -rf "$temp_dir"
  
  if command -v btop &> /dev/null; then
    return 0
  else
    return 1
  fi
}

# 卸載 btop
uninstall_btop() {
  print_info "卸載 btop..."
  
  case $package_manager in
    apt)
      apt-get remove -y btop
      ;;
    dnf)
      dnf remove -y btop
      ;;
    yum)
      yum remove -y btop
      ;;
    pacman)
      pacman -R --noconfirm btop
      ;;
    zypper)
      zypper remove -y btop
      ;;
    apk)
      apk del btop
      ;;
    *)
      if [ -f /usr/local/bin/btop ]; then
        rm -f /usr/local/bin/btop
      fi
      if [ -d /usr/local/share/btop ]; then
        rm -rf /usr/local/share/btop
      fi
      print_info "已從 /usr/local/bin 和 /usr/local/share 移除 btop 文件"
      ;;
  esac
  
  if command -v btop &> /dev/null; then
    print_warning "btop 仍可在系統中使用。它可能安裝在不同的位置。"
    return 1
  else
    print_success "btop 已成功卸載。"
    return 0
  fi
}

# 顯示使用說明
print_usage_instructions() {
  print_success "btop 已成功安裝！"
  echo ""
  echo "---------------------------------------------"
  echo "              BTOP 使用指南                  "
  echo "---------------------------------------------"
  echo ""
  echo "基本命令："
  echo "  btop                   以默認設置啟動 btop"
  echo "  btop --help            顯示所有選項的幫助信息"
  echo ""
  echo "鍵盤快捷鍵（運行 btop 時）："
  echo "  ESC/q/Ctrl-c          退出"
  echo "  F1/h                  顯示幫助菜單"
  echo "  F2                    顯示選項菜單"
  echo "  1/2/3/4               更改視圖模式"
  echo "  m                     切換內存統計"
  echo "  p                     切換進程信息"
  echo "  f                     為進程添加過濾器"
  echo "  +/-                   展開/折疊進程樹"
  echo ""
  echo "更多信息和選項，請訪問："
  echo "https://github.com/aristocratos/btop"
  echo ""
}

# 主函數
main() {
  print_info "btop 安裝腳本"
  
  check_root
  
  detect_package_manager
  print_info "檢測到的包管理器：$package_manager"
  
  echo ""
  echo "您想要做什麼？"
  echo "1. 安裝 btop"
  echo "2. 更新 btop"
  echo "3. 卸載 btop"
  echo "4. 退出"
  read -p "請輸入選擇 [1-4]：" choice
  
  case $choice in
    1)
      if command -v btop &> /dev/null; then
        print_warning "btop 已安裝。請使用更新選項代替。"
        exit 0
      fi
      
      install_dependencies
      
      if install_from_package; then
        print_success "從包管理器成功安裝 btop。"
      else
        print_info "無法從包管理器安裝 btop。從源碼安裝中..."
        if install_from_source; then
          print_success "從源碼成功安裝 btop。"
        else
          print_error "安裝 btop 失敗。"
          exit 1
        fi
      fi
      
      print_usage_instructions
      ;;
      
    2)
      if ! command -v btop &> /dev/null; then
        print_warning "btop 未安裝。請使用安裝選項代替。"
        exit 0
      fi
      
      print_info "更新 btop..."
      case $package_manager in
        apt)
          apt-get update && apt-get install --only-upgrade -y btop
          ;;
        dnf)
          dnf update -y btop
          ;;
        yum)
          yum update -y btop
          ;;
        pacman)
          pacman -Syu --noconfirm btop
          ;;
        zypper)
          zypper update -y btop
          ;;
        apk)
          apk update && apk upgrade btop
          ;;
        *)
          print_info "從源碼更新..."
          uninstall_btop
          install_dependencies
          install_from_source
          ;;
      esac
      
      print_success "btop 已更新到最新版本。"
      ;;
      
    3)
      if ! command -v btop &> /dev/null; then
        print_warning "btop 未安裝。"
        exit 0
      fi
      
      uninstall_btop
      ;;
      
    4)
      print_info "退出。"
      exit 0
      ;;
      
    *)
      print_error "無效的選擇。請輸入 1 到 4 之間的數字。"
      exit 1
      ;;
  esac
}

# 執行主函數
main

