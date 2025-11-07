#!/bin/sh
set -eu

GKI_ROOT=$(pwd)

display_usage() {
    echo "Usage: $0 [--cleanup | <commit-or-tag>]"
    echo "  --cleanup:              Cleans up previous modifications made by the script."
    echo "  <commit-or-tag>:        Sets up or updates the KernelSU to specified tag or commit."
    echo "  -h, --help:             Displays this usage information."
    echo "  (no args):              Sets up or updates the KernelSU environment to the latest tagged version."
}

initialize_variables() {
    if test -d "$GKI_ROOT/common/drivers"; then
         DRIVER_DIR="$GKI_ROOT/common/drivers"
    elif test -d "$GKI_ROOT/drivers"; then
         DRIVER_DIR="$GKI_ROOT/drivers"
    else
         echo '[ERROR] "drivers/" directory not found.'
         exit 127
    fi

    DRIVER_MAKEFILE=$DRIVER_DIR/Makefile
    DRIVER_KCONFIG=$DRIVER_DIR/Kconfig
}

# Reverts modifications made by this script
perform_cleanup() {
    echo "[+] Cleaning up..."
    [ -L "$DRIVER_DIR/kernelsu" ] && rm "$DRIVER_DIR/kernelsu" && echo "[-] Symlink removed."
    grep -q "kernelsu" "$DRIVER_MAKEFILE" && sed -i '/kernelsu/d' "$DRIVER_MAKEFILE" && echo "[-] Makefile reverted."
    grep -q "drivers/kernelsu/Kconfig" "$DRIVER_KCONFIG" && sed -i '/drivers\/kernelsu\/Kconfig/d' "$DRIVER_KCONFIG" && echo "[-] Kconfig reverted."
    if [ -d "$GKI_ROOT/KernelSU" ]; then
        rm -rf "$GKI_ROOT/KernelSU" && echo "[-] KernelSU directory deleted."
    fi
}

