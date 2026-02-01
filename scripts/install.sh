#!/bin/bash

# ==============================================================================
# Shorin Arch Setup - Main Installer (v1.1))
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
SCRIPTS_DIR="$REPO_DIR/scripts"
STATE_FILE="$REPO_DIR/.install_progress"

# --- Source Visual Engine ---
if [ -f "$SCRIPTS_DIR/00-utils.sh" ]; then
    source "$SCRIPTS_DIR/00-utils.sh"
else
    echo "Error: 00-utils.sh not found."
    exit 1
fi
# --- Config & Strict Mode ---
CONFIG_FILE="${SHORIN_CONFIG:-$REPO_DIR/config.conf}"
load_config
enable_strict_mode

# --- Constants ---
readonly REFLECTOR_TIMEOUT=60
readonly REBOOT_COUNTDOWN_SECONDS=10
readonly REFLECTOR_AGE_HOURS=24
readonly REFLECTOR_TOP_MIRRORS=10
readonly EXIT_CODE_INTERRUPTED=130
readonly EXIT_CODE_TIMEOUT=1

# --- Global Cleanup on Exit ---
cleanup_on_exit() {
    tput cnorm
    rm -f "/tmp/shorin_install_user"
}
trap cleanup_on_exit EXIT

# --- Environment ---
export DEBUG=${DEBUG:-0}
export CN_MIRROR=${CN_MIRROR:-0}

