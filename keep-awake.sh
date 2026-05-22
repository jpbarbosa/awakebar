#!/bin/bash
# keep-awake.sh — Claude Code hook: keep macOS awake while Claude is working.
#
# Hooked in ~/.claude/settings.json to:
#   UserPromptSubmit -> start  (Claude begins a turn)
#   Stop             -> stop — UNLESS a Remote Control session is active, in
#                       which case the Mac stays awake *between* turns too, so
#                       a session driven from claude.ai / mobile survives.
#   SessionEnd       -> always stop
#
# Design notes:
#  * One shared caffeinate, tracked in a single fixed pidfile. Each
#    UserPromptSubmit replaces the previous one; a 4h -t cap means nothing can
#    leak indefinitely even if a Stop/SessionEnd is missed.
#  * Remote Control is detected by a non-empty "bridgeSessionId" in a *live*
#    session's ~/.claude/sessions/<pid>.json (files are named by process id;
#    a liveness check rules out stale/ended sessions).
#  * No -d flag: the display may still sleep while the machine keeps working.
#  * CLAUDE_KEEP_AWAKE_PIDFILE overrides the pidfile path (used by tests).
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

pidfile="${CLAUDE_KEEP_AWAKE_PIDFILE:-/tmp/claude-keep-awake.pid}"

kill_tracked() {
  if [ -f "$pidfile" ]; then
    kill "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null
    rm -f "$pidfile"
  fi
}

start() {
  kill_tracked
  # -i no idle sleep, -m no disk sleep, -s no system sleep (AC only).
  # -t 14400: hard 4h cap so a missed Stop can never leak indefinitely.
  nohup caffeinate -i -m -s -t 14400 >/dev/null 2>&1 &
  echo $! > "$pidfile"
  disown 2>/dev/null || true
}

# True when some live Claude Code session has Remote Control connected — its
# ~/.claude/sessions/<pid>.json carries a non-empty "bridgeSessionId".
remote_control_active() {
  local f pid
  for f in "$HOME"/.claude/sessions/*.json; do
    [ -e "$f" ] || continue
    pid=$(basename "$f" .json)
    case "$pid" in ''|*[!0-9]*) continue ;; esac   # files are named by PID
    kill -0 "$pid" 2>/dev/null || continue          # session still running
    if command -v jq >/dev/null 2>&1; then
      [ -n "$(jq -r '.bridgeSessionId // empty' "$f" 2>/dev/null)" ] && return 0
    else
      grep -Eq '"bridgeSessionId"[[:space:]]*:[[:space:]]*"[^"]' "$f" && return 0
    fi
  done
  return 1
}

case "$event" in
  UserPromptSubmit)
    start
    ;;
  Stop)
    # Between turns: stay awake for a remote-controlled session, else release.
    remote_control_active || kill_tracked
    ;;
  SessionEnd)
    kill_tracked
    ;;
esac

exit 0
