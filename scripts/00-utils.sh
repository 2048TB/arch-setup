#!/bin/bash

# ==============================================================================
# 00-utils.sh - The "TUI" Visual Engine (v4.0)
# ==============================================================================

# --- Constants ---
readonly FLATHUB_SELECTION_TIMEOUT=60
readonly LOG_FILE_PERMISSIONS=666
readonly TARGET_USER_UID=1000

# --- 1. 颜色与样式定义 (ANSI) ---
# 注意：这里定义的是字面量字符串，需要 echo -e 来解析
export NC='\033[0m'
export BOLD='\033[1m'
export DIM='\033[2m'
export ITALIC='\033[3m'
export UNDER='\033[4m'

# 常用高亮色
export H_RED='\033[1;31m'
export H_GREEN='\033[1;32m'
export H_YELLOW='\033[1;33m'
export H_BLUE='\033[1;34m'
export H_PURPLE='\033[1;35m'
export H_CYAN='\033[1;36m'
export H_WHITE='\033[1;37m'
export H_GRAY='\033[1;90m'

# 背景色 (用于标题栏)
export BG_BLUE='\033[44m'
export BG_PURPLE='\033[45m'

# 符号定义
export TICK="${H_GREEN}✔${NC}"
export CROSS="${H_RED}✘${NC}"
export INFO="${H_BLUE}ℹ${NC}"
export WARN="${H_YELLOW}⚠${NC}"
export ARROW="${H_CYAN}➜${NC}"

# 日志文件
export TEMP_LOG_FILE="/tmp/log-shorin-arch-setup.txt"
[ ! -f "$TEMP_LOG_FILE" ] && touch "$TEMP_LOG_FILE" && chmod "$LOG_FILE_PERMISSIONS" "$TEMP_LOG_FILE"

# --- 2. 基础工具 ---

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${H_RED}   $CROSS CRITICAL ERROR: Script must be run as root.${NC}"
        exit 1
    fi
}

write_log() {
    # Strip ANSI colors for log file
    local clean_msg=$(echo -e "$2" | sed 's/\x1b\[[0-9;]*m//g')
    echo "[$(date '+%H:%M:%S')] [$1] $clean_msg" >> "$TEMP_LOG_FILE"
}

# --- 3. 视觉组件 (TUI Style) ---

# 绘制分割线
hr() {
    printf "${H_GRAY}%*s${NC}\n" "${COLUMNS:-80}" '' | tr ' ' '─'
}

# 绘制大标题 (Section)
section() {
    local title="$1"
    local subtitle="$2"
    echo ""
    echo -e "${H_PURPLE}╭──────────────────────────────────────────────────────────────────────────────╮${NC}"
    echo -e "${H_PURPLE}│${NC} ${BOLD}${H_WHITE}$title${NC}"
    echo -e "${H_PURPLE}│${NC} ${H_CYAN}$subtitle${NC}"
    echo -e "${H_PURPLE}╰──────────────────────────────────────────────────────────────────────────────╯${NC}"
    write_log "SECTION" "$title - $subtitle"
}

# 绘制键值对信息
info_kv() {
    local key="$1"
    local val="$2"
    local extra="$3"
    printf "   ${H_BLUE}●${NC} %-15s : ${BOLD}%s${NC} ${DIM}%s${NC}\n" "$key" "$val" "$extra"
    write_log "INFO" "$key=$val"
}

# 普通日志
log() {
    echo -e "   $ARROW $1"
    write_log "LOG" "$1"
}

# 成功日志
success() {
    echo -e "   $TICK ${H_GREEN}$1${NC}"
    write_log "SUCCESS" "$1"
}

# 警告日志 (突出显示)
warn() {
    echo -e "   $WARN ${H_YELLOW}${BOLD}WARNING:${NC} ${H_YELLOW}$1${NC}"
    write_log "WARN" "$1"
}

# 错误日志 (非常突出)
error() {
    echo -e ""
    echo -e "${H_RED}   ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓${NC}"
    echo -e "${H_RED}   ┃  ERROR: $1${NC}"
    echo -e "${H_RED}   ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"
    echo -e ""
    write_log "ERROR" "$1"
}

