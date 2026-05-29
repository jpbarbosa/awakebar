#!/bin/bash
# keep-awake.sh — Claude Code hook: keep macOS awake while Claude is working.
#
# Hooked in ~/.claude/settings.json to:
#   SessionStart     -> start (reason "remote"), if the session is remote-
#                       controlled. Wired async; briefly polls for the bridge.
#   UserPromptSubmit -> start (reason "turn") — Claude begins a turn.
#   Stop             -> stop — UNLESS a Remote Control session is active, in
#                       which case the Mac stays awake between turns and the
#                       reason flips to "remote".
#   SessionEnd       -> always stop
#
# Design notes:
#  * One shared caffeinate, tracked in a single fixed pidfile, plus a sibling
#    ".reason" file holding "turn" or "remote" so a menu-bar app can show *why*
#    the Mac is being kept awake. Each UserPromptSubmit replaces the previous
#    caffeinate; a 4h -t cap means nothing can leak indefinitely.
#  * Remote Control detection: Claude Code no longer records bridge state in
#    ~/.claude/sessions/<pid>.json, so we read the bridge lifecycle out of the
#    VSCode extension-host debug log — the only on-disk trace. Best-effort:
#    VSCode-only, needs a --debug session. Mirrors AwakeBar's checkRemoteControl().
#  * No -d flag: the display may still sleep while the machine keeps working.
#  * CLAUDE_KEEP_AWAKE_PIDFILE overrides the pidfile path (used by tests); the
#    reason file is derived from it.
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
reasonfile="${pidfile%.pid}.reason"

kill_tracked() {
  if [ -f "$pidfile" ]; then
    kill "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null
    rm -f "$pidfile"
  fi
  rm -f "$reasonfile"
}

caffeinate_alive() {
  [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null
}

# start <reason> — (re)start caffeinate and record why the Mac is held awake.
start() {
  kill_tracked
  # -i no idle sleep, -m no disk sleep, -s no system sleep (AC only).
  # -t 14400: hard 4h cap so a missed Stop can never leak indefinitely.
  nohup caffeinate -i -m -s -t 14400 >/dev/null 2>&1 &
  echo $! > "$pidfile"
  disown 2>/dev/null || true
  printf '%s' "$1" > "$reasonfile"
}

# True when a VSCode-hosted session has Remote Control connected. Claude Code
# no longer records this in ~/.claude/sessions/*.json; the only on-disk trace
# is the extension-host debug log's bridge lifecycle. Read the tail of each
# recently-modified log and trust the last lifecycle marker: a connect-class
# marker that is newer than any teardown means the bridge is up.
remote_control_active() {
  local root="$HOME/Library/Application Support/Code/logs"
  [ -d "$root" ] || return 1
  local log last
  while IFS= read -r log; do
    last=$(tail -c 2097152 "$log" 2>/dev/null | grep -oE \
      '\[bridge:sdk\] State change: (connected|ready)|\[remote-bridge\] (v2 transport connected|Created session|Torn down|Archive session)' \
      | tail -1)
    case "$last" in
      *"Torn down"*|*"Archive session"*) ;;    # last marker = disconnected
      ?*) return 0 ;;                           # last marker = connect-class
      "") tail -c 2097152 "$log" 2>/dev/null | grep -q '\[remote-bridge\]' \
            && return 0 ;;                      # activity, handshake scrolled off
    esac
  done < <(find "$root" -type f -name 'Claude VSCode.log' \
             -path '*Anthropic.claude-code*' -mmin -30 2>/dev/null)
  return 1
}

case "$event" in
  SessionStart)
    # The remote-control bridge can connect a moment after the session
    # starts; poll briefly so a remote session is held from the start.
    # Wired async in settings.json, so this never delays session startup.
    for _ in $(seq 1 15); do
      if remote_control_active; then start remote; break; fi
      sleep 1
    done
    ;;
  UserPromptSubmit)
    start turn
    ;;
  Stop)
    if remote_control_active; then
      # Turn ended, but the session is remote-controlled — stay awake and
      # relabel the reason (re-arm caffeinate if it somehow stopped).
      if caffeinate_alive; then
        printf 'remote' > "$reasonfile"
      else
        start remote
      fi
    else
      kill_tracked
    fi
    ;;
  SessionEnd)
    kill_tracked
    ;;
esac

exit 0
