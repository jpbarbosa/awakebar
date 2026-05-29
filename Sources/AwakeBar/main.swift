import Cocoa
import ServiceManagement
import IOKit.pwr_mgt   // IOPMAssertion*, to hold the Mac awake for remote sessions
import Darwin          // kill(2), for the session liveness check

// MARK: - Monitor
//
// Reads the *global* power-assertion state via `pmset -g assertions`. This
// reflects whatever is keeping the Mac awake, regardless of which process
// created the assertion — including a `caffeinate` spawned by a Claude Code
// hook, a download, video playback, etc. (Apps like KeepingYouAwake only
// know about their own assertion; this watches the whole system.)
//
// All collection runs off the main thread (see AwakeMonitor.collect), so the
// menu never blocks on `pmset` or on scanning Claude Code's logs. The work is
// pure — it reads the world and returns a Sendable Snapshot — so there is no
// shared mutable state to guard.

enum AwakeMonitor {
    enum State: Sendable { case awake, canSleep }

    // One process keeping the Mac awake. `isClaudeHook` is true when this is
    // the `caffeinate` started by the Claude Code keep-awake hook.
    struct Holder: Sendable {
        let name: String
        let isClaudeHook: Bool
    }

    // Why the keep-awake hook is holding the Mac awake.
    //   .turn   — Claude is actively working a turn
    //   .remote — held between turns because the session is remote-controlled
    enum HookReason: Sendable { case turn, remote, unknown }

    // An immutable view of everything the menu needs, produced by collect().
    struct Snapshot: Sendable {
        var state: State = .canSleep
        var holders: [Holder] = []

        // Whether the Claude Code keep-awake hook's caffeinate is holding the
        // Mac awake right now, why, and whether the hook script is installed.
        var hookActive = false
        var hookReason: HookReason = .unknown
        var hookInstalled = false

        // Project folders (cwd basenames) of the VSCode windows that currently
        // have Remote Control connected. Empty means no remote session.
        var remoteProjects: [String] = []
        var remoteControlActive: Bool { !remoteProjects.isEmpty }
    }

    // Assertions that keep the *machine* awake. Display-sleep assertions are
    // deliberately ignored — a dark screen with the Mac still working is
    // exactly what the hook aims for. NoIdleSleepAssertion is the type
    // Electron's `powerSaveBlocker` registers (e.g. Claude Desktop's
    // keep-awake), so it's counted alongside the `caffeinate`-style ones.
    private static let relevant = ["PreventUserIdleSystemSleep", "PreventSystemSleep",
                                   "NoIdleSleepAssertion"]

    // Ambient daemons that hold sleep assertions as routine background
    // housekeeping — not a deliberate "keep awake". Filtering them keeps the
    // cup meaningful; otherwise it reads "awake" almost permanently:
    //   powerd     — "Prevent sleep while display is on" (a tautology)
    //   bluetoothd — Bluetooth stack activity from paired peripherals
    //   sharingd   — Handoff / Continuity
    // (coreaudiod is intentionally NOT here — audio playback genuinely, and
    // meaningfully, keeps the Mac awake.)
    private static let ignoredProcesses: Set<String> = ["powerd", "bluetoothd", "sharingd"]

    // keep-awake.sh writes its caffeinate PID here while a Claude turn runs,
    // and the reason ("turn" / "remote") in the sibling .reason file.
    private static let hookPidFile = "/tmp/claude-keep-awake.pid"
    private static let hookReasonFile = "/tmp/claude-keep-awake.reason"

    // The hook script itself — its presence distinguishes "idle" from "not set up".
    static let hookScriptPath =
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude/keep-awake.sh")

    // Read the whole world and return a Snapshot. Safe to call off the main
    // thread; touches no shared mutable state.
    static func collect() -> Snapshot {
        var snap = Snapshot()
        let text = runPmset()
        let hookPID = readHookPID()

        // Our own assertion (held while a remote session is connected, see
        // AppDelegate) would otherwise show up here as a holder named after
        // this process — a circular "AwakeBar keeps AwakeBar awake". Filter it
        // out; the remote hold is surfaced separately via remoteProjects.
        let selfName = ProcessInfo.processInfo.processName

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
                  let parsed = parseHolder(line: line),
                  !ignoredProcesses.contains(parsed.name),
                  parsed.name != selfName
            else { continue }

            if pidsByName[parsed.name] == nil {
                pidsByName[parsed.name] = []
                order.append(parsed.name)
            }
            pidsByName[parsed.name]?.insert(parsed.pid)
        }

