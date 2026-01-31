#!/bin/bash

# ==============================================================================
# 00-arch-base-install.sh - Arch Base System Installation for ISO Environment
# ==============================================================================
# 功能：检测ISO环境 → 自动分区 → pacstrap → genfstab → arch-chroot后继续

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/00-utils.sh"

# --- Config & Strict Mode ---
CONFIG_FILE="${SHORIN_CONFIG:-$PARENT_DIR/config.conf}"
load_config
enable_strict_mode

# --- Constants ---
readonly EFI_SIZE="512M"
readonly BIOS_BOOT_SIZE="1M"
readonly MIN_DISK_SIZE_GB=20
readonly MIN_DISK_SIZE_BYTES=$((MIN_DISK_SIZE_GB * 1024 * 1024 * 1024))
readonly PACSTRAP_BASE_PKGS="base base-devel linux linux-firmware btrfs-progs networkmanager grub efibootmgr sudo nano vim git wget curl"

check_root

# ==============================================================================
# STEP 0: ISO Environment Detection
# ==============================================================================
section "Phase 0" "Environment Detection"

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
lsblk -d -n -o NAME,SIZE,TYPE | grep disk || true

TARGET_DISK="${TARGET_DISK:-}"
if [ -z "$TARGET_DISK" ]; then
    error "TARGET_DISK is required. Example: TARGET_DISK=/dev/nvme0n1"
    exit 1
fi

if [ ! -b "$TARGET_DISK" ]; then
    error "TARGET_DISK is not a block device: $TARGET_DISK"
    exit 1
fi

if [ "$(lsblk -no TYPE "$TARGET_DISK")" != "disk" ]; then
    error "TARGET_DISK must be a disk (not a partition): $TARGET_DISK"
    exit 1
fi

DISK_SIZE_BYTES=$(lsblk -d -n -o SIZE -b "$TARGET_DISK")
DISK_SIZE_HUMAN=$(lsblk -d -n -o SIZE "$TARGET_DISK")

info_kv "Target Disk" "$TARGET_DISK" "($DISK_SIZE_HUMAN)"

# 安全检查：确认磁盘大小
if [ "$DISK_SIZE_BYTES" -lt "$MIN_DISK_SIZE_BYTES" ]; then
    error "Disk too small. Minimum ${MIN_DISK_SIZE_GB}GB required."
    exit 1
fi

# 检测启动模式（可用 BOOT_MODE 覆盖）
BOOT_MODE="${BOOT_MODE:-}"
if [ -z "$BOOT_MODE" ]; then
    if [ -d /sys/firmware/efi ]; then
        BOOT_MODE="uefi"
    else
        BOOT_MODE="bios"
    fi
fi
BOOT_MODE="${BOOT_MODE,,}"
if [ "$BOOT_MODE" != "uefi" ] && [ "$BOOT_MODE" != "bios" ]; then
    error "Invalid BOOT_MODE: $BOOT_MODE (use uefi|bios)"
    exit 1
fi
info_kv "Boot Mode" "$BOOT_MODE" "(auto/override)"

# 警告确认
echo ""
echo -e "${H_RED}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${H_RED}║  WARNING: THIS WILL ERASE ALL DATA ON $TARGET_DISK${NC}"
echo -e "${H_RED}║  Disk: $(lsblk -d -n -o MODEL "$TARGET_DISK" 2>/dev/null || echo 'Unknown')${NC}"
echo -e "${H_RED}║  Size: $DISK_SIZE_HUMAN${NC}"
echo -e "${H_RED}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

if [ "${CONFIRM_DISK_WIPE:-}" = "YES" ]; then
    confirm="yes"
else
    if ! read -t 30 -p "$(echo -e "   ${H_YELLOW}Confirm to ERASE $TARGET_DISK? [yes/NO]: ${NC}")" confirm; then
        confirm=""
    fi
    confirm=${confirm:-NO}
fi

if [ "$confirm" != "yes" ]; then
    error "Installation cancelled by user."
    exit 1
fi

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

if [ "$BOOT_MODE" = "uefi" ]; then
    log "Creating EFI partition (${EFI_SIZE})..."
    exe sgdisk -n 1:0:+${EFI_SIZE} -t 1:ef00 -c 1:"EFI" "$TARGET_DISK"

    log "Creating Btrfs partition (remaining space)..."
    exe sgdisk -n 2:0:0 -t 2:8300 -c 2:"Linux" "$TARGET_DISK"
else
    log "Creating BIOS boot partition (${BIOS_BOOT_SIZE})..."
    exe sgdisk -n 1:0:+${BIOS_BOOT_SIZE} -t 1:ef02 -c 1:"BIOS" "$TARGET_DISK"

    log "Creating Btrfs partition (remaining space)..."
    exe sgdisk -n 2:0:0 -t 2:8300 -c 2:"Linux" "$TARGET_DISK"
fi

# 通知内核重新读取分区表
exe partprobe "$TARGET_DISK"
sleep 2

# 分区设备名（处理nvme、mmcblk和sata差异）
if [[ "$TARGET_DISK" =~ (nvme|mmcblk) ]]; then
    EFI_PART="${TARGET_DISK}p1"
    ROOT_PART="${TARGET_DISK}p2"
else
    EFI_PART="${TARGET_DISK}1"
    ROOT_PART="${TARGET_DISK}2"
