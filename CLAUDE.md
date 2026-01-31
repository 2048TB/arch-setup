# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

Shorin Arch Setup - Arch Linux 自动化安装系统，支持 **Arch ISO环境全自动安装** 和 **已安装系统配置**。提供 Niri（滚动平铺WM）和 GNOME（现代桌面）双桌面选择。采用模块化bash脚本架构，包含智能环境检测、自动分区、状态管理、快照恢复、交互式TUI界面、自动配置部署。

**v2.1 新特性：ISO环境支持**
- ✅ 自动检测ISO环境 vs 已安装系统
- ✅ ISO模式：全自动分区（GPT+Btrfs）+ pacstrap + chroot
- ✅ 已安装模式：跳过基础安装，直接配置桌面
- ✅ 一键命令：`bash <(curl -L https://raw.githubusercontent.com/2048TB/shorin-arch-setup/main/strap.sh)`

## 核心架构

### 执行流程
```
[ISO环境]
strap.sh (Bootstrap)
  └─> install.sh (Environment Detection)
       ├─> is_iso_environment() → true
       └─> 00-arch-base-install.sh (Partition + Pacstrap)
            └─> arch-chroot /mnt
                 └─> continue-install.sh
                      └─> install.sh (SKIP_BASE_INSTALL=1)
                           ├─> 00-utils.sh (Tools)
                           └─> scripts/*.sh (Modules)

[已安装系统]
strap.sh (Bootstrap)
  └─> install.sh (Environment Detection)
       ├─> is_iso_environment() → false
       ├─> 00-utils.sh (TUI Engine + Helper Functions)
       └─> scripts/*.sh (Modular Installation Steps)
```

### 关键组件

**install.sh** - 主控制器
- 桌面环境选择菜单（3种选项：None/Niri/GNOME）
- 状态文件管理（`.install_progress`）
- 模块动态加载（根据DESKTOP_ENV变量）
- Reflector镜像优化（带时区检测）
- 全局清理与快照管理

**00-utils.sh** - TUI可视化引擎 + 工具函数库
- ANSI颜色系统（H_RED, H_GREEN等）
- 日志函数（`log`, `success`, `warn`, `error`）
- `exe()` - 命令执行封装（带可视化输出）
- `section()` - 章节标题渲染
- `select_flathub_mirror()` - Flathub镜像选择菜单（拆分为5个子函数）
- `as_user()` - 用户身份切换工具
- `detect_target_user()` - 统一的用户检测函数（优先读取/tmp/shorin_install_user）
- **v2.1新增工具函数**:
  - `install_yay_package(pkg)` - Yay包安装统一接口
  - `is_package_installed(pkg)` - 包状态检查
  - `fzf_select_apps(list_file, [header])` - FZF交互菜单

**00-arch-base-install.sh** - [ISO模式专用] 基础系统安装
- ISO环境检测（/run/archiso, findmnt, hostname）
- 自动磁盘选择（lsblk检测最大盘）
- GPT分区（EFI 512M + Btrfs）
- Btrfs子卷创建（@, @home, @snapshots, @log, @cache）
- pacstrap基础系统安装
- genfstab生成挂载表
- arch-chroot + continue-install.sh桥接
- GRUB引导安装

**模块执行顺序** (BASE_MODULES数组)
```
00-arch-base-install.sh → [ISO模式] 分区+pacstrap+基础配置（仅ISO环境）
00-btrfs-init.sh      → Btrfs/快照初始化
01-base.sh            → 基础系统（yay/paru, 字体, archlinuxcn）
02-musthave.sh        → 必备软件（音频/输入法/蓝牙/fastfetch/flatpak）
02a-dualboot-fix.sh   → 双系统修复（Windows引导/os-prober）
03-user.sh            → 用户创建（zsh默认shell，支持SHORIN_USERNAME/PASSWORD环境变量）+ 自动部署configs配置 + wheel组sudo权限
03b-gpu-driver.sh     → GPU驱动智能检测（AMD/Intel/NVIDIA多版本）
03c-snapshot-before-desktop.sh → 桌面环境前快照
04-niri-setup.sh      → Niri桌面（本地niri-dotfiles部署）
04d-gnome.sh          → GNOME桌面（gnome-dotfiles部署）
07-grub-theme.sh      → GRUB主题
99-apps.sh            → 应用批量安装（FZF交互选择）
```

### 状态管理机制

**恢复能力**
- 每个模块执行成功后写入`.install_progress`
- 重新运行时自动跳过已完成步骤
- Reflector步骤单独标记(`REFLECTOR_DONE`)

**快照策略**
- `clean_intermediate_snapshots()` 清理安装过程中的pre/post快照
- 保留白名单标记快照("Before Desktop Environments"等)
- 双配置支持(root + home分区)

### 桌面环境模块