# Sets up or update KernelSU environment
setup_kernelsu() {
    echo "[+] Setting up KernelSU..."
    
    # 处理参数
    local target_spec=""
    local checkout_type="auto"
    
    if [ -n "${1-}" ]; then
        target_spec="$1"
        echo "[+] Target specified: $target_spec"
        
        # 尝试判断指定的是分支、标签还是提交
        if [[ "$target_spec" =~ ^[0-9a-f]{7,40}$ ]]; then
            checkout_type="commit"
            echo "[+] Detected commit hash"
        elif git ls-remote --tags origin | grep -q "refs/tags/$target_spec$"; then
            checkout_type="tag"
            echo "[+] Detected tag"
        elif git ls-remote --heads origin | grep -q "refs/heads/$target_spec$"; then
            checkout_type="branch"
            echo "[+] Detected branch"
        else
            checkout_type="auto"
            echo "[+] Type not determined, will try auto-detection"
        fi
    fi
    
    # Clone the repository and rename it to KernelSU
    if [ ! -d "$GKI_ROOT/KernelSU" ]; then
        git clone https://github.com/SukiSU-Ultra/SukiSU-Ultra SukiSU-Ultra
        mv SukiSU-Ultra KernelSU
        echo "[+] Repository cloned and renamed to KernelSU."
    fi
    
    cd "$GKI_ROOT/KernelSU"
    
    # 保存当前状态
    local current_branch=$(git branch --show-current 2>/dev/null || echo "detached")
    echo "[-] Current branch: $current_branch"
    
    git stash && echo "[-] Stashed current changes."
    
    # 更新仓库到最新状态
    echo "[+] Fetching updates..."
    git fetch --all --tags
    
    # 根据参数类型进行相应的检出操作
    if [ -n "$target_spec" ]; then
        echo "[+] Attempting to checkout: $target_spec (type: $checkout_type)"
        
        case "$checkout_type" in
            "branch")
                # 检出分支并更新到最新
                if git checkout "$target_spec" 2>/dev/null; then
                    echo "[-] Successfully checked out branch: $target_spec"
                    git pull origin "$target_spec" && echo "[+] Updated branch to latest"
                else
                    echo "[!] Failed to checkout branch: $target_spec"
                    checkout_fallback
                fi
                ;;
            "tag")
                # 检出标签
                if git checkout "refs/tags/$target_spec" 2>/dev/null || git checkout "$target_spec" 2>/dev/null; then
                    echo "[-] Successfully checked out tag: $target_spec"
                else
                    echo "[!] Failed to checkout tag: $target_spec"
                    checkout_fallback
                fi
                ;;
            "commit")
                # 检出特定提交
                if git checkout "$target_spec" 2>/dev/null; then
                    echo "[-] Successfully checked out commit: $target_spec"
                else
                    echo "[!] Failed to checkout commit: $target_spec"
                    checkout_fallback
                fi
                ;;
            "auto")
                # 自动检测类型
                if git checkout "$target_spec" 2>/dev/null; then
                    echo "[-] Successfully checked out: $target_spec"
                    # 如果是分支，则更新到最新
                    if git symbolic-ref -q HEAD >/dev/null; then
                        git pull && echo "[+] Updated to latest"
                    fi
                else
                    echo "[!] Failed to checkout: $target_spec"
                    checkout_fallback
                fi
                ;;
        esac
    else
        # 没有指定时使用最新标签
        checkout_fallback
    fi
    
    # 显示当前状态信息
    echo "[+] Current status:"
    echo "    Branch: $(git branch --show-current 2>/dev/null || echo 'detached')"
    echo "    Commit: $(git log --oneline -1)"
    echo "    Description: $(git describe --tags 2>/dev/null || git rev-parse --short HEAD)"
    
    cd "$DRIVER_DIR"
    ln -sf "$(realpath --relative-to="$DRIVER_DIR" "$GKI_ROOT/KernelSU/kernel")" "kernelsu" && echo "[+] Symlink created."

    # Add entries in Makefile and Kconfig if not already existing
    grep -q "kernelsu" "$DRIVER_MAKEFILE" || printf "\nobj-\$(CONFIG_KSU) += kernelsu/\n" >> "$DRIVER_MAKEFILE" && echo "[+] Modified Makefile."
    grep -q "source \"drivers/kernelsu/Kconfig\"" "$DRIVER_KCONFIG" || sed -i "/endmenu/i\source \"drivers/kernelsu/Kconfig\"" "$DRIVER_KCONFIG" && echo "[+] Modified Kconfig."
    echo '[+] Done.'
}

# 回退函数：切换到最新标签
checkout_fallback() {
    echo "[!] Falling back to latest tag..."
    local latest_tag=$(git describe --abbrev=0 --tags 2>/dev/null)
    if [ -n "$latest_tag" ]; then
        git checkout "$latest_tag" && echo "[-] Checked out latest tag: $latest_tag"
    else
        echo "[!] No tags found, staying on current branch"
        git checkout main 2>/dev/null || git checkout master 2>/dev/null || echo "[!] Could not checkout main/master"
    fi
}

# 辅助函数：列出可用的分支和标签
list_kernelsu_refs() {
    if [ ! -d "$GKI_ROOT/KernelSU" ]; then
        echo "[!] KernelSU directory not found"
        return 1
    fi
    
    cd "$GKI_ROOT/KernelSU"
    echo "[+] Available branches:"
    git branch -r | grep -v '\->' | head -10
    echo ""
    echo "[+] Recent tags:"
    git tag -l --sort=-version:refname "v*" | head -10
    echo ""
    echo "[+] Recent commits:"
    git log --oneline -10
    cd - >/dev/null
}

# Process command-line arguments
if [ "$#" -eq 0 ]; then
    initialize_variables
    setup_kernelsu
elif [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    display_usage
elif [ "$1" = "--cleanup" ]; then
    initialize_variables
    perform_cleanup
else
    initialize_variables
    setup_kernelsu "$@"
fi