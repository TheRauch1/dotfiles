#!/usr/bin/env bash
# prefix g / Alt+g: lazygit for the repo you're looking at.
#   In the editor: the repo of the current file (Neovim reports it as @git_root).
#   Elsewhere: the repo of the pane's folder. In a workspace folder (several
#   repos, see workspace.sh): pick one first.
# Runs in a popup started in the pane's folder (display-popup -d).
. "$(dirname "$0")/lib.sh"
path=${1:-$PWD}
root=${2-$(t display -p '#{@git_root}' 2>/dev/null)}
if [[ -z $root || ! -d $root ]]; then
  root=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null)
fi
if [[ -z $root ]]; then
  mapfile -t repos < <(for d in "$path"/*/; do [[ -e $d.git ]] && basename "$d"; done)
  case ${#repos[@]} in
    0) echo "No git repo here ($path)."; read -rsn1; exit 0 ;;
    1) pick=${repos[0]} ;;
    *) if command -v fzf >/dev/null; then
         pick=$(printf '%s\n' "${repos[@]}" | fzf --prompt 'repo> ' --height 100% --reverse --no-info)
       else
         PS3='repo> '; select pick in "${repos[@]}"; do break; done
       fi ;;
  esac
  [[ -n ${pick:-} ]] || exit 0
  root="$path/$pick"
fi
cd "$root" && exec lazygit
