#!/usr/bin/env bash
# open-project.sh <dir | file.cockpit>: go to the project's window, or make one:
#   Neovim (file tree + git panel) on the left, the agent on the right (25%).
# A .cockpit file is a workspace of several repos (see workspace.sh).
set -euo pipefail
. "$(dirname "$0")/lib.sh"
src=${1:?usage: open-project.sh <dir | file.cockpit>}
if [[ -f $src && $src == *.cockpit ]]; then
  src=$(cd "$(dirname "$src")" && pwd -P)/$(basename "$src")
  dir=$("$IDE_HOME/workspace.sh" "$src")
  name=$(basename "$src" .cockpit)
else
  dir=$(cd "$src" && pwd -P)
  src=$dir
  name=$(basename "$dir")
fi
session=$(ide_session)

if w=$(project_window "$dir" "$session") && [[ -n $w ]]; then
  t select-window -t "$w"
  exit 0
fi

w=$(t new-window -P -F '#{window_id}' -t "$session:" -n "$name" -c "$dir" "$IDE_HOME/editor.sh '$dir'")
t set -w -t "$w" @root "$dir"
t set -w -t "$w" @src "$src"
t split-window -h -l "${IDE_AGENT_WIDTH:-25%}" -t "$w" -c "$dir" "$IDE_HOME/agent.sh '$dir'"
t select-pane -t "$w.1"

# Remember it, so `ide` reopens it after a reboot.
list=$(projects_file "$session")
touch "$list"
grep -qxF "$src" "$list" || echo "$src" >> "$list"
