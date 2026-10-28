#!/usr/bin/env bash
#
# rex-sessionizer picker. Started by init.lua in a floating terminal; see
# that file for the Lua side.
#
#   sessionizer.sh --work-dir DIR [--current LABEL]
#   sessionizer.sh --work-dir DIR [--current LABEL] --list
#
# Basic behavior:
# - Lists directories inside the work dir as options in a fuzzy picker (fzf)
# - Hands the chosen directory to Rex with `rex do sessionizer_go`, which
#   creates or finds the session and asks the app to show it (this needs
#   Remote Control on in Rex → Settings → Rex Server)
# - Current session is always placed at the bottom of the list for easy switching
#
# Smart nested directory handling:
# - If the current project only contains subdirectories (no files),
#   those subdirectories are shown at the top of the picker
# - If the current project's parent only contains directories,
#   all sibling directories are shown at the top
# - Top-level work directories are always available at the bottom of the list
#
# Example structure:
#   ~/work/
#   ├── project1/
#   └── project2/
#       ├── project2-fe/
#       └── project2-be/
#
# Picker shows:
# - When not in project2: project1, project2
# - When in project2 or its subdirectories: project2-fe, project2-be, project1, project2
#
# --list prints the candidates in picker order and exits, for debugging.

set -euo pipefail

work_dir="$HOME/work"
current=""
list_only=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --work-dir) work_dir=$2; shift 2 ;;
        --current)  current=$2;  shift 2 ;;
        --list)     list_only=true; shift ;;
        *) echo "sessionizer: unknown option: $1" >&2; exit 2 ;;
    esac
done
work_dir=${work_dir%/}

# Functions
has_only_directories() {
    local dir=$1
    # Count non-directory items *excluding* .DS_Store
    local non_dirs
    non_dirs=$(find "$dir" -mindepth 1 -maxdepth 1 ! -type d ! -name ".DS_Store" 2>/dev/null | wc -l)

    # True if: no non-dir items AND at least one subdirectory exists
    [[ $non_dirs -eq 0 ]] && [[ -n "$(find "$dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)" ]]
}

subdirectories() {
    find "$1" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -f
}

get_top_level_directories() {
    subdirectories "$work_dir"
}

# The directory of the current session: the one (up to two levels deep) whose
# name is the session's label.
find_current_directory() {
    local label=$1
    [[ -z $label ]] && return 0
    find "$work_dir" -mindepth 1 -maxdepth 2 -type d 2>/dev/null | while IFS= read -r dir; do
        if [[ "$(basename "$dir")" == "$label" ]]; then
            echo "$dir"
            return
        fi
    done
}

find_work_directories() {
    local current_dir=$1

    # If not in a project, just show top-level directories
    if [[ -z $current_dir ]]; then
        get_top_level_directories
        return
    fi

    local parent_dir
    parent_dir=$(dirname "$current_dir")
    local context_dirs=""

    # Check if current directory only has subdirectories
    if has_only_directories "$current_dir"; then
        # Show subdirectories of current directory
        context_dirs=$(subdirectories "$current_dir")
    # Check if parent only has directories and parent is not work root
    elif [[ "$parent_dir" != "$work_dir" ]] && has_only_directories "$parent_dir"; then
        # Show sibling directories (including current)
        context_dirs=$(subdirectories "$parent_dir")
    fi

    # If we have context directories, show them first, then top-level
    if [[ -n $context_dirs ]]; then
        printf "%s\n%s\n" "$context_dirs" "$(get_top_level_directories)"
    else
        get_top_level_directories
    fi
}

# Candidates in picker order: context dirs, top-level dirs, current dir last.
candidates() {
    local current_dir=$1
    local all_dirs
    all_dirs=$(find_work_directories "$current_dir")

    if [[ -n $current_dir ]] && grep -qxF "$current_dir" <<< "$all_dirs"; then
        grep -vxF "$current_dir" <<< "$all_dirs" || true
        echo "$current_dir"
    else
        echo "$all_dirs"
    fi
}

# Main script
main() {
    local current_dir
    current_dir=$(find_current_directory "$current")

    if $list_only; then
        candidates "$current_dir"
        return
    fi

    local header="Switch project"
    [[ -n $current ]] && header="Current session: $current"

    local selected
    selected=$(candidates "$current_dir" | sed "s|^$HOME/||" |
        fzf --header="$header" --prompt="project> ") || true

    [[ -z $selected ]] && return
    [[ $selected == /* ]] || selected="$HOME/$selected"

    # shellcheck disable=SC1010
    if ! rex do sessionizer_go path="$selected" >/dev/null; then
        echo
        echo "Could not switch to $selected." >&2
        echo "If the error above mentions Remote Control, turn it on in Rex → Settings → Rex Server." >&2
        read -r -p "Press Enter to close…"
    fi
}

main