# --- 4. 核心：命令执行器 (Command Exec) ---
exe() {
    local full_command="$*"
    
    # Visual: 显示正在运行的命令
    echo -e "   ${H_GRAY}┌──[ ${H_MAGENTA}EXEC${H_GRAY} ]────────────────────────────────────────────────────${NC}"
    echo -e "   ${H_GRAY}│${NC} ${H_CYAN}$ ${NC}${BOLD}$full_command${NC}"
    
    write_log "EXEC" "$full_command"
    
    # Run the command
    "$@" 
    local status=$?
    
    if [ $status -eq 0 ]; then
        echo -e "   ${H_GRAY}└──────────────────────────────────────────────────────── ${H_GREEN}OK${H_GRAY} ─┘${NC}"
    else
        echo -e "   ${H_GRAY}└────────────────────────────────────────────────────── ${H_RED}FAIL${H_GRAY} ─┘${NC}"
        write_log "FAIL" "Exit Code: $status"
        return $status
    fi
}

# 静默执行
exe_silent() {
    "$@" > /dev/null 2>&1
}

# --- 5. 可复用逻辑块 ---

# Calculate menu width for display
calculate_menu_width() {
    local title="$1"
    shift
    local items=("$@")
    local max_len=${#title}
    
    for item in "${items[@]}"; do
        local item_len=$((${#item} + 18)) # "[x] Name - Recommended"
        if (( item_len > max_len )); then
            max_len=$item_len
        fi
    done
    
    echo $((max_len + 4))
}

# Render menu border and title
render_menu_header() {
    local menu_width="$1"
    local title="$2"
    
    local line_str=""
    printf -v line_str "%*s" "$menu_width" ""
    line_str=${line_str// /─}
    
    echo ""
    echo -e "${H_PURPLE}╭${line_str}╮${NC}"
    
    local title_padding_len=$(( (menu_width - ${#title}) / 2 ))
    local right_padding_len=$((menu_width - ${#title} - title_padding_len))
    local t_pad_l=""; printf -v t_pad_l "%*s" "$title_padding_len" ""
    local t_pad_r=""; printf -v t_pad_r "%*s" "$right_padding_len" ""
    
    echo -e "${H_PURPLE}│${NC}${t_pad_l}${BOLD}${title}${NC}${t_pad_r}${H_PURPLE}│${NC}"
    echo -e "${H_PURPLE}├${line_str}┤${NC}"
}

# Render menu footer
render_menu_footer() {
    local menu_width="$1"
    local line_str=""
    printf -v line_str "%*s" "$menu_width" ""
    line_str=${line_str// /─}
    echo -e "${H_PURPLE}╰${line_str}╯${NC}"
    echo ""
}

# Render single menu option
render_menu_option() {
    local index="$1"
    local name="$2"
    local menu_width="$3"
    local display_idx=$((index + 1))
    
    local color_str raw_str
    if [ "$index" -eq 0 ]; then
        raw_str=" [$display_idx] $name - Recommended"
        color_str=" ${H_CYAN}[$display_idx]${NC} ${name} - ${H_GREEN}Recommended${NC}"
    else
        raw_str=" [$display_idx] $name"
        color_str=" ${H_CYAN}[$display_idx]${NC} ${name}"
    fi
    
    local padding=$((menu_width - ${#raw_str}))
    local pad_str=""
    if [ "$padding" -gt 0 ]; then
        printf -v pad_str "%*s" "$padding" ""
    fi
    
    echo -e "${H_PURPLE}│${NC}${color_str}${pad_str}${H_PURPLE}│${NC}"
}

# Main Flathub mirror selection
select_flathub_mirror() {
    local names=(
        "SJTU (Shanghai Jiao Tong)"
        "USTC (Univ of Sci & Tech of China)"
        "FlatHub Offical"
    )
    
    local urls=(
        "https://mirror.sjtu.edu.cn/flathub"
        "https://mirrors.ustc.edu.cn/flathub"
        "https://dl.flathub.org/repo/"
    )
    
    local title_text="Select Flathub Mirror (${FLATHUB_SELECTION_TIMEOUT}s Timeout)"
    local menu_width
    menu_width=$(calculate_menu_width "$title_text" "${names[@]}")
    
    render_menu_header "$menu_width" "$title_text"
    
    for i in "${!names[@]}"; do
        render_menu_option "$i" "${names[$i]}" "$menu_width"
    done
    
    render_menu_footer "$menu_width"
    
    local choice
    read -t "$FLATHUB_SELECTION_TIMEOUT" -p "$(echo -e "   ${H_YELLOW}Enter choice [1-${#names[@]}]: ${NC}")" choice
    [ $? -ne 0 ] && echo ""
    choice=${choice:-1}
    
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#names[@]}" ]; then
        log "Invalid choice or timeout. Defaulting to SJTU..."
        choice=1
    fi
    
    local index=$((choice - 1))
    local selected_name="${names[$index]}"
    local selected_url="${urls[$index]}"
    
    log "Setting Flathub mirror to: ${H_GREEN}$selected_name${NC}"
    
    if exe flatpak remote-modify flathub --url="$selected_url"; then
        success "Mirror updated."
    else
        error "Failed to update mirror."
    fi
}

as_user() {
  runuser -u "$TARGET_USER" -- "$@"
}

# 统一的用户检测函数
detect_target_user() {
  # 优先从临时文件读取（03-user.sh写入）
  if [ -f "/tmp/shorin_install_user" ]; then
    TARGET_USER=$(cat /tmp/shorin_install_user)
  else
    # 回退到UID 1000检测
    local detected
    detected=$(awk -F: "\$3 == $TARGET_USER_UID {print \$1}" /etc/passwd)
    TARGET_USER="${detected:-$(read -p "Target user: " u && echo "$u")}"
  fi

  HOME_DIR="/home/$TARGET_USER"
  export TARGET_USER HOME_DIR
}

# 包管理统一函数
install_yay_package() {
  local pkg="$1"
  as_user yay -Syu --noconfirm --needed --answerdiff=None --answerclean=None "$pkg"
}

is_package_installed() {
  local pkg="$1"
  pacman -Qi "$pkg" &>/dev/null
}

# FZF通用应用选择菜单
fzf_select_apps() {
  local list_file="$1"
  local header_text="${2:-[TAB] TOGGLE | [ENTER] SELECT | [CTRL-D] DE-ALL | [CTRL-A] SE-ALL}"
  
  grep -vE "^\s*#|^\s*$" "$list_file" | \
    sed -E 's/[[:space:]]+#/\t#/' | \
    fzf --multi \
      --layout=reverse \
      --border \
      --margin=1,2 \
      --prompt="Search App > " \
      --pointer=">>" \
      --marker="* " \
      --delimiter=$'\t' \
      --with-nth=1 \
      --bind 'load:select-all' \
      --bind 'ctrl-a:select-all,ctrl-d:deselect-all' \
      --info=inline \
      --header="$header_text" \
      --preview "echo {} | cut -f2 -d$'\t' | sed 's/^# //'" \
      --preview-window=right:50%:wrap:border-left \
      --color=dark \
      --color=fg+:white,bg+:black \
      --color=hl:blue,hl+:blue:bold \
      --color=header:yellow:bold \
      --color=info:magenta \
      --color=prompt:cyan,pointer:cyan:bold,marker:green:bold \
      --color=spinner:yellow
}


configure_nautilus_user() {
  local sys_file="/usr/share/applications/org.gnome.Nautilus.desktop"
  local user_dir="$HOME_DIR/.local/share/applications"
  local user_file="$user_dir/org.gnome.Nautilus.desktop"

  # 1. 检查系统文件是否存在
  if [ -f "$sys_file" ]; then
    
    # 2. 显卡检测逻辑
    local gpu_count=$(lspci | grep -E -i "vga|3d" | wc -l)
    local has_nvidia=$(lspci | grep -E -i "nvidia" | wc -l)

    # 只有在双显卡且包含 NVIDIA 的情况下才应用修改
    if [ "$gpu_count" -gt 1 ] && [ "$has_nvidia" -gt 0 ]; then
      
      # 定义需要注入的环境变量
      local env_vars="env GSK_RENDERER=gl GTK_IM_MODULE=fcitx"

      # 3. 准备用户目录并复制文件
      mkdir -p "$user_dir"
      cp "$sys_file" "$user_file"
      chown "$TARGET_USER" "$user_file"
      # 4. 修改用户目录下的文件
      sed -i "s|^Exec=|Exec=$env_vars |" "$user_file"
      
      log "已创建用户级 Nautilus 配置: $user_file"

      local env_conf_dir="$HOME_DIR/.config/environment.d"
      if [ ! -f "$env_conf_dir/gsk.conf" ]; then
          mkdir -p "$env_conf_dir"
          echo "GSK_RENDERER=gl" > "$env_conf_dir/gsk.conf"
          log "已添加用户级环境变量配置: $env_conf_dir/gsk.conf"
      fi
      
    fi
  fi
  
}
