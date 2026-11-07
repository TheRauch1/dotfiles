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
link "$DOT/mise/config.toml" "$HOME/.config/mise/config.toml"
link "$DOT/ghostty/config" "$HOME/.config/ghostty/config"
link "$DOT/nvim" "$HOME/.config/nvim"
link "$DOT/cockpit" "$HOME/.config/cockpit"
link "$DOT/pi/extensions/cockpit.ts" "$HOME/.pi/agent/extensions/cockpit.ts"

for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
  if ! grep -q 'doom/shell.zsh' "$rc" 2>/dev/null; then
    printf '\n# Doom Emacs\n[ -f ~/.config/doom/shell.zsh ] && source ~/.config/doom/shell.zsh\n' >> "$rc"
    echo "hooked  $rc"
  fi
done

# Command-line tools and language servers (mise/config.toml).
if ! command -v mise >/dev/null && [[ ! -x $HOME/.local/bin/mise ]]; then
  curl -fsSL https://mise.run | sh
fi
"$(command -v mise || echo "$HOME/.local/bin/mise")" install
# Shims make mise tools visible to Emacs regardless of the current directory
# (and land in Doom's env file below).
export PATH="$HOME/.local/share/mise/shims:$PATH"

# Doom Emacs is optional: without Emacs, stop here (Neovim is ready).
if ! command -v emacs >/dev/null; then
  echo
  echo "Neovim is set up (run: nvim). Emacs not found, so Doom was skipped."
  echo "For Doom too, install Emacs and re-run this script:"
  echo "  sudo apt install -y emacs build-essential   # Debian/Ubuntu"
  echo "  brew install emacs-plus                     # macOS (d12frosted/emacs-plus tap)"
  exit 0
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
