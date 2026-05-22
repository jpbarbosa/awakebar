import Cocoa
import ServiceManagement

// MARK: - Monitor
//
// Reads the *global* power-assertion state via `pmset -g assertions`. This
// reflects whatever is keeping the Mac awake, regardless of which process
// created the assertion — including a `caffeinate` spawned by a Claude Code
// hook, a download, video playback, etc. (Apps like KeepingYouAwake only
// know about their own assertion; this watches the whole system.)

final class AwakeMonitor {
    enum State { case awake, canSleep }

    // One process keeping the Mac awake. `isClaudeHook` is true when this is
    // the `caffeinate` started by the Claude Code keep-awake hook.
    struct Holder {
        let name: String
        let isClaudeHook: Bool
    }

    private(set) var state: State = .canSleep
    private(set) var holders: [Holder] = []

    // Whether the Claude Code keep-awake hook's caffeinate is holding the Mac
    // awake right now, and whether the hook script is installed at all.
    private(set) var hookActive = false
    private(set) var hookInstalled = false

    // Assertions that keep the *machine* awake. Display-sleep assertions are
    // deliberately ignored — a dark screen with the Mac still working is
    // exactly what the hook aims for.
    private let relevant = ["PreventUserIdleSystemSleep", "PreventSystemSleep"]

    // Ambient daemons that hold sleep assertions as routine background
    // housekeeping — not a deliberate "keep awake". Filtering them keeps the
    // cup meaningful; otherwise it reads "awake" almost permanently:
    //   powerd     — "Prevent sleep while display is on" (a tautology)
    //   bluetoothd — Bluetooth stack activity from paired peripherals
    //   sharingd   — Handoff / Continuity
    // (coreaudiod is intentionally NOT here — audio playback genuinely, and
    // meaningfully, keeps the Mac awake.)
    private let ignoredProcesses: Set<String> = ["powerd", "bluetoothd", "sharingd"]

    // keep-awake.sh writes its caffeinate PID here while a Claude turn runs.
    private let hookPidFile = "/tmp/claude-keep-awake.pid"

    // The hook script itself — its presence distinguishes "idle" from "not set up".
    static let hookScriptPath =
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude/keep-awake.sh")

    func refresh() {
        let text = runPmset()
        let hookPID = readHookPID()

        var order: [String] = []
        var pidsByName: [String: Set<Int>] = [:]
        var inProcessSection = false

        // Decide purely from the per-process list (skipping `powerd`); the
        // system-wide summary can't separate real holders from the tautology.
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)

            if line.trimmingCharacters(in: .whitespaces)
                .hasPrefix("Listed by owning process") {
                inProcessSection = true
                continue
            }
            guard inProcessSection,
                  relevant.contains(where: { line.contains($0) }),
                  let parsed = AwakeMonitor.parseHolder(line: line),
                  !ignoredProcesses.contains(parsed.name)
            else { continue }

