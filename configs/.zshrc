############################################
# 加载共享环境变量
############################################
[ -f "$HOME/.config/shell/env" ] && . "$HOME/.config/shell/env"

############################################
# Zinit 插件管理器
############################################
if [[ ! -f $HOME/.local/share/zinit/zinit.git/zinit.zsh ]]; then
    print -P "%F{33} %F{220}Installing %F{33}ZDHARMA-CONTINUUM%F{220} Initiative Plugin Manager (%F{33}zdharma-continuum/zinit%F{220})…%f"
    command mkdir -p "$HOME/.local/share/zinit" && command chmod g-rwX "$HOME/.local/share/zinit"
    command git clone https://github.com/zdharma-continuum/zinit "$HOME/.local/share/zinit/zinit.git" && \
        print -P "%F{33} %F{34}Installation successful.%f%b" || \
        print -P "%F{160} The clone has failed.%f%b"
fi
source "$HOME/.local/share/zinit/zinit.git/zinit.zsh"
autoload -Uz _zinit
(( ${+_comps} )) && _comps[zinit]=_zinit

############################################
# 历史记录设置
############################################
HISTFILE=~/.zsh_history
HISTSIZE=50000
SAVEHIST=50000
setopt append_history
setopt share_history
setopt hist_ignore_all_dups
setopt hist_ignore_space
setopt hist_reduce_blanks

############################################
# Zinit 插件（syntax-highlighting 必须最后加载）
############################################
zinit light zsh-users/zsh-autosuggestions
zinit light zsh-users/zsh-completions
zinit light zsh-users/zsh-history-substring-search
zinit light zsh-users/zsh-syntax-highlighting

############################################
# Starship 提示符
############################################
eval "$(starship init zsh)"

############################################
# Yazi 文件管理器
############################################
function y() {
    local tmp="$(mktemp -t "yazi-cwd.XXXXXX")" cwd
    yazi "$@" --cwd-file="$tmp"
    IFS= read -r -d '' cwd < "$tmp"
    [ -n "$cwd" ] && [ "$cwd" != "$PWD" ] && builtin cd -- "$cwd"
    rm -f -- "$tmp"
}

############################################
# Zoxide
############################################
eval "$(zoxide init zsh)"

############################################
# FZF
############################################
command -v fzf >/dev/null 2>&1 && source <(fzf --zsh)

############################################
# Claude Code 快捷命令
############################################
function ccv() {
    local env_vars=(
        "ENABLE_BACKGROUND_TASKS=true"
        "FORCE_AUTO_BACKGROUND_TASKS=true"
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=true"
        "CLAUDE_CODE_ENABLE_UNIFIED_READ_TOOL=true"
    )

    local claude_args=("--dangerously-skip-permissions")

    if [[ "$1" == "r" ]]; then
        claude_args+=("--resume")
    fi

    env "${env_vars[@]}" claude "${claude_args[@]}"
}

############################################
# Eza (现代版 ls)
############################################
if command -v eza >/dev/null 2>&1; then
    alias ls='eza'
    alias ll='eza -l'
    alias la='eza -la'
    alias lt='eza --tree'
fi

############################################
# Zellij 终端多工器
############################################
if command -v zellij >/dev/null 2>&1; then
    alias zj='zellij'
    alias zja='zellij attach'
    alias zjl='zellij list-sessions'
fi

############################################
# GPG TTY 设置（Git 签名需要）
############################################
if [ -n "$TTY" ]; then
    export GPG_TTY=$(tty)
fi

############################################
# Bun 补全
############################################
[ -s "$BUN_INSTALL/_bun" ] && source "$BUN_INSTALL/_bun"

# 全局搜索
frg() {
  local depth=""
  case "$1" in
    l|1)   depth="--max-depth 1" ;;   # 输入 frg l 或 frg 1 表示仅当前目录
  esac

  fzf --ansi \
    --bind "change:reload:
      if [[ -n {q} ]]; then
        rg $depth --line-number --no-heading --color=always {q};
      else
        rg $depth --files;
      fi || true" \
    --preview "bat --style=numbers --color=always --highlight-line {2} {1}" \
    --delimiter ":"
}

# 合并txt
hbtxt() {
  local out="merged_unique.txt"

  find . -type f -name "*.txt" ! -name "$out" \
    -exec awk 'NF && !seen[$0]++' {} + \
    > "$out"
}
#
