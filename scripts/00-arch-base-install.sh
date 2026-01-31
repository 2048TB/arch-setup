#!/bin/bash

# ==============================================================================
# 00-arch-base-install.sh - Arch Base System Installation for ISO Environment
# ==============================================================================
# 功能：检测ISO环境 → 自动分区 → pacstrap → genfstab → arch-chroot后继续

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/00-utils.sh"

# --- Constants ---
readonly EFI_SIZE="512M"
readonly MIN_DISK_SIZE_GB=20
readonly PACSTRAP_BASE_PKGS="base base-devel linux linux-firmware btrfs-progs networkmanager grub efibootmgr sudo nano vim git wget curl"

check_root

# ==============================================================================
# STEP 0: ISO Environment Detection
# ==============================================================================
section "Phase 0" "Environment Detection"

is_iso_environment() {
    # 多种检测方法确保准确
    [ -d /run/archiso ] || \
    [[ "$(findmnt / -o FSTYPE -n)" =~ ^(overlay|tmpfs|airootfs)$ ]] || \
    [[ "$(hostname)" == "archiso" ]]
}

if ! is_iso_environment; then
    log "Not running in ISO environment. Skipping base installation."
    log "Assuming system is already installed."
    exit 0
fi

warn "Detected Arch ISO environment."
log "Will proceed with base system installation."
echo ""

# ==============================================================================
# STEP 1: Disk Selection & Validation
# ==============================================================================
section "Step 1/7" "Disk Selection"

log "Scanning available disks..."
lsblk -d -n -o NAME,SIZE,TYPE | grep disk

# 自动选择最大磁盘
LARGEST_DISK=$(lsblk -d -n -o NAME,SIZE -b | grep -v loop | sort -k2 -n -r | head -1 | awk '{print $1}')
LARGEST_DISK_SIZE_GB=$(lsblk -d -n -o SIZE /dev/"$LARGEST_DISK" | sed 's/G//')

if [ -z "$LARGEST_DISK" ]; then
    error "No suitable disk found."
    exit 1
fi

info_kv "Target Disk" "/dev/$LARGEST_DISK" "($LARGEST_DISK_SIZE_GB)"

# 安全检查：确认磁盘大小
if [ "${LARGEST_DISK_SIZE_GB%%.*}" -lt "$MIN_DISK_SIZE_GB" ]; then
    error "Disk too small. Minimum ${MIN_DISK_SIZE_GB}GB required."
    exit 1
fi

# 警告确认
echo ""
echo -e "${H_RED}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${H_RED}║  WARNING: THIS WILL ERASE ALL DATA ON /dev/$LARGEST_DISK${NC}"
echo -e "${H_RED}║  Disk: $(lsblk -d -n -o MODEL /dev/$LARGEST_DISK 2>/dev/null || echo 'Unknown')${NC}"
echo -e "${H_RED}║  Size: $LARGEST_DISK_SIZE_GB${NC}"
echo -e "${H_RED}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

read -t 30 -p "$(echo -e "   ${H_YELLOW}Confirm to ERASE /dev/$LARGEST_DISK? [yes/NO]: ${NC}")" confirm
confirm=${confirm:-NO}

if [ "$confirm" != "yes" ]; then
    error "Installation cancelled by user."
    exit 1
fi

TARGET_DISK="/dev/$LARGEST_DISK"

# ==============================================================================
# STEP 2: Partitioning
# ==============================================================================
section "Step 2/7" "Disk Partitioning"

# 确保分区工具存在
if ! command -v sgdisk &>/dev/null; then
    log "Installing partitioning tools..."
    pacman -Sy --noconfirm gptfdisk
fi

log "Creating GPT partition table..."
exe sgdisk -Z "$TARGET_DISK"  # 清除分区表
exe sgdisk -o "$TARGET_DISK"  # 创建GPT

log "Creating EFI partition (${EFI_SIZE})..."
exe sgdisk -n 1:0:+${EFI_SIZE} -t 1:ef00 -c 1:"EFI" "$TARGET_DISK"

log "Creating Btrfs partition (remaining space)..."
exe sgdisk -n 2:0:0 -t 2:8300 -c 2:"Linux" "$TARGET_DISK"

# 通知内核重新读取分区表
exe partprobe "$TARGET_DISK"
sleep 2

# 分区设备名（处理nvme和sata差异）
if [[ "$TARGET_DISK" =~ nvme ]]; then
    EFI_PART="${TARGET_DISK}p1"
    ROOT_PART="${TARGET_DISK}p2"
else
    EFI_PART="${TARGET_DISK}1"
    ROOT_PART="${TARGET_DISK}2"
fi

info_kv "EFI Partition" "$EFI_PART"
info_kv "Root Partition" "$ROOT_PART"

# ==============================================================================
# STEP 3: Format Partitions
# ==============================================================================
section "Step 3/7" "Formatting"

