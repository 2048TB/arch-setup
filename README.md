# Shorin Arch Setup

Arch Linux 全自动安装系统 - 从ISO到桌面的一键部署

## ✨ 特性

- 🆕 **ISO环境支持** - 从Arch ISO直接安装，自动分区+基础系统+桌面配置
- 🎯 **模块化设计** - 独立脚本模块，可单独运行或恢复
- 🔄 **状态管理** - 断点续传，失败自动恢复
- 🎨 **多桌面支持** - Niri（滚动平铺）/ GNOME（现代桌面）
- 🛡️ **快照保护** - Btrfs自动快照，可一键回滚
- 🌏 **智能镜像** - 自动检测地区优化下载源
- ⚡ **GPU自适应** - 自动检测并安装AMD/Intel/NVIDIA驱动
- 📦 **完整工具链** - 开发环境（7种语言）+ 游戏优化 + 现代CLI工具
- 💯 **高质量代码** - 无魔数、函数≤50行、代码零重复

## 🚀 快速开始

### 🆕 一键安装（支持ISO环境）

**场景1: Arch ISO全新安装**
```bash
# 1. 启动Arch ISO，连接网络
iwctl  # WiFi配置

# 2. 运行一键安装（自动分区+完整部署）
bash <(curl -L https://raw.githubusercontent.com/2048TB/shorin-arch-setup/main/strap.sh)

# ✨ 自动完成：
#   - 自动分区（EFI + Btrfs）
#   - pacstrap基础系统
#   - GRUB引导安装
#   - 桌面环境配置
#   - 应用安装
#   - 重启进入新系统
```

**场景2: 已安装Arch系统**
```bash
# 仅配置桌面环境和应用（跳过分区）
bash <(curl -L https://raw.githubusercontent.com/2048TB/shorin-arch-setup/main/strap.sh)
```

**场景3: 零交互自动化安装（预设用户名密码）**
```bash
# ISO环境下完全自动化安装
SHORIN_USERNAME="myuser" SHORIN_PASSWORD="mypassword" \
  bash <(curl -L https://raw.githubusercontent.com/2048TB/shorin-arch-setup/main/strap.sh)

# ✨ 完全无交互：
#   - 自动创建用户myuser
#   - 自动设置密码
#   - 用户自动获得sudo权限（wheel组）
#   - 无需任何手动输入
```

### 方法2：手动克隆（已安装系统）

```bash
# 1. 克隆仓库
git clone https://github.com/2048TB/shorin-arch-setup.git
cd shorin-arch-setup

# 2. 运行安装器
sudo bash install.sh
```

### 指定分支

```bash
# 使用开发分支
BRANCH=dev bash <(curl -L https://raw.githubusercontent.com/2048TB/shorin-arch-setup/main/strap.sh)
```

## 🖥️ 支持的桌面环境

| 选项 | 描述 | 推荐场景 |
|------|------|---------|
| **Shorin's Niri** | 滚动平铺窗口管理器 | 效率党、键盘流 |
| **GNOME** | 现代桌面环境 | 新手、简洁党 |
| **No Desktop** | 纯CLI环境 | 服务器、极简主义 |

## 📦 软件清单

### 自动安装（系统核心）
- **基础系统**: 字体（思源/Noto）、输入法（Fcitx5+雾凇拼音）、音频（Pipewire）
- **AUR助手**: yay, paru
- **GPU驱动**: 自动检测AMD/Intel/NVIDIA
- **Btrfs工具**: snapper, grub-btrfs（自动快照）

### 用户可选（通过FZF选择）
- **开发工具**: Python, Go, Rust, Node.js, Zig, Bun, Docker, Git, CMake
- **终端工具**: ghostty, zsh, zellij, tmux, fd, ripgrep, bat, yazi, btop
- **游戏**: Steam, Lutris, MangoHud, gamemode
- **多媒体**: mpv, ffmpeg, transmission, OBS Studio
- **浏览器**: Google Chrome
- **社交**: Telegram, QQ, WeChat, LocalSend
- **办公**: VSCode, 可选LibreOffice/GIMP

详见 [软件清单](./common-applist.txt) 和 [Niri专用软件](./niri-applist.txt)

## 📀 ISO安装模式详解

