#!/usr/bin/env bash
# prefix R: reopen this project (or workspace) in place: a fresh editor and
# agent in the same tab position, and a workspace's .cockpit file read again.
# Neovim comes back with its files and cursor, the agent with its last
# conversation. Neovim is quit with :qa, so unsaved changes stop the reload.
. "$(dirname "$0")/lib.sh"
session=$(ide_session)
old=$(t display -p '#{window_id}')
src=$(t display -p -t "$old" '#{@src}')
dir=$(t display -p -t "$old" '#{@root}')
if [[ -z $src || -z $dir ]]; then
  t display-message "Not a project tab (prefix p opens one)"
  exit 0
fi

# An agent in the middle of a task gets cut off: ask first.
if [[ ${1:-} != --force && $(json_field "$(state_file "$dir")" state) == working ]]; then
  t confirm-before -p "The agent is working. Reload anyway? (y/n)" "run-shell '$IDE_HOME/reload-project.sh --force'"
  exit 0
fi

# Quit Neovim cleanly (it saves its files and cursor for the restore).
# editor.sh runs it without job control, so tmux names the pane "bash":
# look for nvim among the pane's child processes instead.
read -r editor pid < <(t list-panes -t "$old" -F '#{pane_index} #{pane_id} #{pane_pid}' | awk '$1 == 1 { print $2, $3 }')
nvim_running() { [[ -n ${pid:-} ]] && pgrep -P "$pid" -x nvim >/dev/null; }
if nvim_running; then
  t send-keys -t "$editor" C-\\ C-n Escape ':qa' Enter
  for _ in {1..30}; do
    nvim_running || break
    sleep 0.1
  done
  if nvim_running; then
    t display-message "Neovim has unsaved changes: save them (or :qa!) and reload again"
    exit 0
  fi
fi

# Open it again as a new window, put that where the old one was, drop the old one.
t set -w -u -t "$old" @root
t set -w -u -t "$old" @src
if ! IDE_SESSION=$session "$IDE_HOME/open-project.sh" "$src" 2>"$IDE_STATE/reload.err"; then
  t set -w -t "$old" @root "$dir"
  t set -w -t "$old" @src "$src"
  t display-message "Reload failed: $(tail -n1 "$IDE_STATE/reload.err")"
  exit 1
fi
new=$(t display -p -t "$(project_window "$dir" "$session")" '#{window_id}')
t swap-window -s "$new" -t "$old"
t kill-window -t "$old"
t select-window -t "$new"
