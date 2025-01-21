#!/usr/bin/env python3
import subprocess
import os

SOCAT_CONFIGS = [
    {
        "listen": "54321",
        "target": "141.147.180.25:55789"
    },
]

def check_socat_running(listen_port, target):
    try:
        output = subprocess.check_output(["ps", "aux"]).decode()
        return f"socat -T 30 TCP4-LISTEN:{listen_port},reuseaddr,fork TCP4:{target}" in output
    except subprocess.CalledProcessError:
        return False

def start_socat(listen_port, target):
    command = f"socat -T 30 TCP4-LISTEN:{listen_port},reuseaddr,fork TCP4:{target} >> /dev/null 2>&1 &"
    os.system(command)

if __name__ == "__main__":
    for config in SOCAT_CONFIGS:
        listen_port = config["listen"]
        target = config["target"]
        if not check_socat_running(listen_port, target):
            print(f"socat 配置 {listen_port} -> {target} 未运行，正在启动...")
            start_socat(listen_port, target)
        else:
            print(f"socat 配置 {listen_port} -> {target} 正在运行")
