#!/bin/bash
# notify-attention.sh — Claude Code Notification hook: record that Claude is
# blocked waiting on the user, so AwakeBar can post a native macOS notification.
#
# Claude Code fires the Notification event exactly when it needs you:
#   * it needs permission to use a tool, or
#   * the prompt has been idle for >= 60s.
#
# Hooked in ~/.claude/settings.json:
#   Notification -> this script
#
# Writes ${CLAUDE_ATTENTION_FILE:-/tmp/claude-attention.json}:
#   { "project": "<cwd basename>", "message": "...", "cwd": "...", "ts": <epoch> }
#
# AwakeBar watches this file and posts the notification (suppressed when VSCode
# is already frontmost). Mirrors keep-awake.sh's /tmp marker-file pattern; the
# `ts` is the de-dup key — AwakeBar only alerts on a strictly newer one, so a
# stale marker can never replay. CLAUDE_ATTENTION_FILE overrides the path (tests).
#
# Reads the hook payload as JSON on stdin.

input=$(cat 2>/dev/null)
markerfile="${CLAUDE_ATTENTION_FILE:-/tmp/claude-attention.json}"
ts=$(date +%s)

# Preferred path: jq builds the JSON, so any characters in the message (quotes,
# backslashes, newlines) are escaped correctly.
if command -v jq >/dev/null 2>&1; then
  if printf '%s' "$input" | jq -c --argjson ts "$ts" '
        (.cwd // "") as $cwd
        | { project: ($cwd | split("/") | last),
            message: (.message // "Claude is waiting for you"),
            cwd:     $cwd,
            ts:      $ts }' > "$markerfile" 2>/dev/null; then
    exit 0
  fi
fi

# jq-less (or jq-failed) fallback: best-effort field extraction, escaping the two
# characters that would break the JSON we hand-assemble.
extract() {
  printf '%s' "$input" | tr -d '\n' \
    | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p"
}
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

cwd=$(extract cwd)
message=$(extract message)
[ -n "$message" ] || message="Claude is waiting for you"
project="${cwd##*/}"

printf '{"project":"%s","message":"%s","cwd":"%s","ts":%s}\n' \
  "$(esc "$project")" "$(esc "$message")" "$(esc "$cwd")" "$ts" > "$markerfile"
exit 0
