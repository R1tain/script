#!/usr/bin/env python3
import subprocess
import os
import json
import sys
import time
from datetime import datetime, timedelta
import platform

CONFIG_FILE = "socat.json"
LOG_FILE = "socat.log"
LOG_MAX_DAYS = 1

def get_os_info():
    """获取操作系统信息"""
    os_info = {
        "os_type": "",
        "package_manager": "",
        "install_cmd": "",
    }

    try:
        # 检查 /etc/os-release
        if os.path.exists('/etc/os-release'):
            with open('/etc/os-release', 'r') as f:
                os_release = f.read().lower()
                if 'debian' in os_release or 'ubuntu' in os_release or 'armbian' in os_release:
                    os_info["os_type"] = "debian"
                    os_info["package_manager"] = "apt"
                    os_info["install_cmd"] = "apt-get update && apt-get install -y"
                elif 'almalinux' in os_release or 'centos' in os_release or 'oracle' in os_release:
                    os_info["os_type"] = "rhel"
                    os_info["package_manager"] = "yum"
                    os_info["install_cmd"] = "yum install -y"

        # 检查 Alpine Linux
        if os.path.exists('/etc/alpine-release'):
            os_info["os_type"] = "alpine"
            os_info["package_manager"] = "apk"
            os_info["install_cmd"] = "apk add --no-cache"

        return os_info
    except Exception as e:
        print(f"获取系统信息失败：{e}")
        return None

def install_socat():
    """安装 socat"""
    print("正在安装 socat...")
    os_info = get_os_info()

    if not os_info:
        print("无法确定系统类型，请手动安装 socat")
        return False

    try:
        if os_info["os_type"] == "debian":
            subprocess.run("apt-get update", shell=True, check=True)
            subprocess.run("apt-get install -y socat", shell=True, check=True)
        elif os_info["os_type"] == "rhel":
            subprocess.run("yum install -y socat", shell=True, check=True)
        elif os_info["os_type"] == "alpine":
            subprocess.run("apk add --no-cache socat", shell=True, check=True)
        else:
            print("不支持的系统类型")
            return False

        print("socat 安装成功！")
        return True
    except subprocess.CalledProcessError as e:
        print(f"安装 socat 失败：{e}")
        return False

def clean_old_logs():
    """清理旧的日志文件"""
    try:
        if os.path.exists(LOG_FILE):
            file_mtime = datetime.fromtimestamp(os.path.getmtime(LOG_FILE))
            if datetime.now() - file_mtime > timedelta(days=LOG_MAX_DAYS):
                open(LOG_FILE, 'w').close()
                print(f"日志文件已清空：{LOG_FILE}")
    except Exception as e:
        print(f"清理日志文件时出错：{e}")

