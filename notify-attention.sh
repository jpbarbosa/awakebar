#!/bin/bash
# notify-attention.sh — Claude Code hook feeding AwakeBar's "Claude is waiting"
# alerts. Wired to several events in ~/.claude/settings.json:
#
#   Notification   -> Claude is blocked on you (needs tool permission, or the
#                     prompt idled >=60s). Writes the attention marker.
#   UserPromptSubmit / PostToolUse / Stop / SubagentStop
#                  -> signs you're engaging with that session. Bumps a per-cwd
#                     activity marker.
#
# AwakeBar defers each attention alert by a grace period and drops it if the
# matching session's activity marker moves past the attention timestamp — i.e.
# you approved a prompt, typed, or the turn ended within the window. Keying the
# activity by cwd keeps one busy session from silencing another session's alert.
#
# Files: attention = ${CLAUDE_ATTENTION_FILE:-/tmp/claude-attention.json}
#   ({ project, message, cwd, ts }); activity = /tmp/claude-activity-<sanitised
#   cwd> (<epoch>). Reads the hook payload as JSON on stdin.

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

event=$(field hook_event_name)
ts=$(date +%s)

case "$event" in
  Notification) ;;                       # write the attention marker below
  UserPromptSubmit|PostToolUse|Stop|SubagentStop)
    # Per-cwd activity marker. The sanitiser mirrors AwakeBar's (non-alnum -> _).
    cwd=$(field cwd)
    safe=$(printf '%s' "$cwd" | tr -c 'A-Za-z0-9' '_')
    printf '%s' "$ts" > "/tmp/claude-activity-$safe"
    exit 0 ;;
  *) exit 0 ;;
esac

# --- Notification: write the attention marker -------------------------------
attentionfile="${CLAUDE_ATTENTION_FILE:-/tmp/claude-attention.json}"

# Preferred path: jq builds the JSON so any characters in the message escape
# correctly.
if command -v jq >/dev/null 2>&1; then
  if printf '%s' "$input" | jq -c --argjson ts "$ts" '
        (.cwd // "") as $cwd
        | { project: ($cwd | split("/") | last),
            message: (.message // "Claude is waiting for you"),
            cwd:     $cwd,
            ts:      $ts }' > "$attentionfile" 2>/dev/null; then
    exit 0
  fi
fi

# jq-less (or jq-failed) fallback.
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
cwd=$(field cwd)
message=$(field message)
[ -n "$message" ] || message="Claude is waiting for you"
project="${cwd##*/}"
printf '{"project":"%s","message":"%s","cwd":"%s","ts":%s}\n' \
  "$(esc "$project")" "$(esc "$message")" "$(esc "$cwd")" "$ts" > "$attentionfile"
exit 0
