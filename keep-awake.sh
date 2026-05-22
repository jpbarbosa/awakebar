#!/bin/bash
# keep-awake.sh — Claude Code hook: keep macOS awake while Claude is working.
#
# Hooked in ~/.claude/settings.json to:
#   UserPromptSubmit -> start  (Claude begins a turn)
#   Stop, SessionEnd -> stop   (turn ends / session ends)
#
# Design notes:
#  * One shared caffeinate, tracked in a single fixed pidfile. Claude Code's
#    session_id is deliberately NOT used as a key — it can change mid-
#    conversation, which previously orphaned caffeinate processes.
#  * Each UserPromptSubmit kills the previous caffeinate before starting a
#    fresh one, so at most one ever runs from this script.
#  * caffeinate gets a 4h safety timeout (-t): if Claude Code is killed
#    abruptly with no Stop/SessionEnd, it still self-terminates.
#  * No -d flag: the display may still sleep while the machine keeps working.
#
# Reads the hook payload as JSON on stdin.

input=$(cat 2>/dev/null)

event=""
if command -v jq >/dev/null 2>&1; then
  event=$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null)
fi
if [ -z "$event" ]; then
  event=$(printf '%s' "$input" | tr -d '\n' \
    | sed -n 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
fi

pidfile="/tmp/claude-keep-awake.pid"

kill_tracked() {
  if [ -f "$pidfile" ]; then
    kill "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null
    rm -f "$pidfile"
  fi
}

case "$event" in
  UserPromptSubmit)
    kill_tracked                       # replace any previous turn's process
    # -i no idle sleep, -m no disk sleep, -s no system sleep (AC only).
    # -t 14400: hard 4h cap so a missed Stop can never leak indefinitely.
    nohup caffeinate -i -m -s -t 14400 >/dev/null 2>&1 &
    echo $! > "$pidfile"
    disown 2>/dev/null || true
    ;;
  Stop|SessionEnd)
    kill_tracked
    ;;
esac

exit 0
