#!/usr/bin/env bash
# Right pane: the coding agent for one project ($IDE_AGENT: pi, claude or
# codex; default pi), continuing its last conversation. It reports its state
# to the file in $COCKPIT_STATE (pi: cockpit extension; claude/codex: the
# hooks in ../hooks), which the tab bar shows as ◐ / ● / !.
# When the agent exits, the pane becomes a normal shell.
. "$(dirname "$0")/lib.sh"
dir=$1
cd "$dir" || exit 1
export COCKPIT_STATE
COCKPIT_STATE=$(state_file "$dir")
t set -w @agent_pane "$TMUX_PANE"

agent=${IDE_AGENT:-pi}
[[ -f .cockpit-agent ]] && agent=$(head -n1 .cockpit-agent)   # per project: echo claude > .cockpit-agent
last=$(json_field "$COCKPIT_STATE" session)
case $agent in
  pi)     if [[ -n $last && -f $last ]]; then resume=(--session "$last"); else resume=(-c); fi ;;
  claude) resume=(-c) ;;
  codex)  resume=(resume --last) ;;
  *)      resume=() ;;
esac

started=$SECONDS
"$agent" "${resume[@]}"
# Nothing to continue yet (first start): start fresh.
if (( SECONDS - started < 3 )) && (( ${#resume[@]} )); then "$agent"; fi
printf '{"state":"idle","files":[]}' > "$COCKPIT_STATE"
echo
echo "$agent exited. This is a normal shell now; run $agent again any time."
exec "${SHELL:-bash}"
