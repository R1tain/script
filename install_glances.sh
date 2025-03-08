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
    package_manager="pip"
  fi
}

# 安裝依賴項
install_dependencies() {
  print_info "安裝必要的依賴項..."
  case $package_manager in
    apt)
      apt-get update
      apt-get install -y python3 python3-pip
      ;;
    dnf)
      dnf install -y python3 python3-pip
      ;;
    yum)
      yum install -y python3 python3-pip
      ;;
    pacman)
      pacman -S --noconfirm python python-pip
      ;;
    zypper)
      zypper install -y python3 python3-pip
      ;;
    apk)
      apk add python3 py3-pip
      ;;
    *)
      print_info "無法確定包管理器。將使用 pip 安裝。"
      ;;
  esac
}

# 安裝可選依賴項
install_optional_dependencies() {
  print_info "安裝選定的可選依賴項..."
  
  # 檢查 pip 命令
  if command -v pip3 &> /dev/null; then
    pip_cmd="pip3"
  elif command -v pip &> /dev/null; then
    pip_cmd="pip"
  else
    print_error "找不到 pip 或 pip3 命令。請先安裝 Python pip。"
    exit 1
  fi
  
  # 安裝 Docker 監控依賴
  if [ "$install_docker" = "y" ]; then
    print_info "安裝 Docker 監控依賴..."
    $pip_cmd install docker
  fi
  
  # 安裝電池監控依賴
  if [ "$install_battery" = "y" ]; then
    print_info "安裝電池監控依賴..."
    $pip_cmd install batinfo
  fi
  
  # 安裝 Riemann 匯出模組
  if [ "$install_riemann" = "y" ]; then
    print_info "安裝 Riemann 匯出模組..."
    $pip_cmd install bernhard
  fi
  
  # 安裝 Cassandra 匯出模組
  if [ "$install_cassandra" = "y" ]; then
    print_info "安裝 Cassandra 匯出模組..."
    $pip_cmd install cassandra-driver
  fi
  
  # 安裝動作腳本功能
  if [ "$install_action" = "y" ]; then
    print_info "安裝動作腳本功能依賴..."
    $pip_cmd install chevron
  fi
}

# 從包管理器安裝 Glances
install_from_package() {
  print_info "嘗試從包管理器安裝 Glances..."
  case $package_manager in
    apt)
      apt-get install -y glances
      ;;
    dnf)
      dnf install -y glances
      ;;
    yum)
      yum install -y glances
      ;;
    pacman)
      pacman -S --noconfirm glances
      ;;
    zypper)
      zypper install -y glances
      ;;
    apk)
      apk add glances
      ;;
    *)
      return 1
      ;;
  esac
  
  if command -v glances &> /dev/null; then
    return 0
  else
    return 1
  fi
}

# 從 pip 安裝 Glances
install_from_pip() {
  print_info "從 pip 安裝 Glances..."
  
  # 檢查 pip 命令
  if command -v pip3 &> /dev/null; then
    pip_cmd="pip3"
  elif command -v pip &> /dev/null; then
    pip_cmd="pip"
  else
    print_error "找不到 pip 或 pip3 命令。請先安裝 Python pip。"
    exit 1
  fi
  
  # 安裝基本版本
  $pip_cmd install --upgrade glances
  
  # 如果安裝了 Docker 依賴，不需要在此處再次安裝
  modules="action,browser,cloud,cpuinfo,export,folders,gpu,graph,ip,raid,snmp,web,wifi"
  if [ "$install_docker" != "y" ]; then
    modules="$modules,docker"
  fi
  
  # 安裝可選依賴
  print_info "安裝額外的功能模組..."
  $pip_cmd install --upgrade "glances[$modules]"
  
  if command -v glances &> /dev/null; then
    return 0
  else
    return 1
  fi
}

# 卸載 Glances
uninstall_glances() {
  print_info "卸載 Glances..."
  
  # 先嘗試從包管理器卸載
  case $package_manager in
    apt)
      apt-get remove -y glances
      ;;
    dnf)
      dnf remove -y glances
      ;;
    yum)
      yum remove -y glances
      ;;
    pacman)
      pacman -R --noconfirm glances
      ;;
    zypper)
      zypper remove -y glances
      ;;
    apk)
      apk del glances
      ;;
  esac
  
  # 然後嘗試從 pip 卸載
  if command -v pip3 &> /dev/null; then
    pip3 uninstall -y glances
  elif command -v pip &> /dev/null; then
    pip uninstall -y glances
  fi
  
  if command -v glances &> /dev/null; then
    print_warning "Glances 仍可在系統中找到。它可能安裝在不同的位置。"
    return 1
  else
    print_success "Glances 已成功卸載。"
    return 0
  fi
}

