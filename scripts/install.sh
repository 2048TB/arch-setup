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
    echo "错误：未找到 00-utils.sh。"
    exit 1
fi
# --- Config & Strict Mode ---
CONFIG_FILE="${SHORIN_CONFIG:-$REPO_DIR/config.conf}"
load_config
enable_strict_mode

# --- Constants ---
readonly DESKTOP_SELECTION_TIMEOUT=120
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
    error "在 $SCRIPTS_DIR 找不到 modules.sh"
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
    echo -e "${DIM}   :: Arch Linux 自动化协议 :: v2.1 ::${NC}"
    echo ""
}

# --- Desktop Selection Menu ---
select_desktop() {
    show_banner
    
    # 1. 定义选项 (显示名称|内部ID)
    local OPTIONS=(
        "No Desktop |none"
        "Shorin's Niri |niri"
        "GNOME |gnome"
    )
    
    # 2. 绘制菜单 (半开放式风格)
    # 定义一条足够长的横线，或者固定长度
    local HR="──────────────────────────────────────────────────"
    
    echo -e "${H_PURPLE}╭${HR}${NC}"
    echo -e "${H_PURPLE}│${NC} ${BOLD}选择桌面环境：${NC}"
    echo -e "${H_PURPLE}│${NC}" # 空行分隔

    local idx=1
    for opt in "${OPTIONS[@]}"; do
        local name="${opt%%|*}"
        # 直接打印，无需计算填充空格
        echo -e "${H_PURPLE}│${NC}  ${H_CYAN}[${idx}]${NC} ${name}"
        ((idx++))
    done
    echo -e "${H_PURPLE}│${NC}" # 空行分隔
    echo -e "${H_PURPLE}╰${HR}${NC}"
    echo ""
    
    # 3. 输入处理
    echo -e "   ${DIM}等待输入（超时：2 分钟）...${NC}"
    if ! read -t "$DESKTOP_SELECTION_TIMEOUT" -p "$(echo -e "   ${H_YELLOW}请选择 [1-${#OPTIONS[@]}]： ${NC}")" choice; then
        choice=""
    fi
    
    if [ -z "$choice" ]; then
        echo -e "\n${H_RED}Timeout or no selection.${NC}"
        exit 1
    fi
    
    # 4. 验证并提取 ID
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#OPTIONS[@]}" ]; then
        local selected_opt="${OPTIONS[$((choice-1))]}"
        export DESKTOP_ENV="${selected_opt##*|}" # 提取 ID
        log "已选择: ${selected_opt%%|*}"
    else
        error "选择无效。"
        exit 1
    fi
    sleep 0.5
}
sys_dashboard() {
    echo -e "${H_BLUE}╔════ 系统诊断 ══════════════════════════════╗${NC}"
    echo -e "${H_BLUE}║${NC} ${BOLD}内核${NC}     : $(uname -r)"
    echo -e "${H_BLUE}║${NC} ${BOLD}用户${NC}     : $(whoami)"
    echo -e "${H_BLUE}║${NC} ${BOLD}桌面${NC}     : ${H_MAGENTA}${DESKTOP_ENV^^}${NC}"
    
    if [ "$CN_MIRROR" == "1" ]; then
        echo -e "${H_BLUE}║${NC} ${BOLD}网络${NC}     : ${H_YELLOW}中国镜像优化（手动）${NC}"
    elif [ "$DEBUG" == "1" ]; then
        echo -e "${H_BLUE}║${NC} ${BOLD}网络${NC}     : ${H_RED}DEBUG 强制（CN 模式）${NC}"
    else
        echo -e "${H_BLUE}║${NC} ${BOLD}网络${NC}     : 全球默认"
    fi
    
    if [ -f "$STATE_FILE" ]; then
        done_count=$(wc -l < "$STATE_FILE")
        echo -e "${H_BLUE}║${NC} ${BOLD}进度${NC}     : 继续执行（已记录 $done_count 步）"
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
    section "ISO 模式" "需要基础系统安装"
    log "运行基础安装模块..."
    
    BASE_INSTALL_SCRIPT="$SCRIPTS_DIR/00-arch-base-install.sh"
    if [ -f "$BASE_INSTALL_SCRIPT" ]; then
        bash "$BASE_INSTALL_SCRIPT"
        
        # 基础安装完成后，脚本会在chroot内重新调用 scripts/install.sh
        # 此时SKIP_BASE_INSTALL=1，不会再次进入这个分支
        exit 0
    else
        error "检测到 ISO，但基础安装脚本缺失：$BASE_INSTALL_SCRIPT"
        warn "请先手动安装 Arch Linux，再运行此脚本。"
        exit 1
    fi
fi

if [ -n "${DESKTOP_ENV:-}" ]; then
    DESKTOP_ENV="${DESKTOP_ENV,,}"
    case "$DESKTOP_ENV" in
        niri|gnome|none)
            log "使用配置/环境变量 DESKTOP_ENV: $DESKTOP_ENV"
            ;;
        *)
            error "DESKTOP_ENV 无效: $DESKTOP_ENV（可用 niri|gnome|none）"
            exit 1
            ;;
    esac
else
    select_desktop
fi
clear
show_banner
sys_dashboard

# Dynamic Module List
BASE_MODULES=(
    "00-btrfs-init.sh"
    "01-base.sh"
    "02-musthave.sh"
    "02a-dualboot-fix.sh"
    "03-user.sh"
    "03b-gpu-driver.sh"
    "03c-snapshot-before-desktop.sh"
)

case "$DESKTOP_ENV" in
    niri)
        BASE_MODULES+=("04-niri-setup.sh")
        ;;
    gnome)
        BASE_MODULES+=("04d-gnome.sh")
        ;;
    none)
        log "跳过桌面环境安装。"
        ;;
    *)
        warn "未知选择，跳过桌面安装。"
        ;;
