# Arch Niri Assets

用于已安装 Arch 系统的后安装与配置资产仓库，目标是快速部署基于 `niri + noctalia-shell + ghostty` 的桌面环境。

## 包含内容

- `arch-niri-post-install.sh`：安装软件、部署配置（系统内后安装）。
- `software-packages.txt`：统一软件清单（Repo/AUR/Flatpak）。
- `configs/`：niri、shell、fcitx5、ghostty、wallpapers 等配置资产。

## 重要提示

- 脚本会安装/升级软件并覆盖部分用户配置，建议先备份。

## 快速开始

在已安装系统中：

```bash
chmod +x ./arch-niri-post-install.sh
sudo ./arch-niri-post-install.sh
```

## 常用环境变量

```bash
# 基础身份
export INSTALL_USER="your_user"

# 安装行为
export GPU_PROFILE="auto"         # auto|1|2|3|4

sudo ./arch-niri-post-install.sh
```

说明：
- `INSTALL_USER` 为必填，且用户必须已存在。

GPU 方案说明：
- `1`：无 GPU
- `2`：AMDGPU
- `3`：NVIDIA
- `4`：AMD 核显 + NVIDIA
- `auto`：自动识别并映射到上述 4 类

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

- 安装 repo/AUR/flatpak 软件（按软件清单与默认核心列表）。
- 自动部署 niri/noctalia/ghostty/fcitx5/shell 配置。
- 自动创建多语言开发目录（Go/Rust/Node/Python/Zig/C-C++）与常见工具链路径目录。
- 自动按 `GPU_PROFILE` 4 种方案补充显卡驱动包。

## 建议验证

安装完成后建议检查：

```bash
pacman -Qi niri ghostty
command -v paru || true
command -v flatpak || true
```
