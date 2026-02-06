# Arch Niri Assets

用于 Arch ISO 环境的一键安装与配置资产仓库，目标是快速部署基于 `niri + noctalia-shell + ghostty` 的桌面环境。

## 包含内容

- `arch-iso-niri-installer.sh`：自动分区、安装系统、安装软件、部署配置。
- `software-packages.txt`：统一软件清单（Repo/AUR/Flatpak）。
- `configs/`：niri、shell、fcitx5、ghostty、wallpapers 等配置资产。

## 重要风险

- 脚本会清空目标磁盘（默认自动选择最大非 USB 磁盘）。
- 仅建议在 Arch ISO 中执行。
- 首次开机后请立即修改默认密码。

## 快速开始

在 Arch ISO 中：

```bash
chmod +x ./arch-iso-niri-installer.sh
./arch-iso-niri-installer.sh
```

## 常用环境变量

```bash
# 基础身份
export INSTALL_USER="shorin"
export INSTALL_PASSWORD="change_me"
export ROOT_PASSWORD="change_me_root"
export HOST_NAME="arch-niri"

# 安装行为
export TARGET_DISK="/dev/nvme0n1"   # 不设置则自动选盘
export BOOT_MODE="auto"             # auto|uefi|bios
export AUTO_REBOOT="1"              # 1|0
export ALLOW_NON_ISO="0"            # 1|0
export AUTO_LOGIN_TTY1="1"          # 1|0
export ADD_USER_TO_ROOT_GROUP="0"   # 1|0，不推荐

./arch-iso-niri-installer.sh
```

## 软件清单格式

`software-packages.txt` 支持三类：

- Repo：直接写包名，例如 `ripgrep`
- AUR：`AUR:<pkg>`（大小写不敏感，如 `aur:<pkg>`）
- Flatpak：`flatpak:<app-id>`（大小写不敏感）

示例：

```txt
ripgrep
AUR:visual-studio-code-bin
flatpak:com.discordapp.Discord
```

## 当前自动化能力

- 自动创建用户、设置 root/用户密码、配置 sudo（wheel）。
- 可选将用户加入 root 组（默认关闭，不推荐）。
- Docker 安装后自动将用户加入 `docker` 组。
- 蓝牙组件安装后自动启用 `bluetooth.service`。
- 自动部署 niri/noctalia/ghostty/fcitx5/shell 配置。
- 自动创建多语言开发目录（Go/Rust/Node/Python/Zig/C-C++）与常见工具链路径目录。

## 建议验证

安装完成后建议检查：

```bash
id
groups
sudo -l
systemctl status NetworkManager bluetooth docker --no-pager
```
