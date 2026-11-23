#!/usr/bin/env bash
# prefix Q: restart the ide tmux server, so tmux, Neovim and the agents all
# run what is installed now (after a git pull + setup.sh, or a pi update).
# Every project comes back as after a reboot: Neovim with its files and
# cursor, the agent with its last conversation, and `ide` reattaches you to
# the tab you were on. Every session on the server restarts; the home tab's
# shell and popups don't come back.
# Neovim is quit with :qa first, so unsaved changes stop the restart.
. "$(dirname "$0")/lib.sh"

# Project tabs on the whole server: window id, tab name, project dir.
wins=()
while IFS= read -r line; do wins+=("$line"); done < <(
  t list-windows -a -F '#{window_id}	#{window_name}	#{@root}' | awk -F'\t' '$3 != ""')

# Agents in the middle of a task get cut off: ask first.
if [[ ${1:-} != --force ]]; then
  busy=()
  for w in "${wins[@]}"; do
    IFS=$'\t' read -r _ name dir <<<"$w"
    [[ $(json_field "$(state_file "$dir")" state) == working ]] && busy+=("$name")
  done
  if (( ${#busy[@]} )); then
    t confirm-before -p "Agent working in ${busy[*]}. Restart anyway? (y/n)" "run-shell '$IDE_HOME/restart.sh --force'"
    exit 0
  fi
fi

# Quit every Neovim (it saves its files and cursor for the restore).
# editor.sh runs it without job control, so tmux names the pane "bash":
# look for nvim among the editor pane's child processes instead.
nvim_running() { pgrep -P "$1" -x nvim >/dev/null; }
quitting=()   # window id, editor pane, its pid, tab name, project dir
for w in "${wins[@]}"; do
  IFS=$'\t' read -r id name dir <<<"$w"
  pane= pid=
  read -r pane pid < <(t list-panes -t "$id" -F '#{pane_index} #{pane_id} #{pane_pid}' | awk '$1 == 1 { print $2, $3 }')
  if [[ -n ${pid:-} ]] && nvim_running "$pid"; then
    t send-keys -t "$pane" C-\\ C-n Escape ':qa' Enter
    quitting+=("$id	$pane	$pid	$name	$dir")
  fi
done
for _ in {1..30}; do
  left=0
  for q in "${quitting[@]}"; do
    IFS=$'\t' read -r _ _ pid _ _ <<<"$q"
    nvim_running "$pid" && left=1
  done
  (( left )) || break
  sleep 0.1
done

# A Neovim that is still running has unsaved changes: bring the others back
# as they were and leave the server running.
stuck=() stuck_win= stuck_pane=
for q in "${quitting[@]}"; do
  IFS=$'\t' read -r id pane pid name _ <<<"$q"
  if nvim_running "$pid"; then
    stuck+=("$name")
    [[ -n $stuck_win ]] || { stuck_win=$id stuck_pane=$pane; }
  fi
done
if (( ${#stuck[@]} )); then
  for q in "${quitting[@]}"; do
    IFS=$'\t' read -r _ pane pid _ dir <<<"$q"
    nvim_running "$pid" || t respawn-pane -k -t "$pane" "$IDE_HOME/editor.sh '$dir'"
  done
  t select-window -t "$stuck_win"
  t select-pane -t "$stuck_pane"
  t display-message "Neovim has unsaved changes in ${stuck[*]}: save them (or :qa!) and restart again"
  exit 0
fi

# Leave a note per session for `ide` (bin/ide): the server that is going
# away and the tab to come back to. Then restart.
server=$(t display -p '#{pid}')
while IFS= read -r s; do
  printf '%s\n%s\n' "$server" "$(t display -p -t "=$s:" '#{@src}')" > "$IDE_STATE/$s.restart"
done < <(t list-sessions -F '#{session_name}')
t kill-server
