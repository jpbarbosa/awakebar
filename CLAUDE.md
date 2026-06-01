# AwakeBar — working notes

A tiny macOS menu-bar app (Swift 6.2, macOS 15+) that keeps the Mac awake for
Claude Code sessions and notifies you when Claude is waiting or a task finishes.
Product docs: [README.md](README.md). Mechanics & rationale: [DESIGN.md](DESIGN.md).

## Build & test

- `./build.sh` — builds, signs, and re-syncs the installed `/Applications` copy on every run.
- `swift test` — unit tests covering the `pmset` and VSCode-log parsers in `AwakeMonitor`.

## Source map

`Sources/AwakeBar/`, one file per type:

- `Contract.swift` — the single source of truth for the hook IPC: the `/tmp`
  marker paths, VSCode bridge markers, reason tokens, and cwd sanitiser
  (mirrored on the shell side by `claude-hook-contract.sh`). Also holds the
  app-only `UsageAPI` constants for the plan-usage panel (no shell mirror).
- `AwakeMonitor.swift` — reads `pmset -g assertions` and parses the VSCode
  extension-host log (Remote Control lifecycle + VSCode in-panel permission prompts).
- `NotificationCoordinator.swift` — owns the "Claude is waiting / task finished /
  VSCode permission" notifications: scheduling, grace deferral, posting, withdrawal.
- `PowerAssertion.swift` — holds AwakeBar's own `PreventUserIdleSystemSleep` assertion.
- `AttentionWatcher.swift` — kqueue watcher over a `/tmp/claude-*.json` marker; fires a callback when it changes.
- `PlanLimits.swift` — reads Claude Code's plan-usage limits (the `/usage` screen)
  from the OAuth token: the Keychain read + `/api/oauth/usage` fetch, plus pure,
  tested `decode`/`countdown`/token-parse helpers.
- `PlanLimitsCoordinator.swift` — owns the plan-usage opt-in flag, the fetch
  throttle, the 429 cooldown, and the last-known usage the menu renders.
- `AppDelegate.swift` — menu UI, power assertions, and the refresh loop; owns a
  `NotificationCoordinator` and a `PlanLimitsCoordinator`.
- `main.swift` — entry point.

Icon: `icon/make-icon.swift` (Core Graphics tile + composited cup, `icon/black-coffee-cup.png`,
with a drawn-vector fallback if the PNG is removed); regenerate the tile palette with
`./icon/build-iconset.sh <style>` (`espresso` · `aqua` · `graphite`). `build.sh` bundles
the prebuilt `icon/AppIcon.icns`. It's deliberately *not* the SF Symbol `cup.and.saucer` —
Apple's SF Symbols licence bars its symbols from app icons.

## Gotchas when editing

- **Undocumented Claude Code log strings.** Remote Control and VSCode-prompt
  detection parse log markers Claude Code doesn't promise to keep. They're
  centralised in `Contract.swift` *and* its shell mirror `claude-hook-contract.sh`
  — a Claude Code rename is a one-line fix in each.
- **cwd parse anchor.** Only trust `launch_claude` / `Spawning Claude` lines for
  a session's cwd; the log also echoes back tool inputs that mention `cwd:` —
  don't match those.
- **Plan-usage API is undocumented & rate-limit-touchy.** `PlanLimits` reuses
  Claude Code's own OAuth token to hit `/api/oauth/usage`. The `User-Agent:
  claude-code/<ver>` header is load-bearing — without it the endpoint 429s
  persistently. It's read-only (never `/v1/messages`), fetched at most every
  10 min, and parks for 45 min after a 429. Off by default; the toggle is the
  user's consent to the one-time Keychain prompt.

## Hook ↔ app IPC (`/tmp`)

The hooks (`notify-attention.sh`, `keep-awake.sh`) talk to the app through marker files:

- `claude-attention.json` — Claude needs you (`project`/`message`/`cwd`/`ts` dedup key).
- `claude-done.json` — turn ended (same fields plus `dur`, the turn's length in seconds; `-1` = start not recorded).
- `claude-keep-awake.reason` — why `caffeinate` is running (`turn` | `remote`); drives the **Claude Code Hook** menu wording.
- `claude-keep-awake.idle` — idle window in seconds that AwakeBar publishes for the hook's between-turns `caffeinate -t` (absent → hook's own 4 h backstop).
