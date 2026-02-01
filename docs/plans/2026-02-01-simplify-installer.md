# Shorin Arch Setup 简化实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**目标:** 简化安装脚本，移除所有交互式选择，固定为Niri单桌面自动化安装

**架构:** 通过修改核心脚本(install.sh, modules.sh, 00-utils.sh)移除所有菜单逻辑，删除GNOME和GRUB主题相关代码和资源，固定默认配置选项

**技术栈:** Bash 脚本、Snapper 快照系统、Pacman/Yay 包管理

---

## Task 1: 移除桌面选择菜单，固定Niri桌面

**文件:**
- 修改: `scripts/install.sh:98-234`

**Step 1: 移除select_desktop函数**

删除整个函数定义(98-148行)，替换为固定赋值：

```bash
# --- Fixed Desktop Environment ---
export DESKTOP_ENV="niri"
log "Desktop Environment: Niri (Fixed)"
```

**Step 2: 移除环境变量验证逻辑**

删除 install.sh 第194-209行的 DESKTOP_ENV 验证代码块：

```bash
# 删除这段代码：
if [ -n "${DESKTOP_ENV:-}" ]; then
    DESKTOP_ENV="${DESKTOP_ENV,,}"
    case "$DESKTOP_ENV" in
        niri|gnome|none)
            log "Using DESKTOP_ENV from config/env: $DESKTOP_ENV"
            ;;
        *)
            error "Invalid DESKTOP_ENV: $DESKTOP_ENV (use niri|gnome|none)"
            exit 1
            ;;
    esac
else
    select_desktop
fi
```

替换为：

```bash
# Fixed to Niri
export DESKTOP_ENV="niri"
log "Desktop Environment: Niri (Fixed)"
```

**Step 3: 简化动态模块列表逻辑**

在 install.sh 第220-234行，简化为：

```bash
# Fixed Module List for Niri
MODULES=(
    "00-btrfs-init.sh"
    "01-base.sh"
    "02-musthave.sh"
    "02a-dualboot-fix.sh"
    "03-user.sh"
    "03b-gpu-driver.sh"
    "03c-snapshot-before-desktop.sh"
    "04-niri-setup.sh"
    "99-apps.sh"
)
```

**Step 4: 删除桌面选择相关常量**

删除 install.sh 第28行：

```bash
# 删除这行
readonly DESKTOP_SELECTION_TIMEOUT=120
```

**Step 5: 提交更改**

```bash
git add scripts/install.sh
git commit -m "refactor: 移除桌面选择菜单，固定Niri桌面

- 删除 select_desktop() 交互函数
- 移除 DESKTOP_ENV 验证逻辑
- 简化模块列表为固定Niri配置
- 删除 DESKTOP_SELECTION_TIMEOUT 常量

Co-Authored-By: Claude Sonnet 4.5 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: 移除Reflector镜像选择逻辑

**文件:**
- 修改: `scripts/install.sh:247-309`

**Step 1: 删除Reflector整个代码块**

删除第247-309行的完整Reflector逻辑，包括：
- 时区检测
- 交互提示
- 国家代码检测
- 镜像优化执行

**Step 2: 替换为简单的状态检查**

```bash
# --- Skip Reflector (Use Default Mirrors) ---
section "Pre-Flight" "Mirrorlist"

if grep -q "^REFLECTOR_DONE$" "$STATE_FILE"; then
    log "Mirrorlist check skipped (Resume Mode)."
else
    log "Using default mirrors (Reflector disabled)."
    echo "REFLECTOR_DONE" >> "$STATE_FILE"
fi
```

**Step 3: 删除Reflector相关常量**

删除 install.sh 第29-31行：

```bash
# 删除这3行
readonly REFLECTOR_TIMEOUT=60
readonly REFLECTOR_AGE_HOURS=24
readonly REFLECTOR_TOP_MIRRORS=10
```

**Step 4: 提交更改**

```bash
git add scripts/install.sh
git commit -m "refactor: 移除Reflector镜像优化，使用默认镜像

- 删除时区检测和交互提示逻辑
- 删除国家代码自动检测
- 简化为状态标记检查
- 删除3个Reflector常量

Co-Authored-By: Claude Sonnet 4.5 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: 移除Flathub镜像选择函数

