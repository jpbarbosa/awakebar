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
#    caffeinate; a 4h -t cap means a turn can never leak indefinitely.
#  * A remote session is held only between turns: each Stop restarts caffeinate
#    with -t set to a short idle window, so an idle remote session stops keeping
#    the Mac awake once that window passes without a new turn. The window is read
#    from /tmp/claude-keep-awake.idle (seconds), which AwakeBar writes from its
#    "Remote Idle Timeout" setting; absent/invalid falls back to the 4h cap, so
#    behaviour is unchanged when AwakeBar isn't managing it.
#  * Remote Control detection: Claude Code no longer records bridge state in
#    ~/.claude/sessions/<pid>.json, so we read the bridge lifecycle out of the
#    VSCode extension-host debug log — the only on-disk trace. Best-effort:
#    VSCode-only, needs a --debug session. Mirrors AwakeBar's checkRemoteControl().
#  * No -d flag: the display may still sleep while the machine keeps working.
#  * CLAUDE_KEEP_AWAKE_PIDFILE overrides the pidfile path (used by tests); the
#    reason file is derived from it.
#
# Reads the hook payload as JSON on stdin.

# Shared paths/markers/reason tokens (the mirror of Contract.swift). Lives beside
# this script — copy claude-hook-contract.sh to ~/.claude/ alongside the hooks.
. "$(cd "$(dirname "$0")" && pwd)/claude-hook-contract.sh" 2>/dev/null || {
  echo "keep-awake.sh: cannot source claude-hook-contract.sh — copy it beside the hooks in ~/.claude/" >&2
  exit 0
}

input=$(cat 2>/dev/null)

# field() (the jq/sed payload reader) comes from the sourced contract.
event=$(field hook_event_name)

# Paths come from the sourced contract: CLAUDE_PIDFILE / CLAUDE_REASONFILE /
# CLAUDE_IDLEFILE (the reason/idle files derive from a CLAUDE_KEEP_AWAKE_PIDFILE
# override the same way they used to).

# Seconds to hold a remote session between turns, written by AwakeBar's "Remote
# Idle Timeout" setting. Absent or non-numeric falls back to the default cap, so
# the hook behaves exactly as before when AwakeBar isn't managing the window.
remote_idle_seconds() {
  local v
  v=$(cat "$CLAUDE_IDLEFILE" 2>/dev/null)
  case "$v" in
    ''|*[!0-9]*) printf '%s' "$CLAUDE_DEFAULT_CAP" ;;
    *)           printf '%s' "$v" ;;
  esac
}

kill_tracked() {
  if [ -f "$CLAUDE_PIDFILE" ]; then
    kill "$(cat "$CLAUDE_PIDFILE" 2>/dev/null)" 2>/dev/null
    rm -f "$CLAUDE_PIDFILE"
  fi
  rm -f "$CLAUDE_REASONFILE"
}

# start <reason> [seconds] — (re)start caffeinate and record why the Mac is held
# awake. The optional cap defaults to the contract's 4h backstop: long enough that
# a single turn never trips it, so a missed Stop can never leak indefinitely.
start() {
  kill_tracked
  local cap="${2:-$CLAUDE_DEFAULT_CAP}"
  # -i no idle sleep, -m no disk sleep, -s no system sleep (AC only).
  nohup caffeinate -i -m -s -t "$cap" >/dev/null 2>&1 &
  echo $! > "$CLAUDE_PIDFILE"
  disown 2>/dev/null || true
  printf '%s' "$1" > "$CLAUDE_REASONFILE"
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
    last=$(tail -c 2097152 "$log" 2>/dev/null \
      | grep -oE "$CLAUDE_BRIDGE_MARKERS_RE" | tail -1)
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
      if remote_control_active; then start "$CLAUDE_REASON_REMOTE" "$(remote_idle_seconds)"; break; fi
      sleep 1
    done
    ;;
  UserPromptSubmit)
    start "$CLAUDE_REASON_TURN"
    ;;
  Stop)
    if remote_control_active; then
      # Turn ended, but the session is remote-controlled — keep the Mac awake,
      # restarting caffeinate with the idle window as its -t. Each turn refreshes
      # this; once a window passes with no new turn, caffeinate exits on its own
      # and the idle remote session stops holding the Mac awake.
      start "$CLAUDE_REASON_REMOTE" "$(remote_idle_seconds)"
    else
      kill_tracked
    fi
    ;;
  SessionEnd)
    kill_tracked
    ;;
esac

exit 0
