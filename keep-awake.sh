#!/bin/bash
# keep-awake.sh — Claude Code hook: keep macOS awake while Claude is working.
#
# Hooked in ~/.claude/settings.json to:
#   SessionStart     -> hold (reason "remote"), if this session is remote-
#                       controlled. Wired async; briefly polls for the bridge.
#   UserPromptSubmit -> hold (reason "turn") — Claude begins a turn.
#   Stop             -> release — UNLESS this session is remote-controlled, in
#                       which case it keeps holding between turns as "remote".
#   SessionEnd       -> always release
#
# Design notes:
#  * One caffeinate PER SESSION, tracked in $CLAUDE_HOLD_DIR/<session>.pid. A
#    single shared hold breaks as soon as two sessions are open: whichever one
#    reaches Stop first releases the Mac while the others are still working.
#  * The aggregate $CLAUDE_PIDFILE and its ".reason" sibling are republished from
#    the live holds, because AwakeBar reads them to say whether — and why — the
#    hook is holding. An active turn outranks a remote hold in that wording.
#  * A remote session is held only between turns: each Stop restarts caffeinate
#    with -t set to a short idle window, so an idle remote session stops keeping
#    the Mac awake once that window passes without a new turn. The window is read
#    from /tmp/claude-keep-awake.idle (seconds), which AwakeBar writes from its
#    "Remote Idle Timeout" setting; absent/invalid falls back to the 4h cap.
#  * Remote Control detection reads bridgeSessionId from Claude Code's own
#    ~/.claude/sessions/<pid>.json, and asks it of THIS session only. That is
#    host-agnostic: the CLI, desktop VSCode and a code-server tile all write it,
#    whereas the extension-host log covers desktop VSCode alone.
#  * No -d flag: the display may still sleep while the machine keeps working.
#  * CLAUDE_KEEP_AWAKE_PIDFILE overrides the pidfile path (used by tests); the
#    reason, idle and hold-dir paths all derive from it.
#
# Reads the hook payload as JSON on stdin.

# Shared paths/markers/reason tokens (the mirror of Contract.swift). Lives beside
# this script — copy claude-hook-contract.sh to ~/.claude/ alongside the hooks.
. "$(cd "$(dirname "$0")" && pwd)/claude-hook-contract.sh" 2>/dev/null || {
  echo "keep-awake.sh: cannot source claude-hook-contract.sh — copy it beside the hooks in ~/.claude/" >&2
  exit 0
}

input=$(cat 2>/dev/null)

# field() (the payload reader) and json_field() (its file twin) come from the
# sourced contract, as do CLAUDE_PIDFILE / CLAUDE_REASONFILE / CLAUDE_IDLEFILE /
# CLAUDE_HOLD_DIR / CLAUDE_SESSIONS_DIR.
event=$(field hook_event_name)
session=$(field session_id)

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

# This session's record in Claude Code's sessions dir, whose files are named by
# the owning pid. Prints the path; non-zero when the session has no live record.
session_file() {
  local f pid
  [ -n "$session" ] || return 1
  for f in "$CLAUDE_SESSIONS_DIR"/*.json; do
    [ -f "$f" ] || continue
    pid=$(basename "$f" .json)
    kill -0 "$pid" 2>/dev/null || continue
    [ "$(json_field "$f" sessionId)" = "$session" ] || continue
    printf '%s' "$f"
    return 0
  done
  return 1
}

# True while THIS session has a Remote Control bridge. Asking per session stops a
# stale field on some other, idle session from deciding this one's hold.
session_has_bridge() {
  local f
  f=$(session_file) || return 1
  [ -n "$(json_field "$f" "$CLAUDE_BRIDGE_FIELD")" ]
}

hold_file() {
  printf '%s/%s.pid' "$CLAUDE_HOLD_DIR" \
    "$(printf '%s' "${session:-unknown}" | tr -c 'A-Za-z0-9._-' '_')"
}

hold_kill() {
  local file="$1" pid
  [ -f "$file" ] || return 0
  pid=$(awk '{print $1}' "$file" 2>/dev/null)
  [ -n "$pid" ] && kill "$pid" 2>/dev/null
  rm -f "$file"
}

# Sweep dead holds, then republish the aggregate pid/reason files AwakeBar reads.
publish() {
  local file pid reason spid best="" best_reason=""
  for file in "$CLAUDE_HOLD_DIR"/*.pid; do
    [ -f "$file" ] || continue
    read -r pid reason spid < "$file"
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then rm -f "$file"; continue; fi
    # Session gone without a SessionEnd, so nothing else will ever release this.
    if [ -n "$spid" ] && ! kill -0 "$spid" 2>/dev/null; then hold_kill "$file"; continue; fi
    if [ -z "$best" ] || { [ "$reason" = "$CLAUDE_REASON_TURN" ] && \
                           [ "$best_reason" != "$CLAUDE_REASON_TURN" ]; }; then
      best="$pid"; best_reason="$reason"
    fi
  done
  if [ -n "$best" ]; then
    printf '%s' "$best" > "$CLAUDE_PIDFILE"
    printf '%s' "$best_reason" > "$CLAUDE_REASONFILE"
  else
    rm -f "$CLAUDE_PIDFILE" "$CLAUDE_REASONFILE"
  fi
}

# hold <reason> [seconds] — (re)start this session's caffeinate. The optional cap
# defaults to the contract's 4h backstop: long enough that a single turn never
# trips it, so a missed Stop can never leak indefinitely.
hold() {
  local file cap="${2:-$CLAUDE_DEFAULT_CAP}" pid spid="" f
  file=$(hold_file)
  hold_kill "$file"
  mkdir -p "$CLAUDE_HOLD_DIR" 2>/dev/null
  # -i no idle sleep, -m no disk sleep, -s no system sleep (AC only).
  nohup caffeinate -i -m -s -t "$cap" >/dev/null 2>&1 &
  pid=$!
  disown 2>/dev/null || true
  f=$(session_file) && spid=$(basename "$f" .json)
  printf '%s %s %s\n' "$pid" "$1" "$spid" > "$file"
  publish
}

release() { hold_kill "$(hold_file)"; publish; }

case "$event" in
  SessionStart)
    # The bridge can connect a moment after the session starts; poll briefly so a
    # remote session is held from the start. Wired async, so this delays nothing.
    for _ in $(seq 1 15); do
      if session_has_bridge; then hold "$CLAUDE_REASON_REMOTE" "$(remote_idle_seconds)"; break; fi
      sleep 1
    done
    ;;
  UserPromptSubmit)
    hold "$CLAUDE_REASON_TURN"
    ;;
  Stop)
    # Turn ended. A remote-controlled session keeps holding with the idle window
    # as its -t; each turn refreshes it, and once a window passes with no new turn
    # caffeinate exits on its own.
    if session_has_bridge; then
      hold "$CLAUDE_REASON_REMOTE" "$(remote_idle_seconds)"
    else
      release
    fi
    ;;
  SessionEnd)
    release
    ;;
esac

exit 0
