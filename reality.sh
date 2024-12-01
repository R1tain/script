#!/bin/bash

# 顏色定義
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

# 檢查 root 權限
[[ $EUID -ne 0 ]] && echo -e "${RED}請以 root 身份運行！${PLAIN}" && exit 1

# 檢查包管理器並安裝必要套件
install_base_packages() {
    if command -v apt &>/dev/null; then
        apt update
        apt install -y curl wget unzip tar openssl
    elif command -v apk &>/dev/null; then
        apk update
        apk add curl wget unzip tar openssl bash
    else
        echo -e "${RED}不支持的系統！${PLAIN}"
        exit 1
    fi
}

# 檢查 curl 命令
if ! command -v curl &>/dev/null; then
    echo "curl 未安裝，正在安裝..."
    install_base_packages
fi

# 初始化變量
SING_BOX_PATH="/usr/local/bin/sing-box"
CONFIG_PATH="/usr/local/etc/sing-box/config.json"

# 安裝 sing-box
install_sing_box() {
    echo -e "${GREEN}開始安裝 sing-box...${PLAIN}"
    
    # 請求用戶輸入端口
    while true; do
        read -p "請輸入連接端口 (1-65535): " port
        if [[ ! $port =~ ^[0-9]+$ ]]; then
            echo -e "${RED}請輸入有效的數字！${PLAIN}"
            continue
        elif [ $port -lt 1 ] || [ $port -gt 65535 ]; then
            echo -e "${RED}端口範圍無效，請輸入 1-65535 之間的數字！${PLAIN}"
            continue
        elif [ $port -lt 1024 ] && [ $port -ne 443 ]; then
            echo -e "${YELLOW}警告：使用 1024 以下的端口可能需要 root 權限${PLAIN}"
        fi
        
        # 檢查端口是否已被使用
        if netstat -tuln 2>/dev/null | grep -q ":$port " || ss -tuln 2>/dev/null | grep -q ":$port "; then
            echo -e "${RED}端口 $port 已被使用，請選擇其他端口！${PLAIN}"
            continue
        fi
        break
    done

    # 檢查系統架構
    case $(uname -m) in
        x86_64)  ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        *)
            echo -e "${RED}不支持的系統架構！${PLAIN}"
            exit 1
        ;;
    esac

    # 安裝依賴
    install_base_packages

    # 下載最新版本
    TMP_DIR=$(mktemp -d)
    cd "$TMP_DIR"
    
    VERSION=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | grep -Po '"tag_name": "\K.*?(?=")')
    if [[ -z "$VERSION" ]]; then
        echo -e "${RED}無法獲取版本信息！${PLAIN}"
        exit 1
    fi

    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${VERSION}/sing-box-${VERSION#v}-linux-${ARCH}.tar.gz"
    echo -e "${YELLOW}下載地址: ${DOWNLOAD_URL}${PLAIN}"

    if ! wget -q --show-progress "$DOWNLOAD_URL"; then
        echo -e "${RED}下載失敗！${PLAIN}"
        exit 1
    fi

    tar -xf "sing-box-${VERSION#v}-linux-${ARCH}.tar.gz"
    cd "sing-box-${VERSION#v}-linux-${ARCH}"

    # 安裝文件
    install -m 755 sing-box /usr/local/bin/
    mkdir -p /usr/local/etc/sing-box
    mkdir -p /var/log/sing-box

    # 生成密鑰對
    keys=$($SING_BOX_PATH generate reality-keypair)
    private_key=$(echo $keys | awk -F " " '{print $2}')
    public_key=$(echo $keys | awk -F " " '{print $4}')

    # 生成 UUID
    uuid=$($SING_BOX_PATH generate uuid)
    
    # 生成短 ID
    short_id=$(openssl rand -hex 8)

    # 創建服務文件
    if command -v systemctl &>/dev/null; then
        cat > /etc/systemd/system/sing-box.service << EOF
[Unit]
Description=sing-box Service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c /usr/local/etc/sing-box/config.json
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    else
        # Alpine Linux 使用 OpenRC
        cat > /etc/init.d/sing-box << EOF
#!/sbin/openrc-run

name="sing-box"
description="Sing-box Service"
command="/usr/local/bin/sing-box"
command_args="run -c /usr/local/etc/sing-box/config.json"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"

depend() {
    need net
    after firewall
}
EOF
        chmod +x /etc/init.d/sing-box
    fi

    # 創建配置文件
    cat > $CONFIG_PATH << EOF
{
    "log": {
        "level": "error",
        "timestamp": true
    },
    "inbounds": [
        {
            "type": "vless",
            "tag": "vless-in",
            "listen": "::",
            "listen_port": ${port},
            "users": [
                {
                    "name": "default",
                    "uuid": "${uuid}",
                    "flow": "xtls-rprx-vision"
                }
            ],
            "tls": {
                "enabled": true,
                "server_name": "gateway.icloud.com",
                "reality": {
                    "enabled": true,
                    "handshake": {
                        "server": "gateway.icloud.com",
                        "server_port": 443
                    },
                    "private_key": "${private_key}",
                    "short_id": [
                        "${short_id}"
                    ]
                }
            }
        }
    ],
    "outbounds": [
        {
            "type": "direct",
            "tag": "direct"
        }
    ]
}
EOF

    # 設置服務
    if command -v systemctl &>/dev/null; then
        systemctl daemon-reload
        systemctl enable sing-box
        systemctl start sing-box
    else
        rc-update add sing-box default
        rc-service sing-box start
    fi

    # 清理臨時文件
    cd
    rm -rf "$TMP_DIR"

    # 獲取服務器 IP
    IP=$(curl -s4m8 ip.sb || curl -s6m8 ip.sb)

    # 生成分享連結，根據 IP 類型決定格式
    if [[ $IP =~ ":" ]]; then
    # IPv6 地址需要加方括號
    VLESS_LINK="vless://${uuid}@[${IP}]:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=gateway.icloud.com&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#Sing-Box-Reality"
    else
    # IPv4 地址不需要加方括號
    VLESS_LINK="vless://${uuid}@${IP}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=gateway.icloud.com&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none#Sing-Box-Reality"
    fi

    echo -e "${GREEN}安裝完成！${PLAIN}"
    echo -e "${GREEN}端口: ${port}${PLAIN}"
    echo -e "${GREEN}UUID: ${uuid}${PLAIN}"
    echo -e "${GREEN}Public Key: ${public_key}${PLAIN}"
    echo -e "${GREEN}Short ID: ${short_id}${PLAIN}"
    echo -e "${GREEN}分享鏈接: ${VLESS_LINK}${PLAIN}"
}

