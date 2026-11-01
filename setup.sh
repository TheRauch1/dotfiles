#!/usr/bin/env bash
# Link this repo's configs into $HOME and install Doom Emacs if missing.
# Safe to re-run. Existing files are moved aside to *.bak-<timestamp>.
set -euo pipefail

DOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"

link() {
  local src=$1 dst=$2
  if [[ -L $dst && $(readlink -f "$dst") == "$(readlink -f "$src")" ]]; then
    echo "ok      $dst"
    return
  fi
  if [[ -e $dst || -L $dst ]]; then
    mv "$dst" "$dst.bak-$STAMP"
    echo "backup  $dst -> $dst.bak-$STAMP"
  fi
  mkdir -p "$(dirname "$dst")"
  ln -s "$src" "$dst"
  echo "link    $dst -> $src"
}

link "$DOT/doom"           "$HOME/.config/doom"
link "$DOT/tmux/tmux.conf" "$HOME/.tmux.conf"

if ! grep -q 'doom/shell.zsh' "$HOME/.zshrc" 2>/dev/null; then
  printf '\n# Doom Emacs\n[ -f ~/.config/doom/shell.zsh ] && source ~/.config/doom/shell.zsh\n' >> "$HOME/.zshrc"
  echo "hooked  ~/.zshrc"
fi

if ! command -v emacs >/dev/null; then
  echo
  echo "Emacs not found. Install it, then re-run this script:"
  echo "  sudo apt install -y emacs ripgrep fd-find   # Debian/Ubuntu"
  echo "  brew install emacs-plus ripgrep fd          # macOS (d12frosted/emacs-plus tap)"
  exit 1
fi

if [[ ! -d $HOME/.config/emacs ]]; then
  git clone --depth 1 --recurse-submodules --shallow-submodules \
    https://github.com/doomemacs/doomemacs "$HOME/.config/emacs"
fi

# Doom's modules (:ui, :editor, :lang, ...) live in a git submodule.
# Without it `doom sync` silently installs only the core and Emacs
# starts with no theme, no evil, nothing. Also repairs older clones.
git -C "$HOME/.config/emacs" submodule update --init --depth 1

# Always sync: finishes an interrupted install, applies pulled config
# changes, and refreshes the env file so Emacs sees the current PATH.
"$HOME/.config/emacs/bin/doom" sync --env