check_root
chmod +x "$SCRIPTS_DIR"/*.sh
if [ ! -f "$SCRIPTS_DIR/modules.sh" ]; then
    error "modules.sh not found in $SCRIPTS_DIR"
    exit 1
fi

# --- ASCII Banners ---
banner1() {
cat << "EOF"
   _____ __  ______  ____  _____   __
  / ___// / / / __ \/ __ \/  _/ | / /
  \__ \/ /_/ / / / / /_/ // //  |/ / 
 ___/ / __  / /_/ / _, _// // /|  /  
/____/_/ /_/\____/_/ |_/___/_/ |_/   
EOF
}

banner2() {
cat << "EOF"
  ██████  ██   ██  ██████  ███████ ██ ███    ██ 
  ██      ██   ██ ██    ██ ██   ██    ██ ██  ██ 
  ███████ ███████ ██    ██ ██████  ██ ██ ██  ██ 
       ██ ██   ██ ██    ██ ██   ██ ██ ██  ██ ██ 
  ██████  ██   ██  ██████  ██   ██ ██ ██   ████ 
EOF
}
banner3() {
cat << "EOF"
   ______ __ __   ___   ____   ____  _   _ 
  / ___/|  |  | /   \ |    \ |    || \ | |
 (   \_ |  |  ||     ||  D  ) |  | |  \| |
  \__  ||  _  ||  O  ||    /  |  | |     |
  /  \ ||  |  ||     ||    \  |  | | |\  |
  \    ||  |  ||     ||  .  \ |  | | | \ |
   \___||__|__| \___/ |__|\_||____||_| \_|
EOF
}

show_banner() {
    clear
    local r=$(( $RANDOM % 3 ))
    echo -e "${H_CYAN}"
    case $r in
        0) banner1 ;;
        1) banner2 ;;
        2) banner3 ;;
    esac
    echo -e "${NC}"
    echo -e "${DIM}   :: Arch Linux Automation Protocol :: v2.1 ::${NC}"
    echo ""
}

# --- Fixed Desktop Environment ---
export DESKTOP_ENV="niri"
log "Desktop Environment: Niri (Fixed)"
sys_dashboard() {
    echo -e "${H_BLUE}╔════ SYSTEM DIAGNOSTICS ══════════════════════════════╗${NC}"
    echo -e "${H_BLUE}║${NC} ${BOLD}Kernel${NC}   : $(uname -r)"
    echo -e "${H_BLUE}║${NC} ${BOLD}User${NC}     : $(whoami)"
    echo -e "${H_BLUE}║${NC} ${BOLD}Desktop${NC}  : ${H_MAGENTA}${DESKTOP_ENV^^}${NC}"
    
    if [ "$CN_MIRROR" == "1" ]; then
        echo -e "${H_BLUE}║${NC} ${BOLD}Network${NC}  : ${H_YELLOW}CN Optimized (Manual)${NC}"
    elif [ "$DEBUG" == "1" ]; then
        echo -e "${H_BLUE}║${NC} ${BOLD}Network${NC}  : ${H_RED}DEBUG FORCE (CN Mode)${NC}"
    else
        echo -e "${H_BLUE}║${NC} ${BOLD}Network${NC}  : Global Default"
    fi
    
    if [ -f "$STATE_FILE" ]; then
        done_count=$(wc -l < "$STATE_FILE")
        echo -e "${H_BLUE}║${NC} ${BOLD}Progress${NC} : Resuming ($done_count steps recorded)"
    fi
    echo -e "${H_BLUE}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# --- Main Execution ---

if [ "${1:-}" = "rollback" ]; then
    shift || true
    MODULE="rollback"
    bash "$SCRIPTS_DIR/modules.sh" "$MODULE" "$@"
    exit $?
fi

# 如果在ISO环境，先运行基础安装模块
if is_iso_environment && [ "${SKIP_BASE_INSTALL:-0}" != "1" ]; then
    section "ISO Mode" "Base System Installation Required"
    log "Running base installation module..."
    
    BASE_INSTALL_SCRIPT="$SCRIPTS_DIR/00-arch-base-install.sh"
    if [ -f "$BASE_INSTALL_SCRIPT" ]; then
        bash "$BASE_INSTALL_SCRIPT"
        
        # 基础安装完成后，脚本会在chroot内重新调用 scripts/install.sh
        # 此时SKIP_BASE_INSTALL=1，不会再次进入这个分支
        exit 0
    else
        error "ISO detected but base installation script missing: $BASE_INSTALL_SCRIPT"
        warn "Please install Arch Linux manually first, then run this script."
        exit 1
    fi
fi

clear
show_banner
sys_dashboard

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

if [ "${1:-}" = "--module" ] && [ -n "${2:-}" ]; then
    ONLY_MODULE="$2"
    MODULES=("$ONLY_MODULE")
fi

if [ ! -f "$STATE_FILE" ]; then touch "$STATE_FILE"; fi

TOTAL_STEPS=${#MODULES[@]}
CURRENT_STEP=0

log "Initializing installer sequence..."
sleep 0.5

# --- Reflector Mirror Update (State Aware) ---
section "Pre-Flight" "Mirrorlist Optimization"

# [MODIFIED] Check if already done
if grep -q "^REFLECTOR_DONE$" "$STATE_FILE"; then
    echo -e "   ${H_GREEN}✔${NC} Mirrorlist previously optimized."
    echo -e "   ${DIM}   Skipping Reflector steps (Resume Mode)...${NC}"
else
    # --- Start Reflector Logic ---
    log "Checking Reflector..."
    exe pacman -S --noconfirm --needed reflector

    CURRENT_TZ=$(readlink -f /etc/localtime)
    REFLECTOR_ARGS="-a $REFLECTOR_AGE_HOURS -f $REFLECTOR_TOP_MIRRORS --sort score --save /etc/pacman.d/mirrorlist --verbose"

    if [[ "$CURRENT_TZ" == *"Shanghai"* ]]; then
        echo ""
        echo -e "${H_YELLOW}╔══════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${H_YELLOW}║  DETECTED TIMEZONE: Asia/Shanghai                                ║${NC}"
        echo -e "${H_YELLOW}║  Refreshing mirrors in China can be slow.                        ║${NC}"
        echo -e "${H_YELLOW}║  Do you want to force refresh mirrors with Reflector?            ║${NC}"
        echo -e "${H_YELLOW}╚══════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        
        if ! read -t "$REFLECTOR_TIMEOUT" -p "$(echo -e "   ${H_CYAN}Run Reflector? [y/N] (Default No in ${REFLECTOR_TIMEOUT}s): ${NC}")" choice; then
            echo ""
        fi
        choice=${choice:-N}
        
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            log "Running Reflector for China..."
            if exe reflector $REFLECTOR_ARGS -c China; then
                success "Mirrors updated."
            else
                warn "Reflector failed. Continuing with existing mirrors."
            fi
        else
            log "Skipping mirror refresh."
        fi
    else
        log "Detecting location for optimization..."
        COUNTRY_CODE=$(curl -s --max-time 2 https://ipinfo.io/country || true)
        
        if [ -n "$COUNTRY_CODE" ]; then
            info_kv "Country" "$COUNTRY_CODE" "(Auto-detected)"
            log "Running Reflector for $COUNTRY_CODE..."
            if ! exe reflector $REFLECTOR_ARGS -c "$COUNTRY_CODE"; then
                warn "Country specific refresh failed. Trying global speed test..."
                exe reflector $REFLECTOR_ARGS
            fi
        else
            warn "Could not detect country. Running global speed test..."
            exe reflector $REFLECTOR_ARGS
        fi
        success "Mirrorlist optimized."
    fi
    # --- End Reflector Logic ---

    # [MODIFIED] Record success so we don't ask again
    echo "REFLECTOR_DONE" >> "$STATE_FILE"
fi

# ---- update keyring-----

section "Pre-Flight" "Update Keyring"

exe pacman -Sy
exe pacman -S --noconfirm archlinux-keyring

# --- Global Update ---
section "Pre-Flight" "System update"
log "Ensuring system is up-to-date..."

if exe pacman -Syu --noconfirm; then
    success "System Updated."
else
    error "System update failed. Check your network."
    exit 1
fi

# --- Module Loop ---
for module in "${MODULES[@]}"; do
    CURRENT_STEP=$((CURRENT_STEP + 1))

    # Checkpoint Logic: Auto-skip if in state file
    if grep -q "^${module}$" "$STATE_FILE"; then
        echo -e "   ${H_GREEN}✔${NC} Module ${BOLD}${module}${NC} already completed."
        echo -e "   ${DIM}   Skipping... (Delete .install_progress to force run)${NC}"
        continue
    fi

    section "Module ${CURRENT_STEP}/${TOTAL_STEPS}" "$module"

    set +e
    bash "$SCRIPTS_DIR/modules.sh" "$module"
    exit_code=$?
    set -e

    if [ $exit_code -eq 0 ]; then
        # Only record success
        echo "$module" >> "$STATE_FILE"
        success "Module $module completed."
    elif [ $exit_code -eq $EXIT_CODE_INTERRUPTED ]; then
        echo ""
        warn "Script interrupted by user (Ctrl+C)."
        log "Exiting without rollback. You can resume later."
        exit $EXIT_CODE_INTERRUPTED
    else
        # Failure logic: do NOT write to STATE_FILE
        write_log "FATAL" "Module $module failed with exit code $exit_code"
        error "Module execution failed: $module"
        warn "You can retry with: sudo bash scripts/modules.sh $module"
        exit 1
    fi
done

# ------------------------------------------------------------------------------
# Final Cleanup
# ------------------------------------------------------------------------------
section "Completion" "System Cleanup"

# --- 1. Snapshot Cleanup Logic ---

# Get snapshot IDs to keep (protected markers)
get_protected_snapshot_ids() {
    local config_name="$1"
    shift
    local keep_markers=("$@")
    local ids=()
    
    for marker in "${keep_markers[@]}"; do
        local found_id
        found_id=$(snapper -c "$config_name" list --columns number,description | grep -F "$marker" | awk '{print $1}' | tail -n 1)
        
        if [ -n "$found_id" ]; then
            ids+=("$found_id")
            log "Found protected snapshot: '$marker' (ID: $found_id)"
        fi
    done
    
    echo "${ids[@]}"
}

# Check if snapshot ID is in protected list
is_snapshot_protected() {
    local id="$1"
    shift
    local protected_ids=("$@")
    
    for keep in "${protected_ids[@]}"; do
        if [[ "$id" == "$keep" ]]; then
            return 0
        fi
    done
    return 1
}

# Collect snapshots to delete
collect_snapshots_to_delete() {
    local config_name="$1"
    local start_id="$2"
    shift 2
    local protected_ids=("$@")
    local snapshots=()
    
    while IFS= read -r line; do
        local id type
        id=$(echo "$line" | awk '{print $1}')
        type=$(echo "$line" | awk '{print $3}')

        if [[ "$id" =~ ^[0-9]+$ ]] && [ "$id" -gt "$start_id" ]; then
            if ! is_snapshot_protected "$id" "${protected_ids[@]}"; then
                if [[ "$type" == "pre" || "$type" == "post" ]]; then
                    snapshots+=("$id")
                fi
            fi
        fi
    done < <(snapper -c "$config_name" list --columns number,type)
    
    echo "${snapshots[@]}"
}

# Main cleanup function
clean_intermediate_snapshots() {
    local config_name="$1"
    local start_marker="Before Shorin Setup"
    local keep_markers=(
        "Before Desktop Environments"
        "Before Niri Setup"
    )

    if ! snapper -c "$config_name" list &>/dev/null; then
        return
    fi

    log "Scanning junk snapshots in: $config_name..."

    local start_id
    start_id=$(snapper -c "$config_name" list --columns number,description | grep -F "$start_marker" | awk '{print $1}' | tail -n 1)

    if [ -z "$start_id" ]; then
        warn "Marker '$start_marker' not found in '$config_name'. Skipping cleanup."
        return
    fi

    local protected_ids
    protected_ids=($(get_protected_snapshot_ids "$config_name" "${keep_markers[@]}"))
    
    local snapshots_to_delete
    snapshots_to_delete=($(collect_snapshots_to_delete "$config_name" "$start_id" "${protected_ids[@]}"))

    if [ ${#snapshots_to_delete[@]} -gt 0 ]; then
        log "Deleting ${#snapshots_to_delete[@]} junk snapshots in '$config_name'..."
        if exe snapper -c "$config_name" delete "${snapshots_to_delete[@]}"; then
            success "Cleaned $config_name."
        fi
    else
        log "No junk snapshots found in '$config_name'."
    fi
}
# --- 2. Execute Cleanup ---
log "Cleaning Pacman/Yay cache..."
exe pacman -Sc --noconfirm

clean_intermediate_snapshots "root"
clean_intermediate_snapshots "home"


# Detect user ID 1000 or prompt manually
DETECTED_USER=$(awk -F: "\$3 == 1000 {print \$1}" /etc/passwd)
if [ -z "$DETECTED_USER" ]; then
    read -p "Target user: " TARGET_USER || TARGET_USER=""
    if [ -z "$TARGET_USER" ]; then
        error "User required for cleanup"
        exit 1
    fi
else
    TARGET_USER="$DETECTED_USER"
fi
HOME_DIR="/home/$TARGET_USER"
# --- 3. Remove Installer Files ---
if [ -d "/root/shorin-arch-setup" ]; then
    log "Removing installer from /root..."
    cd /
    rm -rfv /root/shorin-arch-setup
fi

if [ -d "$HOME_DIR/shorin-arch-setup" ]; then
    log "Removing installer from $HOME_DIR/shorin-arch-setup"
    rm -rfv "$HOME_DIR/shorin-arch-setup"
else
    log "Repo cleanup skipped."
    log "please remove the folder yourself."
fi

#--- 清理无用的下载残留
for dir in /var/cache/pacman/pkg/download-*/; do
    # 检查目录是否存在
    if [ -d "$dir" ]; then
        echo "Found residual directory: $dir, cleaning up..."
        rm -rf "$dir"
    fi
