# Doom Emacs shell integration (sourced from ~/.zshrc and ~/.bashrc; works in both)

export PATH="$HOME/.config/emacs/bin:$HOME/.local/share/mise/shims:$HOME/.local/go/bin:$HOME/go/bin:$PATH"
export COLORTERM=truecolor

# A terminal the server doesn't know (e.g. Ghostty's xterm-ghostty over SSH)
# breaks tmux, nvim and tput. Fall back to a common one; colors stay 24-bit
# via COLORTERM. Better: install the terminfo once, from the client:
#   infocmp -x xterm-ghostty | ssh host -- tic -x -
if [ -n "$TERM" ] && command -v infocmp >/dev/null 2>&1 && ! infocmp "$TERM" >/dev/null 2>&1; then
  export TERM=xterm-256color
fi

# Open in the running Emacs daemon (starts one if missing). Survives SSH drops.
e() { emacsclient -t -a '' "${@:-.}"; }
alias ekill="emacsclient -e '(kill-emacs)'"
# Always in the terminal: DISPLAY is often set (e.g. a multiplexer started on
# the desktop), and a GUI window there is invisible from the iPad.
alias emacs='emacs -nw'

# pd [dir]: live diff of the repo in this terminal. It refreshes itself as
# files change (e.g. while pi works in another herdr pane). Same as SPC g d.
pd() {
  local root
  root=$(git -C "${1:-$PWD}" rev-parse --show-toplevel 2>/dev/null) \
    || { echo "pd: not inside a git repo"; return 1; }
  emacsclient -t -a '' -e "(+live-diff \"$root/\")"
}

# dev [name]: your projects and their agents, in one Neovim that survives
# SSH drops and laptop restarts. Reattaches if it's running (taking over
# from another device), else starts Neovim and restores the projects you
# had open (and resumes each agent with Alt+a). `name` keeps separate
# setups apart (e.g. dev work, dev home); `dev ls` lists them.
dev() {
  local name=${1:-default} conf="$HOME/.config/cockpit/tmux.conf"
  if [[ $name == ls ]]; then
    tmux -L cockpit ls 2>/dev/null || echo "(none running)"
    ls "${XDG_STATE_HOME:-$HOME/.local/state}/nvim/cockpit/" 2>/dev/null | sed -n 's/\.json$//p' | sed 's/^/saved: /'
    return
  fi
  local nv="COCKPIT_NAME=$name nvim --cmd 'let g:cockpit_restore=1'"
  if ! command -v tmux >/dev/null; then eval "$nv"; return; fi
  TMUX= tmux -L cockpit -f "$conf" new-session -A -D -s "$name" "$nv"
}

# ide [name]: the other layout, with tmux in charge. One tab per project,
# Neovim on the left, the agent on the right (25%), lazygit on prefix g.
# Reattaches if running; after a reboot reopens every project and continues
# each agent's conversation. Keys: Ctrl+b ? (cockpit/ide/KEYS).
ide() {
  local name=${1:-ide} home="$HOME/.config/cockpit/ide"
  command -v tmux >/dev/null || { echo "ide needs tmux (sudo apt install tmux / brew install tmux)"; return 1; }
  tmux -L ide has-session -t "=$name" 2>/dev/null || COLUMNS=$(tput cols) LINES=$(tput lines) "$home/start.sh" "$name"
  TMUX= tmux -L ide -f "$home/tmux.conf" attach -d -t "=$name"
}

export EDITOR="emacsclient -t -a ''"
export VISUAL="$EDITOR"

# Overlays (~/.config/dotfiles.d/<name>/shell.sh), see README "Overlays".
for f in $(find -L "${DOTFILES_D:-$HOME/.config/dotfiles.d}" -mindepth 2 -maxdepth 2 -name shell.sh 2>/dev/null | sort); do
  . "$f"
done
