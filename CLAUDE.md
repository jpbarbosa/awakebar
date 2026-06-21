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
- `UsageLedger.swift` — *estimates* the plan-usage bars locally from the JSONL
  transcripts (`~/.claude/projects/**/*.jsonl`): scan + dedup + per-model cost
  model + a self-calibrated 5h/weekly window. No OAuth token, no network. Pure
  `cost`/`parse`/`estimate`/`rollingPeak` are tested. This is the fallback / the
  only source until you connect.
- `UsageOAuth.swift` — the *live* source: AwakeBar's own OAuth PKCE login (reusing
  Claude Code's public client id) and the `/api/oauth/usage` fetch behind the exact
  `/usage` numbers. Pure `base64URL`/`challenge`/`pkce`/`authorizeURL`/`splitCode`/
  `decodeToken`/`decodeUsage` are tested; the URLSession calls + `runLive` are IO.
- `TokenStore.swift` — persists the OAuth token in AwakeBar's *own* Keychain item
  (`UsageAPI.oauthKeychainService`, NOT `Claude Code-credentials`), so reads never
  prompt.
- `PlanLimitsCoordinator.swift` — owns the plan-usage opt-in flag, the connect/
  disconnect flow, the scan + live-fetch throttle (incl. a 429 cooldown), and the
  last-known usage the menu renders (live preferred, estimate as fallback).
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
- **Plan-usage has two sources; the estimate is the default, the live OAuth one
  is the upgrade.** The default `UsageLedger` estimate reads the JSONL transcripts
  and self-calibrates: a window's utilisation is its cost as a fraction of the
  largest same-length window in your whole history. Approximate, reads 100% on a
  new peak — hence "(est.)". Cost is the limit-unit proxy (a cache read weighs
  ~1/10th of fresh input); prices live in `UsageLedger.prices`. "Connect Claude
  Account…" upgrades it to the exact numbers from `/api/oauth/usage` (header drops
  the "(est.)", per-model weekly rows appear). Off by default.
- **Why the live path is our *own* OAuth login, not Claude Code's token.** Reading
  `Claude Code-credentials` re-prompts on every token rotation (Claude Code
  delete+recreates the item, wiping our ACL grant). So `UsageOAuth` runs an
  independent PKCE login and `TokenStore` keeps our own Keychain item — no prompt,
  no rotation race (this is how CodeQuota coexists with Claude Code). The endpoint
  is **undocumented/reverse-engineered** (Anthropic disowns it) and 429-prone, so
  it's polled ≥5 min, keeps last-good on 429/offline, and degrades to the estimate
  if a grant dies — a break never blanks the panel. The statusLine `rate_limits`
  block (the clean official source) stays unusable here: it isn't emitted in the
  VSCode extension / headless stream-json mode (verified — a successful headless
  turn invokes the statusLine 0×; CC issues #55643, #58071).

## Hook ↔ app IPC (`/tmp`)

The hooks (`notify-attention.sh`, `keep-awake.sh`) talk to the app through marker files:

- `claude-attention.json` — Claude needs you (`project`/`message`/`cwd`/`ts` dedup key).
- `claude-done.json` — turn ended (same fields plus `dur`, the turn's length in seconds; `-1` = start not recorded).
- `claude-keep-awake.reason` — why `caffeinate` is running (`turn` | `remote`); drives the **Claude Code Hook** menu wording.
- `claude-keep-awake.idle` — idle window in seconds that AwakeBar publishes for the hook's between-turns `caffeinate -t` (absent → hook's own 4 h backstop).
