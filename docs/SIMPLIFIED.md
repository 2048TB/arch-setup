# Shorin Arch Setup - 简化版本

## 变更摘要

### 移除的功能
- ❌ 桌面环境选择菜单（GNOME/Niri/None）
- ❌ Reflector镜像优化提示
- ❌ Flathub镜像选择（SJTU/USTC/Official）
- ❌ Niri依赖包FZF交互选择
- ❌ TTY自动登录选择提示
- ❌ 应用软件FZF交互选择
- ❌ GRUB主题选择和安装
- ❌ GNOME桌面支持

### 固定的配置
- ✅ 桌面环境: Niri
- ✅ TTY自动登录: 启用
- ✅ Flathub镜像: SJTU（CN环境）
- ✅ 镜像优化: 使用默认
- ✅ Niri依赖: 安装全部配置的包
- ✅ 应用软件: 安装全部配置的包

### 保留的交互
- ✅ 磁盘选择菜单（安全机制）
- ✅ 磁盘擦除确认（安全机制）

## 安装流程

1. 启动脚本自动检测环境
2. 显示磁盘选择菜单（或使用TARGET_DISK环境变量）
3. 确认磁盘擦除
4. 自动执行所有安装步骤
5. 无需任何中间交互
6. 完成后自动重启

## 零交互安装示例

```bash
TARGET_DISK=/dev/nvme0n1 \
CONFIRM_DISK_WIPE=YES \
SHORIN_USERNAME="user" \
SHORIN_PASSWORD="pass" \
ROOT_PASSWORD_HASH='$6$rounds=656000$...' \
  bash <(curl -L https://raw.githubusercontent.com/2048TB/shorin-arch-setup/main/scripts/strap.sh)
```

## 技术细节

- 删除代码行数: ~500行
- 删除文件: gnome-dotfiles/, grub-themes/
- 删除常量: 6个超时配置
- 简化模块: 4个(Niri/Apps/Flathub/Reflector)
