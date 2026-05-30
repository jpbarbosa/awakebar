# AwakeBar

A tiny macOS menu bar app that shows, at a glance, whether something is
deliberately keeping your Mac awake — with first-class awareness of the
Claude Code CLI. It can also **notify you when Claude is waiting on you** (a
permission prompt, or an idle session), so you can step away and get pulled
back the moment Claude needs a decision.

![AwakeBar showing the menu bar dropdown next to a Claude Code session](awakebar.webp)

## What it shows

A coffee cup in the menu bar:

- **☕ filled** — something is holding a system-sleep assertion
- **💤 empty** — the Mac can sleep normally

The dropdown lists the responsible processes and always shows a dedicated
**Claude Code hook** line — `Claude is working` during a turn,
`holding for a remote session` when a Remote Control session keeps the Mac
awake between turns, `idle (last active 30s ago)` otherwise — plus a live
**Remote control** line:

```
☕ Mac is being kept awake
──────────────
Claude Code hook: holding for a remote session
Remote control: active
──────────────
Kept awake by:
   caffeinate (Claude Code hook)
──────────────
Open at Login
Quit AwakeBar
```

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
  between turns when the keep-awake hook isn't holding one.
- **Keep awake** — a manual menu toggle to force the Mac awake regardless of
  Claude. It resets to off on each launch, and the menu-bar cup gets a small
  **red badge** while it's on.

Either assertion is filtered out of AwakeBar's own holder list (so it never
circularly lists itself) and surfaced instead under **Kept awake by:** as
*AwakeBar (Remote Control session)* / *AwakeBar (manual)*.

## Build & install

Requires macOS 15+ and Swift 6.2.

```sh
./build.sh
```

Builds and signs `AwakeBar.app`. For the first install, drag it to
`/Applications`, open it, and pick **Open at Login** from its menu — it lives
only in the menu bar, no Dock icon. After that, `./build.sh` keeps the
installed copy in sync on every rebuild.

The app icon — a coffee cup on a Liquid-Glass-style squircle — is assembled in
`icon/make-icon.swift`: the tile (squircle, gloss, sheen) is drawn in Core
Graphics and the cup (`icon/black-coffee-cup.png`, a transparent 3D render) is
composited on top with a soft drop shadow. It's deliberately not the SF Symbol
`cup.and.saucer` — Apple's SF Symbols licence bars its symbols from app icons;
if the PNG is removed it falls back to a drawn vector cup. `build.sh` bundles the
prebuilt `icon/AppIcon.icns`; re-run `./icon/build-iconset.sh <style>`
(`espresso` · `aqua` · `graphite`) to regenerate the tile palette.

## The Claude Code hook (optional)

`keep-awake.sh` is the paired Claude Code hook: it runs a `caffeinate` while
Claude is working and stops when the turn ends — and for a **Remote Control**
session it keeps the Mac awake *between* turns too, so a session driven from
claude.ai or mobile isn't killed by the Mac sleeping. Install it by copying
the script to `~/.claude/` (and `chmod +x` it), then wiring it into
`~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart":    [{ "hooks": [{ "type": "command", "command": "~/.claude/keep-awake.sh", "async": true }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "~/.claude/keep-awake.sh" }] }],
    "Stop":            [{ "hooks": [{ "type": "command", "command": "~/.claude/keep-awake.sh" }] }],
    "SessionEnd":      [{ "hooks": [{ "type": "command", "command": "~/.claude/keep-awake.sh" }] }]
  }
}
```

`SessionStart` is wired `async` so a Remote Control session is held from the
moment it connects, not just from the first turn. While caffeinate runs the
hook records *why* in `/tmp/claude-keep-awake.reason` (`turn` or `remote`),
which is what drives the **Claude Code hook** line's wording.

The app and the hook are independent — the app works on its own; the hook is
what makes the **Claude Code hook** line light up.

## Notifications when Claude needs you

