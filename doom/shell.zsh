# Doom Emacs shell integration (sourced from ~/.zshrc)

export PATH="$HOME/.config/emacs/bin:$HOME/.local/go/bin:$HOME/go/bin:$PATH"
export COLORTERM=truecolor

# Open in the running Emacs daemon (starts one if missing). Survives SSH drops.
e() { emacsclient -t -a '' "${@:-.}"; }
alias ekill="emacsclient -e '(kill-emacs)'"

# pd [dir]: pi + live diff side by side (stacked on narrow screens).
# Run inside or outside tmux. Tap a pane (or prefix + arrow) to switch.
pd() {
  local root
  root=$(git -C "${1:-$PWD}" rev-parse --show-toplevel 2>/dev/null) \
    || { echo "pd: not inside a git repo"; return 1; }
  local diff="emacsclient -t -a '' -e '(+live-diff \"$root/\")'"
  if [[ -z $TMUX ]]; then
    tmux new-session -d -s "pi-${root:t}" -c "$root" 2>/dev/null || {
      tmux attach -t "pi-${root:t}"; return; }
    tmux send-keys -t "pi-${root:t}" "pd" Enter
    tmux attach -t "pi-${root:t}"
    return
  fi
  local split=-h
  (( $(tmux display -p '#{window_width}') < 140 )) && split=-v
  tmux split-window $split -b -l 55% -c "$root"   # diff: left / top
  tmux send-keys "$diff" Enter
  tmux select-pane -l                              # back to this pane
  cd "$root" && pi
}

export EDITOR="emacsclient -t -a ''"
export VISUAL="$EDITOR"
