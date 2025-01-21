#!/bin/bash

# 1. 创建 to 文件夹
mkdir -p to
cd to

# 2. 下载原始脚本
wget https://raw.githubusercontent.com/R1tain/script/main/socat.py

# 3. 创建新的配置脚本
cat > config_socat.py << 'EOL'
#!/usr/bin/env python3
import subprocess
import os
import json
import sys

CONFIG_FILE = "socat_config.json"

def get_user_input():
    configs = []
    while True:
        config = {}
        print("\n=== 新增转发配置 ===")

        # 本地配置
        print("选择本地 IP 版本:")
        print("1. IPv4")
        print("2. IPv6")
        local_ip_ver = input("请选择 (1/2): ").strip()
        local_ip_type = "TCP4" if local_ip_ver == "1" else "TCP6"

        config["listen"] = input("请输入本机转发端口: ").strip()

        # 远端配置
        print("\n选择远端 IP 版本:")
        print("1. IPv4")
        print("2. IPv6")
        remote_ip_ver = input("请选择 (1/2): ").strip()
        remote_ip_type = "TCP4" if remote_ip_ver == "1" else "TCP6"

        remote_ip = input("请输入对端 IP: ").strip()
        remote_port = input("请输入对端端口: ").strip()
        config["target"] = f"{remote_ip}:{remote_port}"
        config["local_type"] = local_ip_type
        config["remote_type"] = remote_ip_type

        configs.append(config)

        if input("\n是否继续添加配置？(y/n): ").lower() != 'y':
            break

    return configs

def save_config(configs):
    with open(CONFIG_FILE, 'w') as f:
        json.dump(configs, f, indent=4)

def load_config():
    try:
        with open(CONFIG_FILE, 'r') as f:
            return json.load(f)
    except FileNotFoundError:
        return []

def check_socat_running(listen_port, target, local_type, remote_type):
    try:
        output = subprocess.check_output(["ps", "aux"]).decode()
        cmd = f"socat -T 30 {local_type}-LISTEN:{listen_port},reuseaddr,fork {remote_type}:{target}"
        return cmd in output
    except subprocess.CalledProcessError:
        return False

def start_socat(listen_port, target, local_type, remote_type):
    cmd = f"socat -T 30 {local_type}-LISTEN:{listen_port},reuseaddr,fork {remote_type}:{target} >> /dev/null 2>&1 &"
    os.system(cmd)

if __name__ == "__main__":
    # 检查是否为首次运行（通过命令行参数控制）
    if len(sys.argv) > 1 and sys.argv[1] == "--init":
        configs = get_user_input()
        save_config(configs)

    # 读取配置并运行
    configs = load_config()
    for config in configs:
        listen_port = config["listen"]
        target = config["target"]
        local_type = config["local_type"]
        remote_type = config["remote_type"]

        if not check_socat_running(listen_port, target, local_type, remote_type):
            print(f"socat 配置 {listen_port} -> {target} 未运行，正在启动...")
            start_socat(listen_port, target, local_type, remote_type)
        else:
            print(f"socat 配置 {listen_port} -> {target} 正在运行")
EOL

# 设置执行权限
chmod +x config_socat.py

# 首次运行配置
./config_socat.py --init

# 4. 创建 crontab 定时任务
(crontab -l 2>/dev/null; echo "* * * * * cd $(pwd) && ./config_socat.py") | crontab -

echo "设置和初始配置已完成！"
