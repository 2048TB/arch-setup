#!/usr/bin/env bash
set -Eeuo pipefail

# Arch post-install script (no disk wipe/partition). Run in installed system as root.

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ASSETS_DIR="${SCRIPT_DIR}"
readonly ASSETS_CONFIG_DIR="${ASSETS_DIR}/configs"
readonly ASSETS_SOFTWARE_LIST="${ASSETS_DIR}/software-packages.txt"

# -----------------------
# User-tunable variables
# -----------------------
INSTALL_USER="${INSTALL_USER:-${SUDO_USER:-}}"
HOST_NAME="${HOST_NAME:-}"
LOCALE_MAIN="${LOCALE_MAIN:-}"
LOCALE_EXTRA="${LOCALE_EXTRA:-}"
TIME_ZONE="${TIME_ZONE:-}"
KEYMAP="${KEYMAP:-}"
GPU_PROFILE="${GPU_PROFILE:-auto}" # auto|1|2|3|4

readonly WORK_DIR="/tmp/arch-niri-post-install"
readonly REPO_LIST_FILE="${WORK_DIR}/repo-packages.txt"
readonly AUR_LIST_FILE="${WORK_DIR}/aur-packages.txt"
readonly FLATPAK_LIST_FILE="${WORK_DIR}/flatpak-packages.txt"
readonly DUP_LIST_FILE="${WORK_DIR}/duplicate-packages.txt"

log()  { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
err()  { printf '[x] %s\n' "$*" >&2; }
is_tty() { [[ -t 0 && -t 1 ]]; }

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || {
    err "缺少命令: $cmd"
    exit 1
  }
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    err "必须以 root 运行（例如 sudo）。"
    exit 1
  fi
}

is_valid_username() {
  local username="$1"
  [[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]] && [[ "$username" != "root" ]]
}

trim_space() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

prompt_install_user_if_empty() {
  if [[ -n "$INSTALL_USER" ]]; then
    return 0
  fi
  if ! is_tty; then
    err "INSTALL_USER 为空且非交互环境，无法提示输入。请通过环境变量指定。"
    exit 1
  fi
  local input
  while true; do
    read -r -p "请输入安装用户 (INSTALL_USER): " input
    input="$(trim_space "$input")"
    if is_valid_username "$input"; then
      INSTALL_USER="$input"
      break
    fi
    warn "用户名无效：仅支持小写字母/数字/_/-，且不能以数字开头。"
  done
}

ensure_pciutils_for_gpu_detection() {
  if [[ "$GPU_PROFILE" != "auto" ]]; then
    return 0
  fi
  if command -v lspci >/dev/null 2>&1; then
    return 0
  fi
  warn "未找到 lspci，尝试安装 pciutils 以进行 GPU 检测..."
  if pacman -S --noconfirm --needed pciutils >/dev/null 2>&1; then
    log "已安装 pciutils。"
  else
    warn "pciutils 安装失败，GPU_PROFILE=auto 将回退为 1(无 GPU)。"
  fi
}

validate_inputs() {
  is_valid_username "$INSTALL_USER" || {
    err "INSTALL_USER 非法：仅支持小写字母/数字/_/-，且不能以数字开头。"
    exit 1
  }
  id -u "$INSTALL_USER" >/dev/null 2>&1 || {
    err "INSTALL_USER 不存在，请先创建用户: $INSTALL_USER"
    exit 1
  }
  [[ "$GPU_PROFILE" =~ ^(auto|1|2|3|4)$ ]] || {
    err "GPU_PROFILE 仅支持 auto|1|2|3|4"
    exit 1
  }
}

