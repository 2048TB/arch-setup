#!/bin/bash

# 脚本功能：
# 从随机老婆图片生成 API 下载图片并使用 Fastfetch 展示。
# 特性：支持 NSFW 模式，支持自动补货，支持阅后即焚防止缓存爆炸。

# ================= 配置区域 =================

# [开关] 阅后即焚模式
# true  = 运行后强力清空 Fastfetch 的图片缓存（推荐，防止缓存目录无限膨胀）
# false = 保留缓存（注意：这会导致 ~/.cache/fastfetch/images/ 占用越来越大）
CLEAN_CACHE_MODE=true

# 每次补货下载多少张
DOWNLOAD_BATCH_SIZE=10
# 最大库存上限
MAX_CACHE_LIMIT=100
# 库存少于多少张时开始补货
MIN_TRIGGER_LIMIT=60

# ===========================================

# --- 0. 参数解析与模式设置 ---

NSFW_MODE=false
# 检查环境变量
if [ "$NSFW" = "1" ]; then
    NSFW_MODE=true
fi

ARGS_FOR_FASTFETCH=()
for arg in "$@"; do
    if [ "$arg" == "--nsfw" ]; then
        NSFW_MODE=true
    else
        ARGS_FOR_FASTFETCH+=("$arg")
    fi
done

# --- 1. 目录配置 ---

# 根据模式区分缓存目录和锁文件
if [ "$NSFW_MODE" = true ]; then
    CACHE_DIR="$HOME/.cache/fastfetch_waifu_nsfw"
    LOCK_FILE="/tmp/fastfetch_waifu_nsfw.lock"
else
    CACHE_DIR="$HOME/.cache/fastfetch_waifu"
    LOCK_FILE="/tmp/fastfetch_waifu.lock"
fi

mkdir -p "$CACHE_DIR"

# --- 2. 核心函数 ---

get_random_url() {
    local TIMEOUT="--connect-timeout 5 --max-time 15"
    RAND=$(( ( RANDOM % 3 ) + 1 ))
    
    if [ "$NSFW_MODE" = true ]; then
        # === NSFW API ===
        case $RAND in
            1) curl -s $TIMEOUT "https://api.waifu.im/search?included_tags=waifu&is_nsfw=true" | jq -r '.images[0].url' ;;
            2) curl -s $TIMEOUT "https://api.waifu.pics/nsfw/waifu" | jq -r '.url' ;;
            3) curl -s $TIMEOUT "https://api.waifu.pics/nsfw/neko" | jq -r '.url' ;;
        esac
    else
        # === SFW (正常) API ===
        case $RAND in
            1) curl -s $TIMEOUT "https://api.waifu.im/search?included_tags=waifu&is_nsfw=false" | jq -r '.images[0].url' ;;
            2) curl -s $TIMEOUT "https://nekos.best/api/v2/waifu" | jq -r '.results[0].url' ;;
            3) curl -s $TIMEOUT "https://api.waifu.pics/sfw/waifu" | jq -r '.url' ;;
        esac
    fi
}

download_one_image() {
    URL=$(get_random_url)
    if [[ "$URL" =~ ^http ]]; then
        # 使用带时间戳的随机文件名
        FILENAME="waifu_$(date +%s%N)_$RANDOM.jpg"
        TARGET_PATH="$CACHE_DIR/$FILENAME"
        
        curl -s -L --connect-timeout 5 --max-time 15 -o "$TARGET_PATH" "$URL"
        
        # 简单校验
        if [ -s "$TARGET_PATH" ]; then
            if command -v file >/dev/null 2>&1; then
                if ! file --mime-type "$TARGET_PATH" | grep -q "image/"; then
                    rm -f "$TARGET_PATH"
                fi
            fi
        else
            rm -f "$TARGET_PATH"
        fi
    fi
}

background_job() {
    (
        flock -n 200 || exit 1
        
        # 1. 补货检查
        CURRENT_COUNT=$(find "$CACHE_DIR" -maxdepth 1 -name "*.jpg" 2>/dev/null | wc -l)

        if [ "$CURRENT_COUNT" -lt "$MIN_TRIGGER_LIMIT" ]; then
            for ((i=1; i<=DOWNLOAD_BATCH_SIZE; i++)); do
                download_one_image
                sleep 0.5
            done
        fi

        # 2. 清理过多库存
        FINAL_COUNT=$(find "$CACHE_DIR" -maxdepth 1 -name "*.jpg" 2>/dev/null | wc -l)
        if [ "$FINAL_COUNT" -gt "$MAX_CACHE_LIMIT" ]; then
             DELETE_START_LINE=$((MAX_CACHE_LIMIT + 1))
             ls -tp "$CACHE_DIR"/*.jpg 2>/dev/null | tail -n +$DELETE_START_LINE | xargs -I {} rm -- "{}"
        fi
        
    ) 200>"$LOCK_FILE"
}

# --- 3. 主程序逻辑 ---

shopt -s nullglob
FILES=("$CACHE_DIR"/*.jpg)
NUM_FILES=${#FILES[@]}
shopt -u nullglob

SELECTED_IMG=""

if [ "$NUM_FILES" -gt 0 ]; then
    # 有库存，随机选一张
    RAND_INDEX=$(( RANDOM % NUM_FILES ))
    SELECTED_IMG="${FILES[$RAND_INDEX]}"
    
    # 后台补货
    background_job >/dev/null 2>&1 &
    
else
    # 没库存，提示语更改
    echo "主人，库存不够啦！正在去搬运新的老婆图片，请稍等哦..."
    download_one_image
    
    shopt -s nullglob
    FILES=("$CACHE_DIR"/*.jpg)
    shopt -u nullglob
    
    if [ ${#FILES[@]} -gt 0 ]; then
        SELECTED_IMG="${FILES[0]}"
        background_job >/dev/null 2>&1 &
    fi
fi

# 运行 Fastfetch
if [ -n "$SELECTED_IMG" ] && [ -f "$SELECTED_IMG" ]; then
    
    # 显示图片
    fastfetch --logo "$SELECTED_IMG" --logo-preserve-aspect-ratio true "${ARGS_FOR_FASTFETCH[@]}"
    
    
    #  检查是否开启“阅后即焚”缓存清理
    if [ "$CLEAN_CACHE_MODE" = true ]; then
    	# 删除原图 
    	rm -f "$SELECTED_IMG"
        # 强力清除 Fastfetch 生成的转码缓存，防止磁盘爆炸
        rm -rf "$HOME/.cache/fastfetch/images"
    fi
else
    # 失败提示语更改
    echo "呜呜... 图片下载失败了，这次只能先显示默认的 Logo 啦 QAQ"
    fastfetch "${ARGS_FOR_FASTFETCH[@]}"
fi
