# AwakeBar — Usage Metrics Plan

**Status:** Plan Usage shipped as a **local estimate** (behind a flag) · **Created:** 2026-06-01 · **Pivoted:** 2026-06-06
**Owner:** JP · **Scope:** add usage metrics to the menu bar in two independent panels.

> **Decision (2026-06-01):** build **Panel 2** first (the actionable plan-limit
> number on a Max subscription) and leave **Panel 1** for a later opportunity.
> Panel 2 shipped as `PlanLimits.swift` + `PlanLimitsCoordinator.swift` +
> `UsageAPI` in `Contract.swift`, with a "Show Plan Usage" toggle (off by
> default) and `PlanLimitsTests.swift`. Remaining: verify against the live
> `/usage` screen once, and confirm the exact per-model bucket keys / the
> Keychain blob shape on the first real response (the decoder is written to be
> lenient about both until then).
>
> **Pivot (2026-06-06):** Panel 2's `/api/oauth/usage` path was **replaced by a
> local estimate** (`UsageLedger.swift`). The Keychain access prompt that gates
> the OAuth token wouldn't stay granted under heavy concurrent-session use, and
> the only other local source of the exact numbers — the status line's
> `rate_limits` — is never emitted in the VSCode extension's headless
> (`stream-json`) mode. So Panel 2 became a **merge of Panels 1 and 2**: it reads
> the JSONL transcripts (Panel 1's source) and derives self-calibrated 5h/weekly
> bars from cost, labelled **(est.)**. `PlanLimits.swift` shrank to shared
> types + formatting; the Keychain/network/429-cooldown code and the `decode`/
> `credential`/`planLabel` helpers (and their tests) are gone. The exact `/usage`
> API findings below are kept for history but are no longer wired up.

Background research is captured inline so this doc stands alone. See also
[CLAUDE.md](CLAUDE.md), [DESIGN.md](DESIGN.md).

---

## 1. Goal

Surface Claude Code usage in the AwakeBar menu, as **two independent panels** that
answer different questions and come from different sources:

- **Panel 1 — Session tokens/cost (local).** "How many tokens / ~$ have I burned on
  this machine (this session / today)." Read locally from JSONL transcripts. No auth,
  no network. Low risk. **Build this first.**
- **Panel 2 — Plan limits (remote).** Reproduce Claude Code's `/usage` screen:
  5-hour window %, weekly all-models %, per-model weekly (Sonnet/Opus), reset times.
  Requires the existing Claude Code OAuth token. Undocumented / ToS-gray. **Behind a
  flag, off by default.**

The two are decoupled: Panel 1 can ship without Panel 2.

---

## 2. Verified findings (the basis for this plan)

### Panel 1 — JSONL transcripts
- **Source:** `~/.claude/projects/**/*.jsonl`, one file per session (verified: 805 files
  present; awakebar project has its own dir).
- **Per-assistant-line shape** (verified on this machine, CC `2.1.157`):
  `type:"assistant"` → `message.model` + `message.usage` with
  `input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`;
  plus top-level `cwd`, `gitBranch`, `sessionId`, `requestId`, `isSidechain`, `timestamp`.
- **Dedup:** sum per unique `(message.id, requestId)` — streaming writes 2–10 lines per
  request; without dedup you multi-count (this is what `ccusage` does).
- **Known bug (mitigated):** in some CC versions `input_tokens`/`output_tokens` are
  streaming placeholders (0/1), undercounting non-cache input. **Did NOT reproduce** on
  `2.1.157` (0/16 placeholder lines). Cache tokens are always accurate, and on real data
  non-cache input was ~3.7% of input-side tokens, so **cost is dominated by reliable
  fields** (cache_read + cache_creation + output). Lean cost on those.
- **No USD in the file** (`stats-cache.json`'s `costUSD` is `0`), so cost needs a small
  **per-model price table** ($/Mtok × the 4 token classes). Source candidate: vendor
  LiteLLM's pricing JSON (what ccusage uses) or hardcode the few models in use.

### Panel 2 — Plan limits API
- **Source:** `GET https://api.anthropic.com/api/oauth/usage` (read-only JSON; reproduces
  the entire `/usage` screen including the per-model bars).
- **Body buckets**, each `{ utilization: 0–100, resets_at: ISO }`:
  `five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet` (null when unused),
  `extra_usage` `{ is_enabled, monthly_limit, used_credits, utilization }`.
- **Auth:** OAuth token from macOS Keychain item `Claude Code-credentials`
  (verified present, acct `jp`). Value is a JSON blob:
  `{ claudeAiOauth: { accessToken, refreshToken, expiresAt, scopes } }` → use `accessToken`.
- **Required headers:** `Authorization: Bearer <accessToken>`,
  `anthropic-beta: oauth-2025-04-20`, `User-Agent: claude-code/<version>`,
  `Content-Type: application/json`.
- **Safety (avoid getting flagged / the 429 trap):**
  1. `User-Agent: claude-code/<version>` is **mandatory** — without it the endpoint
     drops you into an aggressively rate-limited bucket and 429s persist for 30+ min.
  2. Use the read-only `/api/oauth/usage`; never fire `/v1/messages` just to read headers
     (burns real quota and looks like activity).
  3. Poll slowly — data changes only every few hours. Refresh on the existing `Stop` hook
     (≈once/turn) or a ~10–15 min timer / on menu-open. No tight loops.
  4. On `429`: long cooldown (≥30 min), stop polling; there's no `Retry-After`.
  5. On `401`: token rotated — skip the cycle (Claude Code refreshes it on next run).
  6. Single in-flight request; never log/persist the token.

### Rejected alternatives (don't relitigate)
- **OTEL export** — accurate USD + officially documented, but needs a local collector
  daemon + env vars on every CC launch. Too heavy for a "tiny" app. Revisit only if an
  official, file-based path appears.
- **Admin API key** — org-level only, ~1h–2day delay. Not a fit for an individual.
- **`/v1/messages` header probe** — gives only 2 of 3 bars and spends a real generation.
- **CLI delegation (`claude` shell-out)** — no machine-readable usage subcommand.
- **`stats-cache.json`** — pre-aggregated but recomputed lazily (stale); good only as an
  optional "lifetime" footer, never for live numbers.

---

## 3. Architecture / files to touch

New (`Sources/AwakeBar/`):
- `UsageMonitor.swift` — Panel 1: kqueue-watch the projects tree (reuse the
  [AttentionWatcher.swift](Sources/AwakeBar/AttentionWatcher.swift) pattern), tail JSONL by
  byte offset, parse + dedup `(message.id, requestId)`, sum tokens, compute cost.
- `Pricing.swift` — per-model `$/Mtok` table (input/output/cache-write/cache-read). May
  fold into `UsageMonitor.swift` initially.
- `PlanLimits.swift` — Panel 2: Keychain read → token → `/api/oauth/usage` request →
  decode buckets. All network + auth isolated here, behind a flag.

Edit:
- `Contract.swift` — add a `UsageAPI`/`UsageMarkers` section: endpoint URL, Keychain
  service name, beta header, User-Agent builder, and the JSONL field names. Keep the
  undocumented strings here (and mirror in `claude-hook-contract.sh` only if a hook needs
  them), per the CLAUDE.md "one-line rename fix" convention.
- `AppDelegate.swift` — menu items for both panels; wire Panel 2 refresh to the `Stop`
  hook path / a slow timer; feature flag for Panel 2.

Tests (`Tests/AwakeBarTests/`):
- `UsageMonitorTests.swift` — dedup + token-sum + cost math against a checked-in fixture
  transcript (a small real `.jsonl` excerpt). Mirrors the existing
  `AwakeMonitorTests.swift` style.

---

## 4. Milestones (ordered; each independently verifiable)

- **M0 — Contract scaffolding.** Add the `UsageAPI`/JSONL constants to `Contract.swift`.
  *Done when:* builds clean, constants referenced by stubs.
- **M1 — Panel 1 parser + test (no UI, no auth).** Parse one transcript, dedup, sum the 4
  token classes, compute cost from the price table. *Done when:* `swift test` proves the
  numbers against a real fixture and they match a hand check.
- **M2 — Panel 1 live watcher + menu.** kqueue-watch the projects tree, tail incrementally,
  publish "session/today tokens + ~$" to the menu. *Done when:* numbers update live while a
  Claude session runs.
- **M3 — Panel 2 client (flagged, off).** Keychain read → `/api/oauth/usage` with full
  safety rails; decode buckets; log to console only. *Done when:* one manual refresh shows
  the same %s as the `/usage` screen, with correct User-Agent and no 429.
- **M4 — Panel 2 menu (3 bars).** Render five_hour / seven_day / per-model + reset times,
  matching the `/usage` layout. *Done when:* the menu mirrors the screenshot.
- **Bonus — lifetime footer.** Read `stats-cache.json` for all-time totals / busiest hour.
  *Optional, only if time.*

Dependencies: M1 → M2 (Panel 1); M3 → M4 (Panel 2). Panel 1 and Panel 2 are independent.

---

## 5. This-week schedule (Jun 1–7)

- **Mon–Tue:** M0 + M1. Land the parser and its test first — lowest risk, no auth, proves
  the dedup/cost math before any UI or network.
- **Wed:** M2. Live watcher + Panel 1 menu. Panel 1 is shippable on its own here.
- **Thu:** M3. Panel 2 client behind a flag; verify against `/usage`, confirm User-Agent
  keeps us out of the 429 bucket.
- **Fri:** M4. Panel 2 bars in the menu. Buffer for polish / `stats-cache.json` bonus.

Checkpoint after M1: if the placeholder bug shows up on a future CC version, fall back to
cost-from-cache+output and surface tokens only.

---

## 6. Risks & open questions

- **Panel 2 is undocumented / ToS-gray.** Mitigate: your-token-to-your-own-account, local,
  low-frequency, exact-client mimicry. Isolate behind `Contract.swift` + a flag so a break
  or an official replacement is a one-spot change. Track CC issues #33820 / #36056 / #50518
  (pressure to expose this officially to hooks/statusline) and switch when sanctioned.
- **Keychain prompt.** First read triggers a one-time macOS "Always Allow"; it sticks only
  if `build.sh`'s signing identity stays stable. Confirm the ACL survives a rebuild.
- **Token rotation.** Handle `401` gracefully; never assume the cached token is fresh.
- **Pricing drift.** A hardcoded table goes stale as models/prices change. Decide:
  vendor LiteLLM JSON vs. maintain a tiny hardcoded map. (Open.)
- **"Session" semantics.** Panel 1 "session" = a CC conversation; Panel 2 "session" =
  the 5-hour window. Label them distinctly in the UI to avoid confusion.
- **Per-model bar labels.** The screenshot showed "Sonnet only"; the API also exposes
  `seven_day_opus`. Decide which to render (likely both, when non-null).

---

## 7. Out of scope (for this week)
- OTEL / collector integration.
- Historical charts / dashboards beyond a lifetime footer.
- Cost for API-key (non-subscription) usage.
- Multi-machine aggregation of plan usage (Panel 2 is already account-wide via the API;
  Panel 1 stays this-machine-only by design).
