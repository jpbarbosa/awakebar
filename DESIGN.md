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

**Show Plan Usage** mirrors Claude's `/usage` screen in the menu. One source:
`GET /api/oauth/usage`, the endpoint that screen itself is drawing from, so the
rows are the real numbers rather than anything derived — including the per-model
weekly buckets. `PlanLimitsCoordinator` polls it at most every 5 minutes (the
bars move on the scale of hours, and that is also the endpoint's safe floor), off
the main actor, keeping the last-good values through a 429 or an outage so a blip
never blanks the panel. Off by default.

Getting a token is the whole design problem, and there are three ways:

- **Claude Code's own Keychain item** (`Claude Code-credentials`) — rejected.
  Reading another app's item triggers a macOS password prompt, and the grant will
  not stay put: Claude Code delete+recreates the item as it rotates the token,
  wiping our ACL entry, so the prompt keeps returning.
- **The status line's `rate_limits` payload** — the clean official local source,
  but an interactive-TUI feature. The VSCode extension runs Claude headless
  (`--output-format stream-json`), so the status line, and its `rate_limits`, is
  never emitted. (Verified: no VSCode session ever fires a configured `statusLine`
  command. CC issues #55643, #58071.)
- **Our own OAuth login** — what we do. `UsageOAuth` runs an independent PKCE
  login against Claude Code's *public* client id and `TokenStore` keeps the result
  in AwakeBar's own Keychain item, so nothing we hold is subject to another app's
  rotation. This is how CodeQuota coexists with Claude Code. The endpoint is
  undocumented and reverse-engineered, so its literals are centralised in
  `UsageAPI` — a drift is a one-line fix.

### The local estimate, and why it's gone

An earlier version filled the not-connected gap with `UsageLedger`: a local
estimate priced off Claude Code's JSONL transcripts, self-calibrated against the
largest same-length window in your history since Anthropic's real limit is in
opaque internal units. It was removed, and it is worth recording why, because the
idea is tempting enough to come back.

It could not be made to agree with `/usage`, only to hover near it. Both halves
of the fraction were guesses. The **denominator** was your own historical peak, so
it read ~100% whenever you set a new one and was ~1.7× off on a real corpus. The
**numerator** was worse: it measured trailing windows where `/usage` measures
anchored ones — a 5-hour block that opens on your first message, a weekly period
on a fixed schedule. For anyone who works most days a trailing window is always
full, so the bar sat pinned near its peak and its reset read *now*, permanently,
which is indistinguishable from a frozen panel. On a real corpus trailing said
35% / 79% where `/usage` said 5% / 10%.

Anchoring fixed most of that — the 5-hour boundary is recoverable by replaying
Anthropic's block rule over the transcripts, landing within 3 minutes of the real
one — but the weekly period's *phase* is nowhere on disk: no transcript, and
nothing else under `~/.claude`, records when your week rolls over. That left a
setting for the user to copy off the very screen the panel was trying to replace,
to power numbers that were still a few points out. Connecting an account is one
browser round-trip and makes all of it exact. The scan was also the app's entire
CPU and memory cost — a 3 GB corpus, ~250k usage lines, a 47-second cold pass —
so removing it took the incremental-scan cache, its `(mtime, size)` bookkeeping
and a hand-rolled ISO-8601 fast path with it.

Cosmetics: each row's pie fills clockwise with the window and turns **red past
75%**; reset times render with the system clock format (12-/24-hour) and locale;
the header links to the real usage page on the web.
