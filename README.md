# Shorin Arch Setup

Arch Linux 自动化安装脚本 - 快速部署 Niri/GNOME 桌面环境

## ✨ 特性

- 🎯 **模块化设计** - 独立脚本模块，可单独运行或恢复
- 🔄 **状态管理** - 断点续传，失败自动恢复
- 🎨 **多桌面支持** - Niri（滚动平铺）/ GNOME（现代桌面）
- 🛡️ **快照保护** - Btrfs自动快照，可一键回滚
- 🌏 **智能镜像** - 自动检测地区优化下载源
- ⚡ **GPU自适应** - 自动检测并安装AMD/Intel/NVIDIA驱动
- 📦 **完整工具链** - 开发环境（7种语言）+ 游戏优化 + 现代CLI工具

## 🚀 快速开始

### 方法1：一键安装（推荐）

```bash
bash <(curl -L is.gd/shorinsetup)
```

### 方法2：手动克隆

```bash
# 安装git并克隆仓库
sudo pacman -Syu git
git clone https://github.com/YOUR_USERNAME/shorin-arch-setup.git
cd shorin-arch-setup
sudo bash install.sh
```

### 方法3：一条命令

```bash
sudo pacman -Syu --noconfirm git && \
git clone https://github.com/YOUR_USERNAME/shorin-arch-setup.git && \
cd shorin-arch-setup && \
sudo bash install.sh
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

## 🔧 环境变量

```bash
# 调试模式
DEBUG=1 sudo bash install.sh

# 强制使用中国镜像
CN_MIRROR=1 sudo bash install.sh

# 指定安装分支
BRANCH=dev bash strap.sh
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