        // A name is the Claude hook if one of its live PIDs is the hook's PID.
        snap.holders = order.map { name in
            let isHook = hookPID.map { pidsByName[name]?.contains($0) ?? false } ?? false
            return Holder(name: name, isClaudeHook: isHook)
        }
        snap.state = snap.holders.isEmpty ? .canSleep : .awake
        snap.hookActive = snap.holders.contains { $0.isClaudeHook }
        snap.hookReason = snap.hookActive ? readHookReason() : .unknown
        snap.hookInstalled = FileManager.default.fileExists(atPath: hookScriptPath)
        snap.remoteProjects = checkRemoteControl()
        return snap
    }

    private static func runPmset() -> String {
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
    private static func readHookPID() -> Int? {
        guard let raw = try? String(contentsOfFile: hookPidFile, encoding: .utf8)
        else { return nil }
        return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // Why the hook is holding the Mac awake, per its sibling .reason file.
    private static func readHookReason() -> HookReason {
        guard let raw = try? String(contentsOfFile: hookReasonFile, encoding: .utf8)
        else { return .unknown }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "turn":   return .turn
        case "remote": return .remote
        default:       return .unknown
        }
    }

    // Live remote-control check — returns the project folder of each VSCode
    // window whose Remote Control bridge is currently connected (deduped).
    //
    // Claude Code no longer records Remote Control state in
    // ~/.claude/sessions/<pid>.json (the old `bridgeSessionId` field is gone),
    // and the bridge multiplexes over the same TLS as normal inference, so it
    // can't be spotted from sockets or process state either. The only on-disk
    // trace for a VSCode-hosted session is the extension-host debug log, which
    // records both the bridge lifecycle *and* the session's cwd. Per log we
    // read the tail and trust the last lifecycle marker: a connect-class marker
    // newer than any teardown means the bridge is up, and the most recent cwd
    // line in the same tail names the project.
    //
    // Best-effort heuristic (documented in the README):
    //  * VSCode only — pure-terminal sessions log to stderr, not this file.
    //  * Needs a --debug session (Claude's VSCode extension runs with it).
    //  * Per-window/per-project granularity, not per-pid: one window normally
    //    drives one session, so cwd is a faithful label.
    //  * Parses undocumented debug strings; the markers are centralised below
    //    so a Claude Code rename is a one-line fix here.
    private static func checkRemoteControl() -> [String] {
        // A crashed session can leave a "connected" log behind; require that at
        // least one Claude session is actually alive before trusting the logs.
        guard hasLiveSession() else { return [] }
        var projects: [String] = []
        for log in recentVSCodeLogs(within: remoteLogFreshness) {
            if let project = connectedProject(inTailOf: log),
               !projects.contains(project) {
                projects.append(project)
            }
        }
        return projects
    }

    // True when some ~/.claude/sessions/<pid>.json is named by a live PID.
    private static func hasLiveSession() -> Bool {
        let dir = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".claude/sessions")
        guard let files = try? FileManager.default
            .contentsOfDirectory(atPath: dir) else { return false }
        for file in files where file.hasSuffix(".json") {
            if let pid = Int32(file.dropLast(5)), kill(pid, 0) == 0 { return true }
        }
        return false
    }

    // How stale a VSCode log may be and still count: a connected-but-idle
    // bridge can go quiet for many minutes (observed gaps up to ~13 min), so
    // the window is generous; the live-session gate above guards the rest.
    private static let remoteLogFreshness: TimeInterval = 30 * 60

    // Bridge lifecycle markers logged by Claude Code's VSCode extension.
    private static let bridgeConnectMarkers = [
        "[bridge:sdk] State change: connected",
        "[bridge:sdk] State change: ready",
        "[remote-bridge] v2 transport connected",
        "[remote-bridge] Created session",
    ]
    private static let bridgeTeardownMarkers = [
        "[remote-bridge] Torn down",
        "[remote-bridge] Archive session",
    ]

    // Claude Code VSCode extension-host logs modified within `seconds`.
    private static func recentVSCodeLogs(within seconds: TimeInterval) -> [String] {
        let root = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/Code/logs")
        let fm = FileManager.default
        guard let walker = fm.enumerator(atPath: root) else { return [] }
        let cutoff = Date().addingTimeInterval(-seconds)
        var logs: [String] = []
        for case let rel as String in walker
        where rel.hasSuffix("Anthropic.claude-code/Claude VSCode.log") {
            let full = (root as NSString).appendingPathComponent(rel)
            if let mod = (try? fm.attributesOfItem(atPath: full))?[.modificationDate]
                as? Date, mod >= cutoff {
                logs.append(full)
            }
        }
        return logs
    }

    // The project label for a log whose bridge is connected, else nil.
    //
    // Works on the raw bytes of the tail (no String/line splitting): finding
    // the last occurrence of each marker with a backwards byte search is ~400×
    // faster than scanning ~20k lines with Unicode-aware `contains`, which kept
    // the menu fast even on multi-MB logs. The bridge is "connected" when the
    // last lifecycle marker is a connect-class one; if no marker survives in
    // the tail (handshake scrolled off) but bridge traffic is present, that's a
    // connected session past its handshake. The label is the basename of the
    // most recent cwd in the tail, or a generic name if none survived.
    private static func connectedProject(inTailOf path: String) -> String? {
        guard let data = tailData(ofFile: path, maxBytes: 1 << 21) else { return nil }

        func lastIndex(of marker: String) -> Int? {
            data.range(of: Data(marker.utf8), options: .backwards)?.lowerBound
        }
        let lastConnect = bridgeConnectMarkers.compactMap { lastIndex(of: $0) }.max()
        let lastTeardown = bridgeTeardownMarkers.compactMap { lastIndex(of: $0) }.max()
        let connected: Bool?
        if let c = lastConnect, let t = lastTeardown { connected = c > t }
        else if lastConnect != nil { connected = true }
        else if lastTeardown != nil { connected = false }
        else { connected = nil }

        let sawBridgeActivity = data.range(of: Data("[remote-bridge]".utf8)) != nil
            || data.range(of: Data("[bridge:".utf8)) != nil
        guard connected ?? sawBridgeActivity else { return nil }

        return lastCwd(in: data).map { ($0 as NSString).lastPathComponent }
            ?? "Claude session"
    }

    // The most recent cwd a VSCode-hosted session was launched with, read from
    // the same tail. Two authoritative line shapes carry it: the extension's
    // `Spawning Claude … - cwd: <path>,` line and the `launch_claude` webview
    // message (`"cwd":"<path>"`); whichever appears later in the tail wins.
    //
    // The anchors are deliberately specific: the log also echoes back tool
    // inputs (e.g. bash commands the user runs), which can mention `cwd:` and
    // must NOT be mistaken for the session's real cwd. Echoed JSON is escaped
    // (`\"cwd\":\"`), so the unescaped `"cwd":"` only appears in the real
    // message; and the full spawn phrase is the extension's own log string.
    private static func lastCwd(in data: Data) -> String? {
        func cwd(after anchor: String, stop: UInt8) -> (pos: Int, path: String)? {
            guard let r = data.range(of: Data(anchor.utf8), options: .backwards)
            else { return nil }
            var i = r.upperBound
            var bytes: [UInt8] = []
            while i < data.endIndex, data[i] != stop { bytes.append(data[i]); i += 1 }
            let path = String(decoding: bytes, as: UTF8.self)
            return path.hasPrefix("/") ? (r.upperBound, path) : nil
        }
        let candidates = [
            cwd(after: "Spawning Claude with SDK query function - cwd: ", stop: 0x2C), // ','
            cwd(after: "\"cwd\":\"", stop: 0x22),                                       // '"'
        ].compactMap { $0 }
        return candidates.max(by: { $0.pos < $1.pos })?.path
    }

    // Last `maxBytes` of a file as raw bytes (the whole file if it is smaller).
    private static func tailData(ofFile path: String, maxBytes: Int) -> Data? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        guard let end = try? fh.seekToEnd() else { return nil }
        let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        try? fh.seek(toOffset: start)
        return (try? fh.readToEnd()) ?? Data()
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
    private var snap = AwakeMonitor.Snapshot()
    private var timer: Timer?
    private var lastAwake: Bool?
    private var hookLastActive: Date?

    // Collection runs here, off the main thread, so opening the menu never
    // blocks on `pmset` or on scanning Claude Code's logs.
    private let refreshQueue = DispatchQueue(label: "io.jp7.awakebar.refresh",
                                             qos: .utility)
    private var refreshing = false
    // Skip rebuilding the menu when nothing the user can see has changed —
    // important because a refresh may land while the menu is open.
    private var lastMenuSignature: String?

    // While a Remote Control bridge is connected, AwakeBar holds its own power
    // assertion so the Mac stays awake even in the gap between turns when the
    // keep-awake hook isn't holding one (the hook only re-evaluates on hook
    // events, so it can't react to a mid-idle bridge connect). 0 / false when
    // not held.
    private var remoteAssertionID: IOPMAssertionID = 0
    private var holdingRemoteAssertion = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create the status item HERE, not in a property initializer — doing it
        // before the app finishes launching can leave the item not displayed.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.delegate = self
        // Don't auto-disable action-less items — the info rows stay "enabled"
        // so AppKit renders them at full/secondary label color instead of the
        // dimmed "disabled command" gray.
        menu.autoenablesItems = false
        statusItem.menu = menu

        // Render something immediately, then fill in real state asynchronously.
        updateButton(awake: false)
        rebuildMenu(awake: false)
        refresh()
        NSLog("AwakeBar: launched; status item button = %@",
              statusItem.button != nil ? "ok" : "nil")

        // The timer fires on the main run loop, so it is safe to assume
        // main-actor isolation here rather than hop with a Task.
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    // Refresh the moment the menu opens. The refresh is async, so the menu
    // appears instantly with the last poll's data (≤5s old) and updates in
    // place a moment later if anything changed.
    func menuWillOpen(_ menu: NSMenu) { refresh() }

    // Kick off a background collection; coalesce so overlapping triggers (the
    // 5s timer and a menu open) don't pile up.
    private func refresh() {
        if refreshing { return }
        refreshing = true
        refreshQueue.async { [weak self] in
            let snapshot = AwakeMonitor.collect()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.refreshing = false
                    self.apply(snapshot)
                }
            }
        }
    }

    private func apply(_ snapshot: AwakeMonitor.Snapshot) {
        snap = snapshot
        if snapshot.hookActive { hookLastActive = Date() }

        // Hold (or release) our own assertion to match remote-control state,
        // then reflect *actual* awake state: a real external assertion OR the
        // one we are holding ourselves.
        updateRemoteAssertion(active: snapshot.remoteControlActive)
        let awake = snapshot.state == .awake || holdingRemoteAssertion

        updateButton(awake: awake)

        if awake != lastAwake {
            let names = snapshot.holders
                .map { $0.isClaudeHook ? "\($0.name)(claude-hook)" : $0.name }
                .joined(separator: ", ")
            NSLog("AwakeBar: state = %@, holders = [%@]",
                  awake ? "awake" : "canSleep", names)
            lastAwake = awake
        }

        let signature = menuSignature(awake: awake)
        if signature != lastMenuSignature {
            lastMenuSignature = signature
            rebuildMenu(awake: awake)
        }
    }

    private func updateButton(awake: Bool) {
        guard let button = statusItem.button else { return }
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

    // Create our power assertion when a remote session connects, release it
    // when none is connected. Idempotent: only acts on a real transition.
    // PreventUserIdleSystemSleep mirrors the hook's `caffeinate -i` — it stops
    // the *idle* sleep that would otherwise drop a connected-but-idle session;
    // the display may still sleep.
    private func updateRemoteAssertion(active: Bool) {
        if active, !holdingRemoteAssertion {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "AwakeBar: Remote Control session connected" as CFString,
                &id)
            if result == kIOReturnSuccess {
                remoteAssertionID = id
                holdingRemoteAssertion = true
            } else {
                NSLog("AwakeBar: IOPMAssertionCreateWithName failed (0x%08x)", result)
            }
        } else if !active, holdingRemoteAssertion {
            IOPMAssertionRelease(remoteAssertionID)
            remoteAssertionID = 0
            holdingRemoteAssertion = false
        }
    }

    // A fingerprint of everything rebuildMenu renders (minus volatile relative
    // ages, so an idle menu doesn't flicker every poll). When unchanged, the
    // menu is left alone.
    private func menuSignature(awake: Bool) -> String {
        let holders = snap.holders
            .map { "\($0.name)|\($0.isClaudeHook)" }
            .joined(separator: ",")
        return [
            String(awake),
            String(snap.hookInstalled),
            String(snap.hookActive),
            String(describing: snap.hookReason),
            String(snap.remoteControlActive),
            String(holdingRemoteAssertion),
            snap.remoteProjects.joined(separator: ","),
            holders,
        ].joined(separator: "~")
    }

    private func rebuildMenu(awake: Bool) {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        // Headline — primary status: full-contrast label color, flat icon.
        let header = infoItem(awake ? "Mac is being kept awake"
                                    : "Mac can sleep normally",
                              color: .labelColor)
        if let icon = NSImage(
            systemSymbolName: awake ? "cup.and.saucer.fill" : "cup.and.saucer",
            accessibilityDescription: nil) {
            icon.isTemplate = true
            header.image = icon
        }
        menu.addItem(header)

        // Claude Code hook + live remote-control status — secondary info.
        menu.addItem(.separator())
        menu.addItem(infoItem(claudeHookStatusText(), color: .secondaryLabelColor))
        if snap.remoteControlActive {
            menu.addItem(infoItem("Remote control: active", color: .secondaryLabelColor))
            for project in snap.remoteProjects {
                menu.addItem(infoItem(project, color: .secondaryLabelColor, indent: 1))
            }
        } else {
            menu.addItem(infoItem("Remote control: off", color: .secondaryLabelColor))
        }

        var keptAwakeBy = snap.holders.map {
            $0.isClaudeHook ? "\($0.name) (Claude Code hook)" : $0.name
        }
        if holdingRemoteAssertion {
            keptAwakeBy.append("AwakeBar (Remote Control session)")
        }
        if awake && !keptAwakeBy.isEmpty {
            menu.addItem(.separator())
            menu.addItem(infoItem("Kept awake by:", color: .secondaryLabelColor))
            for label in keptAwakeBy {
                menu.addItem(infoItem(label, color: .secondaryLabelColor, indent: 1))
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

    // A non-interactive informational row, drawn at an explicit color via
    // attributedTitle — rather than the dimmed "disabled command" gray a
    // plain disabled item would get.
    private func infoItem(_ text: String, color: NSColor, indent: Int = 0) -> NSMenuItem {
        // Left enabled (the menu has autoenablesItems = false) so AppKit does
        // not dim it; with no action it is still effectively non-interactive.
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.indentationLevel = indent
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.foregroundColor: color,
                         .font: NSFont.menuFont(ofSize: 0)])
        return item
    }

    // The always-present Claude line. Between turns the hook's caffeinate is
    // gone, so this reports the last time it ran rather than just "idle".
    private func claudeHookStatusText() -> String {
        if !snap.hookInstalled {
            return "Claude Code hook: not installed"
        }
        if snap.hookActive {
            switch snap.hookReason {
            case .turn:
                return "Claude Code hook: Claude is working"
            case .remote:
                // The reason file can be stale if remote control dropped
                // between turns — verify against the live check.
                return snap.remoteControlActive
                    ? "Claude Code hook: holding for a remote session"
                    : "Claude Code hook: keeping the Mac awake now"
            case .unknown:
                return "Claude Code hook: keeping the Mac awake now"
            }
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

    @objc private func quit() {
        updateRemoteAssertion(active: false)   // don't leak the assertion
        NSApp.terminate(nil)
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu-bar only: no Dock icon, no Cmd-Tab
app.run()
