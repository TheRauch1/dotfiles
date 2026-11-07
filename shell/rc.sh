# Shell setup, sourced from ~/.bashrc and ~/.zshrc (setup.sh adds the line).
# The commands themselves (dev, ide, pd) are scripts in ../bin, linked to
# ~/.local/bin.

export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$HOME/.local/go/bin:$HOME/go/bin:$PATH"
export COLORTERM=truecolor
export EDITOR=nvim
export VISUAL=nvim

# A terminal the server doesn't know (e.g. Ghostty's xterm-ghostty over SSH)
# breaks tmux, nvim and tput. Fall back to a common one; colors stay 24-bit
# via COLORTERM. Better: install the terminfo once, from the client:
#   infocmp -x xterm-ghostty | ssh host -- tic -x -
if [ -n "$TERM" ] && command -v infocmp >/dev/null 2>&1 && ! infocmp "$TERM" >/dev/null 2>&1; then
  export TERM=xterm-256color
fi

# Overlays (~/.config/dotfiles.d/<name>/shell.sh), see README "Overlays".
for f in $(find -L "${DOTFILES_D:-$HOME/.config/dotfiles.d}" -mindepth 2 -maxdepth 2 -name shell.sh 2>/dev/null | sort); do
  . "$f"
done