fi

if [ "$BOOT_MODE" = "uefi" ]; then
    info_kv "EFI Partition" "$EFI_PART"
fi
info_kv "Root Partition" "$ROOT_PART"

# ==============================================================================
# STEP 3: Format Partitions
# ==============================================================================
section "Step 3/7" "Formatting"

if [ "$BOOT_MODE" = "uefi" ]; then
    log "Formatting EFI partition (FAT32)..."
    exe mkfs.fat -F32 "$EFI_PART"
fi

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

if [ "$BOOT_MODE" = "uefi" ]; then
    log "Mounting EFI partition..."
    exe mount "$EFI_PART" /mnt/boot
fi

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
exe genfstab -U /mnt > /mnt/etc/fstab

log "Verifying fstab..."
cat /mnt/etc/fstab

# ==============================================================================
# STEP 7: Prepare for Chroot Continuation
# ==============================================================================
section "Step 7/7" "Chroot Setup"

log "Copying installer to /mnt/root..."
exe cp -r "$PARENT_DIR" /mnt/root/

log "Creating chroot continuation script..."
{
    printf 'TARGET_DISK=%q\n' "$TARGET_DISK"
    printf 'BOOT_MODE=%q\n' "$BOOT_MODE"
    [ -n "${ROOT_PASSWORD_HASH:-}" ] && printf 'ROOT_PASSWORD_HASH=%q\n' "$ROOT_PASSWORD_HASH"
    [ -n "${SHORIN_USERNAME:-}" ] && printf 'SHORIN_USERNAME=%q\n' "$SHORIN_USERNAME"
    [ -n "${SHORIN_PASSWORD:-}" ] && printf 'SHORIN_PASSWORD=%q\n' "$SHORIN_PASSWORD"
    [ -n "${DESKTOP_ENV:-}" ] && printf 'DESKTOP_ENV=%q\n' "$DESKTOP_ENV"
    [ -n "${CONFIRM_DISK_WIPE:-}" ] && printf 'CONFIRM_DISK_WIPE=%q\n' "$CONFIRM_DISK_WIPE"
    [ -n "${CN_MIRROR:-}" ] && printf 'CN_MIRROR=%q\n' "$CN_MIRROR"
    [ -n "${DEBUG:-}" ] && printf 'DEBUG=%q\n' "$DEBUG"
} > /mnt/root/shorin-install.env

cat > /mnt/root/continue-install.sh << 'CHROOT_EOF'
#!/bin/bash

set -Eeuo pipefail

# 加载安装环境变量与配置
if [ -f /root/shorin-install.env ]; then
  # shellcheck source=/dev/null
  source /root/shorin-install.env
fi
if [ -f /root/shorin-arch-setup/config.conf ]; then
  # shellcheck source=/dev/null
  source /root/shorin-arch-setup/config.conf
fi

# 设置环境变量（防止重复运行基础安装）
export SKIP_BASE_INSTALL=1
export SHORIN_USERNAME="${SHORIN_USERNAME:-}"
export SHORIN_PASSWORD="${SHORIN_PASSWORD:-}"
export DESKTOP_ENV="${DESKTOP_ENV:-}"
export CN_MIRROR="${CN_MIRROR:-0}"
export DEBUG="${DEBUG:-0}"

# 基础配置
TIMEZONE="${TIMEZONE:-Asia/Shanghai}"
HOSTNAME="${HOSTNAME:-shorin-arch}"
LOCALE="${LOCALE:-en_US.UTF-8}"
EXTRA_LOCALES="${EXTRA_LOCALES:-zh_CN.UTF-8}"

ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc

# Locale
for loc in "$LOCALE" $EXTRA_LOCALES; do
  if ! grep -q -E "^${loc} UTF-8" /etc/locale.gen; then
    sed -i "s/^#\s*${loc} UTF-8/${loc} UTF-8/" /etc/locale.gen
    if ! grep -q -E "^${loc} UTF-8" /etc/locale.gen; then
      echo "${loc} UTF-8" >> /etc/locale.gen
    fi
  fi
done
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf

# Hostname
echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
EOF

# 启用NetworkManager
systemctl enable NetworkManager

# GRUB安装
if [ "${BOOT_MODE}" = "bios" ]; then
  if ! grub-install --target=i386-pc "${TARGET_DISK}"; then
    echo "ERROR: GRUB BIOS installation failed"
    exit 1
  fi
else
  if ! grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB; then
    echo "ERROR: GRUB UEFI installation failed"
    exit 1
  fi
fi

# Root 密码（无人值守）
if [ -n "${ROOT_PASSWORD_HASH:-}" ]; then
  if [[ "$ROOT_PASSWORD_HASH" =~ ^\$[0-9]+\$ ]]; then
    if ! echo "root:${ROOT_PASSWORD_HASH}" | chpasswd -e; then
      echo "ERROR: Failed to set root password"
      exit 1
    fi
  else
    echo "ERROR: Invalid ROOT_PASSWORD_HASH format (expected \$id\$...)"
    exit 1
  fi
else
  passwd
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Base system configured. Now running Shorin Setup..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 运行Shorin安装器（跳过ISO安装模块）
cd /root/shorin-arch-setup
export SKIP_BASE_INSTALL=1  # 标记已完成基础安装
bash scripts/install.sh
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
