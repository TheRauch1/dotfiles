#!/usr/bin/env bash
# prefix w: jump to the next project whose agent waits for you.
. "$(dirname "$0")/lib.sh"
session=$(ide_session)
cur=$(t display -p '#{window_index}')
best=
while IFS=$'\t' read -r idx root; do
  [[ -n $root ]] || continue
  s=$(json_field "$(state_file "$root")" state)
  [[ $s == waiting || $s == blocked ]] || continue
  if (( idx > cur )); then best=$idx; break; fi
  [[ -z $best ]] && best=$idx
done < <(t list-windows -t "$session" -F '#{window_index}	#{@root}')
if [[ -n $best ]]; then t select-window -t "$session:$best"; else t display-message "No agent is waiting for you"; fi
