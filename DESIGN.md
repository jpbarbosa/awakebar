# AwakeBar — design notes

The mechanics and rationale behind the behaviors described in
[README.md](README.md). For the build/test commands and source map, see
[CLAUDE.md](CLAUDE.md).

## Notifications: when Claude needs you

AwakeBar posts a native macOS notification when Claude Code is **blocked waiting
on you** — when it needs permission to run a tool, or when the prompt has been
idle for ≥60s. This rides Claude Code's `Notification` hook event, which fires
for exactly those two cases, wired via `notify-attention.sh`.

On `Notification` the hook drops a marker at `/tmp/claude-attention.json`
(`project`, `message`, `cwd`, and a `ts` dedup key); AwakeBar watches it with a
kqueue source — so it reacts instantly, not bound to the 10s poll — and posts the
notification via `UNUserNotificationCenter`, titled `Claude · <project>`, where
`<project>` is the session cwd's git-root basename (the workspace root, so a
session in `…/maru/frontend` reads `maru`, not `frontend`; it falls back to the
cwd's own basename outside a git repo) — so sessions across repos are
distinguishable, though sibling sessions in one repo share a title. The body drops the leading "Claude" so
it doesn't echo that title — *"Claude is requesting permission to use Bash"*
becomes **Requesting permission to use Bash**, *"Claude is waiting for your
input"* becomes **Waiting for your input** — and alerts from one session stack
under a single header (a `threadIdentifier` keyed by `cwd`, falling back to the
project name for the VSCode path) rather than listing every repeat. Clicking the
banner brings VSCode forward.

The alert is **deferred** by a grace period (the **Notification Delay** menu —
5 or 10 s, default 10), then dropped if you've engaged with that session in the
meantime — so it only fires when you've actually stepped away:

- **Quiet if you're on it** — the other three events (`PostToolUse`,
  `UserPromptSubmit`, `Stop`) bump a per-`cwd` activity marker. If that session's
  activity moves past the attention timestamp within the grace window — you
  approved the prompt, typed, or the turn ended — no banner. Keying by `cwd`
  means a *different* busy session (or VSCode window) never silences this one,
  which a plain "is VSCode frontmost?" check got wrong.
- **No replay on launch** — a marker left over from before AwakeBar started is
  recorded as already-seen; only a strictly newer `ts` fires.

When **Clear Notifications When Resumed** is on (the default), a delivered alert
is automatically withdrawn from Notification Center once that session starts
running again — so a stale "Claude is waiting" banner doesn't linger after you've
answered. Turn it off to keep delivered alerts as a record.

**VSCode is the exception.** The `Notification` hook never fires for VSCode's
*in-panel* permission prompts — it's a terminal-CLI event — so the hook path
covers terminal sessions only. For VSCode, AwakeBar instead reads the
extension's debug log (the same log it uses for Remote Control), which records
the extension's own `show_notification` intent (*"Claude is requesting permission
to use …"*) and the resolution (`tool_permission_response`, or the session
leaving `waiting_input`). The same grace applies — answer within the window and
no banner fires. Like the Remote Control detection this parses undocumented log
strings, centralised in `Sources/AwakeBar/Contract.swift` (mirrored by
`claude-hook-contract.sh`) so a Claude Code rename is a one-line fix.

It works for any session — terminal (via the hook) or VSCode (via the log), in
any window.

## Notifications: when a task finishes

