# Shared bits for the ide scripts. Sourced, not run.
IDE_SOCKET=${IDE_SOCKET:-ide}
IDE_HOME=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
IDE_CONF="$IDE_HOME/tmux.conf"
IDE_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/cockpit-ide"
mkdir -p "$IDE_STATE"

t() { tmux -L "$IDE_SOCKET" -f "$IDE_CONF" "$@"; }

# The session we're in (scripts run from key bindings / popups), or $IDE_SESSION.
ide_session() {
  if [[ -n ${IDE_SESSION:-} ]]; then echo "$IDE_SESSION"; else t display -p '#S'; fi
}

# State file the agent of project $1 reports to (same JSON as the Neovim
# cockpit: {"state": "working"|"waiting"|"idle"|"blocked", "files": [...], "session": ...}).
state_file() { printf '%s/%s.json' "$IDE_STATE" "$(printf '%s' "$1" | sed 's/[^A-Za-z0-9._-]/%/g')"; }

projects_file() { printf '%s/%s.projects' "$IDE_STATE" "$1"; }

# Window (session:index) showing project $1 in session $2, if any.
project_window() {
  t list-windows -t "$2" -F '#{session_name}:#{window_index}	#{@root}' 2>/dev/null \
    | awk -F'\t' -v d="$1" '$2 == d { print $1; exit }'
}

json_field() { # json_field <file> <field>: a top-level string field, no jq needed
  sed -n "s/.*\"$2\":\"\\([^\"]*\\)\".*/\\1/p" "$1" 2>/dev/null | head -n1
}
