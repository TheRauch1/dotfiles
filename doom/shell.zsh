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

export EDITOR="emacsclient -t -a ''"
export VISUAL="$EDITOR"
