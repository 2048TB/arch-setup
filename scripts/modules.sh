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
    
    section "Phase 0" "System Snapshot Initialization"
    
    # ------------------------------------------------------------------------------
    # 1. Configure Root (/)
    # ------------------------------------------------------------------------------
    log "Checking Root filesystem..."
    ROOT_FSTYPE=$(findmnt -n -o FSTYPE /)
    
    if [ "$ROOT_FSTYPE" == "btrfs" ]; then
        log "Root is Btrfs. Installing Snapper..."
        # Minimal install for snapshot capability
        exe pacman -Syu --noconfirm --needed snapper less
        
        log "Configuring Snapper for Root..."
        if ! snapper list-configs | grep -q "^root "; then
            # Cleanup existing dir to allow subvolume creation
            if [ -d "/.snapshots" ]; then
                exe_silent umount /.snapshots
                exe_silent rm -rf /.snapshots
            fi
            
            if exe snapper -c root create-config /; then
                success "Config 'root' created."
                
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
            log "Config 'root' already exists."
        fi
    else
        warn "Root is not Btrfs. Skipping Root snapshot."
    fi
    
    # ------------------------------------------------------------------------------
    # 2. Configure Home (/home)
    # ------------------------------------------------------------------------------
    log "Checking Home filesystem..."
    
    # Check if /home is a mountpoint and is btrfs
    if findmnt -n -o FSTYPE /home | grep -q "btrfs"; then
        log "Home is Btrfs. Configuring Snapper for Home..."
        
        if ! snapper list-configs | grep -q "^home "; then
            # Cleanup .snapshots in home if exists
            if [ -d "/home/.snapshots" ]; then
                exe_silent umount /home/.snapshots
                exe_silent rm -rf /home/.snapshots
            fi
            
            if exe snapper -c home create-config /home; then
                success "Config 'home' created."
                
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
            log "Config 'home' already exists."
        fi
    else
        log "/home is not a separate Btrfs volume. Skipping."
    fi
    
    # ------------------------------------------------------------------------------
    # 3. Create Initial Safety Snapshots
    # ------------------------------------------------------------------------------
    section "Safety Net" "Creating Initial Snapshots"
    
    # Snapshot Root
    if snapper list-configs | grep -q "root "; then
        if snapper -c root list --columns description | grep -q "Before Shorin Setup"; then
            log "Snapshot already created."
        else
            log "Creating Root snapshot..."
            if exe snapper -c root create --description "Before Shorin Setup"; then
                success "Root snapshot created."
            else
                error "Failed to create Root snapshot."
                warn "Cannot proceed without a safety snapshot. Aborting."
                exit 1
            fi
        fi
    fi
    
    # Snapshot Home
    if snapper list-configs | grep -q "home "; then
        if snapper -c home list --columns description | grep -q "Before Shorin Setup"; then
            log "Snapshot already created."
        else
            log "Creating Home snapshot..."
            if exe snapper -c home create --description "Before Shorin Setup"; then
                success "Home snapshot created."
            else
                error "Failed to create Home snapshot."
                # This is less critical than root, but should still be a failure.
                exit 1
            fi
        fi
    fi
    
    log "Module 00 completed. Safe to proceed."
    ;;

  "01-base.sh")
    
    # ==============================================================================
    # 01-base.sh - Base System Configuration
    # ==============================================================================
    
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    check_root
    
    log "Starting Phase 1: Base System Configuration..."
    
    # ------------------------------------------------------------------------------
    # 1. Set Global Default Editor
    # ------------------------------------------------------------------------------
    section "Step 1/6" "Global Default Editor"
    
    TARGET_EDITOR="vim"
    
    if command -v nvim &> /dev/null; then
        TARGET_EDITOR="nvim"
        log "Neovim detected."
    elif command -v nano &> /dev/null; then
        TARGET_EDITOR="nano"
        log "Nano detected."
    else
        log "Neovim or Nano not found. Installing Vim..."
        if ! command -v vim &> /dev/null; then
            exe pacman -Syu --noconfirm gvim
        fi
    fi
    
    log "Setting EDITOR=$TARGET_EDITOR in /etc/environment..."
    
    if grep -q "^EDITOR=" /etc/environment; then
        exe sed -i "s/^EDITOR=.*/EDITOR=${TARGET_EDITOR}/" /etc/environment
    else
        # exe handles simple commands, for redirection we wrap in bash -c or just run it
        # For simplicity in logging, we just run it and log success
        echo "EDITOR=${TARGET_EDITOR}" >> /etc/environment
    fi
    success "Global EDITOR set to: ${TARGET_EDITOR}"
    
    # ------------------------------------------------------------------------------
    # 2. Enable 32-bit (multilib) Repository
    # ------------------------------------------------------------------------------
    section "Step 2/6" "Multilib Repository"
    
    if grep -q "^\[multilib\]" /etc/pacman.conf; then
        success "[multilib] is already enabled."
    else
        log "Uncommenting [multilib]..."
        # Uncomment [multilib] and the following Include line
        exe sed -i "/\[multilib\]/,/Include/"'s/^#//' /etc/pacman.conf
        
        log "Refreshing database..."
        exe pacman -Syu
        success "[multilib] enabled."
    fi
    
    # ------------------------------------------------------------------------------
    # 3. Install Base Fonts
    # ------------------------------------------------------------------------------
    section "Step 3/6" "Base Fonts"
    
    log "Installing adobe-source-han-serif-cn-fonts adobe-source-han-sans-cn-fonts noto-fonts-cjk, noto-fonts, emoji..."
    exe pacman -S --noconfirm --needed adobe-source-han-serif-cn-fonts adobe-source-han-sans-cn-fonts noto-fonts-cjk noto-fonts noto-fonts-emoji ttf-jetbrains-mono-nerd
    log "Base fonts installed."
    
    log "Installing terminus-font..."
    # 安装 terminus-font 包
    exe pacman -S --noconfirm --needed terminus-font
    
    log "Setting font for current session..."
    exe setfont ter-v20n
    
    log "Configuring permanent vconsole font..."
    if [ -f /etc/vconsole.conf ] && grep -q "^FONT=" /etc/vconsole.conf; then
        exe sed -i 's/^FONT=.*/FONT=ter-v20n/' /etc/vconsole.conf
    else
        echo "FONT=ter-v20n" >> /etc/vconsole.conf
    fi
    
    log "Restarting systemd-vconsole-setup..."
    exe systemctl restart systemd-vconsole-setup
    
    success "TTY font configured (ter-v20n)."
    # ------------------------------------------------------------------------------
    # 4. Configure archlinuxcn Repository
    # ------------------------------------------------------------------------------
    section "Step 4/6" "ArchLinuxCN Repository"
    
    if grep -q "\[archlinuxcn\]" /etc/pacman.conf; then
        success "archlinuxcn repository already exists."
    else
        log "Adding archlinuxcn mirrors to pacman.conf..."
        cat <<-'EOT' >> /etc/pacman.conf
	
	[archlinuxcn]
	Server = https://mirrors.ustc.edu.cn/archlinuxcn/$arch
	Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxcn/$arch
	Server = https://mirrors.hit.edu.cn/archlinuxcn/$arch
	Server = https://repo.huaweicloud.com/archlinuxcn/$arch
	EOT
        success "Mirrors added."
    fi
    
    log "Installing archlinuxcn-keyring..."
    # Keyring installation often needs -Sy specifically, but -Syu is safe too
    exe pacman -Syu --noconfirm archlinuxcn-keyring
    success "ArchLinuxCN configured."
    
    # ------------------------------------------------------------------------------
    # 5. Install AUR Helpers
    # ------------------------------------------------------------------------------
    section "Step 5/6" "AUR Helpers"
    
    log "Installing yay and paru..."
    exe pacman -S --noconfirm --needed base-devel yay paru
    success "AUR helpers installed."
    
    log "Module 01 completed."
    ;;

  "02-musthave.sh")
    
    # ==============================================================================
    # 02-musthave.sh - Essential Software, Drivers & Locale
    # ==============================================================================
    
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    check_root
    
    CN_MIRROR=${CN_MIRROR:-0}
    DEBUG=${DEBUG:-0}
    
    log ">>> Starting Phase 2: Essential (Must-have) Software & Drivers"
    # ------------------------------------------------------------------------------
    # 1. Btrfs Extras & GRUB (Config was done in 00-btrfs-init)
    # ------------------------------------------------------------------------------
    section "Step 1/8" "Btrfs Extras & GRUB"
    
    ROOT_FSTYPE=$(findmnt -n -o FSTYPE /)
    
    if [ "$ROOT_FSTYPE" == "btrfs" ]; then
        log "Btrfs filesystem detected."
        exe pacman -S --noconfirm --needed snapper btrfs-assistant
        success "Snapper tools installed."
    
        # GRUB Integration
    if [ -f "/etc/default/grub" ] && command -v grub-mkconfig >/dev/null 2>&1; then
            log "Checking GRUB..."
            
             FOUND_EFI_GRUB=""
            
            # 1. 使用 findmnt 查找所有 vfat 类型的挂载点 (通常 ESP 是 vfat)
            # -n: 不输出标题头
            # -l: 列表格式输出
            # -o TARGET: 只输出挂载点路径
            # -t vfat: 限制文件系统类型
            # sort -r: 反向排序，这样 /boot/efi 会排在 /boot 之前（如果同时存在），优先匹配深层路径
            VFAT_MOUNTS=$(findmnt -n -l -o TARGET -t vfat 2>/dev/null || true)
    
            if [ -n "$VFAT_MOUNTS" ]; then
                # 2. 遍历这些 vfat 分区，寻找 grub 目录
                # 使用 while read 循环处理多行输出
                while read -r mountpoint; do
                    # 检查这个挂载点下是否有 grub 目录
                    if [ -d "$mountpoint/grub" ]; then
                        FOUND_EFI_GRUB="$mountpoint/grub"
                        log "Found GRUB directory in ESP mountpoint: $mountpoint"
                        break 
                    fi
                done <<< "$VFAT_MOUNTS"
            fi
    
            # 3. 如果找到了位于 ESP 中的 GRUB 真实路径
            if [ -n "$FOUND_EFI_GRUB" ]; then
                
                # -e 判断存在, -L 判断是软链接 
                if [ -e "/boot/grub" ] || [ -L "/boot/grub" ]; then
                    warn "Skip" "/boot/grub already exists. No symlink created."
                else
                    # 5. 仅当完全不存在时，创建软链接
                    warn "/boot/grub is missing. Linking to $FOUND_EFI_GRUB..."
                    exe ln -sf "$FOUND_EFI_GRUB" /boot/grub
                    success "Symlink created: /boot/grub -> $FOUND_EFI_GRUB"
                fi
            else
                log "No 'grub' directory found in any active vfat mounts. Skipping symlink check."
            fi
            # --- 核心修改结束 ---
    
            exe pacman -Syu --noconfirm --needed grub-btrfs inotify-tools
            systemctl_enable_now grub-btrfsd
    
            if ! grep -q "grub-btrfs-overlayfs" /etc/mkinitcpio.conf; then
                log "Adding overlayfs hook to mkinitcpio..."
                sed -i 's/^HOOKS=(\(.*\))/HOOKS=(\1 grub-btrfs-overlayfs)/' /etc/mkinitcpio.conf
                exe mkinitcpio -P
            fi
    
            log "GRUB config regeneration deferred to final step."
        fi
    else
        log "Root is not Btrfs. Skipping Snapper setup."
    fi
    
    # ------------------------------------------------------------------------------
    # 2. Audio & Video
    # ------------------------------------------------------------------------------
    section "Step 2/8" "Audio & Video"
    
    log "Installing firmware..."
    exe pacman -S --noconfirm --needed sof-firmware alsa-ucm-conf alsa-firmware
    
    log "Installing Pipewire stack..."
    exe pacman -S --noconfirm --needed pipewire lib32-pipewire wireplumber pipewire-pulse pipewire-alsa pipewire-jack pavucontrol
    
    exe systemctl --global enable pipewire pipewire-pulse wireplumber
    success "Audio setup complete."
    
    # ------------------------------------------------------------------------------
    # 3. Locale
    # ------------------------------------------------------------------------------
    section "Step 3/8" "Locale Configuration"
    
    LOCALE="${LOCALE:-en_US.UTF-8}"
    EXTRA_LOCALES="${EXTRA_LOCALES:-zh_CN.UTF-8}"
    MISSING_LOCALE=false
    
    for loc in $LOCALE $EXTRA_LOCALES; do
        loc_key=$(echo "$loc" | tr '[:upper:]' '[:lower:]' | sed 's/utf-8/utf8/')
        if locale -a | tr '[:upper:]' '[:lower:]' | grep -q "^${loc_key}$"; then
            success "Locale active: $loc"
        else
            warn "Locale missing: $loc"
            MISSING_LOCALE=true
        fi
    done
    
    if [ "$MISSING_LOCALE" = true ]; then
        if [ "${FORCE_LOCALE_GEN:-0}" = "1" ]; then
            log "FORCE_LOCALE_GEN=1 detected. Enabling and generating locales..."
            for loc in $LOCALE $EXTRA_LOCALES; do
                if ! grep -q -E "^${loc} UTF-8" /etc/locale.gen; then
                    sed -i "s/^#\\s*${loc} UTF-8/${loc} UTF-8/" /etc/locale.gen
                    if ! grep -q -E "^${loc} UTF-8" /etc/locale.gen; then
                        echo "${loc} UTF-8" >> /etc/locale.gen
                    fi
                fi
            done
            if exe locale-gen; then
                success "Locales generated successfully."
            else
                error "Locale generation failed."
            fi
        else
            log "Locale generation is handled in 00-arch-base-install.sh (ISO mode)."
            log "If you are on an existing system, run: locale-gen or set FORCE_LOCALE_GEN=1"
        fi
    else
        success "All required locales are active."
    fi
    
    # ------------------------------------------------------------------------------
    # 4. Input Method
    # ------------------------------------------------------------------------------
    section "Step 4/8" "Input Method (Fcitx5)"
    
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
                    warn "Failed to install AUR package: rime-ice-git"
                fi
            fi
    
            temp_sudo_end "$SUDO_TEMP_FILE"
            trap - EXIT
        else
            warn "No target user detected yet. Skipping AUR package: rime-ice-git"
        fi
    else
        warn "yay not found. Skipping AUR package: rime-ice-git"
    fi
    
    success "Fcitx5 installed."
    
    # ------------------------------------------------------------------------------
    # 5. Bluetooth (Smart Detection)
    # ------------------------------------------------------------------------------
    section "Step 5/8" "Bluetooth"
    
    # Ensure detection tools are present
    log "Detecting Bluetooth hardware..."
    exe pacman -S --noconfirm --needed usbutils pciutils
    
    BT_FOUND=false
    
    # 1. Check USB
    if lsusb | grep -qi "bluetooth"; then BT_FOUND=true; fi
    # 2. Check PCI
    if lspci | grep -qi "bluetooth"; then BT_FOUND=true; fi
    # 3. Check RFKill
    if rfkill list bluetooth >/dev/null 2>&1; then BT_FOUND=true; fi
    
    if [ "$BT_FOUND" = true ]; then
        info_kv "Hardware" "Detected"
    
        log "Installing Bluez "
        exe pacman -S --noconfirm --needed bluez
    
        systemctl_enable_now bluetooth
        success "Bluetooth service enabled."
    else
        info_kv "Hardware" "Not Found"
        warn "No Bluetooth device detected. Skipping installation."
    fi
    
    # ------------------------------------------------------------------------------
    # 6. Power
    # ------------------------------------------------------------------------------
    section "Step 6/8" "Power Management"
    
    exe pacman -S --noconfirm --needed power-profiles-daemon
    systemctl_enable_now power-profiles-daemon
    success "Power profiles daemon enabled."
    
    # ------------------------------------------------------------------------------
    # 7. Fastfetch
    # ------------------------------------------------------------------------------
    section "Step 7/8" "Fastfetch"
    
    exe pacman -S --noconfirm --needed fastfetch
    success "Fastfetch installed."
    
    log "Module 02 completed."
    
    # ------------------------------------------------------------------------------
    # 9. flatpak
    # ------------------------------------------------------------------------------
    
    exe pacman -S --noconfirm --needed flatpak
    exe flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    
    CURRENT_TZ=$(readlink -f /etc/localtime)
    IS_CN_ENV=false
    if [[ "$CURRENT_TZ" == *"Shanghai"* ]] || [ "$CN_MIRROR" == "1" ] || [ "$DEBUG" == "1" ]; then
      IS_CN_ENV=true
      info_kv "Region" "China Optimization Active"
    fi
    
    if [ "$IS_CN_ENV" = true ]; then
      log "Setting Flathub mirror to: ${H_GREEN}SJTU${NC}"
      if exe flatpak remote-modify flathub --url="https://mirror.sjtu.edu.cn/flathub"; then
        success "Mirror updated."
      else
        warn "Failed to update mirror, continuing..."
      fi
    else
      log "Using Global Sources."
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
        warn "GRUB is not detected. Skipping dual-boot configuration."
        exit 0
    fi
    
    # --- Main Script ---
    
    section "Phase 2A" "Dual-Boot Configuration (Windows)"
    
    # ------------------------------------------------------------------------------
    # 1. Detect Windows
    # ------------------------------------------------------------------------------
    section "Step 1/2" "System Analysis"
    
    log "Installing dual-boot detection tools (os-prober, exfat-utils)..."
    exe pacman -S --noconfirm --needed os-prober exfat-utils
    
    log "Scanning for Windows installation..."
    WINDOWS_DETECTED=$(os-prober | grep -qi "windows" && echo "true" || echo "false")
    
    if [ "$WINDOWS_DETECTED" != "true" ]; then
        log "No Windows installation detected by os-prober."
        log "Skipping dual-boot specific configurations."
        log "Module 02a completed (Skipped)."
        exit 0
    fi
    
    success "Windows installation detected."
    
    # --- Check if already configured ---
    OS_PROBER_CONFIGURED=$(grep -q -E '^\s*GRUB_DISABLE_OS_PROBER\s*=\s*(false|"false")' /etc/default/grub && echo "true" || echo "false")
    
    if [ "$OS_PROBER_CONFIGURED" == "true" ]; then
        log "Dual-boot settings seem to be already configured."
        echo ""
        echo -e "   ${H_YELLOW}>>> It looks like your dual-boot is already set up.${NC}"
        echo ""
    fi
    
    # ------------------------------------------------------------------------------
    # 2. Configure GRUB for Dual-Boot
    # ------------------------------------------------------------------------------
    section "Step 2/2" "Enabling OS Prober"
    
    log "Enabling OS prober to detect Windows..."
    set_grub_value "GRUB_DISABLE_OS_PROBER" "false"
    
    success "Dual-boot settings updated."
    
    log "GRUB config regeneration deferred to final step."
    
    log "Module 02a completed."
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
    section "Phase 3 (Prep)" "Install zsh"
    
    log "Installing zsh shell..."
    exe pacman -S --noconfirm --needed zsh
    success "zsh installed."
    
    # ==============================================================================
    # Phase 1: 用户检测与创建逻辑
    # ==============================================================================
    section "Phase 3" "User Account Setup"
    
    # 检测是否已存在普通用户 (UID 1000)
    EXISTING_USER=$(awk -F: '$3 == 1000 {print $1}' /etc/passwd)
    MY_USERNAME=""
    SKIP_CREATION=false
    
    if [ -n "$EXISTING_USER" ]; then
        info_kv "Detected User" "$EXISTING_USER" "(UID 1000)"
        log "Using existing user configuration."
        MY_USERNAME="$EXISTING_USER"
        SKIP_CREATION=true
    else
        warn "No standard user found (UID 1000)."
        
        # 支持环境变量预设（零交互模式）
        if [ -n "${SHORIN_USERNAME:-}" ]; then
            MY_USERNAME="$SHORIN_USERNAME"
            info_kv "Username" "$MY_USERNAME" "(From ENV)"
            log "Using predefined username from SHORIN_USERNAME."
        else
            # 交互式输入用户名循环
            while true; do
                echo ""
                echo -ne "   ${ARROW} ${H_YELLOW}Please enter new username:${NC} "
                read INPUT_USER
                
                INPUT_USER=$(echo "$INPUT_USER" | xargs)
                
                if [[ -z "$INPUT_USER" ]]; then
                    warn "Username cannot be empty."
                    continue
                fi
    
                echo -ne "   ${INFO} Create user '${BOLD}${H_CYAN}${INPUT_USER}${NC}'? [Y/n] "
                read CONFIRM
                CONFIRM=${CONFIRM:-Y}
                
                if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
                    MY_USERNAME="$INPUT_USER"
                    break
                else
                    log "Cancelled. Please re-enter."
                fi
            done
        fi
    fi
    
    # 将用户名导出到临时文件，供后续脚本 (如安装桌面环境时) 使用
    echo "$MY_USERNAME" > /tmp/shorin_install_user
    
    # ==============================================================================
    # Phase 2: 账户权限与密码配置
    # ==============================================================================
    section "Step 2/4" "Account & Privileges"
    
    if [ "$SKIP_CREATION" = true ]; then
        log "Checking permissions for $MY_USERNAME..."
        if groups "$MY_USERNAME" | grep -q "\bwheel\b"; then
            success "User is already in 'wheel' group."
        else
            log "Adding user to 'wheel' group..."
            exe usermod -aG wheel "$MY_USERNAME"
        fi
    else
        log "Creating new user '${MY_USERNAME}'..."
        exe useradd -m -g wheel -s /bin/zsh "$MY_USERNAME"
        
        # 支持环境变量预设密码（零交互模式）
        if [ -n "${SHORIN_PASSWORD:-}" ]; then
            log "Setting password from SHORIN_PASSWORD..."
            printf '%s:%s\n' "$MY_USERNAME" "$SHORIN_PASSWORD" | chpasswd
            PASSWORD_STATUS=$?
            
            if [ $PASSWORD_STATUS -eq 0 ]; then
                success "Password set successfully (non-interactive)."
            else
                error "Failed to set password via chpasswd."
                exit 1
            fi
        else
            log "Setting password for ${MY_USERNAME} (interactive)..."
            echo -e "   ${H_GRAY}--------------------------------------------------${NC}"
            passwd "$MY_USERNAME"
            PASSWORD_STATUS=$?
            echo -e "   ${H_GRAY}--------------------------------------------------${NC}"
            
            if [ $PASSWORD_STATUS -eq 0 ]; then 
                success "Password set successfully."
            else 
                error "Failed to set password. Script aborted."
                exit 1
            fi
        fi
    fi
    
    # 1. 配置 Sudoers
    log "Configuring sudoers access..."
    if grep -q "^# %wheel ALL=(ALL:ALL) ALL" /etc/sudoers; then
        # 使用 sed 去掉注释
        exe sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
        success "Uncommented %wheel in /etc/sudoers."
    elif grep -q "^%wheel ALL=(ALL:ALL) ALL" /etc/sudoers; then
        success "Sudo access already enabled."
    else
        # 如果找不到标准行，则追加
        log "Appending %wheel rule to /etc/sudoers..."
        echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers
        success "Sudo access configured."
    fi
    
    # 2. 配置 Faillock (防止输错密码锁定) [新增部分]
    log "Configuring password lockout policy (faillock)..."
    FAILLOCK_CONF="/etc/security/faillock.conf"
    
    if [ -f "$FAILLOCK_CONF" ]; then
        # 使用 sed 匹配被注释的(# deny =) 或者未注释的(deny =) 行，统一改为 deny = 0
        # 正则解释: ^#\? 匹配开头可选的井号; \s* 匹配可选空格
        exe sed -i 's/^#\?\s*deny\s*=.*/deny = 0/' "$FAILLOCK_CONF"
        success "Account lockout disabled (deny=0)."
    else
        # 极少数情况该文件不存在，虽然在 Arch 中默认是有这个文件的
        warn "File $FAILLOCK_CONF not found. Skipping lockout config."
    fi
    
    # ==============================================================================
    # Phase 3: 生成 XDG 用户目录
    # ==============================================================================
    section "Step 3/4" "User Directories"
    
    # 安装工具
    exe pacman -Syu --noconfirm --needed xdg-user-dirs
    
    log "Generating directories (Downloads, Documents, etc.)..."
    
    # 获取用户真实的 Home 目录 (处理用户可能更改过 home 的情况)
    REAL_HOME=$(getent passwd "$MY_USERNAME" | cut -d: -f6)
    
    # 强制以该用户身份运行更新命令
    # 注意：使用 env 设置 HOME 和 LANG 确保目录名为英文 (arch 习惯)
    if exe runuser -u "$MY_USERNAME" -- env LANG=en_US.UTF-8 HOME="$REAL_HOME" xdg-user-dirs-update --force; then
        success "Directories created in $REAL_HOME."
    else
        warn "Failed to generate standard directories."
    fi
    
    # ==============================================================================
    # Phase 4: 环境配置 (PATH 与 .local/bin)
    # ==============================================================================
    section "Step 4/4" "Environment Setup"
    
    # 1. 创建 ~/.local/bin
    # 关键点：使用 runuser 确保文件夹归属权是用户，而不是 root
    LOCAL_BIN_PATH="$REAL_HOME/.local/bin"
    
    log "Creating user executable directory..."
    info_kv "Target" "$LOCAL_BIN_PATH"
    
    if exe runuser -u "$MY_USERNAME" -- mkdir -p "$LOCAL_BIN_PATH"; then
        success "Created directory (Ownership: $MY_USERNAME)"
    else
        error "Failed to create ~/.local/bin"
    fi
    
    # 2. 配置全局 PATH (/etc/profile.d/)
    PROFILE_SCRIPT="/etc/profile.d/user_local_bin.sh"
    log "Configuring automatic PATH detection..."
    
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
        success "PATH script installed to /etc/profile.d/"
        info_kv "Effect" "Requires re-login"
    else
        warn "Failed to create profile.d script."
    fi
    
    # ==============================================================================
    # Phase 5: 部署用户配置文件
    # ==============================================================================
    # Note: Shell配置(.zshrc/.bashrc)和应用配置(.config)
    # 由桌面环境模块部署：
    #   - 04-niri-setup.sh    → niri-dotfiles/   (包含所有配置)
    # ==============================================================================
    log "User config deployment delegated to Desktop Environment modules."
    
    # ==============================================================================
    # 完成
    # ==============================================================================
    hr
    success "User setup module completed."
    echo -e "   ${DIM}User '${MY_USERNAME}' is ready for Desktop Environment setup.${NC}"
    echo ""
    ;;

  "03b-gpu-driver.sh")
    
    # ==============================================================================
    # 03b-gpu-driver.sh GPU Driver Installer 参考了cachyos的chwd脚本
    # ==============================================================================
    
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    check_root
    
    section "Phase 2b" "GPU Driver Setup"
    
    # ==============================================================================
    # 1. 变量声明与基础信息获取
    # ==============================================================================
    log "Detecting GPU Hardware..."
    
    # 核心变量：存放 lspci 信息
    GPU_INFO=$(lspci -mm | grep -E -i "VGA|3D|Display")
    log "GPU Info Detected:\n$GPU_INFO"
    
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
        info_kv "Vendor" "AMD Detected"
        # 追加 AMD 基础包
        PKGS+=("mesa" "lib32-mesa" "xf86-video-amdgpu" "vulkan-radeon" "lib32-vulkan-radeon" "linux-firmware-amdgpu" "gst-plugin-va" "opencl-mesa" "lib32-opencl-mesa" "opencl-icd-loader" "lib32-opencl-icd-loader" )
    fi
    
    # --- Intel 检测 ---
    if echo "$GPU_INFO" | grep -q -i "Intel"; then
        HAS_INTEL=true
        info_kv "Vendor" "Intel Detected"
        # 追加 Intel 基础包 (保证能亮机，能跑基础桌面)
        PKGS+=("mesa" "vulkan-intel" "lib32-mesa" "lib32-vulkan-intel" "gst-plugin-va" "linux-firmware-intel" "opencl-mesa" "lib32-opencl-mesa" "opencl-icd-loader" "lib32-opencl-icd-loader" )
    fi
    
    # --- NVIDIA 检测 ---
    if echo "$GPU_INFO" | grep -q -i "NVIDIA"; then
        HAS_NVIDIA=true
        info_kv "Vendor" "NVIDIA Detected"
        # 追加 NVIDIA 基础工具包
    fi
    
    # --- 多显卡检测 ---
    GPU_COUNT=$(echo "$GPU_INFO" | grep -c .)
    
    if [ "$GPU_COUNT" -ge 2 ]; then
        info_kv "GPU Layout" "Dual/Multi-GPU Detected (Count: $GPU_COUNT)"
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
            log "   -> Intel: Modern architecture matched (iHD path)..."
            PKGS+=("intel-media-driver")
        else
            warn "   -> Intel: Legacy or Unknown model. Skipping intel-media-driver."
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
            log "   -> NVIDIA: Modern GPU detected (Turing+). Using Open Kernel Modules."
            
            # 核心驱动包
            PKGS+=("nvidia-open-dkms" "nvidia-utils" "lib32-nvidia-utils" "opencl-nvidia" "lib32-opencl-nvidia" "libva-nvidia-driver" "vulkan-icd-loader" "lib32-vulkan-icd-loader" "opencl-icd-loader" "lib32-opencl-icd-loader")
            DRIVER_SELECTED=true
    
        # ==========================================================================
        # nvidia-580xx-dkms
        # ==========================================================================
        elif echo "$NV_MODEL" | grep -q -E -i "GTX 10|GTX 950|GTX 960|GTX 970|GTX 980|GTX 745|GTX 750|GTX 750 Ti|GTX 840M|GTX 845M|GTX 850M|GTX 860M|GTX 950M|GTX 960M|GeForce 830M|GeForce 840M|GeForce 930M|GeForce 940M|GeForce GTX Titan X|Tegra X1|NVIDIA Titan X|NVIDIA Titan Xp|NVIDIA Titan V|NVIDIA Quadro GV100"; then
            log "   -> NVIDIA: Pascal/Maxwell GPU detected. Using Proprietary DKMS."
            PKGS+=("nvidia-580xx-dkms" "nvidia-580xx-utils" "opencl-nvidia-580xx" "lib32-opencl-nvidia-580xx" "lib32-nvidia-580xx-utils" "libva-nvidia-driver" "vulkan-icd-loader" "lib32-vulkan-icd-loader" "opencl-icd-loader" "lib32-opencl-icd-loader" )
            DRIVER_SELECTED=true
    
        # ==========================================================================
        # nvidia-470xx-dkms
        # ==========================================================================
        elif echo "$NV_MODEL" | grep -q -E -i "GTX 6[0-9][0-9]|GTX 760|GTX 765|GTX 770|GTX 775|GTX 780|GTX 860M|GT 6[0-9][0-9]|GT 710M|GT 720|GT 730M|GT 735M|GT 740|GT 745M|GT 750M|GT 755M|GT 920M|Quadro 410|Quadro K500|Quadro K510|Quadro K600|Quadro K610|Quadro K1000|Quadro K1100|Quadro K2000|Quadro K2100|Quadro K3000|Quadro K3100|Quadro K4000|Quadro K4100|Quadro K5000|Quadro K5100|Quadro K6000|Tesla K10|Tesla K20|Tesla K40|Tesla K80|NVS 510|NVS 1000|Tegra K1|Titan|Titan Z"; then
    
            log "   -> NVIDIA:  Kepler GPU detected. Using nvidia-470xx-dkms."
            PKGS+=("nvidia-470xx-dkms" "nvidia-470xx-utils" "opencl-nvidia-470xx" "vulkan-icd-loader" "lib32-nvidia-470xx-utils" "lib32-opencl-nvidia-470xx" "lib32-vulkan-icd-loader" "libva-nvidia-driver" "opencl-icd-loader" "lib32-opencl-icd-loader")
            DRIVER_SELECTED=true
    
        # ==========================================================================
        # others
        # ========================================================================== 
        else
            warn "   -> NVIDIA: Legacy GPU detected ($NV_MODEL)."
            warn "   -> Please manually install GPU driver."
        fi
    
        # ==========================================================================
        # headers
        # ==========================================================================
        if [ "$DRIVER_SELECTED" = true ]; then
            log "   -> NVIDIA: Scanning installed kernels for headers..."
            
            # 1. 获取所有以 linux 开头的候选包
            CANDIDATES=$(pacman -Qq | grep "^linux" | grep -vE "headers|firmware|api|docs|tools|utils|qq")
    
            for kernel in $CANDIDATES; do
                # 2. 验证：只有在 /boot 下存在对应 vmlinuz 文件的才算是真内核
                if [ -f "/boot/vmlinuz-${kernel}" ]; then
                    HEADER_PKG="${kernel}-headers"
                    log "      + Kernel found: $kernel -> Adding $HEADER_PKG"
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
    log "Temp sudo file created..."
    
    cleanup_sudo() {
        temp_sudo_end "$SUDO_TEMP_FILE"
        log "Security: Temporary sudo privileges revoked."
    }
    trap cleanup_sudo EXIT INT TERM
    
    if [ ${#PKGS[@]} -gt 0 ]; then
        # 数组去重
        UNIQUE_PKGS=($(printf "%s\n" "${PKGS[@]}" | sort -u))
        
        section "Installation" "Installing Packages"
        log "Target Packages: ${UNIQUE_PKGS[*]}"
        
        # 执行安装
        exe runuser -u "$TARGET_USER" -- yay -S --noconfirm --needed --answerdiff=None --answerclean=None "${UNIQUE_PKGS[@]}"
        
        log "Enabling services (if supported)..."
        systemctl enable --now nvidia-powerd &>/dev/null || true
        systemctl enable switcheroo-control.service &>/dev/null || true
        success "GPU Drivers processed successfully."
    else
        warn "No GPU drivers matched or needed."
    fi
    
    log "Module 02b completed."
    ;;

  "03c-snapshot-before-desktop.sh")
    
    # ==============================================================================
    # 03c-snapshot-before-desktop.sh
    # Creates a system snapshot before installing major Desktop Environments.
    # ==============================================================================
    
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # 权限检查
    check_root
    
    section "Phase 3c" "System Snapshot"
    
    # ==============================================================================
    
    create_checkpoint() {
        local MARKER="Before Desktop Environments"
        
        # 0. 检查 snapper 是否安装
        if ! command -v snapper &>/dev/null; then
            warn "Snapper tool not found. Skipping snapshot creation."
            return
        fi
    
        # 1. Root 分区快照
        # 检查 root 配置是否存在
        if snapper -c root get-config &>/dev/null; then
            # 检查是否已存在同名快照 (避免重复创建)
            if snapper -c root list --columns description | grep -Fqx "$MARKER"; then
                log "Snapshot '$MARKER' already exists on [root]."
            else
                log "Creating safety checkpoint on [root]..."
                # 使用 --type single 表示这是一个独立的存档点
                snapper -c root create --description "$MARKER"
                success "Root snapshot created."
            fi
        else
            warn "Snapper 'root' config not configured. Skipping root snapshot."
        fi
    
        # 2. Home 分区快照 (如果存在 home 配置)
        if snapper -c home get-config &>/dev/null; then
            if snapper -c home list --columns description | grep -Fqx "$MARKER"; then
                log "Snapshot '$MARKER' already exists on [home]."
            else
                log "Creating safety checkpoint on [home]..."
                snapper -c home create --description "$MARKER"
                success "Home snapshot created."
            fi
        fi
    }
    
    # ==============================================================================
    # 执行
    # ==============================================================================
    
    log "Preparing to create restore point..."
    create_checkpoint
    
    log "Module 03c completed."
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
      echo -e "\033[0;31m#   CRITICAL INSTALLATION FAILURE DETECTED                     #\033[0m"
      echo -e "\033[0;31m#                                                              #\033[0m"
      echo -e "\033[0;31m#   Reason: $failed_reason\033[0m"
      echo -e "\033[0;31m#                                                              #\033[0m"
      echo -e "\033[0;31m#   OPTIONS:                                                   #\033[0m"
      echo -e "\033[0;31m#   1. Restore snapshot (Undo changes & Exit)                  #\033[0m"
      echo -e "\033[0;31m#   2. Retry / Re-run script                                   #\033[0m"
      echo -e "\033[0;31m#   3. Abort (Exit immediately)                                #\033[0m"
      echo -e "\033[0;31m#                                                              #\033[0m"
      echo -e "\033[0;31m################################################################\033[0m"
      echo ""
    
      while true; do
        read -p "Select an option [1-3]: " -r choice
        case "$choice" in
        1)
          # Option 1: Restore Snapshot
          if [ -f "$UNDO_SCRIPT" ]; then
            warn "Executing recovery script..."
            MARKER="Before Desktop Environments" \
            CLEAN_CACHE=1 \
            REMOVE_MODULE="04-niri-setup.sh" \
            REBOOT_COUNTDOWN_SECONDS=10 \
            bash "$UNDO_SCRIPT" rollback
            exit 1
          else
            error "Recovery script missing! You are on your own."
            exit 1
          fi
          ;;
        2)
          # Option 2: Re-run Script
          warn "Restarting installation script..."
          echo "-----------------------------------------------------"
          sleep 1
          exec "$0" "$@"
          ;;
        3)
          # Option 3: Exit
          warn "User chose to abort."
          warn "Please fix the issue manually before re-running."
          error "Installation aborted."
          exit 1
          ;;
        *) 
          echo "Invalid input. Please enter 1, 2, or 3." 
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
          warn "Retrying '$pkg' ($context)... (Attempt $attempt/$max_attempts)"
          sleep $PACKAGE_RETRY_COOLDOWN_SECONDS # Cooldown
        else
          log "Installing '$pkg' ($context)..."
        fi
    
        # Try installation
        if install_yay_package "$pkg"; then
          install_success=true
          break
        else
          warn "Attempt $attempt/$max_attempts failed for '$pkg'."
        fi
    
        ((attempt++))
      done
    
      # 3. Final Verification
      if [ "$install_success" = true ] && is_package_installed "$pkg"; then
        success "Installed '$pkg'."
      else
        critical_failure_handler "Failed to install '$pkg' after $max_attempts attempts."
      fi
    }
    
    section "Phase 4" "Niri Desktop Environment"
    
    # ==============================================================================
    # STEP 0: Safety Checkpoint
    # ==============================================================================
    
    # Enable Trap
    trap 'critical_failure_handler "Script Error at Line $LINENO"' ERR
    
    # ==============================================================================
    # STEP 1: Identify User & DM Check
    # ==============================================================================
    log "Identifying user..."
    detect_target_user
    info_kv "Target" "$TARGET_USER"
    
    # DM Check & Fixed TTY Auto-login
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
      info_kv "Conflict" "${H_RED}$DM_FOUND${NC}"
      SKIP_AUTOLOGIN=true
    else
      log "TTY auto-login will be enabled (fixed)."
      SKIP_AUTOLOGIN=false
    fi
    
    # ==============================================================================
    # STEP 2: Core Components
    # ==============================================================================
    section "Step 1/9" "Core Components"
    PKGS="niri xdg-desktop-portal-gnome fuzzel libnotify mako polkit-gnome"
    exe pacman -S --noconfirm --needed $PKGS
    
    # ==============================================================================
    # STEP 3: File Manager
    # ==============================================================================
    section "Step 2/9" "File Manager"
    exe pacman -S --noconfirm --needed ffmpegthumbnailer gvfs-smb nautilus-open-any-terminal file-roller gnome-keyring gst-plugins-base gst-plugins-good gst-libav nautilus
    
    exe pacman -S --noconfirm --needed xdg-desktop-portal-gtk thunar tumbler ffmpegthumbnailer poppler-glib gvfs-smb file-roller thunar-archive-plugin gnome-keyring thunar-volman gvfs-mtp gvfs-gphoto2 webp-pixbuf-loader libgsf
    
    if [ ! -f /usr/bin/gnome-terminal ] || [ -L /usr/bin/gnome-terminal ]; then
      exe ln -sf /usr/bin/ghostty /usr/bin/gnome-terminal
    fi
    
    # Nautilus Nvidia/Input Fix
    configure_nautilus_user
    
    section "Step 3/9" "Temp sudo file"
    
    SUDO_TEMP_FILE="/etc/sudoers.d/99_shorin_installer_temp"
    SUDO_TEMP_FILE="$(temp_sudo_begin "$TARGET_USER" "$SUDO_TEMP_FILE")"
    log "Temp sudo file created..."
    cleanup_sudo() {
      temp_sudo_end "$SUDO_TEMP_FILE"
    }
    trap cleanup_sudo EXIT INT TERM
    # ==============================================================================
    # STEP 5: Dependencies (Auto-install All)
    # ==============================================================================
    section "Step 4/9" "Dependencies"
    LIST_FILE="$PARENT_DIR/niri-applist.txt"

    if [ -f "$LIST_FILE" ]; then
      log "Reading Niri application list..."
      mapfile -t ALL_APPS < <(grep -vE "^\s*#|^\s*$" "$LIST_FILE" | sed -E 's/\s*#.*//')

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
          log "Phase 1: Batch Installing ${#REPO_APPS[@]} Repo Packages..."
          as_user yay -Syu --noconfirm --needed --answerdiff=None --answerclean=None "${REPO_APPS[@]}" || true

          # Verify Each
          for pkg in "${REPO_APPS[@]}"; do
            ensure_package_installed "$pkg" "Repo"
          done
        fi

        # Install AUR packages one by one
        if [ ${#AUR_APPS[@]} -gt 0 ]; then
          log "Phase 2: Installing ${#AUR_APPS[@]} AUR Packages (Sequential)..."
          for aur_app in "${AUR_APPS[@]}"; do
            ensure_package_installed "$aur_app" "AUR"
          done
        fi

        # Waybar fallback
        if ! command -v waybar &>/dev/null; then
          warn "Waybar missing. Installing stock..."
          exe pacman -S --noconfirm --needed waybar
        fi

        success "Niri dependencies installed."
      fi
    else
      warn "niri-applist.txt not found."
    fi
    
    # ==============================================================================
    # STEP 6: Dotfiles (Smart Recursive Symlink)
    # ==============================================================================
    section "Step 5/9" "Deploying Dotfiles"
    
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
    
      while read -r src_path; do
        local item_name
        item_name=$(basename "$src_path")
    
        # 0. 排除检查
        if echo "$exclude_list" | grep -qw "$item_name"; then
          log "Skipping excluded: $item_name"
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
      done < <(find "$src_dir" -mindepth 1 -maxdepth 1 -not -path '*/.git*' 2>/dev/null || true)
    }
    
    # --- Execution ---
    
    # 部署本地 niri-dotfiles
    if [ ! -d "$LOCAL_NIRI_DOTFILES" ]; then
      critical_failure_handler "Local niri-dotfiles directory not found at: $LOCAL_NIRI_DOTFILES"
    fi
    
    log "Deploying local niri-dotfiles..."
    
    # 处理排除列表
    EXCLUDE_LIST=""
    if [ "$TARGET_USER" != "shorin" ]; then
      EXCLUDE_FILE="$PARENT_DIR/exclude-dotfiles.txt"
      if [ -f "$EXCLUDE_FILE" ]; then
        log "Loading exclusions..."
        EXCLUDE_LIST=$(grep -vE "^\s*#|^\s*$" "$EXCLUDE_FILE" | tr '\n' ' ')
      fi
    fi
    
    # 备份现有配置
    if [ -d "$HOME_DIR/.config" ]; then
      log "Backing up existing configs..."
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
        log "Updated GTK bookmarks."
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
      log "Wallpapers moved to Pictures/Wallpapers"
    fi
    
    # Templates
    as_user mkdir -p "$HOME_DIR/Templates"
    as_user touch "$HOME_DIR/Templates/new"
    echo "#!/bin/bash" | as_user tee "$HOME_DIR/Templates/new.sh" >/dev/null
    as_user chmod +x "$HOME_DIR/Templates/new.sh"
    
    success "Dotfiles deployed successfully."
    
    # === remove gtk bottom =======
    if ! as_user gsettings set org.gnome.desktop.wm.preferences button-layout ":close"; then
      warn "Failed to apply gsettings (no active session?)."
    fi
    # ==============================================================================
    # STEP 8: Hardware Tools
    # ==============================================================================
    section "Step 7/9" "Hardware"
    if pacman -Q ddcutil &>/dev/null; then
      gpasswd -a "$TARGET_USER" i2c
      lsmod | grep -q i2c_dev || echo "i2c-dev" >/etc/modules-load.d/i2c-dev.conf
    fi
    if pacman -Q swayosd &>/dev/null; then
      systemctl_enable_now swayosd-libinput-backend.service >/dev/null 2>&1 || true
    fi
    success "Tools configured."
    
    # ==============================================================================
    # STEP 9: Cleanup & Auto-Login
    # ==============================================================================
    section "Final" "Cleanup & Boot"
    temp_sudo_end "$SUDO_TEMP_FILE"
    trap - EXIT INT TERM
    
    SVC_DIR="$HOME_DIR/.config/systemd/user"
    SVC_FILE="$SVC_DIR/niri-autostart.service"
    LINK="$SVC_DIR/default.target.wants/niri-autostart.service"
    
    if [ "$SKIP_AUTOLOGIN" = true ]; then
      log "Auto-login skipped."
      as_user rm -f "$LINK" "$SVC_FILE"
    else
      log "Configuring TTY Auto-login..."
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
      success "Enabled."
    fi
    
    trap - ERR
    log "Module 04 completed."
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
        warn "GRUB (grub-mkconfig) not found on this system."
        log "Skipping GRUB theme installation."
        exit 0
    fi
    
    section "Phase 7" "GRUB Customization & Theming"
    
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
    section "Step 1/5" "General GRUB Settings"
    
    log "Enabling GRUB to remember the last selected entry..."
    set_grub_value "GRUB_DEFAULT" "saved"
    set_grub_value "GRUB_SAVEDEFAULT" "true"
    
    log "Configuring kernel boot parameters for detailed logs and performance..."
    manage_kernel_param "remove" "quiet"
    manage_kernel_param "remove" "splash"
    manage_kernel_param "add" "loglevel=5"
    manage_kernel_param "add" "nowatchdog"
    
    # CPU Watchdog Logic
    CPU_VENDOR=$(LC_ALL=C lscpu | grep "Vendor ID:" | awk '{print $3}')
    if [ "$CPU_VENDOR" == "GenuineIntel" ]; then
        log "Intel CPU detected. Disabling iTCO_wdt watchdog."
        manage_kernel_param "add" "modprobe.blacklist=iTCO_wdt"
    elif [ "$CPU_VENDOR" == "AuthenticAMD" ]; then
        log "AMD CPU detected. Disabling sp5100_tco watchdog."
        manage_kernel_param "add" "modprobe.blacklist=sp5100_tco"
    fi
    
    success "Kernel parameters updated."
    
    # ------------------------------------------------------------------------------
    # 2. Detect Themes
    # ------------------------------------------------------------------------------
    section "Step 2/5" "Theme Detection"
    log "Scanning for themes in 'grub-themes' folder..."
    
    SOURCE_BASE="$PARENT_DIR/grub-themes"
    DEST_DIR="/boot/grub/themes"
    
    if [ ! -d "$SOURCE_BASE" ]; then
        warn "Directory 'grub-themes' not found in repo."
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
        warn "No valid theme folders found."
        # 若没找到主题，强制进入跳过模式
        SKIP_THEME=true
    fi
    
    # ------------------------------------------------------------------------------
    # 3. Select Theme (TUI Menu)
    # ------------------------------------------------------------------------------
    section "Step 3/5" "Theme Selection"
    
    # 初始化变量
    SKIP_THEME="${SKIP_THEME:-false}"
    SKIP_OPTION_NAME="No theme (Skip)"
    
    # 如果已经强制跳过（例如没找到文件夹），则不显示菜单
    if [ "$SKIP_THEME" == "true" ]; then
        log "Skipping theme selection (No themes found)."
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
    
        echo -ne "   ${H_YELLOW}Enter choice [1-$SKIP_IDX]: ${NC}"
        if ! read -t "$GRUB_THEME_SELECTION_TIMEOUT" USER_CHOICE; then
            USER_CHOICE=""
        fi
        if [ -z "$USER_CHOICE" ]; then echo ""; fi
        USER_CHOICE=${USER_CHOICE:-1} # 默认选择第一个
    
        # 验证输入
        if ! [[ "$USER_CHOICE" =~ ^[0-9]+$ ]] || [ "$USER_CHOICE" -lt 1 ] || [ "$USER_CHOICE" -gt "$SKIP_IDX" ]; then
            log "Invalid choice or timeout. Defaulting to first option..."
            SELECTED_INDEX=0
        elif [ "$USER_CHOICE" -eq "$SKIP_IDX" ]; then
            SKIP_THEME=true
            info_kv "Selected" "None (Skip Theme Installation)"
        else
            SELECTED_INDEX=$((USER_CHOICE-1))
            THEME_SOURCE="${THEME_PATHS[$SELECTED_INDEX]}"
            THEME_NAME="${THEME_NAMES[$SELECTED_INDEX]}"
            info_kv "Selected" "$THEME_NAME"
        fi
    fi
    
    # ------------------------------------------------------------------------------
    # 4. Install & Configure Theme
    # ------------------------------------------------------------------------------
    section "Step 4/5" "Theme Installation"
    
    if [ "$SKIP_THEME" == "true" ]; then
        log "Skipping theme copy and configuration as requested."
        # 可选：如果选择不安装，是否要清理现有的 GRUB_THEME 配置？
        # 目前逻辑为“不触碰”，即保留现状。
    else
        if [ ! -d "$DEST_DIR" ]; then exe mkdir -p "$DEST_DIR"; fi
        if [ -d "$DEST_DIR/$THEME_NAME" ]; then
            log "Removing existing version..."
            exe rm -rf "$DEST_DIR/$THEME_NAME"
        fi
    
        exe cp -r "$THEME_SOURCE" "$DEST_DIR/"
    
        if [ -f "$DEST_DIR/$THEME_NAME/theme.txt" ]; then
            success "Theme installed."
        else
            error "Failed to copy theme files."
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
            success "Configured GRUB to use theme."
        else
            error "$GRUB_CONF not found."
            exit 1
        fi
    fi
    
    # ------------------------------------------------------------------------------
    # 5. Add Shutdown/Reboot Menu Entries
    # ------------------------------------------------------------------------------
    section "Step 5/5" "Menu Entries & Apply"
    log "Adding Power Options to GRUB menu..."
    
    cp /etc/grub.d/40_custom /etc/grub.d/99_custom
    echo 'menuentry "Reboot"' {reboot} >> /etc/grub.d/99_custom
    echo 'menuentry "Shutdown"' {halt} >> /etc/grub.d/99_custom
    
    success "Added grub menuentry 99-shutdown"
    
    # ------------------------------------------------------------------------------
    # 6. Apply Changes
    # ------------------------------------------------------------------------------
    log "GRUB config regeneration deferred to final step."
    
    log "Module 07 completed."
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
    # (No timeout needed - auto-install mode)

    check_root

    cleanup_sudo() {
        temp_sudo_end "${SUDO_TEMP_FILE:-}"
    }
    
    handle_interrupt() {
        echo -e "\n   ${H_YELLOW}>>> Operation cancelled by user (Ctrl+C). Skipping...${NC}"
        cleanup_sudo
    }
    
    trap handle_interrupt INT
    trap cleanup_sudo EXIT TERM
    
    # ------------------------------------------------------------------------------
    # 0. Identify Target User & Helper
    # ------------------------------------------------------------------------------
    section "Phase 5" "Common Applications"
    
    log "Identifying target user..."
    detect_target_user
    info_kv "Target" "$TARGET_USER"
    
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
        warn "File $LIST_FILENAME not found. Skipping."
        trap - INT
        exit 0
    fi
    
    if ! grep -q -vE "^\s*#|^\s*$" "$LIST_FILE"; then
        warn "App list is empty. Skipping."
        trap - INT
        exit 0
    fi
    
    # Auto-install all applications from common-applist.txt
    log "Auto-installing ALL applications from: $LIST_FILENAME"

    SELECTED_RAW=$(grep -vE "^\s*#|^\s*$" "$LIST_FILE" | sed -E 's/[[:space:]]+#/\t#/')
    
    # ------------------------------------------------------------------------------
    # 2. Categorize Selection & Strip Prefixes (Includes LazyVim Check)
    # ------------------------------------------------------------------------------
    log "Processing selection..."
    
    while IFS= read -r line; do
        raw_pkg=$(echo "$line" | cut -f1 -d$'\t' | xargs)
        [[ -z "$raw_pkg" ]] && continue
    
        # Check for LazyVim explicitly (Case insensitive check)
        if [[ "${raw_pkg,,}" == "lazyvim" ]]; then
            INSTALL_LAZYVIM=true
            REPO_APPS+=("${LAZYVIM_DEPS[@]}")
            info_kv "Config" "LazyVim detected" "Setup deferred to Post-Install"
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
    
    info_kv "Scheduled" "Repo: ${#REPO_APPS[@]}" "AUR: ${#AUR_APPS[@]}" "Flatpak: ${#FLATPAK_APPS[@]}"
    
    # ------------------------------------------------------------------------------
    # [SETUP] GLOBAL SUDO CONFIGURATION
    # ------------------------------------------------------------------------------
    if [ ${#REPO_APPS[@]} -gt 0 ] || [ ${#AUR_APPS[@]} -gt 0 ]; then
        log "Configuring temporary NOPASSWD for installation..."
        SUDO_TEMP_FILE="$(temp_sudo_begin "$TARGET_USER" "/etc/sudoers.d/99_shorin_installer_apps")"
    fi
    
    # ------------------------------------------------------------------------------
    # 3. Install Applications
    # ------------------------------------------------------------------------------
    
    # --- A. Install Repo Apps (BATCH MODE) ---
    if [ ${#REPO_APPS[@]} -gt 0 ]; then
        section "Step 1/3" "Official Repository Packages (Batch)"
        
        REPO_QUEUE=()
        for pkg in "${REPO_APPS[@]}"; do
            if is_package_installed "$pkg"; then
                log "Skipping '$pkg' (Already installed)."
            else
                REPO_QUEUE+=("$pkg")
            fi
        done
    
        if [ ${#REPO_QUEUE[@]} -gt 0 ]; then
            info_kv "Installing" "${#REPO_QUEUE[@]} packages via Pacman/Yay"
            
            if ! exe as_user yay -Syu --noconfirm --needed --answerdiff=None --answerclean=None "${REPO_QUEUE[@]}"; then
                error "Batch installation failed. Some repo packages might be missing."
                for pkg in "${REPO_QUEUE[@]}"; do
                    FAILED_PACKAGES+=("repo:$pkg")
                done
            else
                success "Repo batch installation completed."
            fi
        else
            log "All Repo packages are already installed."
        fi
    fi
    
    # --- B. Install AUR Apps (INDIVIDUAL MODE + RETRY) ---
    if [ ${#AUR_APPS[@]} -gt 0 ]; then
        section "Step 2/3" "AUR Packages "
        
        for app in "${AUR_APPS[@]}"; do
            if is_package_installed "$app"; then
                log "Skipping '$app' (Already installed)."
                continue
            fi
    
    
            log "Installing AUR: $app ..."
            install_success=false
            max_retries=1
            
            for (( i=0; i<=max_retries; i++ )); do
                if [ $i -gt 0 ]; then
                    warn "Retry $i/$max_retries for '$app' ..."
                fi
                
                if install_yay_package "$app"; then
                    install_success=true
                    success "Installed $app"
                    break
                else
                    warn "Attempt $((i+1)) failed for $app"
                fi
            done
    
            if [ "$install_success" = false ]; then
                error "Failed to install $app after $((max_retries+1)) attempts."
                FAILED_PACKAGES+=("aur:$app")
            fi
        done
    fi
    
    # --- C. Install Flatpak Apps (INDIVIDUAL MODE) ---
    if [ ${#FLATPAK_APPS[@]} -gt 0 ]; then
        section "Step 3/3" "Flatpak Packages (Individual)"
        
        for app in "${FLATPAK_APPS[@]}"; do
            if flatpak info "$app" &>/dev/null; then
                log "Skipping '$app' (Already installed)."
                continue
            fi
    
            log "Installing Flatpak: $app ..."
            if ! exe flatpak install -y flathub "$app"; then
                error "Failed to install: $app"
                FAILED_PACKAGES+=("flatpak:$app")
            else
                success "Installed $app"
            fi
        done
    fi
    
    # ------------------------------------------------------------------------------
    # 4. Environment & Additional Configs (Virt/Wine/Steam/LazyVim)
    # ------------------------------------------------------------------------------
    section "Post-Install" "System & App Tweaks"
    
    # --- [NEW] Virtualization Configuration (Virt-Manager) ---
    if is_package_installed virt-manager && ! systemd-detect-virt -q; then
      info_kv "Config" "Virt-Manager detected"
      
      # 1. 安装完整依赖
      # iptables-nft 和 dnsmasq 是默认 NAT 网络必须的
      log "Installing QEMU/KVM dependencies..."
      pacman -S --noconfirm --needed qemu-full virt-manager swtpm dnsmasq 
    
      # 2. 添加用户组 (需要重新登录生效)
      log "Adding $TARGET_USER to libvirt group..."
      usermod -a -G libvirt "$TARGET_USER"
      # 同时添加 kvm 和 input 组以防万一
      usermod -a -G kvm,input "$TARGET_USER"
    
      # 3. 开启服务
      log "Enabling libvirtd service..."
      systemctl_enable_now libvirtd
    
      # 4. [修复] 强制设置 virt-manager 默认连接为 QEMU/KVM
      # 解决第一次打开显示 LXC 或无法连接的问题
      log "Setting default URI to qemu:///system..."
      
      # 编译 glib schemas (防止 gsettings 报错)
      glib-compile-schemas /usr/share/glib-2.0/schemas/
    
      # 强制写入 Dconf 配置
      # uris: 连接列表
      # autoconnect: 自动连接的列表
      as_user gsettings set org.virt-manager.virt-manager.connections uris "['qemu:///system']" || warn "gsettings failed (no active session?)"
      as_user gsettings set org.virt-manager.virt-manager.connections autoconnect "['qemu:///system']" || warn "gsettings failed (no active session?)"
    
      # 5. 配置网络 (Default NAT)
      log "Starting default network..."
      sleep 3
      virsh net-start default >/dev/null 2>&1 || warn "Default network might be already active."
      virsh net-autostart default >/dev/null 2>&1 || true
      
      success "Virtualization (KVM) configured."
    fi
    
    # --- [NEW] Wine Configuration & Fonts ---
    if command -v wine &>/dev/null; then
      info_kv "Config" "Wine detected"
      
      # 1. 安装 Gecko 和 Mono
      log "Ensuring Wine Gecko/Mono are installed..."
      pacman -S --noconfirm --needed wine wine-gecko wine-mono 
    
      # 2. 初始化 Wine (使用 wineboot -u 在后台运行，不弹窗)
      WINE_PREFIX="$HOME_DIR/.wine"
      if [ ! -d "$WINE_PREFIX" ]; then
        log "Initializing wine prefix (This may take a minute)..."
        # WINEDLLOVERRIDES prohibits popups
        as_user env WINEDLLOVERRIDES="mscoree,mshtml=" wineboot -u
        # Wait for completion
        as_user wineserver -w
      else
        log "Wine prefix already exists."
      fi
    
      # 3. 复制字体
      FONT_SRC="$PARENT_DIR/resources/windows-sim-fonts"
      FONT_DEST="$WINE_PREFIX/drive_c/windows/Fonts"
    
      if [ -d "$FONT_SRC" ]; then
        log "Copying Windows fonts from resources..."
        
        # 1. 确保目标目录存在 (以用户身份创建)
        if [ ! -d "$FONT_DEST" ]; then
            as_user mkdir -p "$FONT_DEST"
        fi
    
        # 2. 执行复制 (关键修改：直接以目标用户身份复制，而不是 Root 复制后再 Chown)
        # 使用 cp -rT 确保目录内容合并，而不是把源目录本身拷进去
        # 注意：这里假设 as_user 能够接受命令参数。如果 as_user 只是简单的 su/sudo 封装：
        if sudo -u "$TARGET_USER" cp -rf "$FONT_SRC"/. "$FONT_DEST/"; then
            success "Fonts copied successfully."
        else
            error "Failed to copy fonts."
        fi
    
        # 3. 强制刷新 Wine 字体缓存 (非常重要！)
        # 字体文件放进去了，但 Wine 不一定会立刻重修构建 fntdata.dat
        # 杀死 wineserver 会强制 Wine 下次启动时重新扫描系统和本地配置
        log "Refreshing Wine font cache..."
        if command -v wineserver &> /dev/null; then
            # 必须以目标用户身份执行 wineserver -k
            as_user env WINEPREFIX="$WINE_PREFIX" wineserver -k
        fi
        
        success "Wine fonts installed and cache refresh triggered."
      else
        warn "Resources font directory not found at: $FONT_SRC"
      fi
    fi
    
    if command -v lutris &> /dev/null; then 
        log "Lutris detected. Installing 32-bit gaming dependencies..."
        pacman -S --noconfirm --needed alsa-plugins giflib glfw gst-plugins-base-libs lib32-alsa-plugins lib32-giflib lib32-gst-plugins-base-libs lib32-gtk3 lib32-libjpeg-turbo lib32-libva lib32-mpg123  lib32-openal libjpeg-turbo libva libxslt mpg123 openal ttf-liberation
    fi
    # --- Steam Locale Fix ---
    STEAM_desktop_modified=false
    NATIVE_DESKTOP="/usr/share/applications/steam.desktop"
    if [ -f "$NATIVE_DESKTOP" ]; then
        log "Checking Native Steam..."
        if ! grep -q "env LANG=zh_CN.UTF-8" "$NATIVE_DESKTOP"; then
            exe sed -i 's|^Exec=/usr/bin/steam|Exec=env LANG=zh_CN.UTF-8 /usr/bin/steam|' "$NATIVE_DESKTOP"
            exe sed -i 's|^Exec=steam|Exec=env LANG=zh_CN.UTF-8 steam|' "$NATIVE_DESKTOP"
            success "Patched Native Steam .desktop."
            STEAM_desktop_modified=true
        else
            log "Native Steam already patched."
        fi
    fi
    
    if command -v flatpak &>/dev/null; then
        if flatpak list | grep -q "com.valvesoftware.Steam"; then
            log "Checking Flatpak Steam..."
            exe flatpak override --env=LANG=zh_CN.UTF-8 com.valvesoftware.Steam
            success "Applied Flatpak Steam override."
            STEAM_desktop_modified=true
        fi
    fi
    
    # --- [MOVED] LazyVim Configuration ---
    if [ "$INSTALL_LAZYVIM" = true ]; then
      section "Config" "Applying LazyVim Overrides"
      NVIM_CFG="$HOME_DIR/.config/nvim"
    
      if [ -d "$NVIM_CFG" ]; then
        BACKUP_PATH="$HOME_DIR/.config/nvim.old.apps.$(date +%s)"
        warn "Collision detected. Moving existing nvim config to $BACKUP_PATH"
        mv "$NVIM_CFG" "$BACKUP_PATH"
      fi
    
      log "Cloning LazyVim starter..."
      if as_user git clone https://github.com/LazyVim/starter "$NVIM_CFG"; then
        rm -rf "$NVIM_CFG/.git"
        success "LazyVim installed (Override)."
      else
        error "Failed to clone LazyVim."
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
    section "Config" "Hiding useless .desktop files"
    log "Hiding useless .desktop files"
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
    section "Config" "Clash TUN Mode"
    
    if command -v clash-verge-service &>/dev/null; then
        log "Configuring Clash TUN service..."
        /usr/bin/clash-verge-service &
        sleep 3
        clash-verge-service-uninstall &>/dev/null || true
        sleep 3
        clash-verge-service-install &>/dev/null || true
        success "Clash service configured."
    else
        log "Clash not installed, skipping."
    fi
    
    # ------------------------------------------------------------------------------
    # [FIX] CLEANUP GLOBAL SUDO CONFIGURATION
    # ------------------------------------------------------------------------------
    if [ -n "${SUDO_TEMP_FILE:-}" ]; then
        log "Revoking temporary NOPASSWD..."
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
        echo -e " Installation Failure Report - $(date)" >> "$REPORT_FILE"
        echo -e "========================================================" >> "$REPORT_FILE"
        printf "%s\n" "${FAILED_PACKAGES[@]}" >> "$REPORT_FILE"
        
        chown "$TARGET_USER:$TARGET_USER" "$REPORT_FILE"
        
        echo ""
        warn "Some applications failed to install."
        warn "A report has been saved to:"
        echo -e "   ${BOLD}$REPORT_FILE${NC}"
    else
        success "All scheduled applications processed successfully."
    fi
    
    # Reset Trap
    trap - INT
    
    log "Module 99-apps completed."
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

    log "Searching for safety snapshots..."
    if ! command -v snapper &> /dev/null; then
        error "Snapper is not installed."
        exit 1
    fi

    ROOT_ID=$(snapper -c root list --columns number,description | grep -F "$MARKER" | awk '{print $1}' | tail -n 1)
    if [ -z "$ROOT_ID" ]; then
        error "Critical: Could not find snapshot '$MARKER' for root."
        exit 1
    fi
    info_kv "Root Snapshot" "$ROOT_ID"

    HOME_ID=""
    if snapper list-configs | grep -q "^home "; then
        HOME_ID=$(snapper -c home list --columns number,description | grep -F "$MARKER" | awk '{print $1}' | tail -n 1)
        if [ -n "$HOME_ID" ]; then
            info_kv "Home Snapshot" "$HOME_ID"
        fi
    fi

    log "Reverting / (Root)..."
    snapper -c root undochange "$ROOT_ID"..0

    if [ -n "$HOME_ID" ]; then
        log "Reverting /home..."
        snapper -c home undochange "$HOME_ID"..0
    fi

    if [ "$CLEAN_CACHE" = "1" ]; then
        log "Cleaning package manager caches..."
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

    success "Rollback complete."

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
    error "Unknown module: $MODULE"
    exit 1
    ;;
esac