**Niri (04-niri-setup.sh)**
- 核心组件：niri, fuzzel, libnotify, mako, polkit-gnome
- 默认终端：ghostty（GPU加速）
- 文件管理器：Nautilus + Thunar（双重支持）
- Dotfiles部署：从本地`niri-dotfiles/`复制到用户目录
- 配置内容：niri/waybar/fuzzel/mako/hyprlock/wlogout/matugen等
- 错误恢复：`critical_failure_handler` + `niri-undochange.sh`
- 包安装重试：`ensure_package_installed()` - 3次重试机制

**GNOME (04d-gnome.sh)**
- 核心组件：gnome-shell, gdm, nautilus
- Dotfiles从`gnome-dotfiles/`复制
- 扩展：blur-my-shell, tilingshell, user-theme
- 包含Nautilus双显卡修复（`configure_nautilus_user`）
- GTK/GNOME Shell配置自动应用

## 代码质量规范（v2.1更新）

### 常量定义
所有脚本使用`readonly`定义常量，消除魔数：
- **install.sh**: 8个常量（超时、退出码、UID等）
- **00-utils.sh**: 3个常量（FLATHUB_SELECTION_TIMEOUT等）
- **04-niri-setup.sh**: 4个常量（重试次数、超时等）

### 函数规范
- 函数长度≤50行（已拆分超长函数）
- 嵌套深度≤3层
- 单一职责原则（SRP）
- 工具函数集中在00-utils.sh

### 代码去重
所有重复≥3次的代码已提取为工具函数：
- 包管理: `install_yay_package()`, `is_package_installed()`
- 交互菜单: `fzf_select_apps()`
- 用户检测: `detect_target_user()`

## 开发任务

### 测试脚本模块
```bash
# 单独测试某个模块(需root)
sudo bash scripts/01-base.sh

# 启用调试模式
DEBUG=1 sudo bash install.sh

# 强制CN镜像
CN_MIRROR=1 sudo bash install.sh

# 测试ISO基础安装（虚拟机推荐）
# 注意：会擦除磁盘，仅在测试环境运行
sudo bash scripts/00-arch-base-install.sh
```

### 重置安装状态
```bash
# 删除进度文件以强制重新运行所有步骤
rm -f .install_progress

# 或手动编辑移除特定模块
vim .install_progress
```

### 配置文件管理

**用户Shell配置（configs/）**
- 部署时机：03-user.sh（用户创建时）
- 部署方式：直接复制到`$HOME`
- 内容：`.zshrc`, `.bashrc`, `.config/starship.toml`, `.config/ghostty/`, `.config/yazi/`, `.config/shell/env`
- 作用：所有桌面环境共用的基础配置

**Niri桌面配置（niri-dotfiles/）**
- 部署时机：04-niri-setup.sh（Niri桌面安装时）
- 部署方式：使用`copy_recursive()`递归复制
- 内容：完整Niri配置（niri/waybar/fuzzel/mako等）+ wallpapers
- 来源：本地集成（已包含完整配置，无需网络）
- 排除列表：`exclude-dotfiles.txt`（用户名非shorin时生效）

**GNOME桌面配置（gnome-dotfiles/）**
- 部署时机：04d-gnome.sh（GNOME桌面安装时）
- 部署方式：`cp -rf` 直接复制
- 内容：GTK/dconf/gnome-shell扩展配置

### 添加新软件包

编辑对应的applist.txt:
- `common-applist.txt` - 所有桌面环境通用
- `niri-applist.txt` - Niri专用（Wayland工具链）

格式：
```
package-name                             # 注释说明
AUR:package-name                         # AUR包（会自动处理）
flatpak:app.id                           # Flatpak包
#optional-package                        # 注释掉的可选包
```

**注意：** 脚本硬编码的包（字体/音频/输入法等）不要加入applist，会导致重复安装

### 日志与调试
- 临时日志: `/tmp/log-shorin-arch-setup.txt`
- 最终日志: `~/Documents/log-shorin-arch-setup.txt`
- 所有`exe`函数调用都会记录到日志

## 代码约定

### Bash编码规范
- 使用`#!/bin/bash`(非sh)
- 变量使用大写(SCRIPT_DIR, TARGET_USER)
- 函数使用snake_case
- 始终source `00-utils.sh`获取工具函数
- 使用`exe`包装关键命令以获得可视化输出

### TUI视觉规范
- 使用预定义颜色变量(H_CYAN, H_GREEN等)
- 必须用`echo -e`输出颜色字符串
- 菜单使用盒绘字符(╭─╮│╰╯)
- 标题用`section "Phase X" "Description"`

### 错误处理
- 关键操作检查exit code并调用`error()`
- 使用`|| exit 1`中断致命错误
- 桌面模块使用`critical_failure_handler`提供恢复选项
- AUR包安装使用`ensure_package_installed`重试机制

### 用户交互
- 默认值用`${var:-default}`语法
- 超时用`read -t seconds`
- 确认提示统一格式: `[Y/n]`或`[y/N]`
- 重要选择显示倒计时或超时提示

## 特殊注意事项