            if pidsByName[parsed.name] == nil {
                pidsByName[parsed.name] = []
                order.append(parsed.name)
            }
            pidsByName[parsed.name]?.insert(parsed.pid)
        }

        // A name is the Claude hook if one of its live PIDs is the hook's PID.
        holders = order.map { name in
            let isHook = hookPID.map { pidsByName[name]?.contains($0) ?? false } ?? false
            return Holder(name: name, isClaudeHook: isHook)
        }
        state = holders.isEmpty ? .canSleep : .awake
        hookActive = holders.contains { $0.isClaudeHook }
        hookInstalled = FileManager.default.fileExists(atPath: Self.hookScriptPath)
    }

    private func runPmset() -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        proc.arguments = ["-g", "assertions"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    // The hook's caffeinate PID, or nil if the hook isn't currently active
    // (keep-awake.sh removes the file when the turn ends). A stale PID is
    // harmless: it simply won't match any live holder.
    private func readHookPID() -> Int? {
        guard let raw = try? String(contentsOfFile: hookPidFile, encoding: .utf8)
        else { return nil }
        return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // Parses a `pmset` per-process line: "   pid 123(name): [...] ...".
    private static func parseHolder(line: String) -> (pid: Int, name: String)? {
        guard let open = line.firstIndex(of: "(") else { return nil }
        let afterOpen = line.index(after: open)
        guard let close = line[afterOpen...].firstIndex(of: ")") else { return nil }
        let name = String(line[afterOpen..<close])
        guard !name.isEmpty else { return nil }

        // The PID is the run of digits immediately before "(".
        let digits = line[..<open].reversed().prefix { $0.isNumber }
        guard let pid = Int(String(digits.reversed())) else { return nil }
        return (pid, name)
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let monitor = AwakeMonitor()
    private var timer: Timer?
    private var lastAwake: Bool?
    private var hookLastActive: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create the status item HERE, not in a property initializer — doing it
        // before the app finishes launching can leave the item not displayed.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        update()
        NSLog("AwakeBar: launched; status item button = %@",
              statusItem.button != nil ? "ok" : "nil")

        // The timer fires on the main run loop, so it is safe to assume
        // main-actor isolation here rather than hop with a Task.
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    // Refresh the moment the menu opens so the dropdown is never stale.
    func menuWillOpen(_ menu: NSMenu) { update() }

    private func update() {
        monitor.refresh()
        if monitor.hookActive { hookLastActive = Date() }
        let awake = monitor.state == .awake

        if let button = statusItem.button {
            let symbol = awake ? "cup.and.saucer.fill" : "cup.and.saucer"
            if let image = NSImage(systemSymbolName: symbol,
                                   accessibilityDescription: "Keep-awake status") {
                image.isTemplate = true
                button.image = image
                button.title = ""
            } else {
                // Never leave the item empty (invisible) if SF Symbols fail.
                button.image = nil
                button.title = awake ? "☕︎" : "Zz"
            }
            button.toolTip = awake ? "Mac is being kept awake"
                                   : "Mac can sleep normally"
        }

        if awake != lastAwake {
            let names = monitor.holders
                .map { $0.isClaudeHook ? "\($0.name)(claude-hook)" : $0.name }
                .joined(separator: ", ")
            NSLog("AwakeBar: state = %@, holders = [%@]",
                  awake ? "awake" : "canSleep", names)
            lastAwake = awake
        }

        rebuildMenu(awake: awake)
    }

    private func rebuildMenu(awake: Bool) {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        let header = NSMenuItem(
            title: awake ? "Mac is being kept awake"
                         : "Mac can sleep normally",
            action: nil, keyEquivalent: "")
        if let icon = NSImage(
            systemSymbolName: awake ? "cup.and.saucer.fill" : "cup.and.saucer",
            accessibilityDescription: nil) {
            icon.isTemplate = true   // flat, monochrome — follows the menu text color
            header.image = icon
        }
        header.isEnabled = false
        menu.addItem(header)

        // Claude Code hook status — always shown, so you can tell at a glance
        // whether Claude is what's keeping the Mac awake.
        menu.addItem(.separator())
        let hookItem = NSMenuItem(title: claudeHookStatusText(),
                                  action: nil, keyEquivalent: "")
        hookItem.isEnabled = false
        menu.addItem(hookItem)

        if awake && !monitor.holders.isEmpty {
            menu.addItem(.separator())
            let label = NSMenuItem(title: "Kept awake by:", action: nil, keyEquivalent: "")
            label.isEnabled = false
            menu.addItem(label)
            for holder in monitor.holders {
                let suffix = holder.isClaudeHook ? " (Claude Code hook)" : ""
                let item = NSMenuItem(title: "    •  \(holder.name)\(suffix)",
                                      action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Open at Login",
                               action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)

        let quit = NSMenuItem(title: "Quit AwakeBar",
                              action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // The always-present Claude line. Between turns the hook's caffeinate is
    // gone, so this reports the last time it ran rather than just "idle".
    private func claudeHookStatusText() -> String {
        if !monitor.hookInstalled {
            return "Claude Code hook: not installed"
        }
        if monitor.hookActive {
            return "Claude Code hook: keeping the Mac awake now"
        }
        if let last = hookLastActive {
            return "Claude Code hook: idle (last active \(Self.relativeAge(last)))"
        }
        return "Claude Code hook: idle"
    }

    private static func relativeAge(_ date: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(date)))
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change the login item"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu-bar only: no Dock icon, no Cmd-Tab
app.run()
