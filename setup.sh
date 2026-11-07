#!/usr/bin/env bash
# Link this repo's configs and commands into $HOME and install the tools.
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

link "$DOT/mise/config.toml" "$HOME/.config/mise/config.toml"
link "$DOT/ghostty/config" "$HOME/.config/ghostty/config"
link "$DOT/nvim" "$HOME/.config/nvim"
link "$DOT/cockpit" "$HOME/.config/cockpit"
link "$DOT/pi/extensions/cockpit.ts" "$HOME/.pi/agent/extensions/cockpit.ts"
link "$DOT/shell/rc.sh" "$HOME/.config/dotfiles/rc.sh"
for cmd in "$DOT"/bin/*; do
  link "$cmd" "$HOME/.local/bin/$(basename "$cmd")"
done

# Earlier versions linked a Doom Emacs config; drop that link.
if [[ -L $HOME/.config/doom && $(readlink "$HOME/.config/doom") == "$DOT/doom" ]]; then
  rm "$HOME/.config/doom"
  echo "removed $HOME/.config/doom"
fi

for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
  [[ -f $rc ]] || touch "$rc"
  # Replace the old Doom hook line (and its comment) with the new one.
  if grep -q 'doom/shell.zsh' "$rc"; then
    sed -i.bak-"$STAMP" -e '/^# Doom Emacs$/d' -e '/doom\/shell\.zsh/d' "$rc"
  fi
  if ! grep -q 'dotfiles/rc.sh' "$rc"; then
    printf '\n# dotfiles\n[ -f ~/.config/dotfiles/rc.sh ] && . ~/.config/dotfiles/rc.sh\n' >> "$rc"
    echo "hooked  $rc"
  fi
done

# Command-line tools and language servers (mise/config.toml).
if ! command -v mise >/dev/null && [[ ! -x $HOME/.local/bin/mise ]]; then
  curl -fsSL https://mise.run | sh
fi
"$(command -v mise || echo "$HOME/.local/bin/mise")" install
# `dev` and `ide` need tmux to survive dropped SSH connections.
if ! command -v tmux >/dev/null; then
  echo
  echo "Note: tmux not found. \`dev\` works without it but won't survive a dropped connection:"
  echo "  sudo apt install -y tmux    # Debian/Ubuntu"
  echo "  brew install tmux           # macOS"
fi

echo
echo "Done. Open a new shell (or: . ~/.config/dotfiles/rc.sh), then run: ide   (or: dev, nvim)"
