#!/bin/bash

# ==============================================================================
# Bootstrap Script for Shorin Arch Setup
# ==============================================================================

set -Eeuo pipefail
trap 'echo "引导失败。请检查网络或仓库访问。"; exit 1' ERR

# --- [配置区域] ---
# 支持环境变量配置
TARGET_BRANCH="${BRANCH:-main}"
REPO_URL="https://github.com/2048TB/shorin-arch-setup.git"
DIR_NAME="shorin-arch-setup"

# 导出用户配置（供 scripts/install.sh 使用）
export SHORIN_USERNAME="${SHORIN_USERNAME:-}"
export SHORIN_PASSWORD="${SHORIN_PASSWORD:-}"
export ROOT_PASSWORD_HASH="${ROOT_PASSWORD_HASH:-}"
export DESKTOP_ENV="${DESKTOP_ENV:-}"
export TARGET_DISK="${TARGET_DISK:-}"
export BOOT_MODE="${BOOT_MODE:-}"
export CONFIRM_DISK_WIPE="${CONFIRM_DISK_WIPE:-}"
export SHORIN_CONFIG="${SHORIN_CONFIG:-}"
export STRICT_MODE="${STRICT_MODE:-1}"
export STRICT_MODE_ERR_TRAP="${STRICT_MODE_ERR_TRAP:-1}"
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
    echo "未找到 Git，正在安装..."
    # ISO环境下无需sudo，已安装系统需要sudo
    if [ "$EUID" -eq 0 ]; then
        pacman -Sy --noconfirm git
    else
        sudo pacman -Sy --noconfirm git
    fi
fi

# 2. 选择工作目录（ISO环境使用/root避免空间/权限问题）
WORK_DIR="$(pwd)"
if [ -d /run/archiso ] || [[ "$(findmnt / -o FSTYPE -n 2>/dev/null)" =~ ^(overlay|tmpfs|airootfs)$ ]]; then
    # ISO环境：使用/root（有足够空间和权限）
    WORK_DIR="/root"
    echo -e "\\033[0;33m>>> 检测到 ISO 环境，使用 $WORK_DIR\\033[0m"
fi

# 切换到工作目录
cd "$WORK_DIR" || {
    echo "切换到 $WORK_DIR 失败"
    exit 1
}

# 3. 强力清理旧目录/文件
if [ -e "$DIR_NAME" ]; then
    echo "正在移除已存在的 '$DIR_NAME'..."
    # 强制删除（可能是文件或目录）
    rm -rf "$DIR_NAME" 2>/dev/null || {
        echo "移除失败，尝试强制删除..."
        chmod -R 755 "$DIR_NAME" 2>/dev/null
        rm -rf "$DIR_NAME"
    }
fi

# 验证已清理
if [ -e "$DIR_NAME" ]; then
    echo -e "\\033[0;31m错误：无法移除已存在的 '$DIR_NAME'，请手动删除。\\033[0m"
    echo "运行：rm -rf $WORK_DIR/$DIR_NAME"
    exit 1
fi

# 4. 克隆指定分支 (-b 参数)
echo "正在克隆仓库到 $WORK_DIR/$DIR_NAME..."
if git clone --depth 1 -b "$TARGET_BRANCH" "$REPO_URL"; then
    echo "克隆成功。"
else
    echo -e "\033[0;31m错误：克隆分支 '$TARGET_BRANCH' 失败，请检查是否存在。\033[0m"
    exit 1
fi

# 5. 运行安装
if [ -d "$DIR_NAME" ]; then
    cd "$DIR_NAME" || exit 1
    echo "开始运行安装器..."
    
    # ISO环境下已是root，已安装系统需要sudo
    if [ "$EUID" -eq 0 ]; then
        bash scripts/install.sh
    else
        sudo bash scripts/install.sh
    fi
else
    echo "错误：目录不存在。"
    exit 1
fi