resolve_gpu_profile() {
  local has_amd=0 has_nvidia=0 line

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

prepare_resource_paths() {
  [[ -d "$ASSETS_CONFIG_DIR" ]] || {
    err "缺少资产目录: $ASSETS_CONFIG_DIR"
    exit 1
  }
}

build_package_lists() {
  mkdir -p "$WORK_DIR"

  declare -A seen_repo=()
  declare -A seen_aur=()
  declare -A seen_flatpak=()
  declare -A file_seen_repo=()
  declare -A file_seen_aur=()
  declare -A file_seen_flatpak=()
  local -a repo_pkgs=()
  local -a aur_pkgs=()
  local -a flatpak_pkgs=()
  local -a dupe_same_source=()
  local -a dupe_cross_source=()
  declare -A dupe_same_seen=()
  declare -A dupe_cross_seen=()

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

  add_dupe_same() {
    local msg="$1"
    [[ -n "${dupe_same_seen[$msg]:-}" ]] && return 0
    dupe_same_seen["$msg"]=1
    dupe_same_source+=("$msg")
  }

  add_dupe_cross() {
    local msg="$1"
    [[ -n "${dupe_cross_seen[$msg]:-}" ]] && return 0
    dupe_cross_seen["$msg"]=1
    dupe_cross_source+=("$msg")
  }

  write_list_file() {
    local out_file="$1"
    shift
    : > "$out_file"
    if [[ "$#" -gt 0 ]]; then
      printf '%s\n' "$@" | sort -u > "$out_file"
    fi
  }

  write_duplicate_report() {
    : > "$DUP_LIST_FILE"
    if [[ ${#dupe_same_source[@]} -eq 0 && ${#dupe_cross_source[@]} -eq 0 ]]; then
      echo "No duplicates detected." > "$DUP_LIST_FILE"
      return 0
    fi
    {
      echo "[Duplicate Entries In software-packages.txt]"
      if [[ ${#dupe_same_source[@]} -gt 0 ]]; then
        printf '%s\n' "${dupe_same_source[@]}"
      else
        echo "(none)"
      fi
      echo
      echo "[Cross-Source Duplicates (repo/aur/flatpak)]"
      if [[ ${#dupe_cross_source[@]} -gt 0 ]]; then
        printf '%s\n' "${dupe_cross_source[@]}"
        echo "Resolution: repo > aur > flatpak (lower priority will be dropped)."
      else
        echo "(none)"
      fi
    } > "$DUP_LIST_FILE"
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
        local p
        for p in "${amd_repo[@]}"; do add_repo "$p"; done
        log "GPU 方案 2：已补充 AMDGPU 驱动包。"
        ;;
      3)
        local p
        for p in "${nvidia_repo[@]}"; do add_repo "$p"; done
        log "GPU 方案 3：已补充 NVIDIA 驱动包。"
        ;;
      4)
        local p
        for p in "${amd_repo[@]}"; do add_repo "$p"; done
        for p in "${nvidia_repo[@]}"; do add_repo "$p"; done
        log "GPU 方案 4：已补充 AMD 核显 + NVIDIA 驱动包。"
        ;;
    esac
  }

  local -a core_repo=(
    base-devel git niri ghostty
    pciutils
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
      raw_line="${raw_line%$'\r'}"
      line="${raw_line%%#*}"
      line="$(trim_space "$line")"
      [[ -n "$line" ]] || continue

      if [[ "$line" =~ ^([[:alpha:]]+)[[:space:]]*:[[:space:]]*(.+)$ ]]; then
        prefix="${BASH_REMATCH[1]}"
        pkg="$(trim_space "${BASH_REMATCH[2]}")"
        if [[ -z "$pkg" ]]; then
          warn "软件清单第 ${line_no} 行格式错误（缺少包名），已跳过。"
          continue
        fi
        case "${prefix,,}" in
          repo)
            if [[ -n "${file_seen_repo[$pkg]:-}" ]]; then
              add_dupe_same "repo:${pkg} (lines ${file_seen_repo[$pkg]},${line_no})"
            else
              file_seen_repo["$pkg"]="$line_no"
            fi
            if [[ -n "${file_seen_aur[$pkg]:-}" || -n "${file_seen_flatpak[$pkg]:-}" ]]; then
              add_dupe_cross "${pkg} => repo,aur/flatpak (lines ${line_no})"
            fi
            add_repo "$pkg"
            ;;
          aur)
            if [[ -n "${file_seen_aur[$pkg]:-}" ]]; then
              add_dupe_same "aur:${pkg} (lines ${file_seen_aur[$pkg]},${line_no})"
            else
              file_seen_aur["$pkg"]="$line_no"
            fi
            if [[ -n "${file_seen_repo[$pkg]:-}" || -n "${file_seen_flatpak[$pkg]:-}" ]]; then
              add_dupe_cross "${pkg} => aur,repo/flatpak (lines ${line_no})"
            fi
            add_aur "$pkg"
            ;;
          flatpak)
            if [[ -n "${file_seen_flatpak[$pkg]:-}" ]]; then
              add_dupe_same "flatpak:${pkg} (lines ${file_seen_flatpak[$pkg]},${line_no})"
            else
              file_seen_flatpak["$pkg"]="$line_no"
            fi
            if [[ -n "${file_seen_repo[$pkg]:-}" || -n "${file_seen_aur[$pkg]:-}" ]]; then
              add_dupe_cross "${pkg} => flatpak,repo/aur (lines ${line_no})"
            fi
            add_flatpak "$pkg"
            ;;
          *)
            warn "软件清单第 ${line_no} 行前缀无效（支持 repo/aur/flatpak），已跳过: $line"
            ;;
        esac
      else
        if [[ -n "${file_seen_repo[$line]:-}" ]]; then
          add_dupe_same "repo:${line} (lines ${file_seen_repo[$line]},${line_no})"
        else
          file_seen_repo["$line"]="$line_no"
        fi
        if [[ -n "${file_seen_aur[$line]:-}" || -n "${file_seen_flatpak[$line]:-}" ]]; then
          add_dupe_cross "${line} => repo,aur/flatpak (lines ${line_no})"
        fi
        add_repo "$line"
      fi
    done < "$ASSETS_SOFTWARE_LIST"
  else
    warn "未找到统一软件清单: $ASSETS_SOFTWARE_LIST，仅安装内置核心软件。"
  fi

  for p in "${!seen_repo[@]}"; do
    if [[ -n "${seen_aur[$p]:-}" || -n "${seen_flatpak[$p]:-}" ]]; then
      add_dupe_cross "${p} => repo,aur/flatpak (resolved to repo)"
    fi
  done
  for p in "${!seen_aur[@]}"; do
    if [[ -n "${seen_flatpak[$p]:-}" && -z "${seen_repo[$p]:-}" ]]; then
      add_dupe_cross "${p} => aur,flatpak (resolved to aur)"
    fi
  done

  local -a final_repo=("${repo_pkgs[@]}")
  local -a final_aur=()
  local -a final_flatpak=()
  for p in "${aur_pkgs[@]}"; do
    [[ -n "${seen_repo[$p]:-}" ]] && continue
    final_aur+=("$p")
  done
  for p in "${flatpak_pkgs[@]}"; do
    [[ -n "${seen_repo[$p]:-}" || -n "${seen_aur[$p]:-}" ]] && continue
    final_flatpak+=("$p")
  done

  write_list_file "$REPO_LIST_FILE" "${final_repo[@]}"
  write_list_file "$AUR_LIST_FILE" "${final_aur[@]}"
  write_list_file "$FLATPAK_LIST_FILE" "${final_flatpak[@]}"
  write_duplicate_report
  log "Repo packages: $(wc -l < "$REPO_LIST_FILE" | tr -d ' ')"
  log "AUR  packages: $(wc -l < "$AUR_LIST_FILE" | tr -d ' ')"
  log "Flatpak apps : $(wc -l < "$FLATPAK_LIST_FILE" | tr -d ' ')"
}

install_repo_packages() {
  log "安装 repo 软件..."
  mapfile -t all_repo < <(grep -vE '^\s*$|^\s*#' "$REPO_LIST_FILE" || true)
  local -a to_install=()
  local -a missing_repo=()
  local -a failed_repo=()

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

  if [[ ${#missing_repo[@]} -gt 0 || ${#failed_repo[@]} -gt 0 ]]; then
    local report_dir="/home/${INSTALL_USER}/Documents"
    local report_file="${report_dir}/arch-niri-missing-packages.txt"
    mkdir -p "$report_dir"
    {
      echo "Arch Niri Post Install - Missing/Failed Packages"
      echo "Generated: $(date '+%F %T')"
      echo ""
      echo "[Repo Not Found]"
      printf '%s\n' "${missing_repo[@]:-}"
      echo ""
      echo "[Repo Install Failed]"
      printf '%s\n' "${failed_repo[@]:-}"
      echo ""
      echo "[Duplicate Packages]"
      if [[ -s "$DUP_LIST_FILE" ]]; then
        cat "$DUP_LIST_FILE"
      else
        echo "(none)"
      fi
    } > "$report_file"
    chown -R "${INSTALL_USER}:${INSTALL_USER}" "$report_dir"
    warn "部分包未安装成功，报告已写入: $report_file"
  fi
}

install_aur_packages() {
  if [[ ! -s "$AUR_LIST_FILE" ]]; then
    log "AUR 清单为空，跳过 AUR 安装。"
    return 0
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    warn "未安装 sudo，无法以普通用户运行 AUR 安装。已跳过 AUR。"
    return 0
  fi
  if ! runuser -u "$INSTALL_USER" -- sudo -n true >/dev/null 2>&1; then
    warn "INSTALL_USER 无免密 sudo 权限，AUR 安装可能失败。已跳过 AUR。"
    return 0
  fi

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
        makepkg -s --noconfirm --needed
      '
      local -a paru_pkgs=()
      while IFS= read -r pkg; do
        [[ -n "$pkg" ]] && paru_pkgs+=("$pkg")
      done < <(ls -1 /tmp/paru/*.pkg.tar* 2>/dev/null || true)
      if [[ ${#paru_pkgs[@]} -gt 0 ]]; then
        pacman -U --noconfirm --needed "${paru_pkgs[@]}"
      fi
    fi
  fi
  if ! command -v paru >/dev/null 2>&1; then
    warn "paru 安装失败，已跳过全部 AUR 软件。"
    return 0
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
  if [[ -f "$AUR_LIST_FILE" ]]; then
    while IFS= read -r pkg; do
      [[ -n "$pkg" ]] || continue
      install_aur_nonfatal "$pkg" || true
    done < <(grep -vE '^\s*$|^\s*#' "$AUR_LIST_FILE")
  fi
}

install_flatpak_packages() {
  log "安装 Flatpak 软件（非关键失败继续）..."
  if [[ -s "$FLATPAK_LIST_FILE" ]]; then
    if ! command -v flatpak >/dev/null 2>&1; then
      if ! pacman -S --noconfirm --needed flatpak; then
        warn "flatpak 安装失败，跳过全部 flatpak 应用。"
        return 0
      fi
    fi

    flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || true
    while IFS= read -r app; do
      [[ -n "$app" ]] || continue
      if flatpak info "$app" >/dev/null 2>&1; then
        continue
      fi
      if ! flatpak install -y flathub "$app"; then
        warn "Flatpak 安装失败: $app"
      fi
    done < <(grep -vE '^\s*$|^\s*#' "$FLATPAK_LIST_FILE")
  fi
}

deploy_dotfiles() {
  local home_dir
  home_dir="/home/${INSTALL_USER}"

  [[ -d "$home_dir" ]] || {
    err "用户家目录不存在: $home_dir"
    exit 1
  }

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

  cat >"$home_dir/.cache/noctalia/wallpapers.json" <<EOF_JSON
{
  "defaultWallpaper": "/home/${INSTALL_USER}/.config/noctalia/wallpapers/1.png",
  "wallpapers": {}
}
EOF_JSON

  chown -R "${INSTALL_USER}:${INSTALL_USER}" "$home_dir"
}

final_summary() {
  echo
  log "后安装完成。"
  echo "----------------------------------------"
  echo "User      : $INSTALL_USER"
  echo "GPU mode  : $GPU_PROFILE"
  echo "----------------------------------------"
  warn "如需系统级设置（hostname/locale/timezone），请自行配置或扩展脚本。"
}

main() {
  require_root
  require_cmd pacman
  require_cmd runuser
  prepare_resource_paths
  prompt_install_user_if_empty
  validate_inputs
  ensure_pciutils_for_gpu_detection
  resolve_gpu_profile
  build_package_lists
  install_repo_packages
  install_aur_packages
  install_flatpak_packages
  deploy_dotfiles
  final_summary
}

main "$@"