AwakeBar posts a native macOS notification when Claude Code is **blocked waiting
on you** — when it needs permission to run a tool, or when the prompt has been
idle for ≥60s. This rides Claude Code's `Notification` hook event, which fires
for exactly those two cases. Install the paired hook by copying
`notify-attention.sh` to `~/.claude/` (`chmod +x` it) and wiring these events in
`~/.claude/settings.json` (the last three can sit alongside `keep-awake.sh` on
the same events):

```json
{
  "hooks": {
    "Notification":     [{ "hooks": [{ "type": "command", "command": "~/.claude/notify-attention.sh" }] }],
    "PostToolUse":      [{ "hooks": [{ "type": "command", "command": "~/.claude/notify-attention.sh" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "~/.claude/notify-attention.sh" }] }],
    "Stop":             [{ "hooks": [{ "type": "command", "command": "~/.claude/notify-attention.sh" }] }]
  }
}
```

On `Notification` the hook drops a marker at `/tmp/claude-attention.json`
(`project`, `message`, `cwd`, and a `ts` dedup key); AwakeBar watches it with a
kqueue source — so it reacts instantly, not bound to the 10s poll — and posts the
notification via `UNUserNotificationCenter`, titled with the project so
concurrent sessions are distinguishable. Clicking the banner brings VSCode
forward.

The alert is **deferred ~10 seconds**, then dropped if you've engaged with that
session in the meantime — so it only fires when you've actually stepped away:

- **Quiet if you're on it** — the other three events (`PostToolUse`,
  `UserPromptSubmit`, `Stop`) bump a per-`cwd` activity marker. If that session's
  activity moves past the attention timestamp within the grace window — you
  approved the prompt, typed, or the turn ended — no banner. Keying by `cwd`
  means a *different* busy session (or VSCode window) never silences this one,
  which a plain "is VSCode frontmost?" check got wrong.
- **No replay on launch** — a marker left over from before AwakeBar started is
  recorded as already-seen; only a strictly newer `ts` fires.

**VSCode is the exception.** The `Notification` hook never fires for VSCode's
*in-panel* permission prompts — it's a terminal-CLI event — so the hook path
above covers terminal sessions only. For VSCode, AwakeBar instead reads the
extension's debug log (the same log it uses for Remote Control), which records
the extension's own `show_notification` intent (*"Claude is requesting permission
to use …"*) and the resolution (`tool_permission_response`, or the session
leaving `waiting_input`). The same ~10s grace applies — answer within the window
and no banner fires. Like the Remote Control detection this parses undocumented
log strings, centralised in `main.swift` so a Claude Code rename is a one-line fix.

The first time it fires, macOS asks you to allow notifications for AwakeBar. To
turn the feature off, remove the hooks or switch AwakeBar off in **System
Settings ▸ Notifications**. It works for any session — terminal (via the hook) or
VSCode (via the log), in any window.

### How Remote Control is detected

Claude Code no longer records Remote Control state in a file AwakeBar can read
(the old `~/.claude/sessions/<pid>.json` `bridgeSessionId` field is gone), and
the bridge multiplexes over the same TLS as normal inference, so it can't be
spotted from sockets either. Both the app and the hook fall back to the only
on-disk trace: the bridge **lifecycle** logged by Claude Code's VSCode
extension-host log, trusting the last connect/teardown marker. This is
best-effort — it works for **VSCode-hosted** sessions running with `--debug`
(the extension's default), and reads as "off" for pure-terminal sessions. The
marker strings are centralised in both `main.swift` and `keep-awake.sh` so a
Claude Code rename is a one-line fix.

The app goes one step further and **lists which project** each connected
session is driving: the same log records the session's `cwd` (in its
`launch_claude` / `Spawning Claude` lines), so the menu shows the folder name
under **Remote control: active**. The cwd parse is anchored to those two
authoritative line shapes — the log also echoes back tool inputs (e.g. bash
commands you run), which can mention `cwd:` and must not be mistaken for the
real one. Granularity is per-window/per-project, not per-pid (one window
normally drives one session); if the launch line has scrolled out of the log
tail the entry falls back to a generic "Claude session".
