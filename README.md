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

## 🚀 快速开始

### ISO环境全新安装

**交互式模式**（自动检测并选择磁盘）：
```bash
# 1. 启动Arch ISO，连接网络
iwctl  # WiFi配置

# 2. 运行安装（会显示磁盘选择菜单）
bash <(curl -L https://raw.githubusercontent.com/2048TB/shorin-arch-setup/main/scripts/strap.sh)
```

**快速模式**（指定磁盘）：
```bash
TARGET_DISK=/dev/nvme0n1 \
  bash <(curl -L https://raw.githubusercontent.com/2048TB/shorin-arch-setup/main/scripts/strap.sh)
```

**零交互模式**（预设用户名密码）：
```bash
# 生成root密码哈希: openssl passwd -6 "yourpassword"
TARGET_DISK=/dev/nvme0n1 \
CONFIRM_DISK_WIPE=YES \
SHORIN_USERNAME="myuser" \
SHORIN_PASSWORD="mypassword" \
ROOT_PASSWORD_HASH='$6$rounds=5000$...' \
DESKTOP_ENV="niri" \
  bash <(curl -L https://raw.githubusercontent.com/2048TB/shorin-arch-setup/main/scripts/strap.sh)
```

### 已安装系统配置

```bash
# 仅配置桌面环境和应用
bash <(curl -L https://raw.githubusercontent.com/2048TB/shorin-arch-setup/main/scripts/strap.sh)

# 或手动克隆
git clone https://github.com/2048TB/shorin-arch-setup.git
cd shorin-arch-setup
sudo bash scripts/install.sh
```

## 🖥️ 支持的桌面环境

| 桌面 | 描述 | 推荐场景 |
|------|------|---------|
| **Niri** | 滚动平铺窗口管理器 | 效率党、键盘流 |
| **GNOME** | 现代桌面环境 | 新手、简洁党 |
| **None** | 纯CLI环境 | 服务器、极简 |

## 📦 软件清单

### 自动安装
- **基础系统**: 字体（思源/Noto）、输入法（Fcitx5+雾凇拼音）、音频（Pipewire）
- **AUR助手**: yay, paru
- **GPU驱动**: 自动检测AMD/Intel/NVIDIA
- **Btrfs工具**: snapper, grub-btrfs

### 用户可选（FZF多选）
- **开发**: Python, Go, Rust, Node.js, Zig, Bun, Docker
- **终端**: ghostty, zsh, zellij, fd, ripgrep, bat, yazi, btop
- **游戏**: Steam, Lutris, MangoHud, gamemode
- **多媒体**: mpv, ffmpeg, OBS Studio
- **办公**: VSCode, LibreOffice, GIMP

详见 [common-applist.txt](./common-applist.txt) 和 [niri-applist.txt](./niri-applist.txt)

## 📀 ISO安装模式

### 分区方案
```
/dev/sdX
├─ sdX1  512MB   EFI (FAT32)      # BIOS模式为1M BIOS boot
└─ sdX2  剩余    Btrfs
    ├─ @            → /
    ├─ @home        → /home
    ├─ @snapshots   → /.snapshots
    ├─ @log         → /var/log
    └─ @cache       → /var/cache
```

### 执行流程
1. 环境检测（ISO/已安装）
2. 磁盘确认（需输入`yes`）
3. 基础安装（pacstrap核心包）
4. chroot继续配置
5. 桌面选择（120s超时）
6. 用户创建（交互或环境变量）
7. 应用选择（FZF多选）
8. 自动重启（10s倒计时）

### 安全机制
- ✅ **智能磁盘检测** - 自动过滤光驱/小容量磁盘
- ✅ **状态感知** - 区分空盘/有数据/系统盘（高亮警告）
- ✅ **双重确认** - 系统盘需输入完整磁盘名，普通盘输入yes
- ✅ **磁盘信息展示** - 型号/容量/接口/分区状态一目了然
- ✅ **超时保护** - 60秒无操作自动选择第一块盘
- ✅ **最小容量检查** - 自动跳过小于20GB的磁盘
- ✅ **分区检测** - 显示现有分区和挂载点

## 🔧 环境变量

### ISO环境专用
```bash
TARGET_DISK=/dev/nvme0n1          # 必填
CONFIRM_DISK_WIPE=YES             # 跳过确认
ROOT_PASSWORD_HASH='$6$...'       # root密码哈希
BOOT_MODE="uefi"                  # uefi|bios（默认自动）
```

### 通用参数
```bash
SHORIN_USERNAME="user"            # 用户名
SHORIN_PASSWORD="pass"            # 密码
DESKTOP_ENV="niri"                # niri|gnome|none
CN_MIRROR=1                       # 中国镜像
DEBUG=1                           # 调试模式
```

### 已安装系统
```bash
FORCE_LOCALE_GEN=1                # 强制locale-gen
BRANCH=dev                        # 指定分支
```

### 配置示例
```bash
# 环境变量方式
TARGET_DISK=/dev/nvme0n1
DESKTOP_ENV=niri
SHORIN_USERNAME="youruser"
SHORIN_PASSWORD="yourpassword"
ROOT_PASSWORD_HASH='$6$...'       # 使用 openssl passwd -6 "pass" 生成
```

## 🛡️ 快照与恢复

### 自动快照
- `Before Shorin Setup` - 安装开始
- `Before Desktop Environments` - 桌面前

### 回滚
```bash
sudo bash scripts/install.sh rollback

# 查看快照
sudo snapper -c root list
sudo snapper -c home list
```

## 📁 项目结构

```
shorin-arch-setup/
├── scripts/
│   ├── install.sh              # 主安装器
│   ├── strap.sh                # Bootstrap
│   ├── modules.sh              # 模块集合
│   ├── 00-utils.sh             # 工具函数
│   └── 00-arch-base-install.sh # ISO基础安装
├── niri-dotfiles/               # Niri完整配置（Shell+应用+主题）
├── gnome-dotfiles/              # GNOME配置
├── grub-themes/                 # GRUB主题
├── common-applist.txt           # 通用应用列表
└── niri-applist.txt             # Niri专用应用
```

## 🔍 开发指南

详见 [CLAUDE.md](./CLAUDE.md)

## 📝 许可证

MIT License

## 🙏 致谢

- Niri配置参考：[ShorinArchExperience](https://github.com/SHORiN-KiWATA/ShorinArchExperience-ArchlinuxGuide)
