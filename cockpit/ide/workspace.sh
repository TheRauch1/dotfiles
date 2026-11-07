#!/usr/bin/env bash
# workspace.sh <file.cockpit>: turn a workspace file into a folder of links
# (one per repo) and print its path. The agent and the editor run in that
# folder, so they see every repo of the workspace at once.
#
# A workspace file lists the repos that belong together, one per line:
#
#   # ~/dev/acme.cockpit
#   api      ~/dev/acme-api
#   web      ~/dev/acme-web
#   ~/dev/shared-lib            # name defaults to the folder name
#   agent    claude             # optional: which agent (default pi)
#
# The folder is ~/ws/<name> ($IDE_WORKSPACES/<name>), e.g. ~/ws/acme/api.
set -euo pipefail
file=$(cd "$(dirname "${1:?usage: workspace.sh <file.cockpit>}")" && pwd -P)/$(basename "$1")
name=$(basename "$file" .cockpit)
ws="${IDE_WORKSPACES:-$HOME/ws}/$name"
mkdir -p "$ws"

# Start from a clean set of links (only links: never touch real files).
find "$ws" -mindepth 1 -maxdepth 1 -type l -delete

agent=
repos=()
while IFS= read -r line || [[ -n $line ]]; do
  line=${line%%#*}
  read -r a b _ <<<"$line" || true
  [[ -n ${a:-} ]] || continue
  if [[ $a == agent ]]; then agent=$b; continue; fi
  if [[ -n ${b:-} ]]; then link=$a path=$b; else path=$a link=; fi
  path=${path/#\~/$HOME}
  [[ $path == /* ]] || path="$(dirname "$file")/$path"
  if [[ ! -d $path ]]; then echo "workspace $name: no such folder: $path" >&2; continue; fi
  path=$(cd "$path" && pwd -P)
  link=${link:-$(basename "$path")}
  ln -sfn "$path" "$ws/$link"
  repos+=("$link -> ${path/#"$HOME"/\~}")
done < "$file"

# Marks the folder as a workspace: Neovim's SPC SPC / SPC / then search all repos.
echo "$file" > "$ws/.cockpit-workspace"

if [[ -n $agent ]]; then echo "$agent" > "$ws/.cockpit-agent"; else rm -f "$ws/.cockpit-agent"; fi

# Tell the agent what this folder is (pi reads AGENTS.md, Claude CLAUDE.md).
{
  echo "<!-- Written by cockpit from ${file/#"$HOME"/\~}; edit that file instead. -->"
  echo "# Workspace: $name"
  echo
  echo "This folder links several separate git repositories that belong together:"
  echo
  for r in "${repos[@]}"; do echo "- \`$r\`"; done
  echo
  echo "Each subfolder is its own git repo: run git commands inside it (e.g. \`git -C api status\`),"
  echo "not in this folder. A change may span several repos."
} > "$ws/AGENTS.md"
ln -sfn AGENTS.md "$ws/CLAUDE.md"
echo "$ws"
