#!/bin/bash

# ==============================================================================
# modules.sh - Consolidated module runner
# Usage: bash scripts/modules.sh <module-name>
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/00-utils.sh"
enable_strict_mode

MODULE="${1:-}"

case "$MODULE" in
  "00-btrfs-init.sh")
    
    # ==============================================================================
    # 00-btrfs-init.sh - Pre-install Snapshot Safety Net (Root & Home)
    # ==============================================================================
    
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    check_root
    
    section "阶段 0" "系统快照初始化"
    
    # ------------------------------------------------------------------------------
    # 1. Configure Root (/)
    # ------------------------------------------------------------------------------
    log "检查 Root 文件系统..."
    ROOT_FSTYPE=$(findmnt -n -o FSTYPE /)
    
    if [ "$ROOT_FSTYPE" == "btrfs" ]; then
        log "Root 为 Btrfs，安装 Snapper..."
        # Minimal install for snapshot capability
        exe pacman -Syu --noconfirm --needed snapper less
        
        log "配置 Root 的 Snapper..."
        if ! snapper list-configs | grep -q "^root "; then
            # Cleanup existing dir to allow subvolume creation
            if [ -d "/.snapshots" ]; then
                exe_silent umount /.snapshots
                exe_silent rm -rf /.snapshots
            fi
            
            if exe snapper -c root create-config /; then
                success "已创建配置 'root'。"
                
                # Apply Retention Policy
                exe snapper -c root set-config \
                    ALLOW_GROUPS="wheel" \
                    TIMELINE_CREATE="yes" \
                    TIMELINE_CLEANUP="yes" \
                    NUMBER_LIMIT="10" \
                    NUMBER_MIN_AGE="0" \
                    NUMBER_LIMIT_IMPORTANT="5" \
                    TIMELINE_LIMIT_HOURLY="3" \
                    TIMELINE_LIMIT_DAILY="0" \
                    TIMELINE_LIMIT_WEEKLY="0" \
                    TIMELINE_LIMIT_MONTHLY="0" \
                    TIMELINE_LIMIT_YEARLY="0"
    
                exe systemctl enable snapper-cleanup.timer
                exe systemctl enable snapper-timeline.timer
            fi
        else
            log "配置 'root' 已存在。"
        fi
    else
        warn "Root 不是 Btrfs，跳过 Root 快照。"
    fi
    
    # ------------------------------------------------------------------------------
    # 2. Configure Home (/home)
    # ------------------------------------------------------------------------------
    log "检查 Home 文件系统..."
    
    # Check if /home is a mountpoint and is btrfs
    if findmnt -n -o FSTYPE /home | grep -q "btrfs"; then
        log "Home 为 Btrfs，配置 Home 的 Snapper..."
        
        if ! snapper list-configs | grep -q "^home "; then
            # Cleanup .snapshots in home if exists
            if [ -d "/home/.snapshots" ]; then
                exe_silent umount /home/.snapshots
                exe_silent rm -rf /home/.snapshots
            fi
            
            if exe snapper -c home create-config /home; then
                success "已创建配置 'home'。"
                
                # Apply same policy to home
                exe snapper -c home set-config \
                    ALLOW_GROUPS="wheel" \
                    TIMELINE_CREATE="yes" \
                    TIMELINE_CLEANUP="yes" \
                    NUMBER_MIN_AGE="0" \
                    NUMBER_LIMIT="10" \
                    NUMBER_LIMIT_IMPORTANT="5" \
                    TIMELINE_LIMIT_HOURLY="3" \
                    TIMELINE_LIMIT_DAILY="0" \
                    TIMELINE_LIMIT_WEEKLY="0" \
                    TIMELINE_LIMIT_MONTHLY="0" \
                    TIMELINE_LIMIT_YEARLY="0"
            fi
        else
            log "配置 'home' 已存在。"
        fi
    else
        log "/home 不是单独的 Btrfs 卷，跳过。"
    fi
    
    # ------------------------------------------------------------------------------
    # 3. Create Initial Safety Snapshots
    # ------------------------------------------------------------------------------
    section "安全网" "创建初始快照"
    
    # Snapshot Root
    if snapper list-configs | grep -q "root "; then
        if snapper -c root list --columns description | grep -q "Before Shorin Setup"; then
            log "快照已创建。"
        else
            log "创建 Root 快照..."
            if exe snapper -c root create --description "Before Shorin Setup"; then
                success "Root 快照已创建。"
            else
                error "创建 Root 快照失败。"
                warn "没有安全快照无法继续，已中止。"
                exit 1
            fi
        fi
    fi
    
    # Snapshot Home
    if snapper list-configs | grep -q "home "; then
        if snapper -c home list --columns description | grep -q "Before Shorin Setup"; then
            log "快照已创建。"
        else
            log "创建 Home 快照..."
            if exe snapper -c home create --description "Before Shorin Setup"; then
                success "Home 快照已创建。"
            else
                error "创建 Home 快照失败。"
                # This is less critical than root, but should still be a failure.
                exit 1
            fi
        fi
    fi
    
    log "模块 00 完成，可以继续。"
    ;;

  "01-base.sh")
    
    # ==============================================================================
    # 01-base.sh - Base System Configuration
    # ==============================================================================
    
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    check_root
    
    log "开始阶段 1：基础系统配置..."
    
    # ------------------------------------------------------------------------------
    # 1. Set Global Default Editor
    # ------------------------------------------------------------------------------
    section "步骤 1/6" "全局默认编辑器"
    
    TARGET_EDITOR="vim"
    
    if command -v nvim &> /dev/null; then
        TARGET_EDITOR="nvim"
        log "检测到 Neovim。"
    elif command -v nano &> /dev/null; then
        TARGET_EDITOR="nano"
        log "检测到 Nano。"
    else
        log "未发现 Neovim 或 Nano，安装 Vim..."
        if ! command -v vim &> /dev/null; then
            exe pacman -Syu --noconfirm gvim
        fi
    fi
    
    log "在 /etc/environment 设置 EDITOR=$TARGET_EDITOR..."
    
    if grep -q "^EDITOR=" /etc/environment; then
        exe sed -i "s/^EDITOR=.*/EDITOR=${TARGET_EDITOR}/" /etc/environment
    else
        # exe handles simple commands, for redirection we wrap in bash -c or just run it
        # For simplicity in logging, we just run it and log success
        echo "EDITOR=${TARGET_EDITOR}" >> /etc/environment
    fi
    success "全局 EDITOR 已设置为：${TARGET_EDITOR}"
    
    # ------------------------------------------------------------------------------
    # 2. Enable 32-bit (multilib) Repository
    # ------------------------------------------------------------------------------
    section "步骤 2/6" "Multilib 仓库"
    
    if grep -q "^\[multilib\]" /etc/pacman.conf; then
        success "[multilib] 已启用。"
    else
        log "取消注释 [multilib]..."
        # Uncomment [multilib] and the following Include line
        exe sed -i "/\[multilib\]/,/Include/"'s/^#//' /etc/pacman.conf
        
        log "刷新数据库..."
        exe pacman -Syu
        success "[multilib] 启用完成。"
    fi
    
    # ------------------------------------------------------------------------------
    # 3. Install Base Fonts
    # ------------------------------------------------------------------------------
    section "步骤 3/6" "基础字体"
    
    log "安装 adobe-source-han-serif-cn-fonts adobe-source-han-sans-cn-fonts noto-fonts-cjk, noto-fonts, emoji..."
    exe pacman -S --noconfirm --needed adobe-source-han-serif-cn-fonts adobe-source-han-sans-cn-fonts noto-fonts-cjk noto-fonts noto-fonts-emoji ttf-jetbrains-mono-nerd
    log "基础字体已安装。"
    
    log "安装 terminus-font..."
    # 安装 terminus-font 包
    exe pacman -S --noconfirm --needed terminus-font
    
    log "为当前会话设置字体..."
    exe setfont ter-v20n
    
    log "配置永久 vconsole 字体..."
    if [ -f /etc/vconsole.conf ] && grep -q "^FONT=" /etc/vconsole.conf; then
        exe sed -i 's/^FONT=.*/FONT=ter-v20n/' /etc/vconsole.conf
    else
        echo "FONT=ter-v20n" >> /etc/vconsole.conf
    fi
    
    log "重启 systemd-vconsole-setup..."
    exe systemctl restart systemd-vconsole-setup
    
    success "TTY 字体已配置（ter-v20n）。"
    # ------------------------------------------------------------------------------
    # 4. Configure archlinuxcn Repository
    # ------------------------------------------------------------------------------
    section "步骤 4/6" "ArchLinuxCN 仓库"
    
    if grep -q "\[archlinuxcn\]" /etc/pacman.conf; then
        success "archlinuxcn 仓库已存在。"
    else
        log "将 archlinuxcn 镜像添加到 pacman.conf..."
        cat <<-'EOT' >> /etc/pacman.conf
	
	[archlinuxcn]
	Server = https://mirrors.ustc.edu.cn/archlinuxcn/$arch
	Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxcn/$arch
	Server = https://mirrors.hit.edu.cn/archlinuxcn/$arch
	Server = https://repo.huaweicloud.com/archlinuxcn/$arch
	EOT
        success "镜像已添加。"
    fi
    
    log "安装 archlinuxcn-keyring..."
    # Keyring installation often needs -Sy specifically, but -Syu is safe too
    exe pacman -Syu --noconfirm archlinuxcn-keyring
    success "ArchLinuxCN 已配置。"
    
    # ------------------------------------------------------------------------------
    # 5. Install AUR Helpers
    # ------------------------------------------------------------------------------
    section "步骤 5/6" "AUR 助手"
    
    log "安装 yay 和 paru..."
    exe pacman -S --noconfirm --needed base-devel yay paru
    success "AUR 助手已安装。"
    
    log "模块 01 完成。"
    ;;

  "02-musthave.sh")
    
    # ==============================================================================
    # 02-musthave.sh - Essential Software, Drivers & Locale
    # ==============================================================================
    
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    check_root
    
    CN_MIRROR=${CN_MIRROR:-0}
    DEBUG=${DEBUG:-0}
    
    log ">>> 开始阶段 2：必装软件与驱动"
    # ------------------------------------------------------------------------------
    # 1. Btrfs Extras & GRUB (Config was done in 00-btrfs-init)
    # ------------------------------------------------------------------------------
    section "步骤 1/8" "Btrfs 扩展与 GRUB"
    
    ROOT_FSTYPE=$(findmnt -n -o FSTYPE /)
    
    if [ "$ROOT_FSTYPE" == "btrfs" ]; then
        log "检测到 Btrfs 文件系统。"
        exe pacman -S --noconfirm --needed snapper btrfs-assistant
        success "Snapper 工具已安装。"
    
        # GRUB Integration
    if [ -f "/etc/default/grub" ] && command -v grub-mkconfig >/dev/null 2>&1; then
            log "检查 GRUB..."
            
             FOUND_EFI_GRUB=""
            
            # 1. 使用 findmnt 查找所有 vfat 类型的挂载点 (通常 ESP 是 vfat)
            # -n: 不输出标题头
            # -l: 列表格式输出
            # -o TARGET: 只输出挂载点路径
            # -t vfat: 限制文件系统类型
            # sort -r: 反向排序，这样 /boot/efi 会排在 /boot 之前（如果同时存在），优先匹配深层路径
            VFAT_MOUNTS=$(findmnt -n -l -o TARGET -t vfat)
    
            if [ -n "$VFAT_MOUNTS" ]; then
                # 2. 遍历这些 vfat 分区，寻找 grub 目录
                # 使用 while read 循环处理多行输出
                while read -r mountpoint; do
                    # 检查这个挂载点下是否有 grub 目录
                    if [ -d "$mountpoint/grub" ]; then
                        FOUND_EFI_GRUB="$mountpoint/grub"
                        log "在 ESP 挂载点找到 GRUB 目录：$mountpoint"
                        break 
                    fi
                done <<< "$VFAT_MOUNTS"
            fi
    
            # 3. 如果找到了位于 ESP 中的 GRUB 真实路径
            if [ -n "$FOUND_EFI_GRUB" ]; then
                
                # -e 判断存在, -L 判断是软链接 
                if [ -e "/boot/grub" ] || [ -L "/boot/grub" ]; then
                    warn "跳过" "/boot/grub 已存在，未创建软链接。"
                else
                    # 5. 仅当完全不存在时，创建软链接
                    warn "/boot/grub 缺失，链接到 $FOUND_EFI_GRUB..."
                    exe ln -sf "$FOUND_EFI_GRUB" /boot/grub
                    success "已创建软链接：/boot/grub -> $FOUND_EFI_GRUB"
                fi
            else
                log "在所有已挂载的 vfat 中未找到 'grub' 目录，跳过软链接检查。"
            fi
            # --- 核心修改结束 ---
    
            exe pacman -Syu --noconfirm --needed grub-btrfs inotify-tools
            systemctl_enable_now grub-btrfsd
    
            if ! grep -q "grub-btrfs-overlayfs" /etc/mkinitcpio.conf; then
                log "向 mkinitcpio 添加 overlayfs hook..."
                sed -i 's/^HOOKS=(\(.*\))/HOOKS=(\1 grub-btrfs-overlayfs)/' /etc/mkinitcpio.conf
                exe mkinitcpio -P
            fi
    
            log "GRUB 配置重新生成推迟到最后一步。"
        fi
    else
        log "Root 不是 Btrfs，跳过 Snapper 配置。"
    fi
    
    # ------------------------------------------------------------------------------
    # 2. Audio & Video
    # ------------------------------------------------------------------------------
    section "步骤 2/8" "音频与视频"
    
    log "安装固件..."
    exe pacman -S --noconfirm --needed sof-firmware alsa-ucm-conf alsa-firmware
    
    log "安装 Pipewire 套件..."
    exe pacman -S --noconfirm --needed pipewire lib32-pipewire wireplumber pipewire-pulse pipewire-alsa pipewire-jack pavucontrol
    
    exe systemctl --global enable pipewire pipewire-pulse wireplumber
    success "音频配置完成。"
    
    # ------------------------------------------------------------------------------
    # 3. Locale
    # ------------------------------------------------------------------------------
    section "步骤 3/8" "Locale 配置"
    
    LOCALE="${LOCALE:-en_US.UTF-8}"
    EXTRA_LOCALES="${EXTRA_LOCALES:-zh_CN.UTF-8}"
    MISSING_LOCALE=false
    
    for loc in $LOCALE $EXTRA_LOCALES; do
        loc_key=$(echo "$loc" | tr '[:upper:]' '[:lower:]' | sed 's/utf-8/utf8/')
        if locale -a | tr '[:upper:]' '[:lower:]' | grep -q "^${loc_key}$"; then
            success "Locale 已启用：$loc"
        else
            warn "Locale 缺失：$loc"
            MISSING_LOCALE=true
        fi
    done
    
    if [ "$MISSING_LOCALE" = true ]; then
        if [ "${FORCE_LOCALE_GEN:-0}" = "1" ]; then
            log "检测到 FORCE_LOCALE_GEN=1，启用并生成 locale..."
            for loc in $LOCALE $EXTRA_LOCALES; do
                if ! grep -q -E "^${loc} UTF-8" /etc/locale.gen; then
                    sed -i "s/^#\\s*${loc} UTF-8/${loc} UTF-8/" /etc/locale.gen
                    if ! grep -q -E "^${loc} UTF-8" /etc/locale.gen; then
                        echo "${loc} UTF-8" >> /etc/locale.gen
                    fi
                fi
            done
            if exe locale-gen; then
                success "Locale 生成成功。"
            else
                error "Locale 生成失败。"
            fi
        else
            log "Locale 生成由 00-arch-base-install.sh 处理（ISO 模式）。"
            log "如果是已安装系统，请运行：locale-gen 或设置 FORCE_LOCALE_GEN=1"
        fi
    else
        success "所有需要的 locale 已启用。"
    fi
    
    # ------------------------------------------------------------------------------
    # 4. Input Method
    # ------------------------------------------------------------------------------
    section "步骤 4/8" "输入法（Fcitx5）"
    
    # chinese-addons备用
    exe pacman -S --noconfirm --needed fcitx5-im fcitx5-chinese-addons fcitx5-rime
    
    # rime-ice-git 是 AUR 包，需使用 yay（仅在已有用户时）
    if command -v yay &>/dev/null; then
        AUR_USER=""
        if [ -f "/tmp/shorin_install_user" ]; then
            AUR_USER=$(cat /tmp/shorin_install_user)
        else
            AUR_USER=$(awk -F: '$3 == 1000 {print $1}' /etc/passwd || true)
        fi
    
        if [ -n "$AUR_USER" ]; then
            TARGET_USER="$AUR_USER"
            HOME_DIR="/home/$TARGET_USER"
            export TARGET_USER HOME_DIR
    
            SUDO_TEMP_FILE="$(temp_sudo_begin "$TARGET_USER")"
            trap 'temp_sudo_end "$SUDO_TEMP_FILE"' EXIT
    
            if ! is_package_installed "rime-ice-git"; then
                if ! as_user yay -S --noconfirm --needed --answerdiff=None --answerclean=None rime-ice-git; then
                    warn "AUR 包安装失败：rime-ice-git"
                fi
            fi
    
            temp_sudo_end "$SUDO_TEMP_FILE"
            trap - EXIT
        else
            warn "尚未检测到目标用户，跳过 AUR 包：rime-ice-git"
        fi
    else
        warn "未找到 yay，跳过 AUR 包：rime-ice-git"
    fi
    
    success "Fcitx5 已安装。"
    
    # ------------------------------------------------------------------------------
    # 5. Bluetooth (Smart Detection)
    # ------------------------------------------------------------------------------
    section "步骤 5/8" "蓝牙"
    
    # Ensure detection tools are present
    log "检测蓝牙硬件..."
    exe pacman -S --noconfirm --needed usbutils pciutils
    
    BT_FOUND=false
    
    # 1. Check USB
    if lsusb | grep -qi "bluetooth"; then BT_FOUND=true; fi
    # 2. Check PCI
    if lspci | grep -qi "bluetooth"; then BT_FOUND=true; fi
    # 3. Check RFKill
    if rfkill list bluetooth >/dev/null 2>&1; then BT_FOUND=true; fi
    
    if [ "$BT_FOUND" = true ]; then
        info_kv "硬件" "已检测到"
    
        log "安装 Bluez "
        exe pacman -S --noconfirm --needed bluez
    
        systemctl_enable_now bluetooth
        success "蓝牙服务已启用。"
    else
        info_kv "硬件" "未检测到"
        warn "未检测到蓝牙设备，跳过安装。"
    fi
    
    # ------------------------------------------------------------------------------
    # 6. Power
    # ------------------------------------------------------------------------------
    section "步骤 6/8" "电源管理"
    
    exe pacman -S --noconfirm --needed power-profiles-daemon
    systemctl_enable_now power-profiles-daemon
    success "Power profiles daemon 已启用。"
    
    # ------------------------------------------------------------------------------
    # 7. Fastfetch
    # ------------------------------------------------------------------------------
    section "步骤 7/8" "Fastfetch"
    
    exe pacman -S --noconfirm --needed fastfetch
    success "Fastfetch 已安装。"
    
    log "模块 02 完成。"
    
    # ------------------------------------------------------------------------------
    # 9. flatpak
    # ------------------------------------------------------------------------------
    
    exe pacman -S --noconfirm --needed flatpak
    exe flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    
    CURRENT_TZ=$(readlink -f /etc/localtime)
    IS_CN_ENV=false
    if [[ "$CURRENT_TZ" == *"Shanghai"* ]] || [ "$CN_MIRROR" == "1" ] || [ "$DEBUG" == "1" ]; then
      IS_CN_ENV=true
      info_kv "地区" "中国优化已启用"
    fi
    
    if [ "$IS_CN_ENV" = true ]; then
      select_flathub_mirror
    else
      log "使用全球源。"
    fi
    ;;

  "02a-dualboot-fix.sh")
    
    # ==============================================================================
    # Script: 02a-dualboot-fix.sh
    # Purpose: Auto-configure for Windows dual-boot (OS-Prober only).
    # ==============================================================================
    
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    check_root
    
    # --- GRUB Installation Check ---
    if ! command -v grub-mkconfig &>/dev/null || [ ! -f "/etc/default/grub" ]; then
        warn "未检测到 GRUB，跳过双系统配置。"
        exit 0
    fi
    
    # --- Main Script ---
    
    section "阶段 2A" "双系统配置（Windows）"
    
    # ------------------------------------------------------------------------------
    # 1. Detect Windows
    # ------------------------------------------------------------------------------
    section "步骤 1/2" "系统分析"
    
    log "安装双系统检测工具（os-prober、exfat-utils）..."
    exe pacman -S --noconfirm --needed os-prober exfat-utils
    
    log "扫描 Windows 安装..."
    WINDOWS_DETECTED=$(os-prober | grep -qi "windows" && echo "true" || echo "false")
    
    if [ "$WINDOWS_DETECTED" != "true" ]; then
        log "os-prober 未检测到 Windows 安装。"
        log "跳过双系统相关配置。"
        log "模块 02a 完成（已跳过）。"
        exit 0
    fi
    
    success "检测到 Windows 安装。"
    
    # --- Check if already configured ---
    OS_PROBER_CONFIGURED=$(grep -q -E '^\s*GRUB_DISABLE_OS_PROBER\s*=\s*(false|"false")' /etc/default/grub && echo "true" || echo "false")
    
    if [ "$OS_PROBER_CONFIGURED" == "true" ]; then
        log "双系统设置似乎已配置。"
        echo ""
        echo -e "   ${H_YELLOW}>>> 看起来你的双系统已经配置完成。${NC}"
        echo ""
    fi
    
    # ------------------------------------------------------------------------------
    # 2. Configure GRUB for Dual-Boot
    # ------------------------------------------------------------------------------
    section "步骤 2/2" "启用 OS Prober"
    
    log "启用 OS Prober 以检测 Windows..."
    set_grub_value "GRUB_DISABLE_OS_PROBER" "false"
    
    success "双系统设置已更新。"
    
    log "GRUB 配置重新生成推迟到最后一步。"
    
    log "模块 02a 完成。"
    ;;

  "03-user.sh")
    
    # ==============================================================================
    # 03-user.sh - User Account & Environment Setup
    # ==============================================================================
    
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # 检查 Root 权限
    check_root
    
    # ==============================================================================
    # Phase 0: 安装 zsh
    # ==============================================================================
    section "阶段 3（准备）" "安装 zsh"
    
    log "安装 zsh shell..."
    exe pacman -S --noconfirm --needed zsh
    success "zsh 已安装。"
    
    # ==============================================================================
    # Phase 1: 用户检测与创建逻辑
    # ==============================================================================
    section "阶段 3" "用户账户设置"
    
    # 检测是否已存在普通用户 (UID 1000)
    EXISTING_USER=$(awk -F: '$3 == 1000 {print $1}' /etc/passwd)
    MY_USERNAME=""
    SKIP_CREATION=false
    
    if [ -n "$EXISTING_USER" ]; then
        info_kv "检测到用户" "$EXISTING_USER" "(UID 1000)"
        log "使用现有用户配置。"
        MY_USERNAME="$EXISTING_USER"
        SKIP_CREATION=true
    else
        warn "未找到标准用户（UID 1000）。"
        
        # 支持环境变量预设（零交互模式）
        if [ -n "${SHORIN_USERNAME:-}" ]; then
            MY_USERNAME="$SHORIN_USERNAME"
            info_kv "用户名" "$MY_USERNAME" "(来自环境变量)"
            log "使用 SHORIN_USERNAME 预设用户名。"
        else
            # 交互式输入用户名循环
            while true; do
                echo ""
                echo -ne "   ${ARROW} ${H_YELLOW}请输入新用户名：${NC} "
                read INPUT_USER
                
                INPUT_USER=$(echo "$INPUT_USER" | xargs)
                
                if [[ -z "$INPUT_USER" ]]; then
                    warn "用户名不能为空。"
                    continue
                fi
    
                echo -ne "   ${INFO} 创建用户 '${BOLD}${H_CYAN}${INPUT_USER}${NC}'？ [Y/n] "
                read CONFIRM
                CONFIRM=${CONFIRM:-Y}
                
                if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
                    MY_USERNAME="$INPUT_USER"
                    break
                else
                    log "已取消，请重新输入。"
                fi
            done
        fi
    fi
    
    # 将用户名导出到临时文件，供后续脚本 (如安装桌面环境时) 使用
    echo "$MY_USERNAME" > /tmp/shorin_install_user
    
    # ==============================================================================
    # Phase 2: 账户权限与密码配置
    # ==============================================================================
    section "步骤 2/4" "账户与权限"
    
    if [ "$SKIP_CREATION" = true ]; then
        log "检查 $MY_USERNAME 的权限..."
        if groups "$MY_USERNAME" | grep -q "\bwheel\b"; then
            success "用户已在 'wheel' 组。"
        else
            log "将用户加入 'wheel' 组..."
            exe usermod -aG wheel "$MY_USERNAME"
        fi
    else
        log "创建新用户 '${MY_USERNAME}'..."
        exe useradd -m -g wheel -s /bin/zsh "$MY_USERNAME"
        
        # 支持环境变量预设密码（零交互模式）
        if [ -n "${SHORIN_PASSWORD:-}" ]; then
            log "使用 SHORIN_PASSWORD 设置密码..."
            printf '%s:%s\n' "$MY_USERNAME" "$SHORIN_PASSWORD" | chpasswd
            PASSWORD_STATUS=$?
            
            if [ $PASSWORD_STATUS -eq 0 ]; then
                success "密码设置成功（非交互）。"
            else
                error "通过 chpasswd 设置密码失败。"
                exit 1
            fi
        else
            log "为 ${MY_USERNAME} 设置密码（交互）..."
            echo -e "   ${H_GRAY}--------------------------------------------------${NC}"
            passwd "$MY_USERNAME"
            PASSWORD_STATUS=$?
            echo -e "   ${H_GRAY}--------------------------------------------------${NC}"
            
            if [ $PASSWORD_STATUS -eq 0 ]; then 
                success "密码设置成功。"
            else 
                error "密码设置失败，脚本已中止。"
                exit 1
            fi
        fi
    fi
    
    # 1. 配置 Sudoers
    log "配置 sudoers 权限..."
    if grep -q "^# %wheel ALL=(ALL:ALL) ALL" /etc/sudoers; then
        # 使用 sed 去掉注释
        exe sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
        success "已取消 /etc/sudoers 中的 %wheel 注释。"
    elif grep -q "^%wheel ALL=(ALL:ALL) ALL" /etc/sudoers; then
        success "sudo 权限已启用。"
    else
        # 如果找不到标准行，则追加
        log "向 /etc/sudoers 追加 %wheel 规则..."
        echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers
        success "sudo 权限已配置。"
    fi
    
    # 2. 配置 Faillock (防止输错密码锁定) [新增部分]
    log "配置密码锁定策略（faillock）..."
    FAILLOCK_CONF="/etc/security/faillock.conf"
    
    if [ -f "$FAILLOCK_CONF" ]; then
        # 使用 sed 匹配被注释的(# deny =) 或者未注释的(deny =) 行，统一改为 deny = 0
        # 正则解释: ^#\? 匹配开头可选的井号; \s* 匹配可选空格
        exe sed -i 's/^#\?\s*deny\s*=.*/deny = 0/' "$FAILLOCK_CONF"
        success "账户锁定已禁用（deny=0）。"
    else
        # 极少数情况该文件不存在，虽然在 Arch 中默认是有这个文件的
        warn "未找到 $FAILLOCK_CONF，跳过锁定配置。"
    fi
    
    # ==============================================================================
    # Phase 3: 生成 XDG 用户目录
    # ==============================================================================
    section "步骤 3/4" "用户目录"
    
    # 安装工具
    exe pacman -Syu --noconfirm --needed xdg-user-dirs
    
    log "生成用户目录（Downloads、Documents 等）..."
    
    # 获取用户真实的 Home 目录 (处理用户可能更改过 home 的情况)
    REAL_HOME=$(getent passwd "$MY_USERNAME" | cut -d: -f6)
    
    # 强制以该用户身份运行更新命令
    # 注意：使用 env 设置 HOME 和 LANG 确保目录名为英文 (arch 习惯)
    if exe runuser -u "$MY_USERNAME" -- env LANG=en_US.UTF-8 HOME="$REAL_HOME" xdg-user-dirs-update --force; then
        success "目录已在 $REAL_HOME 创建。"
    else
        warn "生成标准目录失败。"
    fi
    
    # ==============================================================================
    # Phase 4: 环境配置 (PATH 与 .local/bin)
    # ==============================================================================
    section "步骤 4/4" "环境设置"
    
    # 1. 创建 ~/.local/bin
    # 关键点：使用 runuser 确保文件夹归属权是用户，而不是 root
    LOCAL_BIN_PATH="$REAL_HOME/.local/bin"
    
    log "创建用户可执行目录..."
    info_kv "目标" "$LOCAL_BIN_PATH"
    
    if exe runuser -u "$MY_USERNAME" -- mkdir -p "$LOCAL_BIN_PATH"; then
        success "目录已创建（所有者：$MY_USERNAME）"
    else
        error "创建 ~/.local/bin 失败"
    fi
    
    # 2. 配置全局 PATH (/etc/profile.d/)
    PROFILE_SCRIPT="/etc/profile.d/user_local_bin.sh"
    log "配置自动 PATH 检测..."
    
    # 写入配置脚本
    cat <<-'EOF' > "$PROFILE_SCRIPT"
	# Automatically add ~/.local/bin to PATH if it exists
	if [ -d "$HOME/.local/bin" ]; then
	    export PATH="$HOME/.local/bin:$PATH"
	fi
	EOF
    
    # 设置权限 (rw-r--r--)
    exe chmod 644 "$PROFILE_SCRIPT"
    
    if [ -f "$PROFILE_SCRIPT" ]; then
        success "PATH 脚本已安装到 /etc/profile.d/"
        info_kv "效果" "需要重新登录"
    else
        warn "创建 profile.d 脚本失败。"
    fi
    
    # ==============================================================================
    # Phase 5: 部署用户配置文件
    # ==============================================================================
    # Note: Shell配置(.zshrc/.bashrc)和应用配置(.config)
    # 由各自的桌面环境模块部署：
    #   - 04-niri-setup.sh    → niri-dotfiles/   (包含所有配置)
    #   - 04d-gnome.sh        → gnome-dotfiles/  (包含所有配置)
    # ==============================================================================
    log "用户配置部署交由桌面环境模块处理。"
    
    # ==============================================================================
    # 完成
    # ==============================================================================
    hr
    success "用户设置模块完成。"
    echo -e "   ${DIM}用户 '${MY_USERNAME}' 已准备好进行桌面环境配置。${NC}"
    echo ""
    ;;

  "03b-gpu-driver.sh")
    
    # ==============================================================================
    # 03b-gpu-driver.sh GPU Driver Installer 参考了cachyos的chwd脚本
    # ==============================================================================
    
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    check_root
    
    section "阶段 2b" "GPU 驱动设置"
    
    # ==============================================================================
    # 1. 变量声明与基础信息获取
    # ==============================================================================
    log "检测 GPU 硬件..."
    
    # 核心变量：存放 lspci 信息
    GPU_INFO=$(lspci -mm | grep -E -i "VGA|3D|Display")
    log "检测到 GPU 信息：\n$GPU_INFO"
    
    # 状态变量初始化
    HAS_AMD=false
    HAS_INTEL=false
    HAS_NVIDIA=false
    GPU_NUMBER=0
    # 待安装包数组
    PKGS=("libva-utils")
    # ==============================================================================
    # 2. 状态变更 & 基础包追加 (Base Packages)
    # ==============================================================================
    
    # --- AMD 检测 --- -q 静默，-i忽略大小写
    if echo "$GPU_INFO" | grep -q -i "AMD\|ATI"; then
        HAS_AMD=true
        info_kv "厂商" "检测到 AMD"
        # 追加 AMD 基础包
        PKGS+=("mesa" "lib32-mesa" "xf86-video-amdgpu" "vulkan-radeon" "lib32-vulkan-radeon" "linux-firmware-amdgpu" "gst-plugin-va" "opencl-mesa" "lib32-opencl-mesa" "opencl-icd-loader" "lib32-opencl-icd-loader" )
    fi
    
    # --- Intel 检测 ---
    if echo "$GPU_INFO" | grep -q -i "Intel"; then
        HAS_INTEL=true
        info_kv "厂商" "检测到 Intel"
        # 追加 Intel 基础包 (保证能亮机，能跑基础桌面)
        PKGS+=("mesa" "vulkan-intel" "lib32-mesa" "lib32-vulkan-intel" "gst-plugin-va" "linux-firmware-intel" "opencl-mesa" "lib32-opencl-mesa" "opencl-icd-loader" "lib32-opencl-icd-loader" )
    fi
    
    # --- NVIDIA 检测 ---
    if echo "$GPU_INFO" | grep -q -i "NVIDIA"; then
        HAS_NVIDIA=true
        info_kv "厂商" "检测到 NVIDIA"
        # 追加 NVIDIA 基础工具包
    fi
    
    # --- 多显卡检测 ---
    GPU_COUNT=$(echo "$GPU_INFO" | grep -c .)
    
    if [ "$GPU_COUNT" -ge 2 ]; then
        info_kv "GPU 布局" "检测到双/多 GPU（数量：$GPU_COUNT）"
        # 安装 vulkan-mesa-layers 以支持 vk-device-select
        PKGS+=("vulkan-mesa-layers" "lib32-vulkan-mesa-layers")
    
        if [[ $HAS_NVIDIA == true ]]; then 
        PKGS+=("nvidia-prime" "switcheroo-control")
            # fix gtk4 issue with nvidia dual gpu
            if grep -q "GSK_RENDERER" "/etc/environment"; then
                echo 'GSK_RENDERER=gl' >> /etc/environment
            fi
        fi
    fi
    # ==============================================================================
    # 3. Conditional 包判断 
    # ==============================================================================
    
    # ------------------------------------------------------------------------------
    # 3.1 Intel 硬件编解码判断
    # ------------------------------------------------------------------------------
    if [ "$HAS_INTEL" = true ]; then
        if echo "$GPU_INFO" | grep -q -E -i "Arc|Xe|UHD|Iris|Raptor|Alder|Tiger|Rocket|Ice|Comet|Coffee|Kaby|Skylake|Broadwell|Gemini|Jasper|Elkhart|HD Graphics 6|HD Graphics 5[0-9][0-9]\b"; then
            log "   -> Intel：匹配到现代架构（iHD 路径）..."
            PKGS+=("intel-media-driver")
        else
            warn "   -> Intel：旧款或未知型号，跳过 intel-media-driver。"
        fi
    fi
    
    # ------------------------------------------------------------------------------
    # 3.2 NVIDIA 驱动版本与内核 Headers 判断
    # ------------------------------------------------------------------------------
    if [ "$HAS_NVIDIA" = true ]; then
        NV_MODEL=$(echo "$GPU_INFO" | grep -i "NVIDIA" | head -n 1)
        
        # 初始化一个标志位，只有匹配到支持的显卡才设为 true
        DRIVER_SELECTED=false
    
        # ==========================================================================
        #  nvidia-open 
        # ==========================================================================
        if echo "$NV_MODEL" | grep -q -E -i "RTX|GTX 16"; then
            log "   -> NVIDIA：检测到现代 GPU（Turing+），使用 Open Kernel Modules。"
            
            # 核心驱动包
            PKGS+=("nvidia-open-dkms" "nvidia-utils" "lib32-nvidia-utils" "opencl-nvidia" "lib32-opencl-nvidia" "libva-nvidia-driver" "vulkan-icd-loader" "lib32-vulkan-icd-loader" "opencl-icd-loader" "lib32-opencl-icd-loader")
            DRIVER_SELECTED=true
    
        # ==========================================================================
        # nvidia-580xx-dkms
        # ==========================================================================
        elif echo "$NV_MODEL" | grep -q -E -i "GTX 10|GTX 950|GTX 960|GTX 970|GTX 980|GTX 745|GTX 750|GTX 750 Ti|GTX 840M|GTX 845M|GTX 850M|GTX 860M|GTX 950M|GTX 960M|GeForce 830M|GeForce 840M|GeForce 930M|GeForce 940M|GeForce GTX Titan X|Tegra X1|NVIDIA Titan X|NVIDIA Titan Xp|NVIDIA Titan V|NVIDIA Quadro GV100"; then
            log "   -> NVIDIA：检测到 Pascal/Maxwell GPU，使用 Proprietary DKMS。"
            PKGS+=("nvidia-580xx-dkms" "nvidia-580xx-utils" "opencl-nvidia-580xx" "lib32-opencl-nvidia-580xx" "lib32-nvidia-580xx-utils" "libva-nvidia-driver" "vulkan-icd-loader" "lib32-vulkan-icd-loader" "opencl-icd-loader" "lib32-opencl-icd-loader" )
            DRIVER_SELECTED=true
    
        # ==========================================================================
        # nvidia-470xx-dkms
        # ==========================================================================
        elif echo "$NV_MODEL" | grep -q -E -i "GTX 6[0-9][0-9]|GTX 760|GTX 765|GTX 770|GTX 775|GTX 780|GTX 860M|GT 6[0-9][0-9]|GT 710M|GT 720|GT 730M|GT 735M|GT 740|GT 745M|GT 750M|GT 755M|GT 920M|Quadro 410|Quadro K500|Quadro K510|Quadro K600|Quadro K610|Quadro K1000|Quadro K1100|Quadro K2000|Quadro K2100|Quadro K3000|Quadro K3100|Quadro K4000|Quadro K4100|Quadro K5000|Quadro K5100|Quadro K6000|Tesla K10|Tesla K20|Tesla K40|Tesla K80|NVS 510|NVS 1000|Tegra K1|Titan|Titan Z"; then
    
            log "   -> NVIDIA：检测到 Kepler GPU，使用 nvidia-470xx-dkms。"
            PKGS+=("nvidia-470xx-dkms" "nvidia-470xx-utils" "opencl-nvidia-470xx" "vulkan-icd-loader" "lib32-nvidia-470xx-utils" "lib32-opencl-nvidia-470xx" "lib32-vulkan-icd-loader" "libva-nvidia-driver" "opencl-icd-loader" "lib32-opencl-icd-loader")
            DRIVER_SELECTED=true
    
        # ==========================================================================
        # others
        # ========================================================================== 
        else
            warn "   -> NVIDIA：检测到旧款 GPU（$NV_MODEL）。"
            warn "   -> 请手动安装 GPU 驱动。"
        fi
    
        # ==========================================================================
        # headers
        # ==========================================================================
        if [ "$DRIVER_SELECTED" = true ]; then
            log "   -> NVIDIA：扫描已安装内核的 headers..."
            
            # 1. 获取所有以 linux 开头的候选包
            CANDIDATES=$(pacman -Qq | grep "^linux" | grep -vE "headers|firmware|api|docs|tools|utils|qq")
    
            for kernel in $CANDIDATES; do
                # 2. 验证：只有在 /boot 下存在对应 vmlinuz 文件的才算是真内核
                if [ -f "/boot/vmlinuz-${kernel}" ]; then
                    HEADER_PKG="${kernel}-headers"
                    log "      + 发现内核：$kernel -> 添加 $HEADER_PKG"
                    PKGS+=("$HEADER_PKG")
                fi
            done
        fi
    fi
    
    # ==============================================================================
    # 4. 执行
    # ==============================================================================
    
    
    
    detect_target_user
    
    #--------------sudo temp file--------------------#
    SUDO_TEMP_FILE="$(temp_sudo_begin "$TARGET_USER")"
    log "已创建临时 sudo 文件..."
    
    cleanup_sudo() {
        temp_sudo_end "$SUDO_TEMP_FILE"
        log "安全：已撤销临时 sudo 权限。"
    }
    trap cleanup_sudo EXIT INT TERM
    
    if [ ${#PKGS[@]} -gt 0 ]; then
        # 数组去重
        UNIQUE_PKGS=($(printf "%s\n" "${PKGS[@]}" | sort -u))
        
        section "安装" "安装软件包"
        log "目标软件包：${UNIQUE_PKGS[*]}"
        
        # 执行安装
        exe runuser -u "$TARGET_USER" -- yay -S --noconfirm --needed --answerdiff=None --answerclean=None "${UNIQUE_PKGS[@]}"
        
        log "启用服务（如支持）..."
        systemctl enable --now nvidia-powerd &>/dev/null || true
        systemctl enable switcheroo-control.service &>/dev/null || true
        success "GPU 驱动处理完成。"
    else
        warn "未匹配或不需要 GPU 驱动。"
    fi
    
    log "模块 02b 完成。"
    ;;

  "03c-snapshot-before-desktop.sh")
    
    # ==============================================================================
    # 03c-snapshot-before-desktop.sh
    # Creates a system snapshot before installing major Desktop Environments.
    # ==============================================================================
    
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # 权限检查
    check_root
    
    section "阶段 3c" "系统快照"
    
    # ==============================================================================
    
    create_checkpoint() {
        local MARKER="Before Desktop Environments"
        
        # 0. 检查 snapper 是否安装
        if ! command -v snapper &>/dev/null; then
            warn "未找到 Snapper 工具，跳过快照创建。"
            return
        fi
    
        # 1. Root 分区快照
        # 检查 root 配置是否存在
        if snapper -c root get-config &>/dev/null; then
            # 检查是否已存在同名快照 (避免重复创建)
            if snapper -c root list --columns description | grep -Fqx "$MARKER"; then
                log "快照 '$MARKER' 已存在于 [root]。"
            else
                log "在 [root] 创建安全检查点..."
                # 使用 --type single 表示这是一个独立的存档点
                snapper -c root create --description "$MARKER"
                success "Root 快照已创建。"
            fi
        else
            warn "Snapper 'root' 配置未建立，跳过 root 快照。"
        fi
    
        # 2. Home 分区快照 (如果存在 home 配置)
        if snapper -c home get-config &>/dev/null; then
            if snapper -c home list --columns description | grep -Fqx "$MARKER"; then
                log "快照 '$MARKER' 已存在于 [home]。"
            else
                log "在 [home] 创建安全检查点..."
                snapper -c home create --description "$MARKER"
                success "Home 快照已创建。"
            fi
        fi
    }
    
    # ==============================================================================
    # 执行
    # ==============================================================================
    
    log "准备创建还原点..."
    create_checkpoint
    
    log "模块 03c 完成。"
    ;;

  "04-niri-setup.sh")
    
    # ==============================================================================
    # 04-niri-setup.sh - Niri Desktop (Restored FZF & Robust AUR)
    # ==============================================================================
    
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PARENT_DIR="$(dirname "$SCRIPT_DIR")"
    DEBUG=${DEBUG:-0}
    CN_MIRROR=${CN_MIRROR:-0}
    UNDO_SCRIPT="$SCRIPT_DIR/modules.sh"
    
    # --- Constants ---
    readonly MAX_PACKAGE_INSTALL_ATTEMPTS=3
    readonly PACKAGE_RETRY_COOLDOWN_SECONDS=3
    readonly TTY_AUTOLOGIN_TIMEOUT=20
    readonly INSTALLATION_TIMEOUT=60
    
    check_root
    
    # --- [HELPER FUNCTIONS] ---
    
    
    # 2. Critical Failure Handler (The "Big Red Box")
    # 2. Critical Failure Handler (The "Big Red Box")
    critical_failure_handler() {
      local failed_reason="$1"
      trap - ERR
    
      echo ""
      echo -e "\033[0;31m################################################################\033[0m"
      echo -e "\033[0;31m#                                                              #\033[0m"
      echo -e "\033[0;31m#   检测到关键安装失败                                           #\033[0m"
      echo -e "\033[0;31m#                                                              #\033[0m"
      echo -e "\033[0;31m#   原因：$failed_reason\033[0m"
      echo -e "\033[0;31m#                                                              #\033[0m"
      echo -e "\033[0;31m#   选项：                                                     #\033[0m"
      echo -e "\033[0;31m#   1. 恢复快照（撤销更改并退出）                               #\033[0m"
      echo -e "\033[0;31m#   2. 重试 / 重新运行脚本                                     #\033[0m"
      echo -e "\033[0;31m#   3. 中止（立即退出）                                        #\033[0m"
      echo -e "\033[0;31m#                                                              #\033[0m"
      echo -e "\033[0;31m################################################################\033[0m"
      echo ""
    
      while true; do
        read -p "请选择 [1-3]：" -r choice
        case "$choice" in
        1)
          # Option 1: Restore Snapshot
          if [ -f "$UNDO_SCRIPT" ]; then
            warn "执行恢复脚本..."
            MARKER="Before Desktop Environments" \
            CLEAN_CACHE=1 \
            REMOVE_MODULE="04-niri-setup.sh" \
            REBOOT_COUNTDOWN_SECONDS=10 \
            bash "$UNDO_SCRIPT" rollback
            exit 1
          else
            error "恢复脚本缺失！请自行处理。"
            exit 1
          fi
          ;;
        2)
          # Option 2: Re-run Script
          warn "重新启动安装脚本..."
          echo "-----------------------------------------------------"
          sleep 1
          exec "$0" "$@"
          ;;
        3)
          # Option 3: Exit
          warn "用户选择中止。"
          warn "请先手动修复问题后再重试。"
          error "安装已中止。"
          exit 1
          ;;
        *) 
          echo "输入无效，请输入 1、2 或 3。" 
          ;;
        esac
      done
    }
    
    # 3. Robust Package Installation with Retry Loop
    ensure_package_installed() {
      local pkg="$1"
      local context="$2" # e.g., "Repo" or "AUR"
      local max_attempts=$MAX_PACKAGE_INSTALL_ATTEMPTS
      local attempt=1
      local install_success=false
    
      # 1. Check if already installed
      if is_package_installed "$pkg"; then
        return 0
      fi
    
      # 2. Retry Loop
      while [ $attempt -le $max_attempts ]; do
        if [ $attempt -gt 1 ]; then
          warn "重试 '$pkg'（$context）...（第 $attempt/$max_attempts 次）"
          sleep $PACKAGE_RETRY_COOLDOWN_SECONDS # Cooldown
        else
          log "安装 '$pkg'（$context）..."
        fi
    
        # Try installation
        if install_yay_package "$pkg"; then
          install_success=true
          break
        else
          warn "第 $attempt/$max_attempts 次尝试失败：'$pkg'。"
        fi
    
        ((attempt++))
      done
    
      # 3. Final Verification
      if [ "$install_success" = true ] && is_package_installed "$pkg"; then
        success "已安装 '$pkg'。"
      else
        critical_failure_handler "Failed to install '$pkg' after $max_attempts attempts."
      fi
    }
    
    section "阶段 4" "Niri 桌面环境"
    
    # ==============================================================================
    # STEP 0: Safety Checkpoint
    # ==============================================================================
    
    # Enable Trap
    trap 'critical_failure_handler "Script Error at Line $LINENO"' ERR
    
    # ==============================================================================
    # STEP 1: Identify User & DM Check
    # ==============================================================================
    log "识别用户..."
    detect_target_user
    info_kv "目标" "$TARGET_USER"
    
    # DM Check
    KNOWN_DMS=("gdm" "sddm" "lightdm" "lxdm" "slim" "xorg-xdm" "ly" "greetd")
    SKIP_AUTOLOGIN=false
    DM_FOUND=""
    for dm in "${KNOWN_DMS[@]}"; do
      if is_package_installed "$dm"; then
        DM_FOUND="$dm"
        break
      fi
    done
    
    if [ -n "$DM_FOUND" ]; then
      info_kv "冲突" "${H_RED}$DM_FOUND${NC}"
      SKIP_AUTOLOGIN=true
    else
      read -t "$TTY_AUTOLOGIN_TIMEOUT" -p "$(echo -e "   ${H_CYAN}启用 TTY 自动登录？[Y/n]（默认 Y）： ${NC}")" choice || true
      [[ "${choice:-Y}" =~ ^[Yy]$ ]] && SKIP_AUTOLOGIN=false || SKIP_AUTOLOGIN=true
    fi
    
    # ==============================================================================
    # STEP 2: Core Components
    # ==============================================================================
    section "步骤 1/9" "核心组件"
    PKGS="niri xdg-desktop-portal-gnome fuzzel libnotify mako polkit-gnome"
    exe pacman -S --noconfirm --needed $PKGS
    
    # ==============================================================================
    # STEP 3: File Manager
    # ==============================================================================
    section "步骤 2/9" "文件管理器"
    exe pacman -S --noconfirm --needed ffmpegthumbnailer gvfs-smb nautilus-open-any-terminal file-roller gnome-keyring gst-plugins-base gst-plugins-good gst-libav nautilus
    
    exe pacman -S --noconfirm --needed xdg-desktop-portal-gtk thunar tumbler ffmpegthumbnailer poppler-glib gvfs-smb file-roller thunar-archive-plugin gnome-keyring thunar-volman gvfs-mtp gvfs-gphoto2 webp-pixbuf-loader libgsf
    
    if [ ! -f /usr/bin/gnome-terminal ] || [ -L /usr/bin/gnome-terminal ]; then
      exe ln -sf /usr/bin/ghostty /usr/bin/gnome-terminal
    fi
    
    # Nautilus Nvidia/Input Fix
    configure_nautilus_user
    
    section "步骤 3/9" "临时 sudo 文件"
    
    SUDO_TEMP_FILE="/etc/sudoers.d/99_shorin_installer_temp"
    SUDO_TEMP_FILE="$(temp_sudo_begin "$TARGET_USER" "$SUDO_TEMP_FILE")"
    log "已创建临时 sudo 文件..."
    cleanup_sudo() {
      temp_sudo_end "$SUDO_TEMP_FILE"
    }
    trap cleanup_sudo EXIT INT TERM
    # ==============================================================================
    # STEP 5: Dependencies (RESTORED FZF)
    # ==============================================================================
    section "步骤 4/9" "依赖"
    LIST_FILE="$PARENT_DIR/niri-applist.txt"
    
    # Ensure tools
    command -v fzf &>/dev/null || pacman -S --noconfirm fzf >/dev/null 2>&1
    
    if [ -f "$LIST_FILE" ]; then
      mapfile -t DEFAULT_LIST < <(grep -vE "^\s*#|^\s*$" "$LIST_FILE" | sed 's/#.*//; s/AUR://g' | xargs -n1)
    
      if [ ${#DEFAULT_LIST[@]} -eq 0 ]; then
        warn "应用列表为空，跳过。"
        PACKAGE_ARRAY=()
      else
        echo -e "\n   ${H_YELLOW}>>> ${INSTALLATION_TIMEOUT}s 后默认安装，按任意键自定义...${NC}"
    
        if read -t "$INSTALLATION_TIMEOUT" -n 1 -s -r; then
          # --- [RESTORED] Original FZF Selection Logic ---
          clear
          log "加载软件包列表..."
    
          SELECTED_LINES=$(fzf_select_apps "$LIST_FILE" "[TAB] 切换 | [ENTER] 安装 | [CTRL-D] 全不选 | [CTRL-A] 全选")
    
          clear
    
          if [ -z "$SELECTED_LINES" ]; then
            warn "用户取消选择，不安装任何内容。"
            PACKAGE_ARRAY=()
          else
            PACKAGE_ARRAY=()
            while IFS= read -r line; do
              raw_pkg=$(echo "$line" | cut -f1 -d$'\t' | xargs)
              clean_pkg="${raw_pkg#AUR:}"
              [ -n "$clean_pkg" ] && PACKAGE_ARRAY+=("$clean_pkg")
            done <<<"$SELECTED_LINES"
          fi
          # -----------------------------------------------
        else
          log "自动确认安装全部软件包。"
          PACKAGE_ARRAY=("${DEFAULT_LIST[@]}")
        fi
      fi
    
      # --- Installation Loop ---
      if [ ${#PACKAGE_ARRAY[@]} -gt 0 ]; then
        BATCH_LIST=()
        AUR_LIST=()
        info_kv "目标" "计划安装 ${#PACKAGE_ARRAY[@]} 个软件包。"
    
        for pkg in "${PACKAGE_ARRAY[@]}"; do
          [ "$pkg" == "imagemagic" ] && pkg="imagemagick"
          [[ "$pkg" == "AUR:"* ]] && AUR_LIST+=("${pkg#AUR:}") || BATCH_LIST+=("$pkg")
        done
    
        # 1. Batch Install Repo Packages
        if [ ${#BATCH_LIST[@]} -gt 0 ]; then
          log "阶段 1：批量安装仓库软件包..."
          as_user yay -Syu --noconfirm --needed --answerdiff=None --answerclean=None "${BATCH_LIST[@]}" || true  # Batch mode, keep direct call
    
          # Verify Each
          for pkg in "${BATCH_LIST[@]}"; do
            ensure_package_installed "$pkg" "Repo"
          done
        fi
    
        # 2. Sequential AUR Install
        if [ ${#AUR_LIST[@]} -gt 0 ]; then
          log "阶段 2：逐个安装 AUR 软件包..."
          for pkg in "${AUR_LIST[@]}"; do
            ensure_package_installed "$pkg" "AUR"
          done
        fi
    
        # Waybar fallback
        if ! command -v waybar &>/dev/null; then
          warn "Waybar 缺失，安装默认版本..."
          exe pacman -S --noconfirm --needed waybar
        fi
      else
        warn "未选择任何软件包。"
      fi
    else
      warn "未找到 niri-applist.txt。"
    fi
    
    # ==============================================================================
    # STEP 6: Dotfiles (Smart Recursive Symlink)
    # ==============================================================================
    section "步骤 5/9" "部署 Dotfiles"
    
    # 使用本地 niri-dotfiles 目录
    LOCAL_NIRI_DOTFILES="$PARENT_DIR/niri-dotfiles"
    
    # --- Smart Copy Function ---
    # 核心逻辑：递归复制配置文件，对于容器目录（.config, .local, share）则递归进入
    copy_recursive() {
      local src_dir="$1"
      local dest_dir="$2"
      local exclude_list="$3"
    
      # 确保目标容器目录存在 (比如确保 ~/.local/share 存在)
      as_user mkdir -p "$dest_dir"
    
      find "$src_dir" -mindepth 1 -maxdepth 1 -not -path '*/.git*' | while read -r src_path; do
        local item_name
        item_name=$(basename "$src_path")
    
        # 0. 排除检查
        if echo "$exclude_list" | grep -qw "$item_name"; then
          log "跳过排除项：$item_name"
          continue
        fi
    
        # 1. 判断是否是需要"穿透"的系统目录
        # 规则：如果遇到 .config, .local，或者 .local 下面的 share，不要直接复制整个目录，而是递归
        local need_recurse=false
    
        if [ "$item_name" == ".config" ]; then
            need_recurse=true
        elif [ "$item_name" == ".local" ]; then
            need_recurse=true
        # 只有当父目录名字是以 .local 结尾时，才穿透 share
        elif [[ "$src_dir" == *".local" ]] && [ "$item_name" == "share" ]; then
            need_recurse=true
        fi
    
        if [ "$need_recurse" = true ]; then
            # 递归进入：传入当前路径作为新的源和目标
            copy_recursive "$src_path" "$dest_dir/$item_name" "$exclude_list"
        else
            # 2. 具体的配置文件夹/文件（如 fcitx5, niri, .zshrc, .local/bin） -> 执行复制
            local target_path="$dest_dir/$item_name"
    
            # 先清理旧的目标（无论是文件、文件夹还是死链）
            if [ -e "$target_path" ] || [ -L "$target_path" ]; then
                as_user rm -rf "$target_path"
            fi
    
            # 复制文件或目录
            as_user cp -r "$src_path" "$target_path"
        fi
      done
    }
    
    # --- Execution ---
    
    # 部署本地 niri-dotfiles
    if [ ! -d "$LOCAL_NIRI_DOTFILES" ]; then
      critical_failure_handler "Local niri-dotfiles directory not found at: $LOCAL_NIRI_DOTFILES"
    fi
    
    log "部署本地 niri-dotfiles..."
    
    # 处理排除列表
    EXCLUDE_LIST=""
    if [ "$TARGET_USER" != "shorin" ]; then
      EXCLUDE_FILE="$PARENT_DIR/exclude-dotfiles.txt"
      if [ -f "$EXCLUDE_FILE" ]; then
        log "加载排除列表..."
        EXCLUDE_LIST=$(grep -vE "^\s*#|^\s*$" "$EXCLUDE_FILE" | tr '\n' ' ')
      fi
    fi
    
    # 备份现有配置
    if [ -d "$HOME_DIR/.config" ]; then
      log "备份现有配置..."
      as_user tar -czf "$HOME_DIR/config_backup_$(date +%s).tar.gz" -C "$HOME_DIR" .config 2>/dev/null || true
    fi
    
    # 直接从本地niri-dotfiles复制到用户目录（使用copy_recursive处理排除和递归）
    copy_recursive "$LOCAL_NIRI_DOTFILES" "$HOME_DIR" "$EXCLUDE_LIST"
    
    # 设置脚本执行权限
    if [ -d "$HOME_DIR/.local/bin" ]; then
      as_user chmod -R +x "$HOME_DIR/.local/bin"
    fi
    
    # --- Post-Process ---
    OUTPUT_EXAMPLE_KDL="$HOME_DIR/.config/niri/output-example.kdl"
    OUTPUT_KDL="$HOME_DIR/.config/niri/output.kdl"
    
    if [ "$TARGET_USER" != "shorin" ]; then
      as_user touch "$OUTPUT_KDL"
    
      # 修复 GTK Bookmarks
      BOOKMARKS_FILE="$HOME_DIR/.config/gtk-3.0/bookmarks"
      if [ -f "$BOOKMARKS_FILE" ]; then
        as_user sed -i "s/shorin/$TARGET_USER/g" "$BOOKMARKS_FILE"
        log "已更新 GTK 书签。"
      fi
    else
      if [ -f "$OUTPUT_EXAMPLE_KDL" ]; then
        as_user cp "$OUTPUT_EXAMPLE_KDL" "$OUTPUT_KDL"
      fi
    fi
    
    # GTK4 Theme
    GTK4="$HOME_DIR/.config/gtk-4.0"
    THEME="$HOME_DIR/.themes/adw-gtk3-dark/gtk-4.0"
    if [ -d "$GTK4" ] && [ -d "$THEME" ]; then
      as_user rm -f "$GTK4/gtk.css" "$GTK4/gtk-dark.css"
      as_user cp "$THEME/gtk-dark.css" "$GTK4/gtk-dark.css"
      as_user cp "$THEME/gtk.css" "$GTK4/gtk.css"
    fi
    
    # Flatpak overrides
    if command -v flatpak &>/dev/null; then
      as_user flatpak override --user --filesystem="$HOME_DIR/.themes"
      as_user flatpak override --user --filesystem=xdg-config/gtk-4.0
      as_user flatpak override --user --filesystem=xdg-config/gtk-3.0
      as_user flatpak override --user --env=GTK_THEME=adw-gtk3-dark
      as_user flatpak override --user --filesystem=xdg-config/fontconfig
    fi
    
    # Wallpapers
    if [ -d "$HOME_DIR/wallpapers" ]; then
      as_user mkdir -p "$HOME_DIR/Pictures"
      as_user mv "$HOME_DIR/wallpapers" "$HOME_DIR/Pictures/Wallpapers"
      log "壁纸已移动到 Pictures/Wallpapers"
    fi
    
    # Templates
    as_user mkdir -p "$HOME_DIR/Templates"
    as_user touch "$HOME_DIR/Templates/new"
    echo "#!/bin/bash" | as_user tee "$HOME_DIR/Templates/new.sh" >/dev/null
    as_user chmod +x "$HOME_DIR/Templates/new.sh"
    
    success "Dotfiles 部署完成。"
    
    # === remove gtk bottom =======
    if ! as_user gsettings set org.gnome.desktop.wm.preferences button-layout ":close"; then
      warn "应用 gsettings 失败（无活动会话？）。"
    fi
    # ==============================================================================
    # STEP 8: Hardware Tools
    # ==============================================================================
    section "步骤 7/9" "硬件"
    if pacman -Q ddcutil &>/dev/null; then
      gpasswd -a "$TARGET_USER" i2c
      lsmod | grep -q i2c_dev || echo "i2c-dev" >/etc/modules-load.d/i2c-dev.conf
    fi
    if pacman -Q swayosd &>/dev/null; then
      systemctl_enable_now swayosd-libinput-backend.service >/dev/null 2>&1 || true
    fi
    success "工具已配置。"
    
    # ==============================================================================
    # STEP 9: Cleanup & Auto-Login
    # ==============================================================================
    section "最终" "清理与启动"
    temp_sudo_end "$SUDO_TEMP_FILE"
    trap - EXIT INT TERM
    
    SVC_DIR="$HOME_DIR/.config/systemd/user"
    SVC_FILE="$SVC_DIR/niri-autostart.service"
    LINK="$SVC_DIR/default.target.wants/niri-autostart.service"
    
    if [ "$SKIP_AUTOLOGIN" = true ]; then
      log "已跳过自动登录。"
      as_user rm -f "$LINK" "$SVC_FILE"
    else
      log "配置 TTY 自动登录..."
      mkdir -p "/etc/systemd/system/getty@tty1.service.d"
      echo -e "[Service]\nExecStart=\nExecStart=-/sbin/agetty --noreset --noclear --autologin $TARGET_USER - \${TERM}" >"/etc/systemd/system/getty@tty1.service.d/autologin.conf"
    
      as_user mkdir -p "$(dirname "$LINK")"
      cat <<-EOT >"$SVC_FILE"
	[Unit]
	Description=Niri Session Autostart
	After=graphical-session-pre.target
	[Service]
	ExecStart=/usr/bin/niri-session
	Restart=on-failure
	[Install]
	WantedBy=default.target
	EOT
      as_user ln -sf "../niri-autostart.service" "$LINK"
      chown -R "$TARGET_USER" "$SVC_DIR"
      success "已启用。"
    fi
    
    trap - ERR
    log "模块 04 完成。"
    ;;

  "04d-gnome.sh")
    
    # ==============================================================================
    # GNOME Setup Script (04d-gnome.sh)
    # ==============================================================================
    
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PARENT_DIR="$(dirname "$SCRIPT_DIR")"
    log "初始化安装..."
    
    check_root
    
    # ==============================================================================
    #  Identify User
    # ==============================================================================
    log "识别用户..."
    detect_target_user
    TARGET_UID=$(id -u "$TARGET_USER")
    
    info_kv "目标用户" "$TARGET_USER"
    info_kv "Home 目录"    "$HOME_DIR"
    
    # ==================================
    # temp sudo without passwd
    # ==================================
    SUDO_TEMP_FILE="/etc/sudoers.d/99_shorin_installer_temp"
    SUDO_TEMP_FILE="$(temp_sudo_begin "$TARGET_USER" "$SUDO_TEMP_FILE")"
    log "已创建临时 sudo 文件..."
    
    cleanup_sudo() {
        temp_sudo_end "$SUDO_TEMP_FILE"
        log "安全：已撤销临时 sudo 权限。"
    }
    
    trap cleanup_sudo EXIT INT TERM
    
    #=================================================
    # Step 1: Install base pkgs
    #=================================================
    section "步骤 1" "安装基础软件包"
    log "安装 GNOME 和基础工具..."
    if as_user yay -S --noconfirm --needed --answerdiff=None --answerclean=None \
        gnome-desktop gnome-backgrounds gnome-tweaks gdm ghostty celluloid loupe \
        gnome-control-center gnome-software flatpak file-roller \
        nautilus-python firefox nm-connection-editor pacman-contrib \
        dnsmasq ttf-jetbrains-maple-mono-nf-xx-xx; then  # Batch install, keep direct call
    
            exe pacman -S --noconfirm --needed ffmpegthumbnailer gvfs-smb nautilus-open-any-terminal file-roller gnome-keyring gst-plugins-base gst-plugins-good gst-libav nautilus 
            log "软件包安装成功。"
    
    else
            error "安装失败。"
            exit 1
    fi
    
    
    # start gdm 
    log "启用 gdm..."
    exe systemctl enable gdm
    
    #=================================================
    # Step 2: Set default terminal
    #=================================================
    section "步骤 2" "设置默认终端"
    log "设置 GNOME 默认终端为 Ghostty..."
    
    if ! as_user gsettings set org.gnome.desktop.default-applications.terminal exec 'ghostty'; then
        warn "设置 GNOME 默认终端失败（无活动会话？）。"
    fi
    if ! as_user gsettings set org.gnome.desktop.default-applications.terminal exec-arg '-e'; then
        warn "设置 GNOME 终端 exec-arg 失败（无活动会话？）。"
    fi
    
    #=================================================
    # Step 3: Set locale
    #=================================================
    section "步骤 3" "设置 locale"
    log "为用户 $TARGET_USER 配置 GNOME locale..."
    ACCOUNT_FILE="/var/lib/AccountsService/users/$TARGET_USER"
    ACCOUNT_DIR=$(dirname "$ACCOUNT_FILE")
    # 确保目录存在
    mkdir -p "$ACCOUNT_DIR"
    # 设置语言为中文
    cat > "$ACCOUNT_FILE" <<-EOF
	[User]
	Languages=zh_CN.UTF-8
	EOF
    
    #=================================================
    # Step 4: Configure Shortcuts
    #=================================================
    section "步骤 4" "配置快捷键"
    log "配置快捷键..."
    
    # 使用 sudo -u 切换用户并注入 DBUS 变量以修改 dconf
    sudo -u "$TARGET_USER" bash <<-EOF
        # 关键：手动指定 DBUS 地址
        export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${TARGET_UID}/bus"
    
        echo "   ➜ 为用户应用快捷键：$(whoami)..."
    
        # ---------------------------------------------------------
        # 1. org.gnome.desktop.wm.keybindings (窗口管理)
        # ---------------------------------------------------------
        SCHEMA="org.gnome.desktop.wm.keybindings"
        
        # 基础窗口控制
        gsettings set \$SCHEMA close "['<Super>q']"
        gsettings set \$SCHEMA show-desktop "['<Super>h']"
        gsettings set \$SCHEMA toggle-fullscreen "['<Alt><Super>f']"
        gsettings set \$SCHEMA toggle-maximized "['<Super>f']"
        
        # 清理未使用的窗口控制键 
        gsettings set \$SCHEMA maximize "[]"
        gsettings set \$SCHEMA minimize "[]"
        gsettings set \$SCHEMA unmaximize "[]"
    
        # 切换与移动工作区 
        gsettings set \$SCHEMA switch-to-workspace-left "['<Shift><Super>q']"
        gsettings set \$SCHEMA switch-to-workspace-right "['<Shift><Super>e']"
        gsettings set \$SCHEMA move-to-workspace-left "['<Control><Super>q']"
        gsettings set \$SCHEMA move-to-workspace-right "['<Control><Super>e']"
        
        # 切换应用/窗口 
        gsettings set \$SCHEMA switch-applications "['<Alt>Tab']"
        gsettings set \$SCHEMA switch-applications-backward "['<Shift><Alt>Tab']"
        gsettings set \$SCHEMA switch-group "['<Alt>grave']"
        gsettings set \$SCHEMA switch-group-backward "['<Shift><Alt>grave']"
        
        # 清理输入法切换快捷键
        gsettings set \$SCHEMA switch-input-source "[]"
        gsettings set \$SCHEMA switch-input-source-backward "[]"
    
        # ---------------------------------------------------------
        # 2. org.gnome.shell.keybindings (Shell 全局)
        # ---------------------------------------------------------
        SCHEMA="org.gnome.shell.keybindings"
        
        # 截图相关
        gsettings set \$SCHEMA screenshot "['<Shift><Control><Super>a']"
        gsettings set \$SCHEMA screenshot-window "['<Control><Super>a']"
        gsettings set \$SCHEMA show-screenshot-ui "['<Alt><Super>a']"
        
        # 界面视图
        gsettings set \$SCHEMA toggle-application-view "['<Super>g']"
        gsettings set \$SCHEMA toggle-quick-settings "['<Control><Super>s']"
        gsettings set \$SCHEMA toggle-message-tray "[]"
    
        # ---------------------------------------------------------
        # 3. org.gnome.settings-daemon.plugins.media-keys (媒体与自定义)
        # ---------------------------------------------------------
        SCHEMA="org.gnome.settings-daemon.plugins.media-keys"
    
        # 辅助功能
        gsettings set \$SCHEMA magnifier "['<Alt><Super>0']"
        gsettings set \$SCHEMA screenreader "[]"
    
        # --- 自定义快捷键逻辑 ---
        # 定义添加函数
        add_custom() {
            local index="\$1"
            local name="\$2"
            local cmd="\$3"
            local bind="\$4"
            
            local path="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom\$index/"
            local key_schema="org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:\$path"
            
            gsettings set "\$key_schema" name "\$name"
            gsettings set "\$key_schema" command "\$cmd"
            gsettings set "\$key_schema" binding "\$bind"
            
            echo "\$path"
        }
    
        # 构建自定义快捷键列表
        
        P0=\$(add_custom 0 "openbrowser" "firefox" "<Super>b")
        P1=\$(add_custom 1 "openterminal" "ghostty" "<Super>t")
        P2=\$(add_custom 2 "missioncenter" "missioncenter" "<Super>grave")
        P3=\$(add_custom 3 "opennautilus" "nautilus" "<Super>e")
        P4=\$(add_custom 4 "editscreenshot" "gradia --screenshot" "<Shift><Super>s")
        P5=\$(add_custom 5 "gnome-control-center" "gnome-control-center" "<Control><Alt>s")
    
        # 应用列表 (已移除重复的 P6)
        CUSTOM_LIST="['\$P0', '\$P1', '\$P2', '\$P3', '\$P4', '\$P5']"
        gsettings set \$SCHEMA custom-keybindings "\$CUSTOM_LIST"
        
        echo "   ➜ 快捷键已与配置文件同步完成。"
	EOF
    
    #=================================================
    # Step 5: Extensions
    #=================================================
    section "步骤 5" "安装扩展"
    log "安装 Extensions CLI..."
    
    install_yay_package gnome-extensions-cli
    
    EXTENSION_LIST=(
        "arch-update@RaphaelRochet"
        "aztaskbar@aztaskbar.gitlab.com"
        "blur-my-shell@aunetx"
        "caffeine@patapon.info"
        "clipboard-indicator@tudmotu.com"
        "color-picker@tuberry"
        "desktop-cube@schneegans.github.com"
        "fuzzy-application-search@mkhl.codeberg.page"
        "lockkeys@vaina.lt"
        "middleclickclose@paolo.tranquilli.gmail.com"
        "steal-my-focus-window@steal-my-focus-window"
        "tilingshell@ferrarodomenico.com"
        "user-theme@gnome-shell-extensions.gcampax.github.com"
        "kimpanel@kde.org"
        "rounded-window-corners@fxgn"
        "appindicatorsupport@rgcjonas.gmail.com"
    )
    log "下载扩展..."
    sudo -u $TARGET_USER gnome-extensions-cli install "${EXTENSION_LIST[@]}" 2>/dev/null
    
    section "步骤 5.2" "启用 GNOME 扩展"
    sudo -u "$TARGET_USER" bash <<-EOF
        export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${TARGET_UID}/bus"
    
        # 定义一个函数来安全地启用扩展 (追加模式)
        enable_extension() {
            local uuid="\$1"
            local current_list=\$(gsettings get org.gnome.shell enabled-extensions)
            
            # 检查是否已经在列表中
            if [[ "\$current_list" == *"\$uuid"* ]]; then
                echo "   -> 扩展 \$uuid 已启用。"
            else
                echo "   -> 启用扩展：\$uuid"
                # 如果列表为空 (@as [])，直接设置；否则追加
                if [ "\$current_list" = "@as []" ]; then
                    gsettings set org.gnome.shell enabled-extensions "['\$uuid']"
                else
                    new_list="\${current_list%]}, '\$uuid']"
                    gsettings set org.gnome.shell enabled-extensions "\$new_list"
                fi
            fi
        }
    
        echo "   ➜ 通过 gsettings 激活扩展..."
    
        enable_extension "user-theme@gnome-shell-extensions.gcampax.github.com"
        enable_extension "arch-update@RaphaelRochet"
        enable_extension "aztaskbar@aztaskbar.gitlab.com"
        enable_extension "blur-my-shell@aunetx"
        enable_extension "caffeine@patapon.info"
        enable_extension "clipboard-indicator@tudmotu.com"
        enable_extension "color-picker@tuberry"
        enable_extension "desktop-cube@schneegans.github.com"
        enable_extension "fuzzy-application-search@mkhl.codeberg.page"
        enable_extension "lockkeys@vaina.lt"
        enable_extension "middleclickclose@paolo.tranquilli.gmail.com"
        enable_extension "steal-my-focus-window@steal-my-focus-window"
        enable_extension "tilingshell@ferrarodomenico.com"
        enable_extension "kimpanel@kde.org"
        enable_extension "rounded-window-corners@fxgn"
        enable_extension "appindicatorsupport@rgcjonas.gmail.com"
    
        echo "   ➜ 已发送扩展激活请求。"
	EOF
    
    # 编译扩展 Schema (防止报错)
    log "编译扩展 schema..."
    # 先确保所有权正确
    chown -R $TARGET_USER:$TARGET_USER $HOME_DIR/.local/share/gnome-shell/extensions
    
    sudo -u "$TARGET_USER" bash <<-EOF
        EXT_DIR="$HOME_DIR/.local/share/gnome-shell/extensions"
        
        echo "   ➜ 在 \$EXT_DIR 编译 schema..."
        for dir in "\$EXT_DIR"/*; do
            if [ -d "\$dir/schemas" ]; then
                glib-compile-schemas "\$dir/schemas"
            fi
        done
	EOF
    
    #=================================================
    # Firefox Policies
    #=================================================
    section "Firefox" "配置 Firefox GNOME 集成"
    exe install_yay_package gnome-browser-connector
    
    # 配置 Firefox 策略自动安装扩展
    POL_DIR="/etc/firefox/policies"
    exe mkdir -p "$POL_DIR"
    
    echo '{
      "policies": {
        "Extensions": {
          "Install": [
            "https://addons.mozilla.org/firefox/downloads/latest/gnome-shell-integration/latest.xpi"
          ]
        }
      }
    }' > "$POL_DIR/policies.json"
    
    exe chmod 755 "$POL_DIR" && exe chmod 644 "$POL_DIR/policies.json"
    log "Firefox 策略已更新。"
    #=================================================
    # nautilus fix
    #=================================================
    configure_nautilus_user
    #=================================================
    # Step 6: Input Method
    #=================================================
    section "步骤 6" "输入法"
    log "配置输入法环境..."
    
    if ! grep -q "fcitx" "/etc/environment" 2>/dev/null; then
        cat <<- EOT >> /etc/environment
    XIM="fcitx"
    GTK_IM_MODULE=fcitx
    QT_IM_MODULE=fcitx
    XMODIFIERS=@im=fcitx
    XDG_CURRENT_DESKTOP=GNOME
	EOT
        log "已添加 Fcitx 环境变量。"
    else
        log "Fcitx 环境变量已存在。"
    fi
    
    #=================================================
    # Dotfiles
    #=================================================
    section "Dotfiles" "部署 dotfiles"
    GNOME_DOTFILES_DIR=$PARENT_DIR/gnome-dotfiles
    
    # 1. 确保目标目录存在
    log "确保 .config 存在..."
    sudo -u $TARGET_USER mkdir -p $HOME_DIR/.config
    
    # 2. 复制文件 (包含隐藏文件)
    # 使用 /. 语法将源文件夹的*内容*合并到目标文件夹
    log "复制 dotfiles..."
    cp -rf "$GNOME_DOTFILES_DIR/." "$HOME_DIR/"
    as_user mkdir -p "$HOME_DIR/Templates"
    as_user touch "$HOME_DIR/Templates/new"
    as_user touch "$HOME_DIR/Templates/new.sh"
    as_user echo "#!/bin/bash" >> "$HOME_DIR/Templates/new.sh"
    # 3. 修复权限 (因为 cp 是 root 运行的)
    # 明确修复 home 目录下的关键配置文件夹，避免权限问题
    log "修复权限..."
    chown -R $TARGET_USER:$TARGET_USER $HOME_DIR/.config
    chown -R $TARGET_USER:$TARGET_USER $HOME_DIR/.local
    
    
    # ===  flatpak 权限  ====
      if command -v flatpak &>/dev/null; then
        as_user flatpak override --user --filesystem=xdg-config/fontconfig
      fi
    
    # Shell工具已在common-applist.txt中，此处不重复安装
    
    log "安装完成！请重启。"
    cleanup_sudo
    ;;

  "07-grub-theme.sh")
    
    # ==============================================================================
    # 07-grub-theme.sh - GRUB Theming & Advanced Configuration
    # ==============================================================================
    
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PARENT_DIR="$(dirname "$SCRIPT_DIR")"
    # --- Constants ---
    readonly GRUB_THEME_SELECTION_TIMEOUT=60
    
    check_root
    
    # ------------------------------------------------------------------------------
    # 0. Pre-check: Is GRUB installed?
    # ------------------------------------------------------------------------------
    if ! command -v grub-mkconfig >/dev/null 2>&1; then
        echo ""
        warn "系统未找到 GRUB（grub-mkconfig）。"
        log "跳过 GRUB 主题安装。"
        exit 0
    fi
    
    section "阶段 7" "GRUB 定制与主题"
    
    # --- Helper Functions ---
    
    manage_kernel_param() {
        local action="$1"
        local param="$2"
        local conf_file="/etc/default/grub"
        local line
        line=$(grep "^GRUB_CMDLINE_LINUX_DEFAULT=" "$conf_file")
        local params
        params=$(echo "$line" | sed -e 's/GRUB_CMDLINE_LINUX_DEFAULT=//' -e 's/"//g')
        local param_key
        if [[ "$param" == *"="* ]]; then param_key="${param%%=*}"; else param_key="$param"; fi
        params=$(echo "$params" | sed -E "s/\b${param_key}(=[^ ]*)?\b//g")
    
        if [ "$action" == "add" ]; then params="$params $param"; fi
    
        params=$(echo "$params" | tr -s ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        exe sed -i "s,^GRUB_CMDLINE_LINUX_DEFAULT=.*,GRUB_CMDLINE_LINUX_DEFAULT=\"$params\"," "$conf_file"
    }
    
    # ------------------------------------------------------------------------------
    # 1. Advanced GRUB Configuration
    # ------------------------------------------------------------------------------
    section "步骤 1/5" "常规 GRUB 设置"
    
    log "启用 GRUB 记住上次选择..."
    set_grub_value "GRUB_DEFAULT" "saved"
    set_grub_value "GRUB_SAVEDEFAULT" "true"
    
    log "配置内核启动参数以获得更详细日志和性能..."
    manage_kernel_param "remove" "quiet"
    manage_kernel_param "remove" "splash"
    manage_kernel_param "add" "loglevel=5"
    manage_kernel_param "add" "nowatchdog"
    
    # CPU Watchdog Logic
    CPU_VENDOR=$(LC_ALL=C lscpu | grep "Vendor ID:" | awk '{print $3}')
    if [ "$CPU_VENDOR" == "GenuineIntel" ]; then
        log "检测到 Intel CPU，禁用 iTCO_wdt watchdog。"
        manage_kernel_param "add" "modprobe.blacklist=iTCO_wdt"
    elif [ "$CPU_VENDOR" == "AuthenticAMD" ]; then
        log "检测到 AMD CPU，禁用 sp5100_tco watchdog。"
        manage_kernel_param "add" "modprobe.blacklist=sp5100_tco"
    fi
    
    success "内核参数已更新。"
    
    # ------------------------------------------------------------------------------
    # 2. Detect Themes
    # ------------------------------------------------------------------------------
    section "步骤 2/5" "主题检测"
    log "扫描 'grub-themes' 文件夹中的主题..."
    
    SOURCE_BASE="$PARENT_DIR/grub-themes"
    DEST_DIR="/boot/grub/themes"
    
    if [ ! -d "$SOURCE_BASE" ]; then
        warn "仓库中未找到 'grub-themes' 目录。"
        # 继续执行后续步骤，不直接退出，因为可能只想改内核参数
        THEME_NAMES=()
    else
        mapfile -t FOUND_DIRS < <(find "$SOURCE_BASE" -mindepth 1 -maxdepth 1 -type d | sort)
        THEME_PATHS=()
        THEME_NAMES=()
    
        for dir in "${FOUND_DIRS[@]}"; do
            if [ -f "$dir/theme.txt" ]; then
                THEME_PATHS+=("$dir")
                THEME_NAMES+=("$(basename "$dir")")
            fi
        done
    fi
    
    if [ ${#THEME_NAMES[@]} -eq 0 ]; then
        warn "未找到有效主题目录。"
        # 若没找到主题，强制进入跳过模式
        SKIP_THEME=true
    fi
    
    # ------------------------------------------------------------------------------
    # 3. Select Theme (TUI Menu)
    # ------------------------------------------------------------------------------
    section "步骤 3/5" "主题选择"
    
    # 初始化变量
    SKIP_THEME="${SKIP_THEME:-false}"
    SKIP_OPTION_NAME="No theme (Skip)"
    
    # 如果已经强制跳过（例如没找到文件夹），则不显示菜单
    if [ "$SKIP_THEME" == "true" ]; then
        log "未找到主题，跳过主题选择。"
    else
        # Calculation & Menu Rendering
        TITLE_TEXT="Select GRUB Theme (${GRUB_THEME_SELECTION_TIMEOUT}s Timeout)"
        MAX_LEN=${#TITLE_TEXT}
        
        # 计算主题名称最大长度
        for name in "${THEME_NAMES[@]}"; do
            ITEM_LEN=$((${#name} + 20))
            if (( ITEM_LEN > MAX_LEN )); then MAX_LEN=$ITEM_LEN; fi
        done
        
        # 检查“不安装”选项的长度是否更长
        SKIP_LEN=$((${#SKIP_OPTION_NAME} + 10))
        if (( SKIP_LEN > MAX_LEN )); then MAX_LEN=$SKIP_LEN; fi
    
        MENU_WIDTH=$((MAX_LEN + 4))
        
        LINE_STR=""; printf -v LINE_STR "%*s" "$MENU_WIDTH" ""; LINE_STR=${LINE_STR// /─}
    
        echo -e "\n${H_PURPLE}╭${LINE_STR}╮${NC}"
        TITLE_PADDING_LEN=$(( (MENU_WIDTH - ${#TITLE_TEXT}) / 2 ))
        RIGHT_PADDING_LEN=$((MENU_WIDTH - ${#TITLE_TEXT} - TITLE_PADDING_LEN))
        T_PAD_L=""; printf -v T_PAD_L "%*s" "$TITLE_PADDING_LEN" ""
        T_PAD_R=""; printf -v T_PAD_R "%*s" "$RIGHT_PADDING_LEN" ""
        echo -e "${H_PURPLE}│${NC}${T_PAD_L}${BOLD}${TITLE_TEXT}${NC}${T_PAD_R}${H_PURPLE}│${NC}"
        echo -e "${H_PURPLE}├${LINE_STR}┤${NC}"
    
        # 打印主题列表
        for i in "${!THEME_NAMES[@]}"; do
            NAME="${THEME_NAMES[$i]}"
            DISPLAY_IDX=$((i+1))
            
            # 默认第一个高亮标记为 Default
            if [ "$i" -eq 0 ]; then
                COLOR_STR=" ${H_CYAN}[$DISPLAY_IDX]${NC} ${NAME} - ${H_GREEN}Default${NC}"
                RAW_STR=" [$DISPLAY_IDX] $NAME - Default"
            else
                COLOR_STR=" ${H_CYAN}[$DISPLAY_IDX]${NC} ${NAME}"
                RAW_STR=" [$DISPLAY_IDX] $NAME"
            fi
            PADDING=$((MENU_WIDTH - ${#RAW_STR}))
            PAD_STR=""; if [ "$PADDING" -gt 0 ]; then printf -v PAD_STR "%*s" "$PADDING" ""; fi
            echo -e "${H_PURPLE}│${NC}${COLOR_STR}${PAD_STR}${H_PURPLE}│${NC}"
        done
    
        # 打印“不安装”选项（作为列表的最后一项）
        SKIP_IDX=$((${#THEME_NAMES[@]} + 1))
        SKIP_RAW_STR=" [$SKIP_IDX] $SKIP_OPTION_NAME"
        SKIP_COLOR_STR=" ${H_CYAN}[$SKIP_IDX]${NC} ${H_YELLOW}${SKIP_OPTION_NAME}${NC}"
        
        SKIP_PADDING=$((MENU_WIDTH - ${#SKIP_RAW_STR}))
        SKIP_PAD_STR=""; if [ "$SKIP_PADDING" -gt 0 ]; then printf -v SKIP_PAD_STR "%*s" "$SKIP_PADDING" ""; fi
        echo -e "${H_PURPLE}│${NC}${SKIP_COLOR_STR}${SKIP_PAD_STR}${H_PURPLE}│${NC}"
    
        echo -e "${H_PURPLE}╰${LINE_STR}╯${NC}\n"
    
        echo -ne "   ${H_YELLOW}请输入选择 [1-$SKIP_IDX]： ${NC}"
        if ! read -t "$GRUB_THEME_SELECTION_TIMEOUT" USER_CHOICE; then
            USER_CHOICE=""
        fi
        if [ -z "$USER_CHOICE" ]; then echo ""; fi
        USER_CHOICE=${USER_CHOICE:-1} # 默认选择第一个
    
        # 验证输入
        if ! [[ "$USER_CHOICE" =~ ^[0-9]+$ ]] || [ "$USER_CHOICE" -lt 1 ] || [ "$USER_CHOICE" -gt "$SKIP_IDX" ]; then
            log "选择无效或超时，默认使用第一项..."
            SELECTED_INDEX=0
        elif [ "$USER_CHOICE" -eq "$SKIP_IDX" ]; then
            SKIP_THEME=true
            info_kv "已选择" "无（跳过主题安装）"
        else
            SELECTED_INDEX=$((USER_CHOICE-1))
            THEME_SOURCE="${THEME_PATHS[$SELECTED_INDEX]}"
            THEME_NAME="${THEME_NAMES[$SELECTED_INDEX]}"
            info_kv "已选择" "$THEME_NAME"
        fi
    fi
    
    # ------------------------------------------------------------------------------
    # 4. Install & Configure Theme
    # ------------------------------------------------------------------------------
    section "步骤 4/5" "主题安装"
    
    if [ "$SKIP_THEME" == "true" ]; then
        log "按请求跳过主题复制与配置。"
        # 可选：如果选择不安装，是否要清理现有的 GRUB_THEME 配置？
        # 目前逻辑为“不触碰”，即保留现状。
    else
        if [ ! -d "$DEST_DIR" ]; then exe mkdir -p "$DEST_DIR"; fi
        if [ -d "$DEST_DIR/$THEME_NAME" ]; then
            log "移除已存在版本..."
            exe rm -rf "$DEST_DIR/$THEME_NAME"
        fi
    
        exe cp -r "$THEME_SOURCE" "$DEST_DIR/"
    
        if [ -f "$DEST_DIR/$THEME_NAME/theme.txt" ]; then
            success "主题已安装。"
        else
            error "复制主题文件失败。"
            exit 1
        fi
    
        GRUB_CONF="/etc/default/grub"
        THEME_PATH="$DEST_DIR/$THEME_NAME/theme.txt"
    
        if [ -f "$GRUB_CONF" ]; then
            # 设置 GRUB_THEME 变量
            if grep -q "^GRUB_THEME=" "$GRUB_CONF"; then
                exe sed -i "s|^GRUB_THEME=.*|GRUB_THEME=\"$THEME_PATH\"|" "$GRUB_CONF"
            elif grep -q "^#GRUB_THEME=" "$GRUB_CONF"; then
                exe sed -i "s|^#GRUB_THEME=.*|GRUB_THEME=\"$THEME_PATH\"|" "$GRUB_CONF"
            else
                echo "GRUB_THEME=\"$THEME_PATH\"" >> "$GRUB_CONF"
            fi
            
            # 确保不使用 console 输出模式，以便显示图形主题
            if grep -q "^GRUB_TERMINAL_OUTPUT=\"console\"" "$GRUB_CONF"; then
                exe sed -i 's/^GRUB_TERMINAL_OUTPUT="console"/#GRUB_TERMINAL_OUTPUT="console"/' "$GRUB_CONF"
            fi
            # 确保设置了 GFXMODE
            if ! grep -q "^GRUB_GFXMODE=" "$GRUB_CONF"; then
                echo 'GRUB_GFXMODE=auto' >> "$GRUB_CONF"
            fi
            success "已配置 GRUB 使用主题。"
        else
            error "未找到 $GRUB_CONF。"
            exit 1
        fi
    fi
    
    # ------------------------------------------------------------------------------
    # 5. Add Shutdown/Reboot Menu Entries
    # ------------------------------------------------------------------------------
    section "步骤 5/5" "菜单项与应用"
    log "向 GRUB 菜单添加电源选项..."
    
    cp /etc/grub.d/40_custom /etc/grub.d/99_custom
    echo 'menuentry "重启"' {reboot} >> /etc/grub.d/99_custom
    echo 'menuentry "关机"' {halt} >> /etc/grub.d/99_custom
    
    success "已添加 GRUB 菜单项 99-shutdown"
    
    # ------------------------------------------------------------------------------
    # 6. Apply Changes
    # ------------------------------------------------------------------------------
    log "GRUB 配置重新生成推迟到最后一步。"
    
    log "模块 07 完成。"
    ;;

  "99-apps.sh")
    
    # ==============================================================================
    # 99-apps.sh - Common Applications (FZF Menu + Split Repo/AUR + Retry Logic)
    # ==============================================================================
    
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PARENT_DIR="$(dirname "$SCRIPT_DIR")"
    # --- [CONFIGURATION] ---
    # LazyVim 硬性依赖列表 (Moved from niri-setup)
    LAZYVIM_DEPS=("neovim" "ripgrep" "fd" "ttf-jetbrains-mono-nerd" "git")
    
    # --- Constants ---
    readonly APPS_SELECTION_TIMEOUT=60
    
    check_root
    
    # Ensure FZF is installed
    if ! command -v fzf &> /dev/null; then
        log "安装依赖：fzf..."
        pacman -S --noconfirm fzf >/dev/null 2>&1
    fi
    
    cleanup_sudo() {
        temp_sudo_end "${SUDO_TEMP_FILE:-}"
    }
    
    handle_interrupt() {
        echo -e "\n   ${H_YELLOW}>>> 操作被用户取消 (Ctrl+C)，跳过...${NC}"
        cleanup_sudo
    }
    
    trap handle_interrupt INT
    trap cleanup_sudo EXIT TERM
    
    # ------------------------------------------------------------------------------
    # 0. Identify Target User & Helper
    # ------------------------------------------------------------------------------
    section "阶段 5" "常用应用"
    
    log "识别目标用户..."
    detect_target_user
    info_kv "目标" "$TARGET_USER"
    
    # ------------------------------------------------------------------------------
    # 1. List Selection & User Prompt
    # ------------------------------------------------------------------------------
    LIST_FILENAME="common-applist.txt"
    LIST_FILE="$PARENT_DIR/$LIST_FILENAME"
    
    REPO_APPS=()
    AUR_APPS=()
    FLATPAK_APPS=()
    FAILED_PACKAGES=()
    INSTALL_LAZYVIM=false
    
    if [ ! -f "$LIST_FILE" ]; then
        warn "未找到文件 $LIST_FILENAME，跳过。"
        trap - INT
        exit 0
    fi
    
    if ! grep -q -vE "^\s*#|^\s*$" "$LIST_FILE"; then
        warn "应用列表为空，跳过。"
        trap - INT
        exit 0
    fi
    
    echo ""
    echo -e "   选择列表：${BOLD}$LIST_FILENAME${NC}"
    echo -e "   ${H_YELLOW}>>> 是否安装常用应用？${NC}"
    echo -e "   ${H_CYAN}    [回车]  = 选择软件包${NC}"
    echo -e "   ${H_CYAN}    [N]     = 跳过安装${NC}"
    echo -e "   ${H_YELLOW}    [超时 ${APPS_SELECTION_TIMEOUT}s] = 自动安装全部默认软件包（不使用 FZF）${NC}"
    echo ""
    
    if read -t "$APPS_SELECTION_TIMEOUT" -p "   Please select [Y/n]: " choice; then
        READ_STATUS=0
    else
        READ_STATUS=$?
    fi
    
    SELECTED_RAW=""
    
    # Case 1: Timeout (Auto Install ALL)
    if [ $READ_STATUS -ne 0 ]; then
        echo "" 
        warn "超时（${APPS_SELECTION_TIMEOUT}s），自动安装列表中的全部应用..."
        SELECTED_RAW=$(grep -vE "^\s*#|^\s*$" "$LIST_FILE" | sed -E 's/[[:space:]]+#/\t#/')
    
    # Case 2: User Input
    else
        choice=${choice:-Y}
        if [[ "$choice" =~ ^[nN]$ ]]; then
            warn "用户选择跳过应用安装。"
            trap - INT
            exit 0
        else
            clear
            echo -e "\n  加载应用列表..."
            
            SELECTED_RAW=$(fzf_select_apps "$LIST_FILE")
            
            clear
            
            if [ -z "$SELECTED_RAW" ]; then
                log "跳过应用安装（用户取消选择）。"
                trap - INT
                exit 0
            fi
        fi
    fi
    
    # ------------------------------------------------------------------------------
    # 2. Categorize Selection & Strip Prefixes (Includes LazyVim Check)
    # ------------------------------------------------------------------------------
    log "处理选择..."
    
    while IFS= read -r line; do
        raw_pkg=$(echo "$line" | cut -f1 -d$'\t' | xargs)
        [[ -z "$raw_pkg" ]] && continue
    
        # Check for LazyVim explicitly (Case insensitive check)
        if [[ "${raw_pkg,,}" == "lazyvim" ]]; then
            INSTALL_LAZYVIM=true
            REPO_APPS+=("${LAZYVIM_DEPS[@]}")
            info_kv "配置" "检测到 LazyVim" "设置延后到后安装"
            continue
        fi
    
        if [[ "$raw_pkg" == flatpak:* ]]; then
            clean_name="${raw_pkg#flatpak:}"
            FLATPAK_APPS+=("$clean_name")
        elif [[ "$raw_pkg" == AUR:* ]]; then
            clean_name="${raw_pkg#AUR:}"
            AUR_APPS+=("$clean_name")
        else
            REPO_APPS+=("$raw_pkg")
        fi
    done <<< "$SELECTED_RAW"
    
    info_kv "计划" "Repo: ${#REPO_APPS[@]}" "AUR: ${#AUR_APPS[@]}" "Flatpak: ${#FLATPAK_APPS[@]}"
    
    # ------------------------------------------------------------------------------
    # [SETUP] GLOBAL SUDO CONFIGURATION
    # ------------------------------------------------------------------------------
    if [ ${#REPO_APPS[@]} -gt 0 ] || [ ${#AUR_APPS[@]} -gt 0 ]; then
        log "配置临时 NOPASSWD 以便安装..."
        SUDO_TEMP_FILE="$(temp_sudo_begin "$TARGET_USER" "/etc/sudoers.d/99_shorin_installer_apps")"
    fi
    
    # ------------------------------------------------------------------------------
    # 3. Install Applications
    # ------------------------------------------------------------------------------
    
    # --- A. Install Repo Apps (BATCH MODE) ---
    if [ ${#REPO_APPS[@]} -gt 0 ]; then
        section "步骤 1/3" "官方仓库软件包（批量）"
        
        REPO_QUEUE=()
        for pkg in "${REPO_APPS[@]}"; do
            if is_package_installed "$pkg"; then
                log "跳过 '$pkg'（已安装）。"
            else
                REPO_QUEUE+=("$pkg")
            fi
        done
    
        if [ ${#REPO_QUEUE[@]} -gt 0 ]; then
            info_kv "安装" "通过 Pacman/Yay 安装 ${#REPO_QUEUE[@]} 个软件包"
            
            if ! exe as_user yay -Syu --noconfirm --needed --answerdiff=None --answerclean=None "${REPO_QUEUE[@]}"; then
                error "批量安装失败，部分仓库软件包可能缺失。"
                for pkg in "${REPO_QUEUE[@]}"; do
                    FAILED_PACKAGES+=("repo:$pkg")
                done
            else
                success "仓库批量安装完成。"
            fi
        else
            log "所有仓库软件包已安装。"
        fi
    fi
    
    # --- B. Install AUR Apps (INDIVIDUAL MODE + RETRY) ---
    if [ ${#AUR_APPS[@]} -gt 0 ]; then
        section "步骤 2/3" "AUR 软件包"
        
        for app in "${AUR_APPS[@]}"; do
            if is_package_installed "$app"; then
                log "跳过 '$app'（已安装）。"
                continue
            fi
    
    
            log "安装 AUR：$app ..."
            install_success=false
            max_retries=1
            
            for (( i=0; i<=max_retries; i++ )); do
                if [ $i -gt 0 ]; then
                    warn "重试 $i/$max_retries：'$app' ..."
                fi
                
                if install_yay_package "$app"; then
                    install_success=true
                    success "已安装 $app"
                    break
                else
                    warn "第 $((i+1)) 次尝试失败：$app"
                fi
            done
    
            if [ "$install_success" = false ]; then
                error "安装 $app 失败，已尝试 $((max_retries+1)) 次。"
                FAILED_PACKAGES+=("aur:$app")
            fi
        done
    fi
    
    # --- C. Install Flatpak Apps (INDIVIDUAL MODE) ---
    if [ ${#FLATPAK_APPS[@]} -gt 0 ]; then
        section "步骤 3/3" "Flatpak 软件包（单个）"
        
        for app in "${FLATPAK_APPS[@]}"; do
            if flatpak info "$app" &>/dev/null; then
                log "跳过 '$app'（已安装）。"
                continue
            fi
    
            log "安装 Flatpak：$app ..."
            if ! exe flatpak install -y flathub "$app"; then
                error "安装失败：$app"
                FAILED_PACKAGES+=("flatpak:$app")
            else
                success "已安装 $app"
            fi
        done
    fi
    
    # ------------------------------------------------------------------------------
    # 4. Environment & Additional Configs (Virt/Wine/Steam/LazyVim)
    # ------------------------------------------------------------------------------
    section "后安装" "系统与应用调整"
    
    # --- [NEW] Virtualization Configuration (Virt-Manager) ---
    if is_package_installed virt-manager && ! systemd-detect-virt -q; then
      info_kv "配置" "检测到 Virt-Manager"
      
      # 1. 安装完整依赖
      # iptables-nft 和 dnsmasq 是默认 NAT 网络必须的
      log "安装 QEMU/KVM 依赖..."
      pacman -S --noconfirm --needed qemu-full virt-manager swtpm dnsmasq 
    
      # 2. 添加用户组 (需要重新登录生效)
      log "将 $TARGET_USER 加入 libvirt 组..."
      usermod -a -G libvirt "$TARGET_USER"
      # 同时添加 kvm 和 input 组以防万一
      usermod -a -G kvm,input "$TARGET_USER"
    
      # 3. 开启服务
      log "启用 libvirtd 服务..."
      systemctl_enable_now libvirtd
    
      # 4. [修复] 强制设置 virt-manager 默认连接为 QEMU/KVM
      # 解决第一次打开显示 LXC 或无法连接的问题
      log "设置默认 URI 为 qemu:///system..."
      
      # 编译 glib schemas (防止 gsettings 报错)
      glib-compile-schemas /usr/share/glib-2.0/schemas/
    
      # 强制写入 Dconf 配置
      # uris: 连接列表
      # autoconnect: 自动连接的列表
      as_user gsettings set org.virt-manager.virt-manager.connections uris "['qemu:///system']" || warn "gsettings 失败（无活动会话？）"
      as_user gsettings set org.virt-manager.virt-manager.connections autoconnect "['qemu:///system']" || warn "gsettings 失败（无活动会话？）"
    
      # 5. 配置网络 (Default NAT)
      log "启动默认网络..."
      sleep 3
      virsh net-start default >/dev/null 2>&1 || warn "默认网络可能已处于活动状态。"
      virsh net-autostart default >/dev/null 2>&1 || true
      
      success "虚拟化（KVM）已配置。"
    fi
    
    # --- [NEW] Wine Configuration & Fonts ---
    if command -v wine &>/dev/null; then
      info_kv "配置" "检测到 Wine"
      
      # 1. 安装 Gecko 和 Mono
      log "确保已安装 Wine Gecko/Mono..."
      pacman -S --noconfirm --needed wine wine-gecko wine-mono 
    
      # 2. 初始化 Wine (使用 wineboot -u 在后台运行，不弹窗)
      WINE_PREFIX="$HOME_DIR/.wine"
      if [ ! -d "$WINE_PREFIX" ]; then
        log "初始化 wine prefix（可能需要一分钟）..."
        # WINEDLLOVERRIDES prohibits popups
        as_user env WINEDLLOVERRIDES="mscoree,mshtml=" wineboot -u
        # Wait for completion
        as_user wineserver -w
      else
        log "Wine prefix 已存在。"
      fi
    
      # 3. 复制字体
      FONT_SRC="$PARENT_DIR/resources/windows-sim-fonts"
      FONT_DEST="$WINE_PREFIX/drive_c/windows/Fonts"
    
      if [ -d "$FONT_SRC" ]; then
        log "从资源复制 Windows 字体..."
        
        # 1. 确保目标目录存在 (以用户身份创建)
        if [ ! -d "$FONT_DEST" ]; then
            as_user mkdir -p "$FONT_DEST"
        fi
    
        # 2. 执行复制 (关键修改：直接以目标用户身份复制，而不是 Root 复制后再 Chown)
        # 使用 cp -rT 确保目录内容合并，而不是把源目录本身拷进去
        # 注意：这里假设 as_user 能够接受命令参数。如果 as_user 只是简单的 su/sudo 封装：
        if sudo -u "$TARGET_USER" cp -rf "$FONT_SRC"/. "$FONT_DEST/"; then
            success "字体复制成功。"
        else
            error "字体复制失败。"
        fi
    
        # 3. 强制刷新 Wine 字体缓存 (非常重要！)
        # 字体文件放进去了，但 Wine 不一定会立刻重修构建 fntdata.dat
        # 杀死 wineserver 会强制 Wine 下次启动时重新扫描系统和本地配置
        log "刷新 Wine 字体缓存..."
        if command -v wineserver &> /dev/null; then
            # 必须以目标用户身份执行 wineserver -k
            as_user env WINEPREFIX="$WINE_PREFIX" wineserver -k
        fi
        
        success "Wine 字体已安装并触发缓存刷新。"
      else
        warn "未找到资源字体目录：$FONT_SRC"
      fi
    fi
    
    if command -v lutris &> /dev/null; then 
        log "检测到 Lutris，安装 32 位游戏依赖..."
        pacman -S --noconfirm --needed alsa-plugins giflib glfw gst-plugins-base-libs lib32-alsa-plugins lib32-giflib lib32-gst-plugins-base-libs lib32-gtk3 lib32-libjpeg-turbo lib32-libva lib32-mpg123  lib32-openal libjpeg-turbo libva libxslt mpg123 openal ttf-liberation
    fi
    # --- Steam Locale Fix ---
    STEAM_desktop_modified=false
    NATIVE_DESKTOP="/usr/share/applications/steam.desktop"
    if [ -f "$NATIVE_DESKTOP" ]; then
        log "检查 Native Steam..."
        if ! grep -q "env LANG=zh_CN.UTF-8" "$NATIVE_DESKTOP"; then
            exe sed -i 's|^Exec=/usr/bin/steam|Exec=env LANG=zh_CN.UTF-8 /usr/bin/steam|' "$NATIVE_DESKTOP"
            exe sed -i 's|^Exec=steam|Exec=env LANG=zh_CN.UTF-8 steam|' "$NATIVE_DESKTOP"
            success "已修补 Native Steam .desktop。"
            STEAM_desktop_modified=true
        else
            log "Native Steam 已经修补。"
        fi
    fi
    
    if command -v flatpak &>/dev/null; then
        if flatpak list | grep -q "com.valvesoftware.Steam"; then
            log "检查 Flatpak Steam..."
            exe flatpak override --env=LANG=zh_CN.UTF-8 com.valvesoftware.Steam
            success "已应用 Flatpak Steam override。"
            STEAM_desktop_modified=true
        fi
    fi
    
    # --- [MOVED] LazyVim Configuration ---
    if [ "$INSTALL_LAZYVIM" = true ]; then
      section "配置" "应用 LazyVim 覆盖"
      NVIM_CFG="$HOME_DIR/.config/nvim"
    
      if [ -d "$NVIM_CFG" ]; then
        BACKUP_PATH="$HOME_DIR/.config/nvim.old.apps.$(date +%s)"
        warn "检测到冲突，移动现有 nvim 配置到 $BACKUP_PATH"
        mv "$NVIM_CFG" "$BACKUP_PATH"
      fi
    
      log "克隆 LazyVim starter..."
      if as_user git clone https://github.com/LazyVim/starter "$NVIM_CFG"; then
        rm -rf "$NVIM_CFG/.git"
        success "LazyVim 已安装（覆盖）。"
      else
        error "克隆 LazyVim 失败。"
      fi
    fi
    
    # --- hide desktop ---
    # --- hide desktop (User Level Override) ---
    hide_desktop_file() {
        local source_file="$1"
        local filename=$(basename "$source_file")
        local user_dir="$HOME_DIR/.local/share/applications"
        local target_file="$user_dir/$filename"
      mkdir -p "$user_dir"
      if [[ -f "$source_file" ]]; then
          cp -fv "$source_file" "$target_file"
          chown "$TARGET_USER" "$target_file"
            if grep -q "^NoDisplay=" "$target_file"; then
                sed -i 's/^NoDisplay=.*/NoDisplay=true/' "$target_file"
            else
                echo "NoDisplay=true" >> "$target_file"
            fi
      fi
    }
    section "配置" "隐藏无用的 .desktop 文件"
    log "隐藏无用的 .desktop 文件"
    hide_desktop_file "/usr/share/applications/avahi-discover.desktop"
    hide_desktop_file "/usr/share/applications/qv4l2.desktop"
    hide_desktop_file "/usr/share/applications/qvidcap.desktop"
    hide_desktop_file "/usr/share/applications/bssh.desktop"
    hide_desktop_file "/usr/share/applications/org.fcitx.Fcitx5.desktop"
    hide_desktop_file "/usr/share/applications/org.fcitx.fcitx5-migrator.desktop"
    hide_desktop_file "/usr/share/applications/xgps.desktop"
    hide_desktop_file "/usr/share/applications/xgpsspeed.desktop"
    hide_desktop_file "/usr/share/applications/gvim.desktop"
    hide_desktop_file "/usr/share/applications/kbd-layout-viewer5.desktop"
    hide_desktop_file "/usr/share/applications/bvnc.desktop"
    hide_desktop_file "/usr/share/applications/yazi.desktop"
    hide_desktop_file "/usr/share/applications/btop.desktop"
    hide_desktop_file "/usr/share/applications/vim.desktop"
    hide_desktop_file "/usr/share/applications/nvim.desktop"
    hide_desktop_file "/usr/share/applications/nvtop.desktop"
    hide_desktop_file "/usr/share/applications/mpv.desktop"
    hide_desktop_file "/usr/share/applications/org.gnome.Settings.desktop"
    hide_desktop_file "/usr/share/applications/thunar-settings.desktop"
    hide_desktop_file "/usr/share/applications/thunar-bulk-rename.desktop"
    hide_desktop_file "/usr/share/applications/thunar-volman-settings.desktop"
    hide_desktop_file "/usr/share/applications/clipse-gui.desktop"
    hide_desktop_file "/usr/share/applications/waypaper.desktop"
    hide_desktop_file "/usr/share/applications/xfce4-about.desktop"
    
    # --- Clash Configuration ---
    section "配置" "Clash TUN 模式"
    
    if command -v clash-verge-service &>/dev/null; then
        log "配置 Clash TUN 服务..."
        /usr/bin/clash-verge-service &
        sleep 3
        clash-verge-service-uninstall &>/dev/null || true
        sleep 3
        clash-verge-service-install &>/dev/null || true
        success "Clash 服务已配置。"
    else
        log "未安装 Clash，跳过。"
    fi
    
    # ------------------------------------------------------------------------------
    # [FIX] CLEANUP GLOBAL SUDO CONFIGURATION
    # ------------------------------------------------------------------------------
    if [ -n "${SUDO_TEMP_FILE:-}" ]; then
        log "撤销临时 NOPASSWD..."
        temp_sudo_end "$SUDO_TEMP_FILE"
    fi
    
    # ------------------------------------------------------------------------------
    # 5. Generate Failure Report
    # ------------------------------------------------------------------------------
    if [ ${#FAILED_PACKAGES[@]} -gt 0 ]; then
        DOCS_DIR="$HOME_DIR/Documents"
        REPORT_FILE="$DOCS_DIR/安装失败的软件.txt"
        
        if [ ! -d "$DOCS_DIR" ]; then as_user mkdir -p "$DOCS_DIR"; fi
        
        echo -e "\n========================================================" >> "$REPORT_FILE"
        echo -e " 安装失败报告 - $(date)" >> "$REPORT_FILE"
        echo -e "========================================================" >> "$REPORT_FILE"
        printf "%s\n" "${FAILED_PACKAGES[@]}" >> "$REPORT_FILE"
        
        chown "$TARGET_USER:$TARGET_USER" "$REPORT_FILE"
        
        echo ""
        warn "部分应用安装失败。"
        warn "报告已保存到："
        echo -e "   ${BOLD}$REPORT_FILE${NC}"
    else
        success "所有计划应用已处理完成。"
    fi
    
    # Reset Trap
    trap - INT
    
    log "模块 99-apps 完成。"
    ;;

  "rollback")
    # rollback handler (shared)
    # Env: MARKER, CLEAN_CACHE, REMOVE_MODULE, REBOOT, REBOOT_COUNTDOWN_SECONDS
    # Args: optional marker
    MARKER="${MARKER:-${2:-Before Shorin Setup}}"
    CLEAN_CACHE="${CLEAN_CACHE:-0}"
    REMOVE_MODULE="${REMOVE_MODULE:-}"
    REBOOT="${REBOOT:-1}"
    REBOOT_COUNTDOWN_SECONDS="${REBOOT_COUNTDOWN_SECONDS:-2}"

    check_root

    log "搜索安全快照..."
    if ! command -v snapper &> /dev/null; then
        error "Snapper 未安装。"
        exit 1
    fi

    ROOT_ID=$(snapper -c root list --columns number,description | grep -F "$MARKER" | awk '{print $1}' | tail -n 1)
    if [ -z "$ROOT_ID" ]; then
        error "严重：未找到 root 的快照 '$MARKER'。"
        exit 1
    fi
    info_kv "Root 快照" "$ROOT_ID"

    HOME_ID=""
    if snapper list-configs | grep -q "^home "; then
        HOME_ID=$(snapper -c home list --columns number,description | grep -F "$MARKER" | awk '{print $1}' | tail -n 1)
        if [ -n "$HOME_ID" ]; then
            info_kv "Home 快照" "$HOME_ID"
        fi
    fi

    log "还原 /（Root）..."
    snapper -c root undochange "$ROOT_ID"..0

    if [ -n "$HOME_ID" ]; then
        log "还原 /home..."
        snapper -c home undochange "$HOME_ID"..0
    fi

    if [ "$CLEAN_CACHE" = "1" ]; then
        log "清理包管理器缓存..."
        pacman -Sc --noconfirm || true
        MAIN_USER=$(awk -F: '$3 == 1000 {print $1}' /etc/passwd)
        if [ -n "$MAIN_USER" ]; then
            rm -rf "/home/$MAIN_USER/.cache/yay" || true
            rm -rf "/home/$MAIN_USER/.cache/paru" || true
        fi
    fi

    if [ -n "$REMOVE_MODULE" ] && [ -f "$REPO_DIR/.install_progress" ]; then
        sed -i "/${REMOVE_MODULE//\//\\\\/}/d" "$REPO_DIR/.install_progress"
    fi

    success "回滚完成。"

    if [ "$REBOOT" = "1" ]; then
        for i in $(seq "$REBOOT_COUNTDOWN_SECONDS" -1 1); do
            echo -ne "
   ${H_YELLOW}Rebooting in ${i}s...${NC}"
            sleep 1
        done
        echo ""
        reboot
    fi
    ;;

  *)
    error "未知模块：$MODULE"
    exit 1
    ;;
esac
