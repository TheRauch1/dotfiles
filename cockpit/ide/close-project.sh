#!/usr/bin/env bash
# prefix X: close this project's window and forget it (not reopened by `ide`).
. "$(dirname "$0")/lib.sh"
session=$(ide_session)
root=$(t display -p '#{@root}')
if [[ -n $root ]]; then
  list=$(projects_file "$session")
  [[ -f $list ]] && grep -vxF "$root" "$list" > "$list.tmp"; mv -f "$list.tmp" "$list" 2>/dev/null
fi
t kill-window
