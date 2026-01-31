#!/bin/bash

# ==============================================================================
# Bootstrap Script for Shorin Arch Setup
# ==============================================================================

# --- [配置区域] ---
# 支持环境变量配置
TARGET_BRANCH="${BRANCH:-main}"
REPO_URL="https://github.com/SHORiN-KiWATA/shorin-arch-setup.git"
DIR_NAME="shorin-arch-setup"

# 导出用户配置（供install.sh使用）
export SHORIN_USERNAME="${SHORIN_USERNAME:-}"
export SHORIN_PASSWORD="${SHORIN_PASSWORD:-}"
export DEBUG="${DEBUG:-0}"
export CN_MIRROR="${CN_MIRROR:-0}"

echo -e "\033[0;34m>>> Preparing to install from branch: $TARGET_BRANCH\033[0m"

# 显示配置信息
if [ -n "$SHORIN_USERNAME" ]; then
    echo -e "\033[0;32m>>> Username: $SHORIN_USERNAME (non-interactive mode)\033[0m"
fi
if [ -n "$SHORIN_PASSWORD" ]; then
    echo -e "\033[0;32m>>> Password: ******** (preset)\033[0m"
fi

# 1. 检查并安装 git
if ! command -v git &> /dev/null; then
    echo "Git not found. Installing..."
    # ISO环境下无需sudo，已安装系统需要sudo
    if [ "$EUID" -eq 0 ]; then
        pacman -Sy --noconfirm git
    else
        sudo pacman -Sy --noconfirm git
    fi
fi

# 2. 清理旧目录
if [ -d "$DIR_NAME" ]; then
    echo "Removing existing directory..."
    rm -rf "$DIR_NAME"
fi

# 3. 克隆指定分支 (-b 参数)
echo "Cloning repository..."
if git clone --depth 1 -b "$TARGET_BRANCH" "$REPO_URL"; then
    echo "Clone successful."
else
    echo -e "\033[0;31mError: Failed to clone branch '$TARGET_BRANCH'. Check if it exists.\033[0m"
    exit 1
fi

# 4. 运行安装
if [ -d "$DIR_NAME" ]; then
    cd "$DIR_NAME"
    echo "Starting installer..."
    
    # ISO环境下已是root，已安装系统需要sudo
    if [ "$EUID" -eq 0 ]; then
        bash install.sh
    else
        sudo bash install.sh
    fi
else
    echo "Error: Directory not found."
    exit 1
fi
