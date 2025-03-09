#!/bin/bash
# FastFileServer一键安装脚本
# 适用于GitHub项目：https://github.com/R1tain/file-web-Transmission

# 设置颜色代码
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # 无颜色

# 显示欢迎信息
echo -e "${GREEN}=====================================================${NC}"
echo -e "${GREEN}       FastFileServer 一键安装脚本                   ${NC}"
echo -e "${GREEN}=====================================================${NC}"
echo ""

# 检查是否为root用户
if [ "$(id -u)" -eq 0 ]; then
    echo -e "${YELLOW}提示: 您正在使用root用户运行此脚本${NC}"
fi

# 检查系统要求
echo -e "${GREEN}[步骤1] 检查系统环境...${NC}"

# 检查git是否安装
if ! command -v git &> /dev/null; then
    echo -e "${YELLOW}Git未安装，正在安装...${NC}"
    if command -v apt &> /dev/null; then
        sudo apt update
        sudo apt install -y git
    elif command -v yum &> /dev/null; then
        sudo yum install -y git
    else
        echo -e "${RED}无法安装Git，请手动安装后重试${NC}"
        exit 1
    fi
fi
echo -e "${GREEN}✓ Git已安装${NC}"

# 检查Python是否安装
if ! command -v python3 &> /dev/null; then
    echo -e "${YELLOW}Python3未安装，正在安装...${NC}"
    if command -v apt &> /dev/null; then
        sudo apt update
        sudo apt install -y python3 python3-pip
    elif command -v yum &> /dev/null; then
        sudo yum install -y python3 python3-pip
    else
        echo -e "${RED}无法安装Python3，请手动安装后重试${NC}"
        exit 1
    fi
fi
echo -e "${GREEN}✓ Python3已安装${NC}"

# 创建安装目录
echo -e "${GREEN}[步骤2] 准备安装目录...${NC}"
INSTALL_DIR="$HOME/fastfileserver"
mkdir -p "$INSTALL_DIR"
echo -e "${GREEN}✓ 安装目录已创建: $INSTALL_DIR${NC}"

# 克隆仓库
echo -e "${GREEN}[步骤3] 克隆项目仓库...${NC}"
git clone https://github.com/R1tain/file-web-Transmission.git "$INSTALL_DIR/repo"
if [ $? -ne 0 ]; then
    echo -e "${RED}克隆仓库失败，请检查网络连接或GitHub地址${NC}"
    exit 1
fi
echo -e "${GREEN}✓ 代码已成功克隆${NC}"

# 安装依赖
echo -e "${GREEN}[步骤4] 安装依赖...${NC}"
cd "$INSTALL_DIR/repo"
if [ -f "requirements.txt" ]; then
    pip3 install -r requirements.txt
    if [ $? -ne 0 ]; then
        echo -e "${YELLOW}警告: 依赖安装可能不完整，但将继续执行${NC}"
    else
        echo -e "${GREEN}✓ 依赖已安装${NC}"
    fi
else
    echo -e "${YELLOW}未找到requirements.txt文件，跳过依赖安装${NC}"
fi

# 创建uploads目录
echo -e "${GREEN}[步骤5] 创建上传目录...${NC}"
mkdir -p "$INSTALL_DIR/repo/uploads"
echo -e "${GREEN}✓ 上传目录已创建${NC}"

echo ""
echo -e "${GREEN}=====================================================${NC}"
echo -e "${GREEN}       安装完成                                      ${NC}"
echo -e "${GREEN}=====================================================${NC}"
echo ""
echo -e "使用方法:"
echo -e "1. 进入项目目录: ${GREEN}cd $INSTALL_DIR/repo${NC}"
echo -e "2. 启动服务器: ${GREEN}python3 file_server.py${NC}"
echo -e "3. 启动后访问地址: ${GREEN}http://localhost:55673/${NC}"
echo -e "4. 上传的文件将保存在: ${GREEN}$INSTALL_DIR/repo/uploads/${NC}"
echo ""
echo -e "要更改端口，请编辑file_server.py文件中的PORT变量"
echo -e "${YELLOW}感谢使用FastFileServer!${NC}"