**文件:**
- 修改: `scripts/00-utils.sh:324-371`

**Step 1: 删除select_flathub_mirror函数**

完全删除该函数(第324-371行)。

**Step 2: 删除Flathub超时常量**

在 00-utils.sh 找到并删除：

```bash
# 删除这行（通常在文件顶部常量定义区域）
readonly FLATHUB_SELECTION_TIMEOUT=60
```

**Step 3: 修改modules.sh中的Flathub配置**

在 modules.sh 的 02-musthave.sh 模块中查找 `select_flathub_mirror` 调用：

```bash
# 查找并替换为固定SJTU镜像
# 原代码：
select_flathub_mirror

# 替换为：
log "Setting Flathub mirror to: SJTU (Fixed)"
exe flatpak remote-modify flathub --url="https://mirror.sjtu.edu.cn/flathub"
```

**Step 4: 验证修改**

```bash
# 检查语法
bash -n scripts/00-utils.sh
bash -n scripts/modules.sh
```

**Step 5: 提交更改**

```bash
git add scripts/00-utils.sh scripts/modules.sh
git commit -m "refactor: 移除Flathub镜像选择，固定SJTU镜像

- 删除 select_flathub_mirror() 函数
- 删除 FLATHUB_SELECTION_TIMEOUT 常量
- 固定使用 SJTU 镜像源

Co-Authored-By: Claude Sonnet 4.5 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: 简化Niri依赖包安装（移除FZF交互）

**文件:**
- 修改: `scripts/modules.sh` (04-niri-setup.sh 部分)

**Step 1: 定位Niri模块代码**

在 modules.sh 中找到 `"04-niri-setup.sh")` case分支。

**Step 2: 移除TTY自动登录提示**

找到类似代码并删除：

```bash
# 删除这段交互代码
if ! read -t "$TTY_AUTOLOGIN_TIMEOUT" -p "..." choice; then
    ...
fi
```

替换为固定启用：

```bash
# Fixed: Enable TTY Auto-login
log "Configuring TTY auto-login for $TARGET_USER..."
exe mkdir -p "/etc/systemd/system/getty@tty1.service.d"
cat > "/etc/systemd/system/getty@tty1.service.d/autologin.conf" <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\u' --noclear --autologin $TARGET_USER %I \$TERM
EOF
success "TTY auto-login enabled."
```

**Step 3: 移除FZF应用选择逻辑**

删除类似代码：

```bash
# 删除超时等待和FZF调用
if ! read -t "$INSTALLATION_TIMEOUT" ...
fzf_select_apps "$REPO_DIR/niri-applist.txt"
```

替换为直接读取所有包：

```bash
# Auto-install all Niri dependencies
log "Reading Niri application list..."
mapfile -t ALL_APPS < <(grep -vE "^\s*#|^\s*$" "$REPO_DIR/niri-applist.txt" | sed -E 's/\s*#.*//')

