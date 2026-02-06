#!/usr/bin/env bash
set -Eeuo pipefail

# Arch ISO one-key installer (auto wipe + niri/noctalia/ghostty).
# Run in Arch ISO as root.

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ASSETS_DIR="${SCRIPT_DIR}"
readonly ASSETS_CONFIG_DIR="${ASSETS_DIR}/configs"
readonly ASSETS_SOFTWARE_LIST="${ASSETS_DIR}/software-packages.txt"

# -----------------------
# User-tunable variables
# -----------------------
INSTALL_USER="${INSTALL_USER:-}"
INSTALL_PASSWORD="${INSTALL_PASSWORD:-}"
ROOT_PASSWORD="${ROOT_PASSWORD:-}"
HOST_NAME="${HOST_NAME:-arch-niri}"
TIME_ZONE="${TIME_ZONE:-Asia/Shanghai}"
LOCALE_MAIN="${LOCALE_MAIN:-en_US.UTF-8}"
LOCALE_EXTRA="${LOCALE_EXTRA:-zh_CN.UTF-8}"
KEYMAP="${KEYMAP:-us}"
BOOT_MODE="${BOOT_MODE:-auto}" # auto|uefi|bios
TARGET_DISK="${TARGET_DISK:-}" # empty => auto choose largest non-USB disk
AUTO_REBOOT="${AUTO_REBOOT:-1}" # 1|0
ALLOW_NON_ISO="${ALLOW_NON_ISO:-0}" # 1 to bypass ISO-only guard
ADD_USER_TO_ROOT_GROUP="${ADD_USER_TO_ROOT_GROUP:-0}" # 1|0 (not recommended)
AUTO_LOGIN_TTY1="${AUTO_LOGIN_TTY1:-1}" # 1|0
GPU_PROFILE="${GPU_PROFILE:-select}" # select|auto|1|2|3|4

readonly MIN_DISK_BYTES=$((20 * 1024 * 1024 * 1024))
readonly WORK_DIR="/tmp/arch-niri-installer"
readonly REPO_LIST_FILE="${WORK_DIR}/repo-packages.txt"
readonly AUR_LIST_FILE="${WORK_DIR}/aur-packages.txt"
readonly FLATPAK_LIST_FILE="${WORK_DIR}/flatpak-packages.txt"

log()  { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
err()  { printf '[x] %s\n' "$*" >&2; }

cleanup_on_error() {
  local code=$?
  err "安装失败（exit=${code}）。执行清理..."
  swapoff -a >/dev/null 2>&1 || true
  umount -R /mnt >/dev/null 2>&1 || true
}
trap cleanup_on_error ERR

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || {
    err "缺少命令: $cmd"
    exit 1
  }
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    err "必须以 root 运行。"
    exit 1
  fi
}

