#!/bin/bash

CACHE_DIR="$HOME/.cache/matugen-strategy"
TYPE_FILE="$CACHE_DIR/type"
MODE_FILE="$CACHE_DIR/mode"
UPDATE_SCRIPT="$HOME/.config/scripts/matugen-update.sh"
WAYPAPER_CONFIG="$HOME/.config/waypaper/config.ini"

# --- 0. 确保缓存目录存在 ---
if [ ! -d "$CACHE_DIR" ]; then
    mkdir -p "$CACHE_DIR"
fi

# --- 1. 自动检测语言环境 ---
if env | grep -q "zh_CN"; then
    IS_CN=true
else
    IS_CN=false
fi

# --- 2. 读取当前模式 (用于实现 Toggle) ---
CURRENT_MODE="dark"
if [ -f "$MODE_FILE" ]; then
    READ_MODE=$(cat "$MODE_FILE")
    if [[ "$READ_MODE" == "light" ]]; then
        CURRENT_MODE="light"
    fi
fi

# --- 3. 定义选项 (动态生成 Toggle 行) ---

# 根据当前模式，生成相反的选项
if [ "$CURRENT_MODE" == "dark" ]; then
    if [ "$IS_CN" = true ]; then
        MODE_OPTION=">> 切换到亮色模式 (light)"
    else
        MODE_OPTION=">> Switch to Light (light)"
    fi
else
    if [ "$IS_CN" = true ]; then
        MODE_OPTION=">> 切换到暗色模式 (dark)"
    else
        MODE_OPTION=">> Switch to Dark (dark)"
    fi
fi

# 定义配色策略列表
if [ "$IS_CN" = true ]; then
    SCHEMES="默认点调 (scheme-tonal-spot)
鲜艳模式 (scheme-vibrant)
水果沙拉 (scheme-fruit-salad)
忠实还原 (scheme-fidelity)
表现增强 (scheme-expressive)
中性柔和 (scheme-neutral)
单色黑白 (scheme-monochrome)
彩虹混色 (scheme-rainbow)
内容优先 (scheme-content)"
    PROMPT_TEXT="Matugen 设置 > "
else
    SCHEMES="scheme-tonal-spot
scheme-fruit-salad
scheme-vibrant
scheme-fidelity
scheme-expressive
scheme-neutral
scheme-monochrome
scheme-rainbow
scheme-content"
    PROMPT_TEXT="Matugen Config > "
fi

# 合并选项
OPTIONS="${MODE_OPTION}
--------------------
${SCHEMES}"

# --- 4. Fuzzel 菜单 ---
SELECTED_LINE=$(echo "$OPTIONS" | fuzzel -d --prompt="$PROMPT_TEXT" --lines=12)

if [ -z "$SELECTED_LINE" ]; then
    exit 0
fi

# 过滤掉分隔线
if [[ "$SELECTED_LINE" == *"----"* ]]; then
    exit 0
fi

# --- 5. 提取真实参数 ---
REAL_VALUE=$(echo "$SELECTED_LINE" | awk '{print $NF}' | tr -d '()')

# --- 6. 执行逻辑 ---
if [ -n "$REAL_VALUE" ]; then
    
    # 判断是模式还是策略
    if [[ "$REAL_VALUE" == "dark" ]] || [[ "$REAL_VALUE" == "light" ]]; then
        echo "$REAL_VALUE" > "$MODE_FILE"
        MSG_TYPE="Mode"
    else
        echo "$REAL_VALUE" > "$TYPE_FILE"
        MSG_TYPE="Scheme"
    fi

    # 发送通知
    if [ "$IS_CN" = true ]; then
        notify-send "Matugen" "已更新设置: $REAL_VALUE"
    else
        notify-send "Matugen" "Updated $MSG_TYPE to: $REAL_VALUE"
    fi

    # 获取壁纸路径
    CURRENT_WALLPAPER=""
    # 1. 问 swww
    if command -v swww &>/dev/null && pgrep -x "swww-daemon" >/dev/null; then
        WP_SWWW=$(swww query | head -n 1 | awk -F ': ' '{print $2}' | awk '{print $1}')
        if [ -n "$WP_SWWW" ] && [ -f "$WP_SWWW" ]; then
            CURRENT_WALLPAPER="$WP_SWWW"
        fi
    fi
    # 2. 问 Waypaper 配置
    if [ -z "$CURRENT_WALLPAPER" ] && [ -f "$WAYPAPER_CONFIG" ]; then
        WP_CONF=$(sed -n 's/^wallpaper[[:space:]]*=[[:space:]]*//p' "$WAYPAPER_CONFIG")
        WP_CONF="${WP_CONF/#\~/$HOME}"
        if [ -f "$WP_CONF" ]; then
            CURRENT_WALLPAPER="$WP_CONF"
        fi
    fi

    # 立即刷新
    if [ -n "$CURRENT_WALLPAPER" ]; then
        if [ -x "$UPDATE_SCRIPT" ]; then
            "$UPDATE_SCRIPT" "$CURRENT_WALLPAPER"
        else
            notify-send "Error" "脚本未找到: $UPDATE_SCRIPT"
        fi
    else
        if [ "$IS_CN" = true ]; then
            notify-send "Matugen" "设置已保存，但无法获取壁纸路径。"
        else
            notify-send "Matugen" "Settings saved, but wallpaper path not found."
        fi
    fi
fi