# Doom Emacs shell integration (sourced from ~/.zshrc and ~/.bashrc; works in both)

export PATH="$HOME/.config/emacs/bin:$HOME/.local/share/mise/shims:$HOME/.local/go/bin:$HOME/go/bin:$PATH"
export COLORTERM=truecolor

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

export EDITOR="emacsclient -t -a ''"
export VISUAL="$EDITOR"

# Overlays (~/.config/dotfiles.d/<name>/shell.sh), see README "Overlays".
for f in $(find -L "${DOTFILES_D:-$HOME/.config/dotfiles.d}" -mindepth 2 -maxdepth 2 -name shell.sh 2>/dev/null | sort); do
  . "$f"
done
