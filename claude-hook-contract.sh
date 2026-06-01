#!/bin/bash
# claude-hook-contract.sh — shared definitions for the AwakeBar hook scripts.
# Sourced by keep-awake.sh and notify-attention.sh. Holds the /tmp marker files
# the scripts exchange with AwakeBar, the reason tokens keep-awake.sh records,
# the VSCode bridge lifecycle markers, and the cwd → marker-key sanitiser.
#
# MIRROR: Contract.swift (in the AwakeBar app) holds the Swift-side copy of these
# same values. The two files are the only places these literals live — keep them
# in step, a change here is a change there. They can't share a literal at build
# time: one is bash sourced at run time, the other a compiled binary.
#
# Honours the env overrides the scripts already supported (used by tests):
# CLAUDE_KEEP_AWAKE_PIDFILE, CLAUDE_ATTENTION_FILE, CLAUDE_DONE_FILE.

# Marker files exchanged via /tmp. The reason/idle files derive from the pidfile,
# so a CLAUDE_KEEP_AWAKE_PIDFILE override moves all three together (as before).
CLAUDE_PIDFILE="${CLAUDE_KEEP_AWAKE_PIDFILE:-/tmp/claude-keep-awake.pid}"
CLAUDE_REASONFILE="${CLAUDE_PIDFILE%.pid}.reason"
CLAUDE_IDLEFILE="${CLAUDE_PIDFILE%.pid}.idle"
CLAUDE_ATTENTION_MARKER="${CLAUDE_ATTENTION_FILE:-/tmp/claude-attention.json}"
CLAUDE_DONE_MARKER="${CLAUDE_DONE_FILE:-/tmp/claude-done.json}"
CLAUDE_ACTIVITY_PREFIX="/tmp/claude-activity-"
CLAUDE_TURNSTART_PREFIX="/tmp/claude-turnstart-"

# The reason keep-awake.sh records in CLAUDE_REASONFILE (mirror Contract.reason*).
CLAUDE_REASON_TURN="turn"
CLAUDE_REASON_REMOTE="remote"

# Default caffeinate cap (4h): long enough that a single turn never trips it, and
# a backstop so a missed Stop can't keep the Mac awake indefinitely.
CLAUDE_DEFAULT_CAP=14400

# VSCode bridge lifecycle markers (mirror Contract.bridgeConnect/TeardownMarkers),
# as one grep -oE alternation. keep-awake.sh greps the log tail for the last
# match and treats a teardown marker ("Torn down"/"Archive session") as
# disconnected.
CLAUDE_BRIDGE_MARKERS_RE='\[bridge:sdk\] State change: (connected|ready)|\[remote-bridge\] (v2 transport connected|Created session|Torn down|Archive session)'

# cwd → marker-key: non-alphanumerics to '_' (mirror Contract.markerKey), so both
# sides name the same per-cwd activity/turnstart files for a given cwd.
claude_marker_key() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }

# Pull a string field from the hook payload: jq if available, else a sed fallback.
# Reads the global $input the sourcing script fills from stdin, so call it only
# after `input=$(cat)`.
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