log "Formatting EFI partition (FAT32)..."
exe mkfs.fat -F32 "$EFI_PART"

log "Formatting Root partition (Btrfs)..."
exe mkfs.btrfs -f -L "ArchRoot" "$ROOT_PART"

success "Partitions formatted."

# ==============================================================================
# STEP 4: Btrfs Subvolumes Setup
# ==============================================================================
section "Step 4/7" "Btrfs Subvolumes"

log "Mounting root for subvolume creation..."
exe mount "$ROOT_PART" /mnt

log "Creating Btrfs subvolumes..."
exe btrfs subvolume create /mnt/@
exe btrfs subvolume create /mnt/@home
exe btrfs subvolume create /mnt/@snapshots
exe btrfs subvolume create /mnt/@log
exe btrfs subvolume create /mnt/@cache

log "Unmounting to remount with subvolumes..."
exe umount /mnt

log "Mounting subvolumes with optimal options..."
BTRFS_OPTS="defaults,noatime,compress=zstd:1,space_cache=v2"

exe mount -o "subvol=@,$BTRFS_OPTS" "$ROOT_PART" /mnt
exe mkdir -p /mnt/{boot,home,.snapshots,var/log,var/cache}
exe mount -o "subvol=@home,$BTRFS_OPTS" "$ROOT_PART" /mnt/home
exe mount -o "subvol=@snapshots,$BTRFS_OPTS" "$ROOT_PART" /mnt/.snapshots
exe mount -o "subvol=@log,$BTRFS_OPTS" "$ROOT_PART" /mnt/var/log
exe mount -o "subvol=@cache,$BTRFS_OPTS" "$ROOT_PART" /mnt/var/cache

log "Mounting EFI partition..."
exe mount "$EFI_PART" /mnt/boot

success "Btrfs layout configured."
lsblk "$TARGET_DISK"

# ==============================================================================
# STEP 5: Base System Installation
# ==============================================================================
section "Step 5/7" "Installing Base System"

log "Running pacstrap (This may take several minutes)..."
if exe pacstrap /mnt $PACSTRAP_BASE_PKGS; then
    success "Base system installed."
else
    error "pacstrap failed. Check network connection."
    exit 1
fi

# ==============================================================================
# STEP 6: System Configuration
# ==============================================================================
section "Step 6/7" "Generating fstab"

log "Generating fstab with UUIDs..."
exe genfstab -U /mnt >> /mnt/etc/fstab

log "Verifying fstab..."
cat /mnt/etc/fstab

# ==============================================================================
# STEP 7: Prepare for Chroot Continuation
# ==============================================================================
section "Step 7/7" "Chroot Setup"

log "Copying installer to /mnt/root..."
exe cp -r "$PARENT_DIR" /mnt/root/

log "Creating chroot continuation script..."
cat > /mnt/root/continue-install.sh << 'CHROOT_EOF'
#!/bin/bash

# 设置环境变量（防止重复运行基础安装）
export SKIP_BASE_INSTALL=1

# 基础配置
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
hwclock --systohc

# Locale
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
echo "zh_CN.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Hostname
echo "shorin-arch" > /etc/hostname
cat > /etc/hosts << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   shorin-arch.localdomain shorin-arch
EOF

# 启用NetworkManager
systemctl enable NetworkManager

# GRUB安装
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Base system configured. Now running Shorin Setup..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 运行Shorin安装器（跳过ISO安装模块）
cd /root/shorin-arch-setup
export SKIP_BASE_INSTALL=1  # 标记已完成基础安装
bash install.sh
CHROOT_EOF

chmod +x /mnt/root/continue-install.sh

# ==============================================================================
# Chroot Execution
# ==============================================================================
echo ""
echo -e "${H_GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${H_GREEN}║  Base Installation Complete                                    ║${NC}"
echo -e "${H_GREEN}║  Now entering chroot to continue Shorin Setup...               ║${NC}"
echo -e "${H_GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

log "Entering arch-chroot..."
sleep 2

# 重要：在chroot前设置root密码
echo ""
echo -e "${H_YELLOW}>>> Please set ROOT password for the new system:${NC}"
arch-chroot /mnt passwd

# 执行chroot内的继续脚本
if arch-chroot /mnt /root/continue-install.sh; then
    success "Chroot installation completed."
else
    error "Chroot installation failed."
    warn "You can manually chroot to fix: arch-chroot /mnt"
    exit 1
fi

# ==============================================================================
# Cleanup
# ==============================================================================
log "Unmounting filesystems..."
umount -R /mnt 2>/dev/null || true

echo ""
echo -e "${H_GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${H_GREEN}║  INSTALLATION COMPLETE                                         ║${NC}"
echo -e "${H_GREEN}║  You can now reboot into your new Arch system.                 ║${NC}"
echo -e "${H_GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

log "Hint: Remove installation media before reboot."