def check_socat_installed():
    """检查 socat 是否已安装"""
    try:
        subprocess.run(["which", "socat"], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return True
    except subprocess.CalledProcessError:
        return False

def get_user_input():
    """获取用户输入的转发配置"""
    configs = []
    while True:
        config = {}
        print("\n=== 新增转发配置 ===")

        print("选择本地 IP 版本:")
        print("1. IPv4")
        print("2. IPv6")
        local_ip_ver = input("请选择 (1/2): ").strip()
        local_ip_type = "TCP4" if local_ip_ver == "1" else "TCP6"

        config["listen"] = input("请输入本机转发端口: ").strip()

        print("\n选择远端 IP 版本:")
        print("1. IPv4")
        print("2. IPv6")
        remote_ip_ver = input("请选择 (1/2): ").strip()
        remote_ip_type = "TCP4" if remote_ip_ver == "1" else "TCP6"

        remote_ip = input("请输入对端 IP: ").strip()
        remote_port = input("请输入对端端口: ").strip()

        # 如果是 IPv6 地址，需要加上方括号
        if remote_ip_ver == "2":
            # 移除可能已存在的方括号
            remote_ip = remote_ip.replace('[', '').replace(']', '')
            # 添加方括号
            remote_ip = f"[{remote_ip}]"

        config["target"] = f"{remote_ip}:{remote_port}"
        config["local_type"] = local_ip_type
        config["remote_type"] = remote_ip_type

        configs.append(config)

        if input("\n是否继续添加配置？(y/n): ").lower() != 'y':
            break

    return configs

def save_config(configs):
    """保存配置到文件"""
    with open(CONFIG_FILE, 'w') as f:
        json.dump(configs, f, indent=4)

def load_config():
    """从文件加载配置"""
    try:
        with open(CONFIG_FILE, 'r') as f:
            return json.load(f)
    except FileNotFoundError:
        return []

def check_socat_running(listen_port, target, local_type, remote_type):
    """检查指定的 socat 转发是否正在运行"""
    try:
        # 处理 target 中的方括号，避免 grep 命令出错
        escaped_target = target.replace('[', '\\[').replace(']', '\\]')
        cmd = f"pgrep -f 'socat.*{listen_port}.*{escaped_target}'"
        result = subprocess.run(cmd, shell=True)
        return result.returncode == 0
    except subprocess.CalledProcessError:
        return False

def start_socat(listen_port, target, local_type, remote_type):
    """启动 socat 转发"""
    # 在启动新的 socat 之前清理旧日志
    clean_old_logs()

    cmd = f"nohup socat -T 30 {local_type}-LISTEN:{listen_port},reuseaddr,fork {remote_type}:{target} >> {LOG_FILE} 2>&1 &"

    try:
        subprocess.run(cmd, shell=True, check=True)
        time.sleep(1)

        # 使用转义后的 target 进行检查
        escaped_target = target.replace('[', '\\[').replace(']', '\\]')
        check_cmd = f"pgrep -f 'socat.*{listen_port}.*{escaped_target}'"
        result = subprocess.run(check_cmd, shell=True)

        if result.returncode == 0:
            print(f"socat 成功启动：{listen_port} -> {target}")
        else:
            print(f"socat 启动失败，请检查 {LOG_FILE} 文件")
            try:
                with open(LOG_FILE, "r") as f:
                    print("错误日志：")
                    print(f.read())
            except:
                pass
    except subprocess.CalledProcessError as e:
        print(f"启动错误：{e}")

def check_root():
    """检查是否以 root 权限运行"""
    return os.geteuid() == 0

def setup_log_rotation():
    """设置日志轮转"""
    os_info = get_os_info()
    if not os_info:
        print("无法设置日志轮转")
        return

    cron_job = f"0 0 * * * root truncate -s 0 {os.path.abspath(LOG_FILE)}"

    try:
        if os_info["os_type"] in ["debian", "rhel"]:
            cron_file = "/etc/cron.d/socat_log_rotation"
            with open(cron_file, 'w') as f:
                f.write(cron_job + "\n")
            os.chmod(cron_file, 0o644)
        elif os_info["os_type"] == "alpine":
            cron_file = "/etc/crontabs/root"
            if os.path.exists(cron_file):
                with open(cron_file, 'a') as f:
                    f.write(cron_job + "\n")
            else:
                with open(cron_file, 'w') as f:
                    f.write(cron_job + "\n")
            os.chmod(cron_file, 0o600)
            subprocess.run("rc-service crond restart", shell=True, check=True)

        print("已设置日志自动清理（每天零点）")
    except Exception as e:
        print(f"设置日志轮转失败：{e}")

def show_help():
    """显示帮助信息"""
    print("""
使用方法：
    首次配置：sudo ./socat.py --init
    启动服务：sudo ./socat.py
    显示帮助：sudo ./socat.py --help

选项：
    --init    首次运行，配置转发规则
    --help    显示此帮助信息
    """)

if __name__ == "__main__":
    # 检查命令行参数
    if len(sys.argv) > 1 and sys.argv[1] == "--help":
        show_help()
        sys.exit(0)

    # 检查 root 权限
    if not check_root():
        print("错误：请使用 root 权限运行此脚本")
        sys.exit(1)

    # 获取系统信息
    os_info = get_os_info()
    if not os_info:
        print("无法确定系统类型，退出")
        sys.exit(1)

    print(f"检测到系统类型：{os_info['os_type']}")

    # 检查并安装 socat
    if not check_socat_installed():
        print("未找到 socat，正在尝试安装...")
        if not install_socat():
            print("socat 安装失败，请手动安装")
            sys.exit(1)

    # 设置日志轮转
    setup_log_rotation()

    # 检查是否为首次运行
    if len(sys.argv) > 1 and sys.argv[1] == "--init":
        configs = get_user_input()
        save_config(configs)

    # 读取配置并运行
    configs = load_config()
    if not configs:
        print("未找到配置文件，请先运行：./socat.py --init")
        sys.exit(1)

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
