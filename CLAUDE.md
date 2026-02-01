# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**最后更新**: 2026-02-01 | **版本**: v2.2.0

## 项目概述

Shorin Arch Setup - Arch Linux 自动化安装系统，**固定Niri桌面环境自动部署**。采用模块化bash脚本架构，包含智能环境检测、自动分区、状态管理、快照恢复。

## 核心架构

### 执行流程
```
[ISO环境]
scripts/strap.sh → scripts/install.sh → 00-arch-base-install.sh
  → 磁盘选择菜单（交互式/环境变量）
  → 磁盘状态检测（空盘/有数据/系统盘）
  → 双重确认机制
  → pacstrap → arch-chroot → continue-install.sh
  → scripts/install.sh (SKIP_BASE_INSTALL=1) → modules.sh

[已安装系统]
scripts/strap.sh → scripts/install.sh → modules.sh
```

### 关键组件

**scripts/install.sh** - 主控制器
- **固定Niri桌面环境**（移除选择菜单）
- 状态文件管理（`/var/lib/shorin/install_state`，兼容旧 `.install_progress`）
- 模块动态加载
- 使用默认镜像（移除Reflector）
- 全局清理与快照管理

**scripts/00-utils.sh** - 工具函数库
- ANSI颜色系统（`H_RED`, `H_GREEN`等）
- 日志函数（`log`, `success`, `warn`, `error`）
- `exe()` - 命令执行封装
- `detect_target_user()` - 用户检测
- `install_yay_package()` - Yay包安装
- `fzf_select_apps()` - FZF交互菜单

**scripts/00-arch-base-install.sh** - ISO基础安装
- ISO环境检测
- GPT分区（EFI 512M + Btrfs）
- Btrfs子卷（@, @home, @snapshots, @log, @cache）
- pacstrap + genfstab + arch-chroot
- GRUB引导安装

**scripts/modules.sh** - 模块集合
```
00-btrfs-init.sh      → Btrfs快照初始化
01-base.sh            → 基础系统（字体、可选archlinuxcn/AUR）
02-musthave.sh        → 必备软件（音频/输入法/蓝牙/Flatpak）
02a-dualboot-fix.sh   → 双系统修复
03-user.sh            → 用户创建 + configs部署
03b-gpu-driver.sh     → GPU驱动
03c-snapshot-before-desktop.sh → 桌面前快照
04-niri-setup.sh      → Niri桌面（自动安装48个依赖，启用TTY登录）
99-apps.sh            → 应用批量安装（自动安装93个应用）
```

### 状态管理

**恢复能力**
- 模块成功后写入 `/var/lib/shorin/install_state`
- 重新运行自动跳过已完成步骤

**快照策略**
- 清理中间pre/post快照
- 保留白名单标记快照
- 支持root + home双分区

## 代码质量规范

### 常量定义
- **scripts/install.sh**: 7个常量（超时、退出码）
- **00-utils.sh**: 2个常量（LOG_FILE_PERMISSIONS, TARGET_USER_UID）
- **00-arch-base-install.sh**: 5个常量（分区大小、最小磁盘）

### 函数规范
- 函数长度≤50行
- 嵌套深度≤3层
- 单一职责原则（SRP）
- 工具函数集中在 00-utils.sh

### 代码去重
- 包管理: `install_yay_package()`, `is_package_installed()`
- 交互菜单: `fzf_select_apps()`
- 用户检测: `detect_target_user()`

## 安全性与错误处理

### Strict Mode
- 所有脚本启用 `set -Eeuo pipefail`
- read命令失败安全退出
- 可通过 `STRICT_MODE=0` 禁用

### 输入验证
- TARGET_DISK 必填检查（ISO模式，可用 REQUIRE_TARGET_DISK=1 强制）
- ROOT_PASSWORD_HASH 格式验证（`$id$...`）
- 磁盘大小检查（最小20GB）
- 设备类型检查（mmcblk/nvme/sata）

### 错误恢复
- GRUB安装失败立即退出
- 模块失败显示重试命令
- chpasswd失败详细提示

### 密码安全
- 使用 `printf '%s:%s\n'` 避免特殊字符问题
- chroot环境变量安全传递（`printf %q`）

## 配置部署

