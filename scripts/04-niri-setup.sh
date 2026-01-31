#!/bin/bash

# ==============================================================================
# 04-niri-setup.sh - Niri Desktop (Restored FZF & Robust AUR)
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/00-utils.sh"

DEBUG=${DEBUG:-0}
CN_MIRROR=${CN_MIRROR:-0}
UNDO_SCRIPT="$SCRIPT_DIR/niri-undochange.sh"

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
        bash "$UNDO_SCRIPT"
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
  info_kv "Conflict" "${H_RED}$DM_FOUND${NC}"
  SKIP_AUTOLOGIN=true
else
  read -t "$TTY_AUTOLOGIN_TIMEOUT" -p "$(echo -e "   ${H_CYAN}Enable TTY auto-login? [Y/n] (Default Y): ${NC}")" choice || true
  [[ "${choice:-Y}" =~ ^[Yy]$ ]] && SKIP_AUTOLOGIN=false || SKIP_AUTOLOGIN=true
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
echo "$TARGET_USER ALL=(ALL) NOPASSWD: ALL" >"$SUDO_TEMP_FILE"
chmod 440 "$SUDO_TEMP_FILE"
log "Temp sudo file created..."
# ==============================================================================
# STEP 5: Dependencies (RESTORED FZF)
# ==============================================================================
section "Step 4/9" "Dependencies"
LIST_FILE="$PARENT_DIR/niri-applist.txt"

# Ensure tools
command -v fzf &>/dev/null || pacman -S --noconfirm fzf >/dev/null 2>&1

if [ -f "$LIST_FILE" ]; then
  mapfile -t DEFAULT_LIST < <(grep -vE "^\s*#|^\s*$" "$LIST_FILE" | sed 's/#.*//; s/AUR://g' | xargs -n1)

  if [ ${#DEFAULT_LIST[@]} -eq 0 ]; then
    warn "App list is empty. Skipping."
    PACKAGE_ARRAY=()
  else
    echo -e "\n   ${H_YELLOW}>>> Default installation in ${INSTALLATION_TIMEOUT}s. Press ANY KEY to customize...${NC}"

    if read -t "$INSTALLATION_TIMEOUT" -n 1 -s -r; then
      # --- [RESTORED] Original FZF Selection Logic ---
      clear
      log "Loading package list..."

      SELECTED_LINES=$(fzf_select_apps "$LIST_FILE" "[TAB] TOGGLE | [ENTER] INSTALL | [CTRL-D] DE-ALL | [CTRL-A] SE-ALL")

      clear

      if [ -z "$SELECTED_LINES" ]; then
        warn "User cancelled selection. Installing NOTHING."
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
      log "Auto-confirming ALL packages."
      PACKAGE_ARRAY=("${DEFAULT_LIST[@]}")
    fi
  fi

  # --- Installation Loop ---
  if [ ${#PACKAGE_ARRAY[@]} -gt 0 ]; then
    BATCH_LIST=()
    AUR_LIST=()
    info_kv "Target" "${#PACKAGE_ARRAY[@]} packages scheduled."

    for pkg in "${PACKAGE_ARRAY[@]}"; do
      [ "$pkg" == "imagemagic" ] && pkg="imagemagick"
      [[ "$pkg" == "AUR:"* ]] && AUR_LIST+=("${pkg#AUR:}") || BATCH_LIST+=("$pkg")
    done

    # 1. Batch Install Repo Packages
    if [ ${#BATCH_LIST[@]} -gt 0 ]; then
      log "Phase 1: Batch Installing Repo Packages..."
      as_user yay -Syu --noconfirm --needed --answerdiff=None --answerclean=None "${BATCH_LIST[@]}" || true  # Batch mode, keep direct call

      # Verify Each
      for pkg in "${BATCH_LIST[@]}"; do
        ensure_package_installed "$pkg" "Repo"
      done
    fi

    # 2. Sequential AUR Install
    if [ ${#AUR_LIST[@]} -gt 0 ]; then
      log "Phase 2: Installing AUR Packages (Sequential)..."
      for pkg in "${AUR_LIST[@]}"; do
        ensure_package_installed "$pkg" "AUR"
      done
    fi

    # Waybar fallback
    if ! command -v waybar &>/dev/null; then
      warn "Waybar missing. Installing stock..."
      exe pacman -S --noconfirm --needed waybar
    fi
  else
    warn "No packages selected."
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

  find "$src_dir" -mindepth 1 -maxdepth 1 -not -path '*/.git*' | while read -r src_path; do
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
  done
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
as_user gsettings set org.gnome.desktop.wm.preferences button-layout ":close"
# ==============================================================================
# STEP 8: Hardware Tools
# ==============================================================================
section "Step 7/9" "Hardware"
if pacman -Q ddcutil &>/dev/null; then
  gpasswd -a "$TARGET_USER" i2c
  lsmod | grep -q i2c_dev || echo "i2c-dev" >/etc/modules-load.d/i2c-dev.conf
fi
if pacman -Q swayosd &>/dev/null; then
  systemctl enable --now swayosd-libinput-backend.service >/dev/null 2>&1
fi
success "Tools configured."

# ==============================================================================
# STEP 9: Cleanup & Auto-Login
# ==============================================================================
section "Final" "Cleanup & Boot"
rm -f "$SUDO_TEMP_FILE"

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
  cat <<EOT >"$SVC_FILE"
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