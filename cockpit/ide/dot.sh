#!/usr/bin/env bash
# Tab-bar mark for one project window: dot.sh <root> <window_active> <name>
#   ◐ working  ● your turn  ! needs approval  (nothing: idle / no agent)
# Also pops a message when an agent in a background window gets done.
. "$(dirname "$0")/lib.sh"
root=$1 active=$2 name=$3
[[ -n $root ]] || exit 0
f=$(state_file "$root")
[[ -f $f ]] || exit 0
s=$(json_field "$f" state)
seen="$f.seen"
prev=$(cat "$seen" 2>/dev/null)
if [[ $s != "$prev" ]]; then
  echo "$s" > "$seen"
  if [[ $active != 1 && $prev == working && ( $s == waiting || $s == blocked ) ]]; then
    t display-message -d 5000 "● $name: agent is waiting for you  (prefix w jumps there)" 2>/dev/null
  fi
fi
case $s in
  working) printf ' #[fg=#61afef]◐#[default]' ;;
  waiting) printf ' #[fg=#e5c07b,bold]●#[default]' ;;
  blocked) printf ' #[fg=#e06c75,bold]!#[default]' ;;
esac
