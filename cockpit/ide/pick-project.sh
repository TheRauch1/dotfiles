#!/usr/bin/env bash
# prefix p: fuzzy-pick a git project under ~/dev (or $IDE_PROJECTS), or a
# workspace file (*.cockpit, several repos in one tab), and open it.
. "$(dirname "$0")/lib.sh"
root=${IDE_PROJECTS:-$HOME/dev}
list() {
  if command -v fd >/dev/null; then
    fd -H -t d -d 3 --prune '^\.git$' "$root" -x dirname {} 2>/dev/null
  else
    find "$root" -maxdepth 3 -name .git -type d -prune 2>/dev/null | xargs -n1 dirname
  fi | sort -u | sed "s|^$HOME/|~/|"
  # Workspaces first would hide repos while typing; list them after.
  find "$root" -maxdepth 3 -name '*.cockpit' -type f 2>/dev/null | sort | sed "s|^$HOME/|~/|"
}
if command -v fzf >/dev/null; then
  pick=$(list | fzf --prompt 'project> ' --height 100% --reverse --no-info)
else
  mapfile -t items < <(list)
  PS3='project> '
  select pick in "${items[@]}"; do break; done
fi
[[ -n ${pick:-} ]] || exit 0
exec "$IDE_HOME/open-project.sh" "${pick/#\~/$HOME}"