**niri-dotfiles/** - Niri完整配置
- 部署时机：modules.sh → 04-niri-setup
- Shell配置：.zshrc, .bashrc, .vimrc
- 应用配置：niri, waybar, fuzzel, mako, ghostty, yazi, starship
- 主题资源：.themes, wallpapers
- 复制方式：`copy_recursive()` 智能递归（穿透.config/.local）

## 智能磁盘选择

### 功能特性
- **自动扫描** - 检测所有≥20GB的硬盘
- **智能过滤** - 排除光驱，警告USB设备
- **状态检测** - 区分三种状态：
  - ✓ EMPTY - 空盘（绿色）
  - ⚠ DATA - 有分区但非系统盘（黄色）
  - ⚠ SYSTEM - 有挂载点的系统盘（红色）
- **详细信息** - 显示型号/容量/类型（SSD/HDD）/接口（NVMe/SATA/USB）
- **安全确认**：
  - 空盘/数据盘：输入 `yes`
  - 系统盘：必须输入完整磁盘名（如 `/dev/nvme0n1`）
- **超时处理** - 60秒无操作自动选择第一块盘

### 使用示例

**交互式模式**（推荐新手）：
```bash
# 不指定TARGET_DISK，自动显示菜单
bash <(curl -L https://raw.githubusercontent.com/2048TB/shorin-arch-setup/main/scripts/strap.sh)

# 菜单示例：
# ╭────────────────────────────────────────────────────────────────────────
# │ Select Target Disk (ALL DATA WILL BE ERASED):
# │
# │  [1] /dev/nvme0n1    476.9G
# │      Samsung SSD 980 PRO 500GB   SSD NVMe ✓ EMPTY
# │
# │  [2] /dev/sda        931.5G
# │      WDC WD10EZEX-08WN4A0         HDD SATA ⚠ DATA
# │
# ╰────────────────────────────────────────────────────────────────────────
```

**零交互模式**（自动化部署）：
```bash
TARGET_DISK=/dev/nvme0n1 \
CONFIRM_DISK_WIPE=YES \
  bash <(curl -L ...)
```

**系统盘安全机制**：
- 检测到系统盘时，需输入完整磁盘名确认（不接受`yes`）
- CONFIRM_DISK_WIPE=YES 对系统盘无效（强制手动确认）

## 环境变量

### ISO环境专用
- `TARGET_DISK`: 目标磁盘（可选，留空则显示交互菜单）
- `REQUIRE_TARGET_DISK`: 必须显式指定磁盘（1/0）
- `CONFIRM_DISK_WIPE`: 跳过确认（YES，仅非系统盘）
- `ROOT_PASSWORD_HASH`: Root密码哈希
- `BOOT_MODE`: uefi|bios（默认自动）
- `DRY_RUN`: 仅打印分区/格式化命令（1/0）
- `FORCE_PARTITION`: 强制重新分区（1/0）
- `FORCE_FORMAT`: 强制重新格式化（1/0）
- `CLEANUP_INSTALL_ENV`: 清理 /root/shorin-install.env 与 continue-install.sh（1/0）

### 通用参数
- `SHORIN_USERNAME`: 用户名
- `SHORIN_PASSWORD`: 密码
- `DESKTOP_ENV`: 当前仅支持 niri（其他值会被忽略）
- `CN_MIRROR`: 中国镜像（0/1）
- `DEBUG`: 调试模式（0/1）
- `ENABLE_ARCHLINUXCN`: 启用 archlinuxcn（默认跟随 CN_MIRROR）
- `ENABLE_AUR_HELPERS`: 启用 yay/paru（1/0）
- `FAILLOCK_DENY`: 失败锁定次数（0 表示禁用）
- `CLEANUP_INSTALLER`: 安装后清理源码目录（1/0）

### 已安装系统
- `FORCE_LOCALE_GEN`: 强制locale-gen（0/1）
- `BRANCH`: Git分支（main/dev）

## 开发任务

### 测试脚本
```bash
# 单独测试模块
sudo bash scripts/modules.sh 01-base.sh

# 调试模式
DEBUG=1 sudo bash scripts/install.sh

# 强制CN镜像
CN_MIRROR=1 sudo bash scripts/install.sh
```

### 重置状态
```bash
# 删除进度文件
sudo rm -f /var/lib/shorin/install_state
```

### 语法检查
```bash
bash -n scripts/*.sh
```

## Bash编码规范

- 使用 `#!/bin/bash`（非sh）
- 变量使用大写（SCRIPT_DIR, TARGET_USER）
- 函数使用 snake_case
- modules.sh 顶部已统一加载 00-utils.sh
- 使用 `exe` 包装关键命令
- heredoc 使用 `<<-` 支持缩进

## TUI视觉规范

- 使用预定义颜色变量（H_CYAN, H_GREEN）
- 必须用 `echo -e` 输出颜色字符串
- 菜单使用盒绘字符（╭─╮│╰╯）
- 标题用 `section "Phase X" "Description"`

## 错误处理

- 关键操作检查 exit code 并调用 `error()`
- 使用 `|| exit 1` 中断致命错误
- 桌面模块使用 `critical_failure_handler`
- AUR包安装使用 `ensure_package_installed` 重试

## 特殊注意事项

### 双显卡处理
- 检测lspci输出
- NVIDIA+其他 → nvidia专有驱动 + nvidia-prime

### Btrfs快照
- 使用snapper创建快照
- 安装开始前："Before Shorin Setup"
- 桌面环境前："Before Desktop Environments"
- 清理函数仅删除pre/post类型

### 应用安装
- 自动安装所有预定义应用（无交互）
- 分类安装：Repo批量 / AUR逐个 / Flatpak逐个
- 智能依赖：Wine/Virt-Manager/Lutris/LazyVim
- 跳过已安装包（pacman -Qi检测）

## Bootstrap部署

**一键安装（最小参数）**
```bash
TARGET_DISK=/dev/nvme0n1 \
  bash <(curl -L https://raw.githubusercontent.com/2048TB/shorin-arch-setup/main/scripts/strap.sh)
```

**零交互模式（完整参数）**
```bash
TARGET_DISK=/dev/nvme0n1 \
CONFIRM_DISK_WIPE=YES \
SHORIN_USERNAME="user" SHORIN_PASSWORD="pass" \
ROOT_PASSWORD_HASH='$6$...' \
  bash <(curl -L ...)
```

**环境变量传递链路**
```
strap.sh (export) → install.sh → 00-arch-base-install.sh
  → shorin-install.env (printf %q) → continue-install.sh (source)
  → install.sh (SKIP_BASE_INSTALL=1) → modules.sh
```

## Git操作

### 提交规范
```bash
git add -A
git commit -m "$(cat <<'EOF'
type: 标题

详细说明...

Co-Authored-By: Claude Sonnet 4.5 (1M context) <noreply@anthropic.com>
EOF
)"
git push origin main
```

### Commit类型
- `feat`: 新功能
- `fix`: Bug修复
- `docs`: 文档更新
- `refactor`: 重构
- `test`: 测试
- `chore`: 构建/工具