# 更新密鑰
update_keys() {
    if [ ! -f $CONFIG_PATH ]; then
        echo -e "${RED}配置文件不存在！${PLAIN}"
        return 1
    fi

    echo -e "${GREEN}正在生成新的密鑰對...${PLAIN}"
    keys=$($SING_BOX_PATH generate reality-keypair)
    private_key=$(echo $keys | awk -F " " '{print $2}')
    public_key=$(echo $keys | awk -F " " '{print $4}')

    # 備份配置
    cp $CONFIG_PATH "${CONFIG_PATH}.bak"

    # 更新配置
    sed -i "s/\"private_key\": \"[^\"]*\"/\"private_key\": \"$private_key\"/" $CONFIG_PATH

    # 重啟服務
    if command -v systemctl &>/dev/null; then
        systemctl restart sing-box
    else
        rc-service sing-box restart
    fi

    if pgrep sing-box >/dev/null; then
        echo -e "${GREEN}密鑰更新成功！${PLAIN}"
        echo -e "${GREEN}新的 Public Key: ${public_key}${PLAIN}"
    else
        echo -e "${RED}服務重啟失敗！${PLAIN}"
        mv "${CONFIG_PATH}.bak" $CONFIG_PATH
        if command -v systemctl &>/dev/null; then
            systemctl restart sing-box
        else
            rc-service sing-box restart
        fi
        echo -e "${YELLOW}已還原配置${PLAIN}"
    fi
}

# 卸載
uninstall() {
    echo -e "${YELLOW}正在卸載 sing-box...${PLAIN}"
    if command -v systemctl &>/dev/null; then
        systemctl stop sing-box
        systemctl disable sing-box
        rm -f /etc/systemd/system/sing-box.service
        systemctl daemon-reload
    else
        rc-service sing-box stop
        rc-update del sing-box default
        rm -f /etc/init.d/sing-box
    fi
    rm -f $SING_BOX_PATH
    rm -rf /usr/local/etc/sing-box
    rm -rf /var/log/sing-box
    echo -e "${GREEN}卸載完成！${PLAIN}"
}

# 顯示菜單
show_menu() {
    echo -e "
  ${GREEN}Sing-box Reality 管理腳本${PLAIN}
  ${GREEN}1.${PLAIN} 安裝
  ${GREEN}2.${PLAIN} 更新密鑰
  ${GREEN}3.${PLAIN} 卸載
  ${GREEN}0.${PLAIN} 退出
  "
    echo && read -p "請輸入選擇 [0-3]: " num

    case "${num}" in
        1) install_sing_box ;;
        2) update_keys ;;
        3) uninstall ;;
        0) exit 0 ;;
        *) echo -e "${RED}請輸入正確數字 [0-3]${PLAIN}" ;;
    esac
}

# 主程序
show_menu