### 镜像选择逻辑
- Asia/Shanghai时区 → 提示是否运行Reflector(默认跳过)
- 其他时区 → 自动检测国家代码并优化镜像
- Flathub镜像有SJTU/USTC/Official三选一菜单

### 双显卡处理
- `03b-gpu-driver.sh`检测lspci输出
- NVIDIA+其他 → 安装nvidia专有驱动 + nvidia-prime
- 仅AMD → 仅mesa/vulkan
- GNOME Nautilus在双显卡+NVIDIA时强制GSK_RENDERER=gl

### Btrfs快照
- 使用snapper创建快照
- 安装开始前创建"Before Shorin Setup"标记
- 桌面环境前创建"Before Desktop Environments"
- 清理函数仅删除pre/post类型,保留single类型(用户手动快照)

### 应用安装（99-apps.sh）

**安装方式：**
- FZF交互式选择（支持全选/多选/搜索）
- 超时60秒自动安装全部
- 分类批量安装：Repo包批量 / AUR包逐个重试 / Flatpak包逐个

**智能依赖处理：**
- Wine检测：自动安装wine-gecko/wine-mono，复制Windows字体
- Virt-Manager检测：自动安装qemu-full/dnsmasq，配置libvirtd服务
- Lutris检测：自动安装32位游戏依赖
- LazyVim检测：自动安装依赖并克隆starter配置

**已安装检测：**
- 跳过已安装的包（pacman -Qi检测）
- 失败包记录到`~/Documents/安装失败的软件.txt`

## 核心技术特性

### 配置部署策略

**双层配置系统：**
1. **configs/** - 通用Shell配置（所有用户/所有桌面）
   - 部署时机：03-user.sh
   - 内容：.zshrc（zinit）, starship.toml, ghostty, yazi, shell/env
   - 方式：直接复制到 `$HOME`

2. **niri-dotfiles/** - Niri完整配置（仅Niri桌面）
   - 部署时机：04-niri-setup.sh
   - 内容：niri/waybar/fuzzel/mako/主题/脚本/壁纸
   - 方式：`copy_recursive()` 递归复制（非软链接）
   - 排除：exclude-dotfiles.txt（ghostty等在用户名非shorin时排除）

### 用户检测机制

**统一函数：** `detect_target_user()`
- 优先级1：读取 `/tmp/shorin_install_user`（03-user.sh写入）
- 优先级2：检测UID 1000用户
- 优先级3：手动输入

**使用场景：**
- 03b-gpu-driver.sh - GPU驱动安装
- 04-niri-setup.sh - Niri配置部署
- 04d-gnome.sh - GNOME配置部署
- 99-apps.sh - 应用安装

### Btrfs快照策略

**自动快照点：**
- `Before Shorin Setup` - 安装开始（00-btrfs-init.sh）
- `Before Desktop Environments` - 桌面前（03c-snapshot-before-desktop.sh）

**快照清理：**
- 保护白名单快照（Before Desktop Environments等）
- 仅删除pre/post类型（保留用户手动创建的single快照）
- 使用snapper delete批量清理

**回滚工具：**
- `undochange.sh` - 一键回滚到安装前（根目录）
- `scripts/niri-undochange.sh` - Niri安装失败回滚

## Bootstrap部署

**一键安装（ISO环境支持）**
```bash
# 通用命令（自动检测环境）
bash <(curl -L https://raw.githubusercontent.com/2048TB/shorin-arch-setup/main/strap.sh)

# ISO环境执行流程:
# 1. 自动分区（GPT + Btrfs子卷）
# 2. pacstrap基础系统
# 3. arch-chroot继续配置
# 4. 桌面环境 + 应用安装
# 5. 重启

# 已安装系统执行流程:
# 1. 跳过分区
# 2. 桌面环境 + 应用安装
```

**手动克隆**
```bash
git clone https://github.com/YOUR_USERNAME/shorin-arch-setup.git
cd shorin-arch-setup
sudo bash install.sh
```

**指定分支**
```bash
BRANCH=dev bash strap.sh
```

**环境变量**
```bash
# 零交互模式（预设用户名密码）
SHORIN_USERNAME="user" SHORIN_PASSWORD="pass" bash install.sh

# ISO零交互完整示例（推荐）
SHORIN_USERNAME="shorin" SHORIN_PASSWORD="Secure123!" CN_MIRROR=1 \
  bash <(curl -L https://raw.githubusercontent.com/2048TB/shorin-arch-setup/main/strap.sh)

# 调试模式
DEBUG=1 sudo bash install.sh

# 强制中国镜像
CN_MIRROR=1 sudo bash install.sh
```

**变量说明：**
- `SHORIN_USERNAME`: 预设用户名（跳过交互输入）
- `SHORIN_PASSWORD`: 预设密码（跳过交互输入）
- 用户自动添加到wheel组并配置sudoers（sudo权限）
- `DEBUG`: 调试模式（0/1）
- `CN_MIRROR`: 强制中国镜像（0/1）
- `BRANCH`: Git分支选择（main/dev）