ensure_iso_toolchain() {
  local -a must_cmds=(
    lsblk findmnt wipefs sgdisk parted partprobe udevadm mkfs.fat mkfs.btrfs btrfs
    pacstrap genfstab arch-chroot
    chpasswd useradd usermod runuser
  )
  local -a bootstrap_pkgs=(
    arch-install-scripts
    util-linux
    shadow
    gptfdisk
    parted
    dosfstools
    btrfs-progs
    pciutils
    systemd
  )
  local -a missing_cmds=()
  local cmd

  require_cmd pacman

  for cmd in "${must_cmds[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing_cmds+=("$cmd")
    fi
  done

  if [[ ${#missing_cmds[@]} -gt 0 ]]; then
    warn "ISO 环境缺少命令: ${missing_cmds[*]}"
    log "尝试通过 pacman 安装安装器所需工具..."
    pacman -Sy --noconfirm --needed "${bootstrap_pkgs[@]}"
  fi

  for cmd in "${must_cmds[@]}"; do
    require_cmd "$cmd"
  done
}

is_valid_username() {
  local username="$1"
  [[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]] && [[ "$username" != "root" ]]
}

validate_zero_one_flag() {
  local key="$1"
  local value="$2"
  [[ "$value" =~ ^[01]$ ]] || {
    err "${key} 仅支持 0 或 1"
    exit 1
  }
}

trim_space() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

prompt_hidden_password() {
  local prompt_text="$1"
  local p1="" p2=""
  while true; do
    read -r -s -p "$prompt_text" p1
    echo
    read -r -s -p "请再次输入确认: " p2
    echo
    [[ -n "$p1" ]] || {
      warn "密码不能为空，请重新输入。"
      continue
    }
    [[ "$p1" == "$p2" ]] || {
      warn "两次密码不一致，请重新输入。"
      continue
    }
    printf '%s' "$p1"
    return 0
  done
}

collect_identity_inputs() {
  if [[ -z "$INSTALL_USER" || -z "$INSTALL_PASSWORD" || -z "$ROOT_PASSWORD" ]]; then
    if [[ ! -t 0 ]]; then
      err "非交互终端下必须显式设置 INSTALL_USER/INSTALL_PASSWORD/ROOT_PASSWORD。"
      exit 1
    fi
  fi

  if [[ -z "$INSTALL_USER" ]]; then
    while true; do
      read -r -p "请输入新用户名: " INSTALL_USER
      if is_valid_username "$INSTALL_USER"; then
        break
      fi
      warn "用户名非法：需小写字母/数字/_/-，不能以数字开头且不能为 root。"
    done
  fi

  if [[ -z "$INSTALL_PASSWORD" ]]; then
    INSTALL_PASSWORD="$(prompt_hidden_password "请输入用户密码: ")"
  fi

  if [[ -z "$ROOT_PASSWORD" ]]; then
    local same_as_user
    read -r -p "root 密码与用户密码相同吗？[Y/n]: " same_as_user
    if [[ -z "$same_as_user" || "$same_as_user" =~ ^[Yy]$ ]]; then
      ROOT_PASSWORD="$INSTALL_PASSWORD"
    else
      ROOT_PASSWORD="$(prompt_hidden_password "请输入 root 密码: ")"
    fi
  fi
}

validate_inputs() {
  validate_zero_one_flag AUTO_REBOOT "$AUTO_REBOOT"
  validate_zero_one_flag ALLOW_NON_ISO "$ALLOW_NON_ISO"
  validate_zero_one_flag ADD_USER_TO_ROOT_GROUP "$ADD_USER_TO_ROOT_GROUP"
  validate_zero_one_flag AUTO_LOGIN_TTY1 "$AUTO_LOGIN_TTY1"

  is_valid_username "$INSTALL_USER" || {
    err "INSTALL_USER 非法：仅支持小写字母/数字/_/-，且不能以数字开头。"
    exit 1
  }

  [[ "$HOST_NAME" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || {
    err "HOST_NAME 非法：仅支持字母/数字/-，不能以 - 开头或结尾，长度 1-63。"
    exit 1
  }
  [[ -n "$INSTALL_PASSWORD" ]] || {
    err "INSTALL_PASSWORD 不能为空。"
    exit 1
  }
  [[ -n "$ROOT_PASSWORD" ]] || {
    err "ROOT_PASSWORD 不能为空。"
    exit 1
  }
  [[ "$GPU_PROFILE" =~ ^(select|auto|1|2|3|4)$ ]] || {
    err "GPU_PROFILE 仅支持 select|auto|1|2|3|4"
    exit 1
  }
  [[ -f "/usr/share/zoneinfo/${TIME_ZONE}" ]] || {
    err "TIME_ZONE 无效或不存在: ${TIME_ZONE}"
    exit 1
  }
}

is_arch_iso() {
  [[ -d /run/archiso ]] || [[ "$(hostname 2>/dev/null || true)" == "archiso" ]]
}

resolve_boot_mode() {
  case "$BOOT_MODE" in
    uefi)
      if [[ ! -d /sys/firmware/efi/efivars ]]; then
        err "当前环境未检测到 UEFI 固件变量（/sys/firmware/efi/efivars）。"
        err "请在 UEFI 模式启动 Arch ISO，或将 BOOT_MODE 设为 auto/bios。"
        exit 1
      fi
      ;;
    bios) ;;
    auto)
      if [[ -d /sys/firmware/efi/efivars ]]; then
        BOOT_MODE="uefi"
      else
        BOOT_MODE="bios"
      fi
      ;;
    *)
      err "BOOT_MODE 仅支持 auto|uefi|bios"
      exit 1
      ;;
  esac
  log "Boot mode: $BOOT_MODE"
}

resolve_gpu_profile() {
  local has_amd=0 has_nvidia=0 line

  if [[ "$GPU_PROFILE" == "select" ]]; then
    if [[ -t 0 ]]; then
      echo "请选择 GPU 方案："
      echo "  1) 无 GPU"
      echo "  2) AMDGPU"
      echo "  3) NVIDIA"
      echo "  4) AMD 核显 + NVIDIA"
      while true; do
        read -r -p "输入 1/2/3/4: " GPU_PROFILE
        if [[ "$GPU_PROFILE" =~ ^[1-4]$ ]]; then
          break
        fi
        warn "输入无效，请输入 1、2、3 或 4。"
      done
    else
      warn "GPU_PROFILE=select 但当前非交互终端，自动回退到 auto。"
      GPU_PROFILE="auto"
    fi
  fi

  if [[ "$GPU_PROFILE" == "auto" ]]; then
    if command -v lspci >/dev/null 2>&1; then
      while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        [[ "$line" == *amd* || "$line" == *advanced*micro*devices* || "$line" == *ati* ]] && has_amd=1
        [[ "$line" == *nvidia* ]] && has_nvidia=1
      done < <(lspci -nn | awk '/VGA compatible controller|3D controller|Display controller/ {print tolower($0)}')
    else
      warn "未找到 lspci，GPU_PROFILE=auto 将回退为 1(无 GPU)。"
    fi
    if [[ "$has_amd" == "1" && "$has_nvidia" == "1" ]]; then
      GPU_PROFILE="4"
    elif [[ "$has_amd" == "1" ]]; then
      GPU_PROFILE="2"
    elif [[ "$has_nvidia" == "1" ]]; then
      GPU_PROFILE="3"
    else
      GPU_PROFILE="1"
    fi
  fi

  case "$GPU_PROFILE" in
    1) log "GPU 方案: 1) 无 GPU" ;;
    2) log "GPU 方案: 2) AMDGPU" ;;
    3) log "GPU 方案: 3) NVIDIA" ;;
    4) log "GPU 方案: 4) AMD 核显 + NVIDIA" ;;
  esac
}

