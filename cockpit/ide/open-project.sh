#!/usr/bin/env bash
# open-project.sh <dir>: go to the project's window, or make one:
#   Neovim (file tree + git panel) on the left, the agent on the right (25%).
set -euo pipefail
. "$(dirname "$0")/lib.sh"
dir=$(cd "${1:?usage: open-project.sh <dir>}" && pwd -P)
session=$(ide_session)

if w=$(project_window "$dir" "$session") && [[ -n $w ]]; then
  t select-window -t "$w"
  exit 0
fi

name=$(basename "$dir")
w=$(t new-window -P -F '#{window_id}' -t "$session:" -n "$name" -c "$dir" "$IDE_HOME/editor.sh '$dir'")
t set -w -t "$w" @root "$dir"
t split-window -h -l "${IDE_AGENT_WIDTH:-25%}" -t "$w" -c "$dir" "$IDE_HOME/agent.sh '$dir'"
t select-pane -t "$w.1"

# Remember it, so `ide` reopens it after a reboot.
list=$(projects_file "$session")
touch "$list"
grep -qxF "$dir" "$list" || echo "$dir" >> "$list"
