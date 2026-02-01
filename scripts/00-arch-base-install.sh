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
section "阶段 0" "环境检测"

if ! is_iso_environment; then
    log "未检测到 ISO 环境，跳过基础安装。"
    log "假定系统已安装。"
    exit 0
fi

warn "检测到 Arch ISO 环境。"
log "将继续进行基础系统安装。"
echo ""

# ==============================================================================
# STEP 1: Disk Selection & Validation
# ==============================================================================

# --- Disk Analysis Functions ---

# 检测磁盘是否有分区
has_partitions() {
    local disk="$1"
    [ "$(lsblk -n -o TYPE "$disk" | grep -c part)" -gt 0 ]
}

# 检测是否为系统盘（有挂载分区）
is_system_disk() {
    local disk="$1"
    lsblk -n -o MOUNTPOINT "$disk" 2>/dev/null | grep -qE '^(/|/boot|/home|/var)'
}

# 检测磁盘类型（过滤不适合的类型）
is_suitable_disk() {
    local disk="$1"
    local rota=$(lsblk -d -n -o ROTA "$disk" 2>/dev/null)
    local tran=$(lsblk -d -n -o TRAN "$disk" 2>/dev/null)
    
    # 排除光驱
    [[ "$(lsblk -d -n -o TYPE "$disk")" != "rom" ]] || return 1
    
    # 警告USB设备（仍然允许选择）
    if [[ "$tran" == "usb" ]]; then
        return 2  # USB disk (warning)
    fi
    
    return 0
}

# 获取磁盘详细信息
get_disk_info() {
    local disk="$1"
    local model=$(lsblk -d -n -o MODEL "$disk" 2>/dev/null | xargs)
    local size=$(lsblk -d -n -o SIZE "$disk")
    local tran=$(lsblk -d -n -o TRAN "$disk" 2>/dev/null)
    local rota=$(lsblk -d -n -o ROTA "$disk" 2>/dev/null)
    
    # 磁盘类型标识
    local type_label=""
    if [ "$rota" = "0" ]; then
        type_label="SSD"
    else
        type_label="HDD"
    fi
    
    # 传输接口
    local tran_label=""
    case "$tran" in
        nvme) tran_label="NVMe" ;;
        sata) tran_label="SATA" ;;
        usb)  tran_label="USB" ;;
        *)    tran_label="$tran" ;;
    esac
    
    # 状态检测
    local status=""
    if is_system_disk "$disk"; then
        status="${H_RED}⚠ SYSTEM${NC}"
    elif has_partitions "$disk"; then
        status="${H_YELLOW}⚠ DATA${NC}"
    else
        status="${H_GREEN}✓ EMPTY${NC}"
    fi
    
    echo "${model:-未知}|${size}|${type_label}|${tran_label}|${status}"
}

