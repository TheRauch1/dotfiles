#!/usr/bin/env bash
# Left pane: Neovim for one project, with its file tree and git panel, and
# the files/cursor it had last time. Quitting Neovim leaves a shell.
. "$(dirname "$0")/lib.sh"
dir=$1
cd "$dir" || exit 1
export COCKPIT_IDE=1
COCKPIT_NAME="ide-$(printf '%s' "$dir" | sed 's/[^A-Za-z0-9._-]/%/g')" nvim --cmd 'let g:cockpit_restore=1'
echo "Neovim closed. Run: nvim   (or close this pane: exit)"
exec "${SHELL:-bash}"