esac

BASE_MODULES+=("07-grub-theme.sh" "99-apps.sh")
MODULES=("${BASE_MODULES[@]}")

if [ "${1:-}" = "--module" ] && [ -n "${2:-}" ]; then
    ONLY_MODULE="$2"
    MODULES=("$ONLY_MODULE")
fi

if [ ! -f "$STATE_FILE" ]; then touch "$STATE_FILE"; fi

TOTAL_STEPS=${#MODULES[@]}
CURRENT_STEP=0

log "初始化安装流程..."
sleep 0.5

# --- Reflector Mirror Update (State Aware) ---
section "预检" "镜像列表优化"

# [MODIFIED] Check if already done
if grep -q "^REFLECTOR_DONE$" "$STATE_FILE"; then
    echo -e "   ${H_GREEN}✔${NC} 镜像列表已优化。"
    echo -e "   ${DIM}   跳过 Reflector 步骤（续跑模式）...${NC}"
else
    # --- Start Reflector Logic ---
    log "检查 Reflector..."
    exe pacman -S --noconfirm --needed reflector

    CURRENT_TZ=$(readlink -f /etc/localtime)
    REFLECTOR_ARGS="-a $REFLECTOR_AGE_HOURS -f $REFLECTOR_TOP_MIRRORS --sort score --save /etc/pacman.d/mirrorlist --verbose"

    if [[ "$CURRENT_TZ" == *"Shanghai"* ]]; then
        echo ""
        echo -e "${H_YELLOW}╔══════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${H_YELLOW}║  检测到时区：Asia/Shanghai                                      ║${NC}"
        echo -e "${H_YELLOW}║  在中国刷新镜像可能较慢。                                       ║${NC}"
        echo -e "${H_YELLOW}║  是否强制使用 Reflector 刷新镜像？                               ║${NC}"
        echo -e "${H_YELLOW}╚══════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        
        if ! read -t "$REFLECTOR_TIMEOUT" -p "$(echo -e "   ${H_CYAN}运行 Reflector？[y/N]（默认 N，${REFLECTOR_TIMEOUT}s 后）： ${NC}")" choice; then
            echo ""
        fi
        choice=${choice:-N}
        
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            log "为中国运行 Reflector..."
            if exe reflector $REFLECTOR_ARGS -c China; then
                success "镜像已更新。"
            else
                warn "Reflector 失败，继续使用现有镜像。"
            fi
        else
            log "跳过镜像刷新。"
        fi
    else
        log "检测地区用于优化..."
        COUNTRY_CODE=$(curl -s --max-time 2 https://ipinfo.io/country || true)
        
        if [ -n "$COUNTRY_CODE" ]; then
            info_kv "国家" "$COUNTRY_CODE" "(自动检测)"
            log "为 $COUNTRY_CODE 运行 Reflector..."
            if ! exe reflector $REFLECTOR_ARGS -c "$COUNTRY_CODE"; then
                warn "国家镜像刷新失败，尝试全球测速..."
                exe reflector $REFLECTOR_ARGS
            fi
        else
            warn "无法检测国家，运行全球测速..."
            exe reflector $REFLECTOR_ARGS
        fi
        success "镜像列表优化完成。"
    fi
    # --- End Reflector Logic ---

    # [MODIFIED] Record success so we don't ask again
    echo "REFLECTOR_DONE" >> "$STATE_FILE"
fi

# ---- update keyring-----

section "预检" "更新 keyring"

exe pacman -Sy
exe pacman -S --noconfirm archlinux-keyring

# --- Global Update ---
section "预检" "系统更新"
log "确保系统已更新..."

if exe pacman -Syu --noconfirm; then
    success "系统已更新。"
else
    error "系统更新失败，请检查网络。"
    exit 1
fi

# --- Module Loop ---
for module in "${MODULES[@]}"; do
    CURRENT_STEP=$((CURRENT_STEP + 1))

    # Checkpoint Logic: Auto-skip if in state file
    if grep -q "^${module}$" "$STATE_FILE"; then
        echo -e "   ${H_GREEN}✔${NC} 模块 ${BOLD}${module}${NC} 已完成。"
        echo -e "   ${DIM}   跳过...（删除 .install_progress 可强制重跑）${NC}"
        continue
    fi

    section "模块 ${CURRENT_STEP}/${TOTAL_STEPS}" "$module"

    set +e
    bash "$SCRIPTS_DIR/modules.sh" "$module"
    exit_code=$?
    set -e

    if [ $exit_code -eq 0 ]; then
        # Only record success
        echo "$module" >> "$STATE_FILE"
        success "模块 $module 完成。"
    elif [ $exit_code -eq $EXIT_CODE_INTERRUPTED ]; then
        echo ""
        warn "脚本被用户中断 (Ctrl+C)。"
        log "未回滚直接退出，可稍后继续。"
        exit $EXIT_CODE_INTERRUPTED
    else
        # Failure logic: do NOT write to STATE_FILE
        write_log "FATAL" "模块 $module 失败，退出码 $exit_code"
        error "模块执行失败: $module"
        warn "可使用以下命令重试：sudo bash scripts/modules.sh $module"
        exit 1
    fi
done

# ------------------------------------------------------------------------------
# Final Cleanup
# ------------------------------------------------------------------------------
section "完成" "系统清理"

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
            log "发现受保护快照：'$marker'（ID: $found_id）"
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

    log "扫描多余快照：$config_name..."

    local start_id
    start_id=$(snapper -c "$config_name" list --columns number,description | grep -F "$start_marker" | awk '{print $1}' | tail -n 1)

    if [ -z "$start_id" ]; then
        warn "在 '$config_name' 中未找到标记 '$start_marker'，跳过清理。"
        return
    fi

    local protected_ids
    protected_ids=($(get_protected_snapshot_ids "$config_name" "${keep_markers[@]}"))
    
    local snapshots_to_delete
    snapshots_to_delete=($(collect_snapshots_to_delete "$config_name" "$start_id" "${protected_ids[@]}"))

    if [ ${#snapshots_to_delete[@]} -gt 0 ]; then
        log "删除 '$config_name' 中 ${#snapshots_to_delete[@]} 个多余快照..."
        if exe snapper -c "$config_name" delete "${snapshots_to_delete[@]}"; then
            success "$config_name 清理完成。"
        fi
    else
        log "'$config_name' 中未发现多余快照。"
    fi
}
# --- 2. Execute Cleanup ---
log "清理 Pacman/Yay 缓存..."
exe pacman -Sc --noconfirm

clean_intermediate_snapshots "root"
clean_intermediate_snapshots "home"


# Detect user ID 1000 or prompt manually
DETECTED_USER=$(awk -F: "\$3 == 1000 {print \$1}" /etc/passwd)
if [ -z "$DETECTED_USER" ]; then
    read -p "Target user: " TARGET_USER || TARGET_USER=""
    if [ -z "$TARGET_USER" ]; then
        error "清理需要用户"
        exit 1
    fi
else
    TARGET_USER="$DETECTED_USER"
fi
HOME_DIR="/home/$TARGET_USER"
# --- 3. Remove Installer Files ---
if [ -d "/root/shorin-arch-setup" ]; then
    log "从 /root 移除安装器..."
    cd /
    rm -rfv /root/shorin-arch-setup
fi

if [ -d "$HOME_DIR/shorin-arch-setup" ]; then
    log "从 $HOME_DIR/shorin-arch-setup 移除安装器"
    rm -rfv "$HOME_DIR/shorin-arch-setup"
else
    log "仓库清理已跳过。"
    log "请自行删除该目录。"
fi

#--- 清理无用的下载残留
for dir in /var/cache/pacman/pkg/download-*/; do
    # 检查目录是否存在
    if [ -d "$dir" ]; then
        echo "发现残留目录：$dir，正在清理..."
        rm -rf "$dir"
    fi
done

# --- 4. Final GRUB Update ---
log "重新生成最终 GRUB 配置..."
exe env LANG=en_US.UTF-8 grub-mkconfig -o /boot/grub/grub.cfg

# --- Completion ---
clear
show_banner
echo -e "${H_GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${H_GREEN}║             安装完成                                  ║${NC}"
echo -e "${H_GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

if [ -f "$STATE_FILE" ]; then rm "$STATE_FILE"; fi

log "归档日志..."
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
    echo -e "   ${H_BLUE}●${NC} 日志已保存     : ${BOLD}$FINAL_DOCS/log-shorin-arch-setup.txt${NC}"
fi

# --- Reboot Countdown ---
echo ""
echo -e "${H_YELLOW}>>> 系统需要重启。${NC}"

while read -r -t 0.01 -n 10000 discard 2>/dev/null; do :; done

for i in $(seq $REBOOT_COUNTDOWN_SECONDS -1 1); do
    echo -ne "\r   ${DIM}${i}s 后自动重启...（按 'n' 取消）${NC}"
    
    if read -t 1 -n 1 input; then
        if [[ "$input" == "n" || "$input" == "N" ]]; then
            echo -e "\n\n   ${H_BLUE}>>> 已取消重启。${NC}"
            exit 0
        else
            break
        fi
    fi
done

echo -e "\n\n   ${H_GREEN}>>> Rebooting...${NC}"
systemctl reboot