The same hook also notifies you when a **task finishes** — gated on how long the
turn ran, *not* on whether you're at the keyboard, so it fires the instant a real
task ends whatever window you're in (switch to another VSCode window and you're
still told the moment it's done). `notify-attention.sh` records the turn's start
on `UserPromptSubmit` and, on `Stop`, writes a marker at `/tmp/claude-done.json`
(`project`/`message`/`cwd`/`ts` plus `dur`, the turn's length in seconds)
alongside the activity bump. AwakeBar watches it on its own kqueue source and
posts a *"Task finished at HH:mm"* banner — stamped with when the turn ended, so
a banner you spot later still says when it actually finished — when `dur` is at
least **30 s** — a real task — so quick conversational replies stay quiet (a `dur`
of −1, meaning the start wasn't recorded, errs toward notifying). It's deferred by
the same grace as the waiting alerts (the **Notification Delay** menu): resume the
session within that window — a new prompt bumps the activity marker past the done
timestamp — and the banner never fires, since you clearly saw it finish. Resume
*after* it has posted and, when **Clear Notifications When Resumed** is on, the
next poll (≤10 s) withdraws it. But a finished task is one you may never return
to, so that resume may never come; a delivered banner that has simply aged past
**5 minutes** is swept anyway, so completed-task FYIs don't pile up unanswered in
Notification Center. Toggle it with **Notify When Task Finishes** in the menu (on by
default); it needs no extra wiring beyond the `Stop` and `UserPromptSubmit`
events. This works in **VSCode too** — the `Stop` hook fires there even though the
`Notification` hook doesn't, so it fills the gap the in-panel-only permission
prompts leave.

Gating on duration rather than presence is deliberate: an idle check (no
keyboard/mouse) can't tell "stepped away" from "working in another window" — if
you switched to a second VSCode window to keep working, you're *not* idle, so an
idle-gated alert would never fire in exactly the case you wanted it. Turn length
is the signal that actually tracks "this was a task worth announcing."

## The Claude Code hook

`keep-awake.sh` runs a `caffeinate` while Claude is working and stops when the
turn ends — and for a **Remote Control** session it keeps the Mac awake *between*
turns too, so a session driven from claude.ai or mobile isn't killed by the Mac
sleeping. The between-turns hold is bounded: each turn restarts `caffeinate` with
`-t` set to the idle window AwakeBar publishes at `/tmp/claude-keep-awake.idle`
(default 4 h when that file is absent), so an idle remote session stops holding
once the window passes with no new turn.

`SessionStart` is wired `async` so a Remote Control session is held from the
moment it connects, not just from the first turn. While caffeinate runs the hook
records *why* in `/tmp/claude-keep-awake.reason` (`turn` or `remote`), which is
what drives the **Claude Code Hook** menu line's wording.

The app and the hook are independent — the app works on its own; the hook is what
makes the **Claude Code Hook** line light up.

## How awake detection works

State comes from `pmset -g assertions`, so it reflects the *whole system* —
unlike KeepingYouAwake or Amphetamine, whose icon only tracks their own
assertion. It counts the three assertion types that keep the *machine* awake
(`PreventUserIdleSystemSleep`, `PreventSystemSleep`, and the
`NoIdleSleepAssertion` that Electron's `powerSaveBlocker` registers — e.g.
Claude Desktop's own keep-awake). Ambient daemons (`powerd`, `bluetoothd`,
`sharingd`) are filtered out so a filled cup means something deliberate.

AwakeBar is mostly an *observer* — it reads the system's assertions rather than
creating them. It holds its own `PreventUserIdleSystemSleep` assertion (the Mac
stays awake; the display may still sleep) in two cases:

- **Remote Control** — automatically, while a bridge is connected, so a session
  driven from claude.ai / mobile can't be dropped by idle sleep in the gap
  between turns when the keep-awake hook isn't holding one. This hold is capped
  by the **Remote Idle Timeout** (below) so an abandoned remote session doesn't
  keep the Mac awake forever.
- **Keep awake** — a manual menu toggle to force the Mac awake regardless of
  Claude. It resets to off on each launch, and the menu-bar cup gets a small
  **red badge** while it's on.

Either assertion is filtered out of AwakeBar's own holder list (so it never
circularly lists itself) and surfaced instead under **Kept awake by:** as
*AwakeBar (Remote Control session)* / *AwakeBar (manual)*.

### Remote Idle Timeout

A remote session that's been left idle shouldn't keep the Mac awake
indefinitely. The **Remote Idle Timeout** menu (Off / 30 min / 1 hr / 2 hr,
default **1 hr**) releases the Remote Control hold once a connected session has
seen no activity (no prompt, tool use, or turn) for that long — a new turn
resets the timer. When it fires, the menu shows **Remote control: idle (sleep
allowed)** and the Mac can sleep normally.

Because the keep-awake hook *also* holds the Mac awake between turns for a
remote session, this only delivers a true cap end-to-end: AwakeBar publishes the
chosen window to `/tmp/claude-keep-awake.idle`, and `keep-awake.sh` restarts its
between-turns `caffeinate` with that as its `-t`, so the hook's own hold expires
on the same window instead of its 4 h backstop. Set the timeout to **Off** to
restore the old behavior (held as long as the bridge is connected; hook caps at
4 h/prompt). The idle signal comes from `notify-attention.sh`'s per-cwd activity
markers, so that hook must be installed for sub-4 h capping to apply.

## How Remote Control is detected

Claude Code no longer records Remote Control state in a file AwakeBar can read
(the old `~/.claude/sessions/<pid>.json` `bridgeSessionId` field is gone), and
the bridge multiplexes over the same TLS as normal inference, so it can't be
spotted from sockets either. Both the app and the hook fall back to the only
on-disk trace: the bridge **lifecycle** logged by Claude Code's VSCode
extension-host log, trusting the last connect/teardown marker. This is
best-effort — it works for **VSCode-hosted** sessions running with `--debug`
(the extension's default), and reads as "off" for pure-terminal sessions. The
marker strings are centralised in `Sources/AwakeBar/Contract.swift` and its shell
mirror `claude-hook-contract.sh` so a Claude Code rename is a one-line fix.

The app goes one step further and **lists which project** each connected
session is driving: the same log records the session's `cwd` (in its
`launch_claude` / `Spawning Claude` lines), so the menu shows the folder name
under **Remote control: active**. The cwd parse is anchored to those two
authoritative line shapes — the log also echoes back tool inputs (e.g. bash
commands you run), which can mention `cwd:` and must not be mistaken for the
real one. Granularity is per-window/per-project, not per-pid (one window
normally drives one session); if the launch line has scrolled out of the log
tail the entry falls back to a generic "Claude session".

## Plan usage (the optional `/usage` panel)

**Show Plan Usage** mirrors Claude Code's `/usage` limits in the menu. The
numbers come from the same read-only endpoint `/usage` itself uses —
`GET https://api.anthropic.com/api/oauth/usage` — which returns the plan's usage
windows (`five_hour`, `seven_day`, and per-model `seven_day_opus` /
`seven_day_sonnet`), each with a `utilization` and `resets_at`. We never call
`/v1/messages`: the usage endpoint is read-only and spends no message quota.

Authenticating reuses Claude Code's **own login** rather than asking for anything
new: the OAuth token lives in the login Keychain under the generic-password
service `Claude Code-credentials`, stored as a JSON blob
(`{ claudeAiOauth: { accessToken, subscriptionType, rateLimitTier, … } }`). The
same blob yields the plan label shown in the header (**Max (5x)** from
`subscriptionType` + the `Nx` in `rateLimitTier`). Reading another app's keychain
item triggers a one-time macOS prompt — hence the feature is **off until you opt
in**, and stays granted across rebuilds because `build.sh` signs with a stable
identity.

This is an **undocumented** interface, so everything fragile is quarantined:

- The endpoint, keychain service, beta header and User-Agent live in the
  `UsageAPI` enum in `Sources/AwakeBar/Contract.swift` (app-only — unlike the hook
  markers there's no shell mirror), so an upstream rename is a one-line fix; the
  JSON decoder (`PlanLimits.swift`) is deliberately lenient about field spellings.
- The **`User-Agent: claude-code/<ver>` header is load-bearing** — without it the
  endpoint drops you into an aggressively rate-limited bucket that returns `429`
  for many minutes. With it, AwakeBar still fetches sparingly: at most once every
  ~10 minutes (on launch, the refresh tick, and menu-open), it parks for 45
  minutes after a `429`, and a `401` (a rotated token) just skips the cycle —
  Claude Code refreshes the token on its next run. `PlanLimitsCoordinator` owns
  this throttle/cooldown so the menu code stays unaware of the network beneath.

Cosmetics: each row's pie fills clockwise with the window and turns **red past
75%**; reset times render with the system clock format (12-/24-hour) and locale;
the header links to the usage page on the web.
