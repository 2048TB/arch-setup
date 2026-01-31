#!/usr/bin/env python3

import subprocess
import json
import sys
import shutil
import os

# ================= Configuration =================
# 定义菜单窗口的专属 App ID，用于识别是否已打开
MENU_APP_ID = "niri-quick-switch-menu"

# 排除列表：把菜单自己也排除掉
EXCLUDE_APPS = ["quick-switch", "niri-quick-switch", MENU_APP_ID]

FZF_ARGS = [
    "--reverse", 
    "--height=100%", 
    "--header=Switch Window", 
    "--info=inline",
    "--border",
    "--margin=0",    # 紧凑风格
    "--padding=0",
    "--delimiter= ",
]
# =================================================

def run_cmd(cmd):
    try:
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
        if result.returncode != 0: return None
        if "-j" in cmd:
            return json.loads(result.stdout)
        return result.stdout
    except Exception: return None

def get_fzf_path():
    path = shutil.which("fzf")
    if path: return path
    if os.path.exists("/usr/bin/fzf"): return "/usr/bin/fzf"
    if os.path.exists("/usr/local/bin/fzf"): return "/usr/local/bin/fzf"
    return None

def wait_and_exit(msg, exit_code=0):
    print(f"\nℹ️  {msg}")
    try:
        input("\n[ 按回车键关闭 ]")
    except KeyboardInterrupt:
        pass
    sys.exit(exit_code)

def get_active_workspace_id():
    workspaces = run_cmd("niri msg -j workspaces")
    if not workspaces: return None
    for ws in workspaces:
        if ws.get("is_focused"): return ws.get("id")
    return None

def get_window_sort_key(w):
    if w.get("is_floating"):
        return (99999, 0, w.get("id"))
    try:
        layout = w.get("layout", {})
        pos = layout.get("pos_in_scrolling_layout")
        if pos and isinstance(pos, list) and len(pos) >= 2:
            return (pos[0], pos[1], w.get("id"))
    except Exception:
        pass
    return (9999, 0, w.get("id"))

# --- 核心逻辑区分 ---

def launch_menu_interface():
    """
    启动模式：检查是否已打开，决定是聚焦还是新建
    """
    windows = run_cmd("niri msg -j windows")
    if windows:
        # 1. 检查是否存在 MENU_APP_ID 的窗口
        existing_menu = None
        for w in windows:
            if w.get("app_id") == MENU_APP_ID:
                existing_menu = w
                break
        
        # 2. 如果存在，聚焦它并退出 (防止重复打开)
        if existing_menu:
            win_id = existing_menu.get("id")
            # print(f"Menu already open (ID: {win_id}), focusing...")
            subprocess.run(["niri", "msg", "action", "focus-window", "--id", str(win_id)])
            sys.exit(0)

    # 3. 如果不存在，启动 Kitty 并运行本脚本的“内部模式”
    # 获取当前脚本的绝对路径
    script_path = os.path.abspath(__file__)
    
    try:
        subprocess.Popen([
            "kitty", 
            "--class", MENU_APP_ID, 
            "-e", "python3", script_path, "--internal-run"
        ])
    except Exception as e:
        subprocess.run(["notify-send", "Error", f"Failed to launch kitty: {e}"])
        sys.exit(1)

def run_fzf_logic():
    """
    内部模式：实际的 FZF 逻辑
    """
    fzf_bin = get_fzf_path()
    if not fzf_bin: wait_and_exit("错误: 找不到 fzf 命令，请先安装。", 1)

    ws_id = get_active_workspace_id()
    if ws_id is None: wait_and_exit("错误: 无法获取当前工作区 ID。", 1)

    windows = run_cmd("niri msg -j windows")
    if not windows: wait_and_exit("当前系统没有任何窗口。")

    current_windows = []
    for w in windows:
        if w.get("workspace_id") != ws_id:
            continue
        
        # 排除
        app_id = w.get("app_id") or ""
        if app_id in EXCLUDE_APPS:
            continue
            
        current_windows.append(w)

    if not current_windows: wait_and_exit("当前工作区没有窗口。")

    # 排序
    current_windows.sort(key=get_window_sort_key)

    # 构建列表
    input_str = ""
    mapping = {} 

    for idx, w in enumerate(current_windows):
        mapping[idx] = w.get("id")
        app_id = w.get("app_id") or "Wayland"
        title = w.get("title", "No Title").replace("\n", " ")
        display_str = f"{idx} [{app_id}] {title}"
        input_str += f"{display_str}\n"

    try:
        cmd = [fzf_bin] + FZF_ARGS + ["--with-nth=2.."]
        
        proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True
        )
        stdout, _ = proc.communicate(input=input_str)

        if stdout.strip():
            selected_line = stdout.strip()
            selected_idx = int(selected_line.split()[0])
            target_id = mapping.get(selected_idx)
            
            if target_id:
                subprocess.run(["niri", "msg", "action", "focus-window", "--id", str(target_id)])

    except Exception as e:
        wait_and_exit(f"发生未知错误: {str(e)}", 1)

if __name__ == "__main__":
    # 检查命令行参数
    if len(sys.argv) > 1 and sys.argv[1] == "--internal-run":
        # 如果有标志，运行 FZF 界面
        run_fzf_logic()
    else:
        # 如果没有标志，作为启动器运行
        launch_menu_interface()