# --- Interactive Disk Selection ---
select_disk() {
    section "步骤 1/7" "磁盘选择"
    
    log "正在扫描可用磁盘..."
    
    # 收集所有合适的磁盘
    local -a DISKS=()
    local -a DISK_INFO=()
    
    while IFS= read -r disk_name; do
        local disk_path="/dev/$disk_name"
        
        # 跳过不合适的磁盘（如光驱）
        if ! is_suitable_disk "$disk_path"; then
            [ $? -eq 1 ] && continue  # 完全跳过（光驱）
        fi
        
        # 检查最小大小
        local size_bytes=$(lsblk -d -n -o SIZE -b "$disk_path")
        if [ "$size_bytes" -lt "$MIN_DISK_SIZE_BYTES" ]; then
            continue
        fi
        
        DISKS+=("$disk_path")
        DISK_INFO+=("$(get_disk_info "$disk_path")")
    done < <(lsblk -d -n -o NAME,TYPE | awk '$2=="disk" {print $1}')
    
    if [ ${#DISKS[@]} -eq 0 ]; then
        error "未找到合适磁盘（至少需要 ${MIN_DISK_SIZE_GB}GB）。"
        exit 1
    fi
    
    # 绘制菜单
    local HR="────────────────────────────────────────────────────────────────────────"
    echo -e "${H_PURPLE}╭${HR}${NC}"
    echo -e "${H_PURPLE}│${NC} ${BOLD}选择目标磁盘（所有数据将被清除）：${NC}"
    echo -e "${H_PURPLE}│${NC}"
    
    local idx=1
    for i in "${!DISKS[@]}"; do
        local disk="${DISKS[$i]}"
        IFS='|' read -r model size type tran status <<< "${DISK_INFO[$i]}"
        
        # 格式化显示
        printf "${H_PURPLE}│${NC}  ${H_CYAN}[%d]${NC} %-15s ${BOLD}%s${NC}\n" \
            "$idx" "$disk" "$size"
        printf "${H_PURPLE}│${NC}      %-30s ${DIM}%s %s${NC} %b\n" \
            "$model" "$type" "$tran" "$status"
        
        ((idx++))
    done
    
    echo -e "${H_PURPLE}│${NC}"
    echo -e "${H_PURPLE}╰${HR}${NC}"
    echo ""
    
    # 输入处理
    echo -e "   ${DIM}60 秒后自动选择第一个磁盘...${NC}"
    local choice=""
    if ! read -t 60 -p "$(echo -e "   ${H_YELLOW}选择 [1-${#DISKS[@]}] 或回车自动： ${NC}")" choice; then
        choice=""
    fi
    
    # 默认选择第一个
    if [ -z "$choice" ]; then
        choice=1
        log "超时 - 使用第一个磁盘。"
    fi
    
    # 验证输入
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#DISKS[@]}" ]; then
        export TARGET_DISK="${DISKS[$((choice-1))]}"
        log "已选择: $TARGET_DISK"
    else
        error "选择无效。"
        exit 1
    fi
    
    echo ""
}

# --- Main Disk Selection Logic ---

TARGET_DISK="${TARGET_DISK:-}"
if [ -z "$TARGET_DISK" ]; then
    # 交互式选择
    select_disk
else
    # 环境变量模式 - 仅做验证
    section "步骤 1/7" "磁盘选择"
    log "使用环境变量 TARGET_DISK: $TARGET_DISK"
fi

# --- Validation ---
if [ ! -b "$TARGET_DISK" ]; then
    error "TARGET_DISK 不是块设备: $TARGET_DISK"
    log "可用磁盘："
    lsblk -d -o NAME,SIZE,TYPE | grep disk || true
    exit 1
fi

if [ "$(lsblk -d -no TYPE "$TARGET_DISK")" != "disk" ]; then
    error "TARGET_DISK 必须是磁盘（不是分区）：$TARGET_DISK"
    exit 1
fi

DISK_SIZE_BYTES=$(lsblk -d -n -o SIZE -b "$TARGET_DISK")
DISK_SIZE_HUMAN=$(lsblk -d -n -o SIZE "$TARGET_DISK")

info_kv "目标磁盘" "$TARGET_DISK" "($DISK_SIZE_HUMAN)"

# 安全检查：确认磁盘大小
if [ "$DISK_SIZE_BYTES" -lt "$MIN_DISK_SIZE_BYTES" ]; then
    error "磁盘太小，至少需要 ${MIN_DISK_SIZE_GB}GB。"
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
    error "BOOT_MODE 无效: $BOOT_MODE（可用 uefi|bios）"
    exit 1
fi
info_kv "启动模式" "$BOOT_MODE" "(auto/override)"

# --- Final Confirmation ---
section "步骤 1/7" "最终确认"

# 再次检查是否为系统盘
warning_level="CRITICAL"
if is_system_disk "$TARGET_DISK"; then
    warning_level="${H_RED}严重：系统盘${NC}"
elif has_partitions "$TARGET_DISK"; then
    warning_level="${H_YELLOW}警告：有数据${NC}"
else
    warning_level="${H_GREEN}正常：空磁盘${NC}"
fi

echo ""
echo -e "${H_RED}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${H_RED}║  ⚠️  最终警告：所有数据将被清除  ⚠️             ║${NC}"
echo -e "${H_RED}╠════════════════════════════════════════════════════════════════╣${NC}"
echo -e "${H_RED}║${NC}  磁盘     : ${BOLD}$TARGET_DISK${NC}"
echo -e "${H_RED}║${NC}  型号     : $(lsblk -d -n -o MODEL "$TARGET_DISK" 2>/dev/null || echo '未知')"
echo -e "${H_RED}║${NC}  容量     : $DISK_SIZE_HUMAN"
echo -e "${H_RED}║${NC}  状态     : $warning_level"

# 显示现有分区（如果有）
if has_partitions "$TARGET_DISK"; then
    echo -e "${H_RED}║${NC}"
    echo -e "${H_RED}║${NC}  ${H_YELLOW}现有分区：${NC}"
    while IFS= read -r line; do
        echo -e "${H_RED}║${NC}    $line"
    done < <(lsblk -n -o NAME,SIZE,FSTYPE,MOUNTPOINT "$TARGET_DISK" | grep -v "^$(basename "$TARGET_DISK")")
fi

echo -e "${H_RED}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

if [ "${CONFIRM_DISK_WIPE:-}" = "YES" ]; then
    confirm="yes"
    log "通过 CONFIRM_DISK_WIPE=YES 自动确认"
else
    # 系统盘需要输入完整磁盘名称
    if is_system_disk "$TARGET_DISK"; then
        echo -e "${H_RED}>>> 检测到系统盘！请输入完整磁盘名确认：${NC}"
        if ! read -t 30 -p "$(echo -e "   ${H_YELLOW}输入 '$TARGET_DISK' 以确认： ${NC}")" confirm; then
            confirm=""
        fi
        
        if [ "$confirm" != "$TARGET_DISK" ]; then
            error "确认失败，安装已取消。"
            exit 1
        fi
        confirm="yes"
    else
        # 普通磁盘只需输入 yes
        if ! read -t 30 -p "$(echo -e "   ${H_YELLOW}输入 'yes' 以清除 $TARGET_DISK： ${NC}")" confirm; then
            confirm=""
        fi
        confirm=${confirm:-NO}
    fi
fi

if [ "$confirm" != "yes" ]; then
    error "安装已被用户取消。"
    exit 1
fi

success "磁盘选择已确认: $TARGET_DISK"

# ==============================================================================
# STEP 2: Partitioning
# ==============================================================================
section "步骤 2/7" "磁盘分区"

# 确保分区工具存在
if ! command -v sgdisk &>/dev/null; then
    log "安装分区工具..."
    pacman -Sy --noconfirm gptfdisk
fi

log "创建 GPT 分区表..."
exe sgdisk -Z "$TARGET_DISK"  # 清除分区表
exe sgdisk -o "$TARGET_DISK"  # 创建GPT

if [ "$BOOT_MODE" = "uefi" ]; then
    log "创建 EFI 分区 (${EFI_SIZE})..."
    exe sgdisk -n 1:0:+${EFI_SIZE} -t 1:ef00 -c 1:"EFI" "$TARGET_DISK"

    log "创建 Btrfs 分区（剩余空间）..."
    exe sgdisk -n 2:0:0 -t 2:8300 -c 2:"Linux" "$TARGET_DISK"
else
    log "创建 BIOS 启动分区 (${BIOS_BOOT_SIZE})..."
    exe sgdisk -n 1:0:+${BIOS_BOOT_SIZE} -t 1:ef02 -c 1:"BIOS" "$TARGET_DISK"

    log "创建 Btrfs 分区（剩余空间）..."
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
    info_kv "EFI 分区" "$EFI_PART"
fi
info_kv "根分区" "$ROOT_PART"

# ==============================================================================
# STEP 3: Format Partitions
# ==============================================================================
section "步骤 3/7" "格式化"

if [ "$BOOT_MODE" = "uefi" ]; then
    log "格式化 EFI 分区 (FAT32)..."
    exe mkfs.fat -F32 "$EFI_PART"
fi

log "格式化根分区 (Btrfs)..."
exe mkfs.btrfs -f -L "ArchRoot" "$ROOT_PART"

success "分区格式化完成。"

# ==============================================================================
# STEP 4: Btrfs Subvolumes Setup
# ==============================================================================
section "步骤 4/7" "Btrfs 子卷"

log "挂载根分区以创建子卷..."
exe mount "$ROOT_PART" /mnt

log "创建 Btrfs 子卷..."
exe btrfs subvolume create /mnt/@
exe btrfs subvolume create /mnt/@home
exe btrfs subvolume create /mnt/@snapshots
exe btrfs subvolume create /mnt/@log
exe btrfs subvolume create /mnt/@cache

log "卸载后以子卷方式重新挂载..."
exe umount /mnt

log "使用优化参数挂载子卷..."
BTRFS_OPTS="defaults,noatime,compress=zstd:1,space_cache=v2"

exe mount -o "subvol=@,$BTRFS_OPTS" "$ROOT_PART" /mnt
exe mkdir -p /mnt/{boot,home,.snapshots,var/log,var/cache}
exe mount -o "subvol=@home,$BTRFS_OPTS" "$ROOT_PART" /mnt/home
exe mount -o "subvol=@snapshots,$BTRFS_OPTS" "$ROOT_PART" /mnt/.snapshots
exe mount -o "subvol=@log,$BTRFS_OPTS" "$ROOT_PART" /mnt/var/log
exe mount -o "subvol=@cache,$BTRFS_OPTS" "$ROOT_PART" /mnt/var/cache

if [ "$BOOT_MODE" = "uefi" ]; then
    log "挂载 EFI 分区..."
    exe mount "$EFI_PART" /mnt/boot
fi

success "Btrfs 布局配置完成。"
lsblk "$TARGET_DISK"

# ==============================================================================
# STEP 5: Base System Installation
# ==============================================================================
section "步骤 5/7" "安装基础系统"

log "运行 pacstrap（可能需要几分钟）..."
if exe pacstrap /mnt $PACSTRAP_BASE_PKGS; then
    success "基础系统安装完成。"
else
    error "pacstrap 失败，请检查网络。"
    exit 1
fi

# ==============================================================================
# STEP 6: System Configuration
# ==============================================================================
section "步骤 6/7" "生成 fstab"

log "使用 UUID 生成 fstab..."
exe genfstab -U /mnt > /mnt/etc/fstab

log "校验 fstab..."
cat /mnt/etc/fstab

# ==============================================================================
# STEP 7: Prepare for Chroot Continuation
# ==============================================================================
section "步骤 7/7" "Chroot 配置"

log "复制安装器到 /mnt/root..."
exe cp -r "$PARENT_DIR" /mnt/root/

log "创建 chroot 继续脚本..."
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
    echo "错误：GRUB BIOS 安装失败"
    exit 1
  fi
else
  if ! grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB; then
    echo "错误：GRUB UEFI 安装失败"
    exit 1
  fi
fi

# Root 密码（无人值守）
if [ -n "${ROOT_PASSWORD_HASH:-}" ]; then
  # 验证格式：$id$salt$hash（如 $6$rounds=5000$salt$hash）
  if [[ "$ROOT_PASSWORD_HASH" =~ ^\$[0-9]+\$[^\$]+\$ ]]; then
    if ! echo "root:${ROOT_PASSWORD_HASH}" | chpasswd -e 2>&1; then
      echo "错误：通过 chpasswd 设置 root 密码失败"
      echo "Hash 格式可能无效。可用以下命令生成：openssl passwd -6 'yourpassword'"
      exit 1
    fi
    echo "已使用 ROOT_PASSWORD_HASH 设置 root 密码"
  else
    echo "错误：ROOT_PASSWORD_HASH 格式无效"
    echo "期望格式：\$id\$salt\$hash"
    echo "生成命令：openssl passwd -6 'yourpassword'"
    exit 1
  fi
else
  echo "未提供 ROOT_PASSWORD_HASH，将交互式设置密码："
  passwd
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  基础系统已配置，开始运行 Shorin Setup..."
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
echo -e "${H_GREEN}║  基础安装完成                                                  ║${NC}"
echo -e "${H_GREEN}║  即将进入 chroot 继续 Shorin Setup...                           ║${NC}"
echo -e "${H_GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

log "进入 arch-chroot..."
sleep 2

# 执行chroot内的继续脚本
if arch-chroot /mnt /root/continue-install.sh; then
    success "Chroot 安装完成。"
else
    error "Chroot 安装失败。"
    warn "可手动 chroot 修复：arch-chroot /mnt"
    exit 1
fi

# ==============================================================================
# Cleanup
# ==============================================================================
log "卸载文件系统..."
umount -R /mnt 2>/dev/null || true

echo ""
echo -e "${H_GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${H_GREEN}║  安装完成                                                      ║${NC}"
echo -e "${H_GREEN}║  现在可以重启进入新 Arch 系统。                                ║${NC}"
echo -e "${H_GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

log "提示：重启前请移除安装介质。"