### 自动分区方案
```
/dev/sdX (自动检测最大磁盘)
├─ sdX1  512MB   EFI System       (FAT32)
└─ sdX2  剩余    Linux Filesystem (Btrfs)
    ├─ @            → /
    ├─ @home        → /home
    ├─ @snapshots   → /.snapshots
    ├─ @log         → /var/log
    └─ @cache       → /var/cache
```

### 执行流程
1. **环境检测** - 自动识别ISO/已安装系统
2. **磁盘确认** - 显示目标磁盘，需输入`yes`确认擦除
3. **基础安装** - pacstrap核心包（约5-10分钟）
4. **chroot继续** - 自动进入新系统继续配置
5. **桌面选择** - Niri/GNOME/None（120s超时）
6. **用户创建** - 交互设置用户名和密码
7. **应用选择** - FZF多选（60s超时全选）
8. **自动重启** - 10秒倒计时

### 安全机制
- ✅ 磁盘大小检查（最小20GB）
- ✅ 30秒确认超时（防止误操作）
- ✅ 已安装系统自动跳过分区
- ✅ SKIP_BASE_INSTALL标志防止重复

详见 [ISO-INSTALL-GUIDE.md](./ISO-INSTALL-GUIDE.md)

## 🔧 环境变量

### 用户配置（零交互模式）
```bash
# 预设用户名和密码（ISO自动安装必备）
SHORIN_USERNAME="username" SHORIN_PASSWORD="password" bash strap.sh

# 完整示例（ISO零交互安装）
SHORIN_USERNAME="shorin" \
SHORIN_PASSWORD="mypassword123" \
CN_MIRROR=1 \
  bash <(curl -L https://raw.githubusercontent.com/2048TB/shorin-arch-setup/main/strap.sh)
```

### 其他选项
```bash
# 调试模式
DEBUG=1 sudo bash install.sh

# 强制使用中国镜像
CN_MIRROR=1 sudo bash install.sh

# 指定安装分支
BRANCH=dev bash strap.sh
```

**权限说明：**
- ✅ 用户自动添加到 `wheel` 组（标准sudo权限）
- ✅ sudoers自动配置：`%wheel ALL=(ALL:ALL) ALL`
- ✅ 等同root权限，但更安全（通过sudo执行管理命令）
- ✅ 密码锁定禁用：`faillock deny=0`（防止误锁）
- ❌ **不推荐**直接使用root账户（安全风险）

**验证sudo权限：**
```bash
# 登录用户后
sudo whoami  # 输出: root
sudo pacman -Syu  # 可执行系统管理
```

## 🛡️ 快照与恢复

### 自动快照点
- `Before Shorin Setup` - 安装开始前
- `Before Desktop Environments` - 桌面环境安装前

### 回滚到初始状态
```bash
sudo bash undochange.sh
```

### 查看快照
```bash
# Root分区快照
sudo snapper -c root list

# Home分区快照
sudo snapper -c home list
```

## 📁 项目结构

```
shorin-arch-setup/
├── install.sh              # 主安装器
├── strap.sh                # Bootstrap脚本
├── scripts/                # 模块化脚本
│   ├── 00-btrfs-init.sh   # Btrfs初始化
│   ├── 01-base.sh         # 基础系统
│   ├── 02-musthave.sh     # 必备软件
│   ├── 03-user.sh         # 用户创建（自动部署zsh配置）
│   ├── 03b-gpu-driver.sh  # GPU驱动
│   ├── 04-niri-setup.sh   # Niri桌面
│   ├── 04d-gnome.sh       # GNOME桌面
│   ├── 07-grub-theme.sh   # GRUB主题
│   └── 99-apps.sh         # 应用安装
├── configs/                # 用户Shell配置（zsh/starship/ghostty）
├── niri-dotfiles/          # Niri完整配置
├── gnome-dotfiles/         # GNOME配置
└── resources/              # 资源文件（Windows字体等）
```

## 🔍 开发指南

详见 [CLAUDE.md](./CLAUDE.md)

## 📝 许可证

MIT License

## 🙏 致谢

- Niri配置参考：[ShorinArchExperience-ArchlinuxGuide](https://github.com/SHORiN-KiWATA/ShorinArchExperience-ArchlinuxGuide)