# 更新 Glances
update_glances() {
  print_info "更新 Glances..."
  
  # 檢查當前安裝方式
  if command -v apt &> /dev/null && apt list --installed 2>/dev/null | grep -q "glances"; then
    apt-get update && apt-get install --only-upgrade -y glances
  elif command -v dnf &> /dev/null && dnf list installed glances &>/dev/null; then
    dnf update -y glances
  elif command -v yum &> /dev/null && yum list installed glances &>/dev/null; then
    yum update -y glances
  elif command -v pacman &> /dev/null && pacman -Q glances &>/dev/null; then
    pacman -Syu --noconfirm glances
  elif command -v zypper &> /dev/null && zypper search -i glances &>/dev/null; then
    zypper update -y glances
  elif command -v apk &> /dev/null && apk info -e glances &>/dev/null; then
    apk update && apk upgrade glances
  else
    # 從 pip 更新
    if command -v pip3 &> /dev/null; then
      pip3 install --upgrade glances
      pip3 install --upgrade "glances[action,browser,cloud,cpuinfo,docker,export,folders,gpu,graph,ip,raid,snmp,web,wifi]"
    elif command -v pip &> /dev/null; then
      pip install --upgrade glances
      pip install --upgrade "glances[action,browser,cloud,cpuinfo,docker,export,folders,gpu,graph,ip,raid,snmp,web,wifi]"
    else
      print_error "無法更新 Glances，請先安裝它。"
      return 1
    fi
  fi
  
  print_success "Glances 已更新到最新版本。"
  return 0
}

# 顯示使用說明
print_usage_instructions() {
  print_success "Glances 已成功安裝！"
  echo ""
  echo "---------------------------------------------"
  echo "            GLANCES 使用指南                  "
  echo "---------------------------------------------"
  echo ""
  echo "基本命令："
  echo "  glances                    以標準模式啟動 Glances"
  echo "  glances -w                 啟動 Web 伺服器模式 (訪問 http://IP:61208/)"
  echo "  glances -s                 啟動伺服器模式"
  echo "  glances -c IP地址          以客戶端模式連接到伺服器"
  echo "  glances --browser          在瀏覽器中打開 Glances Web 界面"
  echo "  glances -t 5               每 5 秒刷新一次 (默認為 2 秒)"
  echo "  glances --export influxdb  將資料導出到 InfluxDB"
  echo ""
  echo "監控 Docker："
  echo "  Glances 會自動檢測並顯示 Docker 容器信息"
  echo "  在 Glances 界面中按下 'D' 鍵切換 Docker 容器視圖"
  echo "  在 Web 界面中，Docker 容器信息會顯示在獨立的面板中"
  echo ""
  echo "鍵盤快捷鍵（運行 Glances 時）："
  echo "  q 或 ESC 或 CTRL-C        退出"
  echo "  F1 或 h                   顯示幫助"
  echo "  D                         顯示/隱藏 Docker 容器信息"
  echo "  1                         切換 CPU 統計"
  echo "  2                         切換 GPU 統計"
  echo "  3                         切換 MEM 統計"
  echo "  4                         切換 NET 統計"
  echo "  5                         切換磁碟 IO 統計"
  echo "  6                         切換檔案系統統計"
  echo "  d                         顯示/隱藏磁碟 IO 統計"
  echo "  f                         顯示/隱藏檔案系統統計"
  echo "  p                         按 CPU/MEM 排序進程"
  echo "  m                         按內存使用量排序進程"
  echo "  i                         按 IO 速率排序進程"
  echo "  a                         自動排序進程"
  echo ""
  echo "更多信息和選項，請訪問："
  echo "https://github.com/nicolargo/glances"
  echo ""
}

# 主函數
main() {
  print_info "Glances 安裝腳本"
  
  check_root
  
  detect_package_manager
  print_info "檢測到的包管理器：$package_manager"
  
  echo ""
  echo "您想要做什麼？"
  echo "1. 安裝 Glances"
  echo "2. 更新 Glances"
  echo "3. 卸載 Glances"
  echo "4. 退出"
  read -p "請輸入選擇 [1-4]：" choice
  
  case $choice in
    1)
      if command -v glances &> /dev/null; then
        print_warning "Glances 已安裝。請使用更新選項代替。"
        exit 0
      fi
      
      # 詢問可選依賴
      echo ""
      echo "選擇要安裝的可選依賴："
      read -p "安裝 Docker 監控支持? (y/n): " install_docker
      read -p "安裝電池監控支持? (y/n): " install_battery
      read -p "安裝 Riemann 匯出模組? (y/n): " install_riemann
      read -p "安裝 Cassandra 匯出模組? (y/n): " install_cassandra
      read -p "安裝動作腳本功能? (y/n): " install_action
      
      install_dependencies
      install_optional_dependencies
      
      if [ "$package_manager" != "pip" ] && install_from_package; then
        print_success "從包管理器成功安裝 Glances。"
      else
        print_info "從 pip 安裝 Glances..."
        if install_from_pip; then
          print_success "從 pip 成功安裝 Glances。"
        else
          print_error "安裝 Glances 失敗。"
          exit 1
        fi
      fi
      
      print_usage_instructions
      ;;
      
    2)
      if ! command -v glances &> /dev/null; then
        print_warning "Glances 未安裝。請使用安裝選項代替。"
        exit 0
      fi
      
      update_glances
      ;;
      
    3)
      if ! command -v glances &> /dev/null; then
        print_warning "Glances 未安裝。"
        exit 0
      fi
      
      uninstall_glances
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
