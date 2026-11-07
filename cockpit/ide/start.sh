#!/usr/bin/env bash
# Start an ide session (detached): a home shell, then every project that was
# open last time, each with its editor and agent resuming where they were.
. "$(dirname "$0")/lib.sh"
session=${1:-ide}
export IDE_SESSION=$session
# Start at the real terminal size, so the 25 % agent pane is right from the start.
t new-session -d -s "$session" -x "${COLUMNS:-$(tput cols 2>/dev/null || echo 120)}" -y "${LINES:-$(tput lines 2>/dev/null || echo 34)}" -n home -c "${IDE_PROJECTS:-$HOME/dev}" \
  "printf '\\n  ide: prefix (Ctrl+b) then p = open a project, ? = all keys\\n\\n'; exec \"\${SHELL:-bash}\""
list=$(projects_file "$session")
first=
if [[ -f $list ]]; then
  while IFS= read -r dir; do
    [[ -d $dir ]] || continue
    "$IDE_HOME/open-project.sh" "$dir"
    [[ -n $first ]] || first=$dir
  done < "$list"
fi
if [[ -n $first ]]; then
  t select-window -t "$(project_window "$first" "$session")"
else
  # Nothing to restore: show the project picker as soon as you attach.
  t set-hook -t "$session" client-attached \
    "set-hook -u -t '$session' client-attached ; display-popup -E -w 70% -h 60% '$IDE_HOME/pick-project.sh'"
fi
