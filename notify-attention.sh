#!/bin/bash
# notify-attention.sh — Claude Code hook feeding AwakeBar's notifications. Wired
# to several events in ~/.claude/settings.json:
#
#   Notification   -> Claude is blocked on you (needs tool permission, or the
#                     prompt idled >=60s). Writes the attention marker.
#   UserPromptSubmit
#                  -> a turn started. Bumps the activity marker (below) AND
#                     records the turn's start time, per cwd.
#   Stop           -> a turn finished. Bumps the activity marker, times how long
#                     the turn ran (now - start), and writes a "task finished"
#                     marker carrying that duration; AwakeBar notifies for turns
#                     that ran past a threshold (a real task) so a quick reply
#                     stays quiet — independent of which window you're in.
#   PostToolUse / SubagentStop
#                  -> signs you're engaging with that session. Bumps a per-cwd
#                     activity marker.
#
# AwakeBar defers each attention alert by a grace period and drops it if the
# matching session's activity marker moves past the attention timestamp — i.e.
# you approved a prompt, typed, or the turn ended within the window. Keying the
# activity by cwd keeps one busy session from silencing another session's alert.
#
# Files: attention = ${CLAUDE_ATTENTION_FILE:-/tmp/claude-attention.json},
#   done = ${CLAUDE_DONE_FILE:-/tmp/claude-done.json} (both { project, message,
#   cwd, ts, dur } — dur is the turn's length in seconds, or -1 when unknown);
#   activity = /tmp/claude-activity-<sanitised cwd> (<epoch>); turn start =
#   /tmp/claude-turnstart-<sanitised cwd> (<epoch>). Reads the hook payload as
#   JSON on stdin.

input=$(cat 2>/dev/null)

# Pull a string field from the payload: jq if available, else a sed fallback.
field() {
  local v=""
  if command -v jq >/dev/null 2>&1; then
    v=$(printf '%s' "$input" | jq -r --arg k "$1" '.[$k] // empty' 2>/dev/null)
  fi
  if [ -z "$v" ]; then
    v=$(printf '%s' "$input" | tr -d '\n' \
      | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p")
  fi
  printf '%s' "$v"
}

# Minimal JSON string escaping for the printf fallback below.
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# Sanitised cwd (non-alphanumeric -> _), mirroring AwakeBar's marker key.
safe_cwd() { printf '%s' "$(field cwd)" | tr -c 'A-Za-z0-9' '_'; }

# Write { project, message, cwd, ts, dur } to $1 with message $2 and duration $3
# (seconds, default -1 = unknown). jq builds it when present so any characters in
# the message escape correctly; an sed/printf fallback covers a jq-less box.
write_marker() {
  local file="$1" message="$2" dur="${3:--1}" cwd project
  if command -v jq >/dev/null 2>&1; then
    if printf '%s' "$input" | jq -c --argjson ts "$ts" --arg msg "$message" \
          --argjson dur "$dur" '
          (.cwd // "") as $cwd
          | { project: ($cwd | split("/") | last), message: $msg,
              cwd: $cwd, ts: $ts, dur: $dur }' > "$file" 2>/dev/null; then
      return 0
    fi
  fi
  cwd=$(field cwd)
  project="${cwd##*/}"
  printf '{"project":"%s","message":"%s","cwd":"%s","ts":%s,"dur":%s}\n' \
    "$(esc "$project")" "$(esc "$message")" "$(esc "$cwd")" "$ts" "$dur" > "$file"
}

# Bump the per-cwd activity marker — the engagement signal AwakeBar uses to drop
# an attention alert you've already acted on.
bump_activity() { printf '%s' "$ts" > "/tmp/claude-activity-$(safe_cwd)"; }

event=$(field hook_event_name)
ts=$(date +%s)

case "$event" in
  Notification) ;;                       # write the attention marker below
  UserPromptSubmit)
    # A turn started: engagement signal + record when, so Stop can time the turn.
    bump_activity
    printf '%s' "$ts" > "/tmp/claude-turnstart-$(safe_cwd)"
    exit 0 ;;
  Stop)
    # End of a turn. Bump activity, then publish the task-finished marker with how
    # long the turn ran; AwakeBar decides whether to notify from that duration, so
    # a long task pings the instant it ends (whatever window you're in) and a quick
    # reply stays quiet. dur = -1 when the start wasn't recorded.
    safe=$(safe_cwd)
    printf '%s' "$ts" > "/tmp/claude-activity-$safe"
    startfile="/tmp/claude-turnstart-$safe"
    dur=-1
    if [ -r "$startfile" ]; then
      start=$(tr -dc '0-9' < "$startfile" 2>/dev/null)
      [ -n "$start" ] && dur=$(( ts - start ))
      rm -f "$startfile"
    fi
    write_marker "${CLAUDE_DONE_FILE:-/tmp/claude-done.json}" "Task finished" "$dur"
    exit 0 ;;
  PostToolUse|SubagentStop)
    bump_activity
    exit 0 ;;
  *) exit 0 ;;
esac

# --- Notification: write the attention marker -------------------------------
message=$(field message)
[ -n "$message" ] || message="Claude is waiting for you"
write_marker "${CLAUDE_ATTENTION_FILE:-/tmp/claude-attention.json}" "$message"
exit 0