done

# --- 4. Final GRUB Update ---
log "Regenerating final GRUB configuration..."
exe env LANG=en_US.UTF-8 grub-mkconfig -o /boot/grub/grub.cfg

# --- Completion ---
clear
show_banner
echo -e "${H_GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${H_GREEN}║             INSTALLATION  COMPLETE                   ║${NC}"
echo -e "${H_GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

if [ -f "$STATE_FILE" ]; then rm "$STATE_FILE"; fi

log "Archiving log..."
if [ -f "/tmp/shorin_install_user" ]; then
    FINAL_USER=$(cat /tmp/shorin_install_user)
else
    FINAL_USER=$(awk -F: '$3 == 1000 {print $1}' /etc/passwd)
fi

if [ -n "$FINAL_USER" ]; then
    FINAL_DOCS="/home/$FINAL_USER/Documents"
    mkdir -p "$FINAL_DOCS"
    cp "$TEMP_LOG_FILE" "$FINAL_DOCS/log-shorin-arch-setup.txt"
    chown -R "$FINAL_USER:$FINAL_USER" "$FINAL_DOCS"
    echo -e "   ${H_BLUE}●${NC} Log Saved     : ${BOLD}$FINAL_DOCS/log-shorin-arch-setup.txt${NC}"
fi

# --- Reboot Countdown ---
echo ""
echo -e "${H_YELLOW}>>> System requires a REBOOT.${NC}"

while read -r -t 0.01 -n 10000 discard 2>/dev/null; do :; done

for i in $(seq $REBOOT_COUNTDOWN_SECONDS -1 1); do
    echo -ne "\r   ${DIM}Auto-rebooting in ${i}s... (Press 'n' to cancel)${NC}"
    
    if read -t 1 -n 1 input; then
        if [[ "$input" == "n" || "$input" == "N" ]]; then
            echo -e "\n\n   ${H_BLUE}>>> Reboot cancelled.${NC}"
            exit 0
        else
            break
        fi
    fi
done

echo -e "\n\n   ${H_GREEN}>>> Rebooting...${NC}"
systemctl reboot
