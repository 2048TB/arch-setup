if status is-interactive
    # Commands to run in interactive sessions can go here
end
set fish_greeting ""


starship init fish | source
zoxide init fish --cmd cd | source

function y
	set tmp (mktemp -t "yazi-cwd.XXXXXX")
	yazi $argv --cwd-file="$tmp"
	if read -z cwd < "$tmp"; and [ -n "$cwd" ]; and [ "$cwd" != "$PWD" ]
		builtin cd -- "$cwd"
	end
	rm -f -- "$tmp"
end

function ls
	command eza $argv
end

thefuck --alias | source
# fa运行fastfetch
abbr fa fastfetch
# f运行带二次元美少女的fastfetch
function f 
    command bash $HOME/.config/scripts/fastfetch-random-wife.sh
   end
# fzf安装软件包
function pac --description "Fuzzy search and install packages with accurate installed status"
    # --- 1. 环境与颜色配置 ---
    set -lx LC_ALL C 
    
    set color_official  "\033[34m"   # 蓝色
    set color_aur       "\033[35m"   # 紫色
    set color_installed "\033[32m"   # 绿色
    set color_reset     "\033[0m"

    set aur_filter '^(mingw-|lib32-|cross-|.*-debug$)'
    set preview_cmd 'yay -Si {2}'

    # 创建两个临时文件
    set target_file (mktemp -t pac_fzf.XXXXXX)
    set installed_list (mktemp -t pac_installed.XXXXXX)

    # --- 2. 准备工作：获取已安装列表 ---
    # 这比依赖 yay/pacman 的输出文本更可靠。
    # -Q: 查询, -q: 仅输出包名
    pacman -Qq > $installed_list

    # --- 3. 定义 AWK 处理逻辑 ---
    # 这段 awk 脚本比较复杂，为了复用，我们定义成变量
    # 逻辑：
    # 1. 如果读取的是第一个文件 (FNR==NR)，它是 installed_list，将其存入 map。
    # 2. 如果读取的是后续流，它是 pacman/yay 输出。检查包名($2)是否在 map 中。
    set awk_cmd '
        # 阶段1：加载已安装列表到内存
        FNR==NR {
            installed[$1]=1; 
            next 
        }
        # 阶段2：处理包列表流
        {
            status=""
            # 直接查表，极快且准确
            if ($2 in installed) {
                status = ci " ✔ [已装]" r
            }
            # 格式化输出
            printf "%s%-10s%s %-30s %-20s %s\n", c, $1, r, $2, $3, status
        }
    '

    # --- 4. 生成数据流并交互 ---
    begin
        # A. 官方源
        # 注意：这里把 $installed_list 放在前面传给 awk
        pacman -Sl | awk -v c=$color_official -v ci=$color_installed -v r=$color_reset \
            "$awk_cmd" $installed_list -

        # B. AUR 源
        # 注意：同样把 $installed_list 作为第一个参数传给 awk，"-" 代表标准输入
        yay -Sl aur | grep -vE "$aur_filter" | awk -v c=$color_aur -v ci=$color_installed -v r=$color_reset \
            "$awk_cmd" $installed_list -
            
    end | \
    fzf --multi --ansi \
        --preview $preview_cmd --preview-window=right:50%:wrap \
        --height=95% --layout=reverse --border \
        --tiebreak=index \
        --nth=2 \
        --header 'Tab:多选 | Enter:安装 | Esc:退出' \
        --query "$argv" \
    > $target_file

    # --- 5. 执行安装 ---
    if test -s $target_file
        set packages (cat $target_file | awk '{print $2}')
        if test -n "$packages"
            echo -e "\n$color_installed>> 准备安装:$color_reset"
            echo $packages
            echo "----------------------------------------"
            yay -S $packages
        end
    end

    # 清理临时文件
    rm -f $target_file $installed_list
end
# fzf卸载软件包
function pacr --description "Fuzzy find and remove packages (UI matched with pac)"
    # --- 配置区域 ---
    # 1. 定义颜色 (保持与 pac 一致)
    set color_official  "\033[34m"    
    set color_aur       "\033[35m"    
    set color_reset     "\033[0m"

    # --- 逻辑区域 ---
    # 预览命令：查询本地已安装详细信息 (-Qi)，目标是第2列(包名)
    set preview_cmd 'yay -Qi {2}'

    # 生成列表 -> 上色 -> fzf
    set packages (begin
        # 1. 官方源安装 (Native): 蓝色前缀 [local]
        pacman -Qn | awk -v c=$color_official -v r=$color_reset \
            '{printf "%s%-10s%s %-30s %s\n", c, "local", r, $1, $2}'

        # 2. AUR/外部源安装 (Foreign): 紫色前缀 [aur]
        pacman -Qm | awk -v c=$color_aur -v r=$color_reset \
            '{printf "%s%-10s%s %-30s %s\n", c, "aur", r, $1, $2}'
    end | \
    fzf --multi --ansi \
        --preview $preview_cmd --preview-window=right:60%:wrap \
        --height=95% --layout=reverse --border \
        --tiebreak=index \
        --nth=2 \
        --header 'Tab:多选 | Enter:卸载 | Esc:退出' \
        --query "$argv" | \
    awk '{print $2}') # 提取第2列纯净包名

    # --- 执行卸载 ---
    if test -n "$packages"
        echo "正在准备卸载: $packages"
        # -Rns: 递归删除配置文件和不再需要的依赖
        yay -Rns $packages
    end
end