if [ ${#ALL_APPS[@]} -eq 0 ]; then
    warn "No applications found in niri-applist.txt"
else
    log "Installing ${#ALL_APPS[@]} Niri dependencies..."

    REPO_APPS=()
    AUR_APPS=()

    for app in "${ALL_APPS[@]}"; do
        if [[ "$app" == AUR:* ]]; then
            AUR_APPS+=("${app#AUR:}")
        else
            REPO_APPS+=("$app")
        fi
    done

    # Install repo packages in batch
    if [ ${#REPO_APPS[@]} -gt 0 ]; then
        exe pacman -S --noconfirm --needed "${REPO_APPS[@]}"
    fi

    # Install AUR packages one by one
    for aur_app in "${AUR_APPS[@]}"; do
        install_yay_package "$aur_app"
    done

    success "Niri dependencies installed."
fi
```

**Step 4: 删除超时常量**

删除：

```bash
readonly TTY_AUTOLOGIN_TIMEOUT=20
readonly INSTALLATION_TIMEOUT=60
```

**Step 5: 提交更改**

```bash
git add scripts/modules.sh
git commit -m "refactor: 简化Niri依赖安装，移除FZF交互

- 固定启用TTY自动登录
- 自动安装niri-applist.txt中所有48个包
- 删除超时等待和交互逻辑
- 删除2个超时常量

Co-Authored-By: Claude Sonnet 4.5 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: 简化应用软件批量安装（移除FZF交互）

**文件:**
- 修改: `scripts/modules.sh` (99-apps.sh 部分)

**Step 1: 定位99-apps模块代码**

在 modules.sh 中找到 `"99-apps.sh")` case分支。

**Step 2: 移除初期选择提示**

删除类似代码：

```bash
# 删除超时询问逻辑
if ! read -t "$APPS_SELECTION_TIMEOUT" -p "Install applications? [Y/n]: " choice; then
    ...
fi
```

**Step 3: 替换为自动安装所有包**

```bash
# Auto-install all applications from common-applist.txt
section "Applications" "Batch Installation"

log "Reading application list..."
mapfile -t ALL_APPS < <(grep -vE "^\s*#|^\s*$" "$REPO_DIR/common-applist.txt" | sed -E 's/\s*#.*//')

if [ ${#ALL_APPS[@]} -eq 0 ]; then
    warn "No applications found in common-applist.txt"
    exit 0
fi

log "Installing ${#ALL_APPS[@]} applications..."

REPO_APPS=()
AUR_APPS=()
FLATPAK_APPS=()

for app in "${ALL_APPS[@]}"; do
    if [[ "$app" == AUR:* ]]; then
        AUR_APPS+=("${app#AUR:}")
    elif [[ "$app" == flatpak:* ]]; then
        FLATPAK_APPS+=("${app#flatpak:}")
    else
        REPO_APPS+=("$app")
    fi
done

# Install repo packages in batch
if [ ${#REPO_APPS[@]} -gt 0 ]; then
    log "Installing ${#REPO_APPS[@]} official packages..."
    exe pacman -S --noconfirm --needed "${REPO_APPS[@]}"
fi

# Install AUR packages one by one
if [ ${#AUR_APPS[@]} -gt 0 ]; then
    log "Installing ${#AUR_APPS[@]} AUR packages..."
    for aur_app in "${AUR_APPS[@]}"; do
        install_yay_package "$aur_app"
    done
fi

# Install Flatpak packages one by one
if [ ${#FLATPAK_APPS[@]} -gt 0 ]; then
    log "Installing ${#FLATPAK_APPS[@]} Flatpak packages..."
    for flatpak_app in "${FLATPAK_APPS[@]}"; do
        exe flatpak install -y flathub "$flatpak_app"
    done
fi

# Handle LazyVim if neovim was installed
if pacman -Qi neovim &>/dev/null && [[ " ${REPO_APPS[*]} " =~ " neovim " ]]; then
    log "Setting up LazyVim..."
    as_user git clone https://github.com/LazyVim/starter ~/.config/nvim
    as_user nvim --headless "+Lazy! sync" +qa
fi

success "Application installation complete."
```

**Step 4: 删除超时常量**

删除：

```bash
readonly APPS_SELECTION_TIMEOUT=60
```

**Step 5: 提交更改**

```bash
git add scripts/modules.sh
git commit -m "refactor: 简化应用安装，自动安装所有配置包

- 移除初期选择提示和FZF交互
- 自动安装common-applist.txt中所有93个包
- 保留分类安装逻辑(Repo/AUR/Flatpak)
- 删除APPS_SELECTION_TIMEOUT常量

Co-Authored-By: Claude Sonnet 4.5 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: 完全移除GNOME支持

**文件:**
- 修改: `scripts/modules.sh` (04d-gnome.sh 部分)
- 删除: `gnome-dotfiles/` 目录

**Step 1: 删除GNOME模块代码**

在 modules.sh 中找到 `"04d-gnome.sh")` case分支，删除整个分支：

```bash
# 完全删除这个case分支及其内部所有代码
"04d-gnome.sh")
    # ... 所有GNOME相关代码 ...
    ;;
```

**Step 2: 删除GNOME配置目录**

```bash
rm -rf gnome-dotfiles/
```

**Step 3: 验证无残留引用**

```bash
# 检查是否还有GNOME相关引用
grep -r "gnome" scripts/ || echo "No GNOME references found"
grep -r "04d-gnome" scripts/ || echo "No module references found"
```

**Step 4: 提交更改**

```bash
git add scripts/modules.sh
git rm -rf gnome-dotfiles/
git commit -m "refactor: 完全移除GNOME桌面支持

- 删除04d-gnome.sh模块代码
- 删除gnome-dotfiles/配置目录
- 移除GNOME相关包安装逻辑

Co-Authored-By: Claude Sonnet 4.5 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: 完全移除GRUB主题支持

**文件:**
- 修改: `scripts/install.sh:231` (模块列表)
- 修改: `scripts/modules.sh` (07-grub-theme.sh 部分)
- 删除: `grub-themes/` 目录

**Step 1: 从模块列表删除GRUB主题**

在 install.sh 的 MODULES 数组中删除：

```bash
# 删除这行
"07-grub-theme.sh"

# 修改后的数组应该是：
MODULES=(
    "00-btrfs-init.sh"
    "01-base.sh"
    "02-musthave.sh"
    "02a-dualboot-fix.sh"
    "03-user.sh"
    "03b-gpu-driver.sh"
    "03c-snapshot-before-desktop.sh"
    "04-niri-setup.sh"
    "99-apps.sh"
)
```

**Step 2: 删除GRUB主题模块代码**

在 modules.sh 中删除 `"07-grub-theme.sh")` case分支。

**Step 3: 删除GRUB主题资源目录**

```bash
rm -rf grub-themes/
```

**Step 4: 验证无残留引用**

```bash
grep -r "grub-theme" scripts/ || echo "No GRUB theme references found"
grep -r "GRUB_THEME_SELECTION" scripts/ || echo "No GRUB constants found"
```

**Step 5: 提交更改**

```bash
git add scripts/install.sh scripts/modules.sh
git rm -rf grub-themes/
git commit -m "refactor: 完全移除GRUB主题支持

- 从模块列表删除07-grub-theme.sh
- 删除GRUB主题选择逻辑
- 删除grub-themes/资源目录
- 删除GRUB_THEME_SELECTION_TIMEOUT常量

Co-Authored-By: Claude Sonnet 4.5 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: 更新项目文档

**文件:**
- 修改: `CLAUDE.md`

**Step 1: 更新项目概述**

```markdown
## 项目概述

Shorin Arch Setup - Arch Linux 自动化安装系统，**固定Niri桌面环境全自动部署**。采用零交互bash脚本架构，包含智能环境检测、自动分区、状态管理、快照恢复。
```

**Step 2: 更新核心架构**

删除桌面选择相关内容：

```markdown
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

**scripts/install.sh** - 主控制器
- **固定Niri桌面环境**（移除选择菜单）
- 状态文件管理（`.install_progress`）
- 模块动态加载
- 使用默认镜像（移除Reflector）
- 全局清理与快照管理
```

**Step 3: 更新模块列表**

```markdown
**scripts/modules.sh** - 模块集合
```
00-btrfs-init.sh      → Btrfs快照初始化
01-base.sh            → 基础系统（yay, 字体, archlinuxcn）
02-musthave.sh        → 必备软件（音频/输入法/蓝牙，固定SJTU Flathub）
02a-dualboot-fix.sh   → 双系统修复
03-user.sh            → 用户创建 + configs部署
03b-gpu-driver.sh     → GPU驱动
03c-snapshot-before-desktop.sh → 桌面前快照
04-niri-setup.sh      → Niri桌面（自动安装48个依赖，启用TTY登录）
99-apps.sh            → 应用批量安装（自动安装93个应用）
```
```

**Step 4: 删除已移除功能的文档**

删除以下章节：
- "智能磁盘选择" 保留（仍需要）
- "环境变量" - 删除 `DESKTOP_ENV` 相关
- 删除所有GNOME相关内容
- 删除GRUB主题相关内容
- 删除Flathub镜像选择说明
- 删除Reflector说明

**Step 5: 更新简化后的环境变量列表**

```markdown
## 环境变量

### ISO环境专用
- `TARGET_DISK`: 目标磁盘（可选，留空则显示交互菜单）
- `CONFIRM_DISK_WIPE`: 跳过确认（YES，仅非系统盘）
- `ROOT_PASSWORD_HASH`: Root密码哈希
- `BOOT_MODE`: uefi|bios（默认自动）

### 通用参数
- `SHORIN_USERNAME`: 用户名
- `SHORIN_PASSWORD`: 密码
- `CN_MIRROR`: 中国镜像（0/1，已弃用Reflector）
- `DEBUG`: 调试模式（0/1）

### 已安装系统
- `FORCE_LOCALE_GEN`: 强制locale-gen（0/1）
- `BRANCH`: Git分支（main/dev）
```

**Step 6: 更新Bootstrap部署示例**

```markdown
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
```

**Step 7: 提交更改**

```bash
git add CLAUDE.md
git commit -m "docs: 更新文档反映简化后的架构

- 更新项目概述为固定Niri单桌面
- 删除桌面选择、GNOME、GRUB主题说明
- 删除Reflector和Flathub选择文档
- 简化环境变量列表
- 更新模块说明为自动安装模式

Co-Authored-By: Claude Sonnet 4.5 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: 最终验证和测试

**Step 1: 语法检查所有修改的脚本**

```bash
bash -n scripts/install.sh
bash -n scripts/modules.sh
bash -n scripts/00-utils.sh
```

预期输出: 无错误

**Step 2: 检查残留的交互逻辑**

```bash
# 检查是否还有read -t命令（交互提示）
grep -n "read -t" scripts/*.sh || echo "No interactive prompts found"

# 检查是否还有已删除的常量引用
grep -rn "DESKTOP_SELECTION_TIMEOUT\|REFLECTOR_TIMEOUT\|FLATHUB_SELECTION_TIMEOUT\|GRUB_THEME_SELECTION_TIMEOUT\|TTY_AUTOLOGIN_TIMEOUT\|APPS_SELECTION_TIMEOUT" scripts/ || echo "No old constants found"
```

预期输出: "No interactive prompts found" 或仅剩磁盘选择的read命令

**Step 3: 验证文件删除**

```bash
# 确认已删除的目录不存在
[ ! -d "gnome-dotfiles" ] && echo "✓ gnome-dotfiles deleted"
[ ! -d "grub-themes" ] && echo "✓ grub-themes deleted"
```

预期输出: 两个 ✓ 确认

**Step 4: 验证应用列表文件存在**

```bash
[ -f "niri-applist.txt" ] && echo "✓ niri-applist.txt exists"
[ -f "common-applist.txt" ] && echo "✓ common-applist.txt exists"
```

预期输出: 两个 ✓ 确认

**Step 5: 创建测试总结**

创建文件 `docs/SIMPLIFIED.md`:

```markdown
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
- ✅ Flathub镜像: SJTU
- ✅ 镜像优化: 使用默认
- ✅ Niri依赖: 安装全部48个包
- ✅ 应用软件: 安装全部93个包

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
```

**Step 6: 最终提交**

```bash
git add docs/SIMPLIFIED.md
git commit -m "docs: 添加简化版本说明文档

- 总结所有移除的功能
- 说明固定的配置
- 提供零交互安装示例
- 记录技术变更细节

Co-Authored-By: Claude Sonnet 4.5 (1M context) <noreply@anthropic.com>"
```

---

## 执行顺序

**关键依赖关系:**
- Task 1-3 可并行（不同文件）
- Task 4-5 依赖Task 3（Flathub函数删除）
- Task 6-7 可并行
- Task 8 依赖所有前置任务
- Task 9 必须最后执行

**推荐执行顺序:**
1. Task 1 (桌面选择) → Task 2 (Reflector) → Task 8 (文档) → Task 9 (验证)
2. Task 3 (Flathub) → Task 4 (Niri) → Task 5 (Apps)
3. Task 6 (GNOME) + Task 7 (GRUB) 并行

**预计总时间:** 15-20分钟（手动执行每个步骤）

---

## 回滚方案

如果需要回滚所有更改：

```bash
# 查看提交历史
git log --oneline -10

# 回滚到简化前的提交
git reset --hard <commit-id-before-task-1>

# 或使用git revert逐个撤销
git revert <commit-id> --no-edit
```

## 注意事项

1. **备份重要文件**: 在执行前备份 `scripts/` 和配置文件
2. **测试环境**: 建议先在虚拟机测试完整安装流程
3. **保留应用列表**: 不要修改 `niri-applist.txt` 和 `common-applist.txt`
4. **Git历史**: 每个Task单独提交，便于追踪和回滚
