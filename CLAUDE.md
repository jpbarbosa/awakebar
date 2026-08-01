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
  app-only `UsageAPI` constants: the plan-usage web link plus the OAuth/`/usage`
  endpoint literals (client id, authorize/token hosts, scope, Keychain service).
- `AwakeMonitor.swift` — reads `pmset -g assertions` and parses the VSCode
  extension-host log (Remote Control lifecycle + VSCode in-panel permission prompts).
- `NotificationCoordinator.swift` — owns the "Claude is waiting / task finished /
  VSCode permission" notifications: scheduling, grace deferral, posting, withdrawal.
- `PowerAssertion.swift` — holds AwakeBar's own `PreventUserIdleSystemSleep` assertion.
- `AttentionWatcher.swift` — kqueue watcher over a `/tmp/claude-*.json` marker; fires a callback when it changes.
- `PlanLimits.swift` — the shared plan-usage value types (`Window`/`Usage`) plus
  the pure, tested `countdown`/`parseDate` helpers the menu renders with.
- `UsageOAuth.swift` — the only source: AwakeBar's own OAuth PKCE login (reusing
  Claude Code's public client id) and the `/api/oauth/usage` fetch behind the exact
  `/usage` numbers. Pure `base64URL`/`challenge`/`pkce`/`authorizeURL`/`splitCode`/
  `decodeToken`/`decodeUsage` are tested; the URLSession calls + `runLive` are IO.
- `TokenStore.swift` — persists the OAuth token in AwakeBar's *own* Keychain item
  (`UsageAPI.oauthKeychainService`, NOT `Claude Code-credentials`), so reads never
  prompt.
- `PlanLimitsCoordinator.swift` — owns the plan-usage opt-in flag, the connect/
  disconnect flow, the fetch throttle (incl. a 429 cooldown), and the last-known
  usage the menu renders.
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
- **Plan usage has exactly one source: `/api/oauth/usage`.** Connected → the real
  `/usage` numbers, including the per-model weekly rows. Not connected → the panel
  says "Connect to show your usage" and shows nothing. Off by default.
- **Don't re-add a local estimate.** There was one (`UsageLedger`, priced off the
  JSONL transcripts, self-calibrated against your historical peak) and it was
  removed 2026-08-01: both halves of the fraction were guesses, it read 35%/79%
  where `/usage` said 5%/10%, and the fix needed a weekly-reset phase that exists
  nowhere on disk — i.e. a setting copied off the very screen it was replacing. It
  also *was* the app's CPU and memory cost (3 GB corpus, 47 s cold scan). DESIGN.md
  keeps the full autopsy. Connecting is one browser round-trip and is exact.
- **Why the token is our *own* OAuth login, not Claude Code's.** Reading
  `Claude Code-credentials` re-prompts on every token rotation (Claude Code
  delete+recreates the item, wiping our ACL grant). So `UsageOAuth` runs an
  independent PKCE login and `TokenStore` keeps our own Keychain item — no prompt,
  no rotation race (this is how CodeQuota coexists with Claude Code). The endpoint
  is **undocumented/reverse-engineered** (Anthropic disowns it) and 429-prone, so
  it's polled ≥5 min and keeps last-good on 429/offline — a blip never blanks the
  panel. The statusLine `rate_limits` block (the clean official source) stays
  unusable here: it isn't emitted in the VSCode extension / headless stream-json
  mode (verified — a successful headless turn invokes the statusLine 0×; CC issues
  #55643, #58071).

## Hook ↔ app IPC (`/tmp`)

The hooks (`notify-attention.sh`, `keep-awake.sh`) talk to the app through marker files:

- `claude-attention.json` — Claude needs you (`project`/`message`/`cwd`/`ts` dedup key).
- `claude-done.json` — turn ended (same fields plus `dur`, the turn's length in seconds; `-1` = start not recorded).
- `claude-keep-awake.reason` — why `caffeinate` is running (`turn` | `remote`); drives the **Claude Code Hook** menu wording.
- `claude-keep-awake.idle` — idle window in seconds that AwakeBar publishes for the hook's between-turns `caffeinate -t` (absent → hook's own 4 h backstop).
