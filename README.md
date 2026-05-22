# AwakeBar

A tiny macOS menu bar app that shows, at a glance, whether something is
deliberately keeping your Mac awake — with first-class awareness of the
Claude Code CLI.

## What it shows

A coffee cup in the menu bar:

- **☕ filled** — something is holding a system-sleep assertion
- **💤 empty** — the Mac can sleep normally

The dropdown lists the responsible processes and always shows a dedicated
**Claude Code hook** line — `keeping the Mac awake now` during a Claude turn,
`idle (last active 30s ago)` between turns:

```
☕ Mac is being kept awake
──────────────
Claude Code hook: keeping the Mac awake now
──────────────
Kept awake by:
   • caffeinate (Claude Code hook)
──────────────
Open at Login
Quit AwakeBar
```

State comes from `pmset -g assertions`, so it reflects the *whole system* —
unlike KeepingYouAwake or Amphetamine, whose icon only tracks their own
assertion. Ambient daemons (`powerd`, `bluetoothd`, `sharingd`) are filtered
out so a filled cup means something deliberate. AwakeBar only *reads* power
state; it never creates an assertion itself.

## Build & install

Requires macOS 15+ and Swift 6.2.

```sh
./build.sh
```

Builds and signs `AwakeBar.app`. For the first install, drag it to
`/Applications`, open it, and pick **Open at Login** from its menu — it lives
only in the menu bar, no Dock icon. After that, `./build.sh` keeps the
installed copy in sync on every rebuild.

## The Claude Code hook (optional)

`keep-awake.sh` is the paired Claude Code hook: it runs a `caffeinate` while
Claude is working and stops it when the turn ends. Install it by copying the
script to `~/.claude/` (and `chmod +x` it), then wiring it into
`~/.claude/settings.json`:

```json
{
  "hooks": {
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "~/.claude/keep-awake.sh" }] }],
    "Stop":            [{ "hooks": [{ "type": "command", "command": "~/.claude/keep-awake.sh" }] }],
    "SessionEnd":      [{ "hooks": [{ "type": "command", "command": "~/.claude/keep-awake.sh" }] }]
  }
}
```

The app and the hook are independent — the app works on its own; the hook is
what makes the **Claude Code hook** line light up.