part_path() {
  local disk="$1"
  local idx="$2"
  if [[ "$disk" =~ [0-9]$ ]]; then
    printf '%sp%s\n' "$disk" "$idx"
  else
    printf '%s%s\n' "$disk" "$idx"
  fi
}

select_target_disk() {
  local normalized_target
  if [[ -n "$TARGET_DISK" ]]; then
    normalized_target="$TARGET_DISK"
    if [[ "$normalized_target" != /dev/* && -b "/dev/${normalized_target}" ]]; then
      normalized_target="/dev/${normalized_target}"
    fi
    TARGET_DISK="$normalized_target"
    [[ -b "$TARGET_DISK" ]] || {
      err "TARGET_DISK 不存在或不是块设备: $TARGET_DISK"
      exit 1
    }
    log "使用手动指定磁盘: $TARGET_DISK"
    return
  fi

  local best_disk=""
  local best_size=0
  while read -r path type rm size tran; do
    [[ "$type" == "disk" ]] || continue
    [[ "$rm" == "0" ]] || continue
    [[ "$tran" == "usb" ]] && continue
    [[ "$size" -ge "$MIN_DISK_BYTES" ]] || continue
    if (( size > best_size )); then
      best_size="$size"
      best_disk="$path"
    fi
  done < <(lsblk -dnbo PATH,TYPE,RM,SIZE,TRAN)

  [[ -n "$best_disk" ]] || {
    err "未找到可用磁盘（要求：非 USB、非 removable、>=20GB）。"
    lsblk -d -o NAME,SIZE,TYPE,RM,TRAN,MODEL
    exit 1
  }

  TARGET_DISK="$best_disk"
  log "自动选择最大非 USB 磁盘: $TARGET_DISK"
}

ensure_target_disk_not_mounted() {
  local dev mount_point
  local has_blocking_mount=0

  while IFS= read -r dev; do
    while IFS= read -r mount_point; do
      [[ -n "$mount_point" ]] || continue
      if [[ "$mount_point" != /mnt && "$mount_point" != /mnt/* ]]; then
        err "目标磁盘仍被挂载: ${dev} -> ${mount_point}"
        has_blocking_mount=1
      fi
    done < <(findmnt -rn -S "$dev" -o TARGET || true)
  done < <(lsblk -nrpo NAME "$TARGET_DISK")

  if [[ "$has_blocking_mount" == "1" ]]; then
    err "请先手动卸载目标盘所有非 /mnt 挂载点后再执行。"
    exit 1
  fi
}

confirm_wipe_countdown() {
  warn "即将清空磁盘: $TARGET_DISK"
  lsblk -f "$TARGET_DISK" || true
  warn "5 秒后开始自动清盘。按 Ctrl+C 取消。"
  sleep 5
}

prepare_resource_paths() {
  [[ -d "$ASSETS_CONFIG_DIR" ]] || {
    err "缺少资产目录: $ASSETS_CONFIG_DIR"
    exit 1
  }
  local dir
  for dir in niri noctalia ghostty; do
    [[ -d "${ASSETS_CONFIG_DIR}/${dir}" ]] || {
      err "缺少目录: ${ASSETS_CONFIG_DIR}/${dir}"
      exit 1
    }
  done
}

build_package_lists() {
  mkdir -p "$WORK_DIR"

  declare -A seen_repo=()
  declare -A seen_aur=()
  declare -A seen_flatpak=()
  local -a repo_pkgs=()
  local -a aur_pkgs=()
  local -a flatpak_pkgs=()

  add_repo() {
    local p="$1"
    [[ -n "$p" ]] || return 0
    [[ -n "${seen_repo[$p]:-}" ]] && return 0
    seen_repo["$p"]=1
    repo_pkgs+=("$p")
  }

  add_aur() {
    local p="$1"
    [[ -n "$p" ]] || return 0
    [[ -n "${seen_aur[$p]:-}" ]] && return 0
    seen_aur["$p"]=1
    aur_pkgs+=("$p")
  }

  add_flatpak() {
    local p="$1"
    [[ -n "$p" ]] || return 0
    [[ -n "${seen_flatpak[$p]:-}" ]] && return 0
    seen_flatpak["$p"]=1
    flatpak_pkgs+=("$p")
  }

  write_list_file() {
    local out_file="$1"
    shift
    : > "$out_file"
    if [[ "$#" -gt 0 ]]; then
      printf '%s\n' "$@" | sort -u > "$out_file"
    fi
  }

  add_detected_hardware_packages() {
    local mode="$GPU_PROFILE"
    local -a amd_repo=(vulkan-radeon lib32-vulkan-radeon libva-mesa-driver)
    local -a nvidia_repo=(nvidia nvidia-utils lib32-nvidia-utils nvidia-settings nvidia-prime)

    if grep -q 'GenuineIntel' /proc/cpuinfo 2>/dev/null; then
      add_repo intel-ucode
    elif grep -q 'AuthenticAMD' /proc/cpuinfo 2>/dev/null; then
      add_repo amd-ucode
    fi

    case "$mode" in
      1)
        log "GPU 方案 1：不补充 GPU 驱动包。"
        ;;
      2)
        for line in "${amd_repo[@]}"; do add_repo "$line"; done
        log "GPU 方案 2：已补充 AMDGPU 驱动包。"
        ;;
      3)
        for line in "${nvidia_repo[@]}"; do add_repo "$line"; done
        log "GPU 方案 3：已补充 NVIDIA 驱动包。"
        ;;
      4)
        for line in "${amd_repo[@]}"; do add_repo "$line"; done
        for line in "${nvidia_repo[@]}"; do add_repo "$line"; done
        log "GPU 方案 4：已补充 AMD 核显 + NVIDIA 驱动包。"
        ;;
    esac
  }

  # Core: niri + ghostty + runtime essentials.
  local -a core_repo=(
    base-devel git niri ghostty
    xdg-desktop-portal-gnome xdg-desktop-portal-gtk
    fuzzel libnotify mako polkit-gnome
    waybar wl-clipboard cliphist swayidle swaync swww
    grim slurp wf-recorder hyprpicker satty
    brightnessctl playerctl pipewire pipewire-pulse wireplumber pavucontrol
    bluez bluez-utils
    qt6ct qt5ct nautilus file-roller gnome-keyring
    gvfs gvfs-smb gvfs-mtp gvfs-gphoto2 udisks2
    thunar tumbler thunar-archive-plugin thunar-volman
    ffmpegthumbnailer poppler-glib webp-pixbuf-loader libgsf
    noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-jetbrains-mono-nerd
    fcitx5 fcitx5-configtool fcitx5-gtk fcitx5-qt fcitx5-chinese-addons
    zsh vim
  )

  local p
  for p in "${core_repo[@]}"; do
    add_repo "$p"
  done

  add_detected_hardware_packages

  if [[ -f "$ASSETS_SOFTWARE_LIST" ]]; then
    local raw_line line prefix pkg
    local line_no=0
    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
      line_no=$((line_no + 1))
      line="${raw_line%%#*}"
      line="$(trim_space "$line")"
      [[ -n "$line" ]] || continue

      if [[ "$line" == *:* ]]; then
        prefix="${line%%:*}"
        pkg="$(trim_space "${line#*:}")"
        if [[ -z "$pkg" ]]; then
          warn "软件清单第 ${line_no} 行格式错误（缺少包名），已跳过。"
          continue
        fi
        case "${prefix,,}" in
          repo) add_repo "$pkg" ;;
          aur) add_aur "$pkg" ;;
          flatpak) add_flatpak "$pkg" ;;
          *)
            warn "软件清单第 ${line_no} 行前缀无效（支持 repo/aur/flatpak），已跳过: $line"
            ;;
        esac
      else
        add_repo "$line"
      fi
    done < "$ASSETS_SOFTWARE_LIST"
  else
    warn "未找到统一软件清单: $ASSETS_SOFTWARE_LIST，仅安装内置核心软件。"
  fi

  write_list_file "$REPO_LIST_FILE" "${repo_pkgs[@]}"
  write_list_file "$AUR_LIST_FILE" "${aur_pkgs[@]}"
  write_list_file "$FLATPAK_LIST_FILE" "${flatpak_pkgs[@]}"
  log "Repo packages: $(wc -l < "$REPO_LIST_FILE" | tr -d ' ')"
  log "AUR  packages: $(wc -l < "$AUR_LIST_FILE" | tr -d ' ')"
  log "Flatpak apps : $(wc -l < "$FLATPAK_LIST_FILE" | tr -d ' ')"
}

wipe_and_partition_disk() {
  local disk="$TARGET_DISK"

  log "清理磁盘签名与分区表..."
  swapoff -a || true
  umount -R /mnt 2>/dev/null || true
  wipefs -af "$disk"
  sgdisk --zap-all "$disk"
  partprobe "$disk"

  log "创建分区表..."
  if [[ "$BOOT_MODE" == "uefi" ]]; then
    parted -s "$disk" mklabel gpt
    parted -s "$disk" mkpart ESP fat32 1MiB 513MiB
    parted -s "$disk" set 1 esp on
    parted -s "$disk" mkpart primary btrfs 513MiB 100%
  else
    parted -s "$disk" mklabel gpt
    parted -s "$disk" mkpart primary 1MiB 3MiB
    parted -s "$disk" set 1 bios_grub on
    parted -s "$disk" mkpart primary btrfs 3MiB 100%
  fi
  partprobe "$disk"
  udevadm settle
}

format_and_mount_btrfs() {
  local disk="$TARGET_DISK"
  local efi_part root_part
  efi_part="$(part_path "$disk" 1)"
  root_part="$(part_path "$disk" 2)"

  [[ -b "$root_part" ]] || {
    err "root 分区不存在: $root_part"
    exit 1
  }
  if [[ "$BOOT_MODE" == "uefi" ]]; then
    [[ -b "$efi_part" ]] || {
      err "EFI 分区不存在: $efi_part"
      exit 1
    }
  fi

  if [[ "$BOOT_MODE" == "uefi" ]]; then
    log "格式化 EFI 分区..."
    mkfs.fat -F32 "$efi_part"
  fi
  log "格式化 Btrfs 根分区..."
  mkfs.btrfs -f "$root_part"

  mount "$root_part" /mnt
  btrfs subvolume create /mnt/@
  btrfs subvolume create /mnt/@home
  btrfs subvolume create /mnt/@snapshots
  btrfs subvolume create /mnt/@var_log
  umount /mnt

  local opts="noatime,compress=zstd,ssd"
  mount -o "${opts},subvol=@" "$root_part" /mnt
  mkdir -p /mnt/{home,.snapshots,var/log,boot}
  mount -o "${opts},subvol=@home" "$root_part" /mnt/home
  mount -o "${opts},subvol=@snapshots" "$root_part" /mnt/.snapshots
  mount -o "${opts},subvol=@var_log" "$root_part" /mnt/var/log

  if [[ "$BOOT_MODE" == "uefi" ]]; then
    mount "$efi_part" /mnt/boot
  fi
}

install_base_system() {
  local -a base_pkgs=(
    base linux linux-firmware linux-headers
    btrfs-progs networkmanager sudo openssh
    grub os-prober
    efibootmgr dosfstools mtools
    vim git curl wget zsh xdg-user-dirs
  )
  log "Pacstrap 基础系统..."
  pacstrap -K /mnt "${base_pkgs[@]}"
  genfstab -U /mnt >> /mnt/etc/fstab
}

prepare_chroot_scripts() {
  mkdir -p /mnt/root/installer-meta
  cp "$REPO_LIST_FILE" /mnt/root/installer-meta/repo-packages.txt
  cp "$AUR_LIST_FILE" /mnt/root/installer-meta/aur-packages.txt
  cp "$FLATPAK_LIST_FILE" /mnt/root/installer-meta/flatpak-packages.txt

  cat >/mnt/root/installer-meta/chroot-setup.sh <<'CHROOT_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail

log()  { printf '[chroot] [+] %s\n' "$*"; }
warn() { printf '[chroot] [!] %s\n' "$*" >&2; }
err()  { printf '[chroot] [x] %s\n' "$*" >&2; }

require_var() {
  local k="$1"
  [[ -n "${!k:-}" ]] || { err "missing env: $k"; exit 1; }
}

require_var INSTALL_USER
require_var INSTALL_PASSWORD
require_var ROOT_PASSWORD
require_var HOST_NAME
require_var TIME_ZONE
require_var LOCALE_MAIN
require_var LOCALE_EXTRA
require_var KEYMAP
require_var BOOT_MODE
require_var TARGET_DISK

repo_file="/root/installer-meta/repo-packages.txt"
aur_file="/root/installer-meta/aur-packages.txt"
flatpak_file="/root/installer-meta/flatpak-packages.txt"

# Enable multilib for steam/wine/gaming stack.
if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
  log "启用 [multilib] 仓库..."
  sed -i "/\[multilib\]/,/Include/"'s/^#//' /etc/pacman.conf || true
fi
pacman -Syy --noconfirm

sed -i "s/^#\?\(${LOCALE_MAIN//\//\\/}\)/\1/" /etc/locale.gen || true
sed -i "s/^#\?\(${LOCALE_EXTRA//\//\\/}\)/\1/" /etc/locale.gen || true
locale-gen
echo "LANG=${LOCALE_MAIN}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
ln -sf "/usr/share/zoneinfo/${TIME_ZONE}" /etc/localtime
hwclock --systohc
echo "$HOST_NAME" > /etc/hostname
cat >/etc/hosts <<EOF
127.0.0.1 localhost
::1       localhost
127.0.1.1 ${HOST_NAME}.localdomain ${HOST_NAME}
EOF

echo "root:${ROOT_PASSWORD}" | chpasswd

if ! id -u "$INSTALL_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/zsh "$INSTALL_USER"
fi
usermod -aG wheel "$INSTALL_USER"
usermod -s /bin/zsh "$INSTALL_USER" || true
if [[ "${ADD_USER_TO_ROOT_GROUP:-0}" == "1" ]]; then
  warn "ADD_USER_TO_ROOT_GROUP=1：将用户加入 root 组（不推荐）。"
  usermod -aG root "$INSTALL_USER" || true
fi
echo "${INSTALL_USER}:${INSTALL_PASSWORD}" | chpasswd
install -d -m 0755 /etc/sudoers.d
cat >/etc/sudoers.d/10-wheel <<EOF
%wheel ALL=(ALL:ALL) ALL
EOF
chmod 0440 /etc/sudoers.d/10-wheel

log "安装 repo 软件..."
mapfile -t all_repo < <(grep -vE '^\s*$|^\s*#' "$repo_file" || true)
to_install=()
missing_repo=()
failed_repo=()
failed_aur=()
failed_flatpak=()
for pkg in "${all_repo[@]}"; do
  if pacman -Si "$pkg" >/dev/null 2>&1; then
    to_install+=("$pkg")
  else
    warn "repo 不存在，跳过: $pkg"
    missing_repo+=("$pkg")
  fi
done
if [[ ${#to_install[@]} -gt 0 ]]; then
  if ! pacman -S --noconfirm --needed "${to_install[@]}"; then
    warn "Repo 批量安装失败，回退到逐个安装..."
    for pkg in "${to_install[@]}"; do
      if ! pacman -S --noconfirm --needed "$pkg"; then
        failed_repo+=("$pkg")
      fi
    done
  fi
fi

for must_pkg in niri ghostty; do
  if ! pacman -Qi "$must_pkg" >/dev/null 2>&1; then
    err "关键包缺失: $must_pkg"
    exit 1
  fi
done

log "安装 paru..."
pacman -S --noconfirm --needed base-devel git
if ! command -v paru >/dev/null 2>&1; then
  if pacman -Si paru >/dev/null 2>&1; then
    pacman -S --noconfirm --needed paru
  else
    runuser -u "$INSTALL_USER" -- bash -lc '
      set -Eeuo pipefail
      rm -rf /tmp/paru
      git clone https://aur.archlinux.org/paru.git /tmp/paru
      cd /tmp/paru
      makepkg -si --noconfirm --needed
    '
  fi
fi
if ! command -v paru >/dev/null 2>&1; then
  err "paru 安装失败，无法继续 AUR 安装。"
  exit 1
fi

install_aur_nonfatal() {
  local pkg="$1"
  if pacman -Qi "$pkg" >/dev/null 2>&1; then
    return 0
  fi
  if runuser -u "$INSTALL_USER" -- paru -Si "$pkg" >/dev/null 2>&1; then
    if ! runuser -u "$INSTALL_USER" -- paru -S --noconfirm --needed --skipreview --removemake --cleanafter "$pkg"; then
      warn "AUR 安装失败: $pkg"
      return 1
    fi
  else
    warn "AUR 不存在，跳过: $pkg"
    return 1
  fi
}

log "安装 AUR 软件（非关键失败继续）..."
if [[ -f "$aur_file" ]]; then
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] || continue
    install_aur_nonfatal "$pkg" || failed_aur+=("$pkg")
  done < <(grep -vE '^\s*$|^\s*#' "$aur_file")
fi

log "安装 Flatpak 软件（非关键失败继续）..."
if [[ -s "$flatpak_file" ]]; then
  if ! command -v flatpak >/dev/null 2>&1; then
    if ! pacman -S --noconfirm --needed flatpak; then
      warn "flatpak 安装失败，跳过全部 flatpak 应用。"
      while IFS= read -r app; do
        [[ -n "$app" ]] || continue
        failed_flatpak+=("$app")
      done < <(grep -vE '^\s*$|^\s*#' "$flatpak_file")
    fi
  fi

  if command -v flatpak >/dev/null 2>&1; then
    flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || true
    while IFS= read -r app; do
      [[ -n "$app" ]] || continue
      if flatpak info "$app" >/dev/null 2>&1; then
        continue
      fi
      if ! flatpak install -y flathub "$app"; then
        warn "Flatpak 安装失败: $app"
        failed_flatpak+=("$app")
      fi
    done < <(grep -vE '^\s*$|^\s*#' "$flatpak_file")
  fi
fi

install_noctalia_required() {
  log "安装 Noctalia（关键）：paru -S noctalia-shell"
  if pacman -Qi noctalia-shell >/dev/null 2>&1; then
    return 0
  fi
  if ! runuser -u "$INSTALL_USER" -- paru -Si noctalia-shell >/dev/null 2>&1; then
    err "AUR 中未找到 noctalia-shell"
    exit 1
  fi
  if ! runuser -u "$INSTALL_USER" -- paru -S --noconfirm --needed --skipreview --removemake --cleanafter noctalia-shell; then
    err "安装 noctalia-shell 失败"
    exit 1
  fi
}

install_noctalia_required

systemctl enable NetworkManager
systemctl enable sshd
systemctl enable fstrim.timer
if pacman -Qi docker >/dev/null 2>&1; then
  systemctl enable docker || true
  if getent group docker >/dev/null 2>&1; then
    usermod -aG docker "$INSTALL_USER" || true
  fi
fi
if pacman -Qi bluez >/dev/null 2>&1; then
  systemctl enable bluetooth || true
fi

log "安装引导程序..."
if [[ "$BOOT_MODE" == "uefi" ]]; then
  grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Arch --recheck
else
  grub-install --target=i386-pc --recheck "$TARGET_DISK"
fi
grub-mkconfig -o /boot/grub/grub.cfg

if [[ "${AUTO_LOGIN_TTY1:-1}" == "1" ]]; then
  mkdir -p /etc/systemd/system/getty@tty1.service.d
  cat >/etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --noreset --noclear --autologin ${INSTALL_USER} - \$TERM
EOF
else
  rm -f /etc/systemd/system/getty@tty1.service.d/autologin.conf
fi

home_dir="/home/${INSTALL_USER}"
svc_dir="${home_dir}/.config/systemd/user"
mkdir -p "${svc_dir}/default.target.wants"
cat >"${svc_dir}/niri-autostart.service" <<EOF
[Unit]
Description=Niri Session Autostart
After=graphical-session-pre.target

[Service]
ExecStart=/usr/bin/niri-session
Restart=on-failure

[Install]
WantedBy=default.target
EOF
ln -sf ../niri-autostart.service "${svc_dir}/default.target.wants/niri-autostart.service"
chown -R "${INSTALL_USER}:${INSTALL_USER}" "${svc_dir}"

runuser -u "$INSTALL_USER" -- xdg-user-dirs-update || true

  if [[ ${#missing_repo[@]} -gt 0 || ${#failed_repo[@]} -gt 0 || ${#failed_aur[@]} -gt 0 || ${#failed_flatpak[@]} -gt 0 ]]; then
  report_dir="/home/${INSTALL_USER}/Documents"
  report_file="${report_dir}/arch-niri-missing-packages.txt"
  mkdir -p "$report_dir"
  {
    echo "Arch Niri Installer - Missing/Failed Packages"
    echo "Generated: $(date '+%F %T')"
    echo ""
    echo "[Repo Not Found]"
    printf '%s\n' "${missing_repo[@]:-}"
    echo ""
    echo "[Repo Install Failed]"
    printf '%s\n' "${failed_repo[@]:-}"
    echo ""
    echo "[AUR Install Failed]"
    printf '%s\n' "${failed_aur[@]:-}"
    echo ""
    echo "[Flatpak Install Failed]"
    printf '%s\n' "${failed_flatpak[@]:-}"
  } > "$report_file"
  chown -R "${INSTALL_USER}:${INSTALL_USER}" "$report_dir"
  warn "部分包未安装成功，报告已写入: $report_file"
fi

log "chroot 阶段完成。"
CHROOT_SCRIPT

  chmod +x /mnt/root/installer-meta/chroot-setup.sh

  arch-chroot /mnt /usr/bin/env \
    INSTALL_USER="$INSTALL_USER" \
    INSTALL_PASSWORD="$INSTALL_PASSWORD" \
    ROOT_PASSWORD="$ROOT_PASSWORD" \
    HOST_NAME="$HOST_NAME" \
    TIME_ZONE="$TIME_ZONE" \
    LOCALE_MAIN="$LOCALE_MAIN" \
    LOCALE_EXTRA="$LOCALE_EXTRA" \
    KEYMAP="$KEYMAP" \
    BOOT_MODE="$BOOT_MODE" \
    TARGET_DISK="$TARGET_DISK" \
    ADD_USER_TO_ROOT_GROUP="$ADD_USER_TO_ROOT_GROUP" \
    AUTO_LOGIN_TTY1="$AUTO_LOGIN_TTY1" \
    /bin/bash /root/installer-meta/chroot-setup.sh
}

deploy_dotfiles() {
  local home_dir="/mnt/home/${INSTALL_USER}"
  mkdir -p "$home_dir/.config" "$home_dir/.cache/noctalia"

  local src_niri="${ASSETS_CONFIG_DIR}/niri"
  local src_noctalia="${ASSETS_CONFIG_DIR}/noctalia"
  local src_ghostty="${ASSETS_CONFIG_DIR}/ghostty"
  local src_fcitx5="${ASSETS_CONFIG_DIR}/fcitx5"
  local src_shell="${ASSETS_CONFIG_DIR}/shell"
  local src_wallpapers="${ASSETS_CONFIG_DIR}/wallpapers"

  [[ -d "$src_niri" ]] && cp -a "$src_niri" "$home_dir/.config/"
  [[ -d "$src_noctalia" ]] && cp -a "$src_noctalia" "$home_dir/.config/"
  [[ -d "$src_ghostty" ]] && cp -a "$src_ghostty" "$home_dir/.config/"
  if [[ -d "$src_fcitx5" ]]; then
    mkdir -p "$home_dir/.config/fcitx5"
    cp -a "${src_fcitx5}/." "$home_dir/.config/fcitx5/"
  fi
  [[ -f "${src_shell}/zshrc" ]] && cp -a "${src_shell}/zshrc" "$home_dir/.zshrc"
  [[ -f "${src_shell}/bashrc" ]] && cp -a "${src_shell}/bashrc" "$home_dir/.bashrc"
  [[ -f "${src_shell}/vimrc" ]] && cp -a "${src_shell}/vimrc" "$home_dir/.vimrc"

  # Common language workspace/cache directories.
  mkdir -p \
    "$home_dir/Code/c-cpp" \
    "$home_dir/Code/go" \
    "$home_dir/Code/nodejs" \
    "$home_dir/Code/python" \
    "$home_dir/Code/rust" \
    "$home_dir/Code/zig" \
    "$home_dir/.local/bin" \
    "$home_dir/.local/share/go/bin" \
    "$home_dir/.local/share/go/pkg" \
    "$home_dir/.cache/go-build" \
    "$home_dir/.cargo/bin" \
    "$home_dir/.rustup" \
    "$home_dir/.local/share/pnpm" \
    "$home_dir/.npm-global/bin" \
    "$home_dir/.bun"

  if [[ -d "$src_wallpapers" ]]; then
    mkdir -p "$home_dir/.config/noctalia/wallpapers" "$home_dir/Pictures/Wallpapers"
    cp -a "${src_wallpapers}/." "$home_dir/.config/noctalia/wallpapers/"
    cp -a "${src_wallpapers}/." "$home_dir/Pictures/Wallpapers/"
  fi

  cat >"$home_dir/.cache/noctalia/wallpapers.json" <<EOF
{
  "defaultWallpaper": "/home/${INSTALL_USER}/.config/noctalia/wallpapers/1.png",
  "wallpapers": {}
}
EOF

  chown -R "${INSTALL_USER}:${INSTALL_USER}" "$home_dir"
}

final_summary() {
  echo
  log "安装完成。"
  echo "----------------------------------------"
  echo "Disk      : $TARGET_DISK"
  echo "Boot mode : $BOOT_MODE"
  echo "Hostname  : $HOST_NAME"
  echo "User      : $INSTALL_USER"
  echo "Pass(user): [hidden]"
  echo "Pass(root): [hidden]"
  echo "----------------------------------------"
  warn "首次开机后请立即修改默认密码。"
  if [[ "$ROOT_PASSWORD" == "$INSTALL_PASSWORD" ]]; then
    warn "当前 root 与普通用户密码相同，建议分别设置。"
  fi
}

main() {
  require_root
  ensure_iso_toolchain
  collect_identity_inputs
  validate_inputs
  if ! is_arch_iso; then
    if [[ "$ALLOW_NON_ISO" == "1" ]]; then
      warn "未检测到 Arch ISO 环境，但 ALLOW_NON_ISO=1，继续执行。"
    else
      err "未检测到 Arch ISO 环境。若确认要继续，请设置 ALLOW_NON_ISO=1。"
      exit 1
    fi
  fi

  resolve_boot_mode
  resolve_gpu_profile
  prepare_resource_paths
  build_package_lists
  select_target_disk
  ensure_target_disk_not_mounted
  confirm_wipe_countdown
  wipe_and_partition_disk
  format_and_mount_btrfs
  install_base_system
  prepare_chroot_scripts
  deploy_dotfiles
  final_summary

  if [[ "$AUTO_REBOOT" == "1" ]]; then
    log "5 秒后自动重启..."
    sleep 5
    reboot
  else
    log "AUTO_REBOOT=0，未重启。你可手动执行: reboot"
  fi
}

main "$@"
