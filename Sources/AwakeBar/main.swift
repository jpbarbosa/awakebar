import Cocoa
import ServiceManagement
import IOKit.pwr_mgt   // IOPMAssertion*, to hold the Mac awake for remote sessions
import UserNotifications // UNUserNotificationCenter, for "Claude is waiting" alerts
import Darwin          // kill(2), open/close + O_EVTONLY for the marker watcher

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

    // One attention notification parsed from a VSCode extension log: the project
    // it belongs to, the message the extension wanted to show, when it fired, and
    // whether it was already resolved (you answered) by the time we scanned.
    struct VSCodeAttention: Sendable {
        let project: String
        let message: String
        let time: Date
        let resolved: Bool
    }

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

        // Attention notifications the VSCode extension surfaced (permission
        // prompts). Its in-panel toasts don't reach the OS and the Notification
        // hook never fires for them, so this log-derived list is the only signal.
        var vscodeAttention: [VSCodeAttention] = []
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
        snap.vscodeAttention = collectVSCodeAttention()
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

    // MARK: VSCode attention notifications

    // The VSCode extension can't post an OS notification when its window is in the
    // background — it logs its intent instead (a show_notification message) and
    // logs the resolution (you answering) as a tool_permission_response or a
    // state→running change. The Notification *hook* never fires for these in-panel
    // prompts, so this log is the only signal there. We parse recent ones; the app
    // defers each by the grace period and drops it if it was resolved in time.
    private static let vscodeNotifyFreshness: TimeInterval = 5 * 60
    private static let notifyMarker = "\"type\":\"show_notification\""
    private static let notifyWanted = "requesting permission"   // skip UI hints
    private static let resolveMarkers = ["\"type\":\"tool_permission_response\"",
                                         "\"state\":\"running\""]

    // Fixed calendar for the log's local "yyyy-MM-dd HH:mm:ss.SSS" timestamps.
    private static let logCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = .current; return c
    }()

    private static func collectVSCodeAttention() -> [VSCodeAttention] {
        guard hasLiveSession() else { return [] }
        let cutoff = Date().addingTimeInterval(-vscodeNotifyFreshness)
        var events: [VSCodeAttention] = []
        for log in recentVSCodeLogs(within: remoteLogFreshness) {
            guard let data = tailData(ofFile: log, maxBytes: 1 << 21) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            let project = lastCwd(in: data).map { ($0 as NSString).lastPathComponent }
                ?? "Claude session"
            // One pass: collect resolution times and the notification lines.
            var resolveTimes: [Date] = []
            var notifs: [(time: Date, message: String)] = []
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let isResolve = resolveMarkers.contains { line.contains($0) }
                let isNotify = line.contains(notifyMarker) && line.contains(notifyWanted)
                guard isResolve || isNotify, let t = lineTime(line) else { continue }
                if isResolve { resolveTimes.append(t) }
                if isNotify, let msg = notifyMessage(in: line) { notifs.append((t, msg)) }
            }
            for n in notifs where n.time >= cutoff {
                events.append(VSCodeAttention(
                    project: project, message: n.message, time: n.time,
                    resolved: resolveTimes.contains { $0 > n.time }))
            }
        }
        return events
    }

    // Parse the leading "yyyy-MM-dd HH:mm:ss.SSS" timestamp of a log line, nil if
    // the line doesn't start with one (e.g. a wrapped continuation line).
    private static func lineTime(_ line: Substring) -> Date? {
        let c = Array(line.prefix(23))
        guard c.count == 23 else { return nil }
        func n(_ a: Int, _ b: Int) -> Int? { Int(String(c[a..<b])) }
        guard let y = n(0, 4), let mo = n(5, 7), let d = n(8, 10),
              let h = n(11, 13), let mi = n(14, 16), let s = n(17, 19), let ms = n(20, 23)
        else { return nil }
        var dc = DateComponents()
        dc.year = y; dc.month = mo; dc.day = d
        dc.hour = h; dc.minute = mi; dc.second = s; dc.nanosecond = ms * 1_000_000
        return logCalendar.date(from: dc)
    }

    // Extract the "message":"…" value from a show_notification line (the messages
    // hold no embedded quotes, so the first closing quote ends it).
    private static func notifyMessage(in line: Substring) -> String? {
        guard let r = line.range(of: "\"message\":\"") else { return nil }
        let rest = line[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
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

// MARK: - Power assertion

// A single IOKit power assertion that AwakeBar holds itself. `set(true)`
// creates it (idempotent), `set(false)` releases it; `held` reflects the
// current state. PreventUserIdleSystemSleep mirrors `caffeinate -i`: the Mac
// stays awake but the display may still sleep.
@MainActor
final class PowerAssertion {
    private let name: String
    private var id: IOPMAssertionID = 0
    private(set) var held = false

    init(_ name: String) { self.name = name }

    func set(_ active: Bool) {
        if active, !held {
            var newID = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                name as CFString,
                &newID)
            if result == kIOReturnSuccess {
                id = newID
                held = true
            } else {
                NSLog("AwakeBar: power assertion '%@' failed (0x%08x)", name, result)
            }
        } else if !active, held {
            IOPMAssertionRelease(id)
            id = 0
            held = false
        }
    }
}

// MARK: - Attention watcher
//
// Watches the marker file notify-attention.sh writes when Claude Code is
// blocked waiting on the user. A kqueue-backed DispatchSource fires the moment
// the file changes, so the alert is effectively instant rather than waiting on
// the 10s poll. The hook rewrites the file in place (`> file`), keeping the
// inode, so a plain `.write`/`.extend` is the common path; `.delete`/`.rename`
// (an atomic replace, or the file going away) re-arm the watch on a fresh fd.
//
// @unchecked Sendable: every member is touched only from `queue`, a single
// serial queue, so the mutable `source` is never raced — but that confinement
// is a runtime invariant the compiler can't see, hence unchecked.
final class AttentionWatcher: @unchecked Sendable {
    private let path: String
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "io.jp7.awakebar.attention")
    private var source: DispatchSourceFileSystemObject?

    init(path: String, onChange: @escaping @Sendable () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    func start() { queue.async { [weak self] in self?.arm() } }

    private func arm() {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // Not created yet (the hook hasn't fired). Retry; one cheap syscall.
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.arm() }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            if src.data.contains(.delete) || src.data.contains(.rename) {
                self.rearm()
            } else {
                self.onChange()
            }
        }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
        // The file exists now: check it once, both to catch a write that landed
        // between open() and resume(), and to surface a marker that was written
        // while no watch was armed (e.g. just after launch).
        onChange()
    }

    private func rearm() {
        source?.cancel()   // the cancel handler closes the old fd
        source = nil
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.arm() }
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate,
                         UNUserNotificationCenterDelegate {
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

    // Power assertions AwakeBar holds itself. The remote one tracks Remote
    // Control automatically — so the Mac stays awake even in the gap between
    // turns the event-driven keep-awake hook can't cover. The manual one is the
    // user's "Keep awake" menu toggle, not persisted (resets to off on launch).
    private let remoteAssertion = PowerAssertion("AwakeBar: Remote Control session connected")
    private let manualAssertion = PowerAssertion("AwakeBar: Keep awake (manual)")
    private var manualKeepAwake = false

    // Native "Claude is waiting for you" notifications. notify-attention.sh writes
    // attentionMarkerPath when a session is blocked on the user; the watcher fires
    // the moment it changes. Rather than alert at once, we wait attentionGrace and
    // alert only if the user hasn't engaged with THAT session meanwhile — detected
    // via a per-cwd activity marker the same hook bumps on prompt/tool/stop events
    // (so one busy session can't silence another's alert). lastAttentionTs dedupes:
    // only a strictly newer ts is considered, so a marker from before launch stays
    // silent.
    private let attentionMarkerPath = "/tmp/claude-attention.json"
    private var attentionWatcher: AttentionWatcher?
    private var lastAttentionTs = 0
    private var pendingAlert: DispatchWorkItem?
    private let attentionGrace: TimeInterval = 10

    // VSCode permission prompts surfaced via the extension log (see AwakeMonitor).
    // appLaunch floors out events logged before launch; lastVSNotify is the
    // per-project high-water of handled events so none is alerted twice.
    private let appLaunch = Date()
    private var lastVSNotify: [String: Date] = [:]

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
        timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }

        // Alert when Claude Code is blocked waiting on the user. Prime the dedup
        // cursor from any marker left by a previous run BEFORE arming the watch,
        // so launching AwakeBar never replays a stale "Claude is waiting" alert.
        setUpNotifications()
        primeAttention()
        attentionWatcher = AttentionWatcher(path: attentionMarkerPath) { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handleAttention() }
            }
        }
        attentionWatcher?.start()
    }

    // Refresh the moment the menu opens. The refresh is async, so the menu
    // appears instantly with the last poll's data (≤10s old) and updates in
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
        // Track Remote Control automatically; the manual hold is driven by the
        // menu toggle. Then reflect everything in the icon and menu.
        remoteAssertion.set(snapshot.remoteControlActive)
        processVSCodeAttention(snapshot.vscodeAttention)
        render()
    }

    // Reflect current state — the snapshot plus the assertions we hold — in the
    // icon and menu. Called after every refresh and whenever a toggle changes.
    private func render() {
        // Awake means a real external assertion OR one we are holding ourselves.
        let awake = snap.state == .awake || remoteAssertion.held || manualAssertion.held

        updateButton(awake: awake)

        if awake != lastAwake {
            let names = snap.holders
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
        let forced = manualAssertion.held
        if let image = statusImage(awake: awake, forced: forced) {
            button.image = image
            button.title = ""
        } else {
            // Never leave the item empty (invisible) if SF Symbols fail.
            button.image = nil
            button.title = awake ? "☕︎" : "Zz"
        }
        button.toolTip = forced ? "Keep awake is on — Mac forced awake"
                       : awake  ? "Mac is being kept awake"
                                : "Mac can sleep normally"
    }

    // The menu-bar cup. Normally a template image, so it adapts to the menu bar
    // (black/white, inverts when the menu is open). When the manual "Keep
    // awake" hold is on, a red dot is composited at the bottom-right; that
    // forces a *non-template* image (template images are drawn monochrome by
    // the system, which would erase the red), so the cup itself is redrawn in
    // the menu bar's label colour to still look right.
    private func statusImage(awake: Bool, forced: Bool) -> NSImage? {
        let symbol = awake ? "cup.and.saucer.fill" : "cup.and.saucer"
        guard let base = NSImage(systemSymbolName: symbol,
                                 accessibilityDescription: "Keep-awake status")
        else { return nil }
        guard forced else {
            return nudgedDown(base, template: true)
        }
        let size = base.size
        let badged = NSImage(size: size)
        let appearance = statusItem.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            badged.lockFocus()
            // Cup: recolour the template glyph to the menu bar's label colour.
            let rect = NSRect(origin: .zero, size: size)
            base.draw(in: rect.offsetBy(dx: 0, dy: -iconVerticalNudge))
            NSColor.labelColor.set()
            rect.fill(using: .sourceAtop)
            // Red badge, tangent to the bottom-right corner.
            let d = (size.height * 0.46).rounded()
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: size.width - d, y: 0, width: d, height: d)).fill()
            badged.unlockFocus()
        }
        badged.isTemplate = false
        return badged
    }

    // The saucer gives cup.and.saucer a low optical centre, so the glyph reads
    // as sitting high in the bar even though its box is centred. Shift the whole
    // glyph down a couple of points within a same-size canvas (no rescaling, so
    // the menu bar still centres the box) to correct the impression.
    private let iconVerticalNudge: CGFloat = 0.5  // points down (~1px on Retina)

    private func nudgedDown(_ image: NSImage, template: Bool) -> NSImage {
        let size = image.size
        let shifted = NSImage(size: size)
        shifted.lockFocus()
        // Bottom-left origin: "down" on screen is a negative y offset.
        image.draw(in: NSRect(origin: .zero, size: size)
                        .offsetBy(dx: 0, dy: -iconVerticalNudge))
        shifted.unlockFocus()
        shifted.isTemplate = template
        return shifted
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
            String(remoteAssertion.held),
            String(manualAssertion.held),
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
        if remoteAssertion.held {
            keptAwakeBy.append("AwakeBar (Remote Control session)")
        }
        if manualAssertion.held {
            keptAwakeBy.append("AwakeBar (manual)")
        }
        if awake && !keptAwakeBy.isEmpty {
            menu.addItem(.separator())
            menu.addItem(infoItem("Kept awake by:", color: .secondaryLabelColor))
            for label in keptAwakeBy {
                menu.addItem(infoItem(label, color: .secondaryLabelColor, indent: 1))
            }
        }

        menu.addItem(.separator())

        // Manual override: hold the Mac awake regardless of Claude/remote state.
        let keepAwake = NSMenuItem(title: "Keep awake",
                                   action: #selector(toggleKeepAwake), keyEquivalent: "")
        keepAwake.target = self
        keepAwake.state = manualKeepAwake ? .on : .off
        keepAwake.toolTip = "Hold the Mac awake until turned off (the display may still sleep)"
        menu.addItem(keepAwake)

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

    // Toggle the manual "Keep awake" hold and re-render immediately.
    @objc private func toggleKeepAwake() {
        manualKeepAwake.toggle()
        manualAssertion.set(manualKeepAwake)
        render()
    }

    @objc private func quit() {
        remoteAssertion.set(false)   // don't leak assertions
        manualAssertion.set(false)
        NSApp.terminate(nil)
    }

    // MARK: Attention notifications

    // The marker notify-attention.sh writes; `ts` is the dedup key (unix sec).
    // All fields but ts are optional so a partial read (a write caught mid-flight)
    // simply fails to decode and is retried on the next event, never crashes.
    private struct AttentionEvent: Decodable {
        var project: String?
        var message: String?
        var cwd: String?
        var ts: Int
    }

    private func setUpNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                NSLog("AwakeBar: notification auth error: %@", error.localizedDescription)
            } else {
                NSLog("AwakeBar: notification auth granted = %@", granted ? "yes" : "no")
            }
        }
    }

    private func readAttentionMarker() -> AttentionEvent? {
        guard let data = FileManager.default.contents(atPath: attentionMarkerPath)
        else { return nil }
        return try? JSONDecoder().decode(AttentionEvent.self, from: data)
    }

    // Record the current marker's ts without alerting, so a marker written before
    // this launch can't fire a notification at startup.
    private func primeAttention() {
        if let event = readAttentionMarker() { lastAttentionTs = event.ts }
    }

    // Called on the main actor whenever the marker changes. Defers the alert by
    // the grace period; fireIfStillWaiting then drops it if the user engaged with
    // that session meanwhile. A newer event cancels and reschedules.
    private func handleAttention() {
        guard let event = readAttentionMarker(), event.ts > lastAttentionTs
        else { return }
        lastAttentionTs = event.ts
        pendingAlert?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.fireIfStillWaiting(event) }
        pendingAlert = item
        DispatchQueue.main.asyncAfter(deadline: .now() + attentionGrace, execute: item)
    }

    // Fired attentionGrace after the event. If the session has since shown
    // activity past the event (you approved a prompt, typed, or the turn ended),
    // stay quiet — you're on it. Otherwise alert.
    private func fireIfStillWaiting(_ event: AttentionEvent) {
        pendingAlert = nil
        if let cwd = event.cwd, activityTs(forCwd: cwd) > event.ts { return }
        postAttentionNotification(project: event.project, message: event.message,
                                  id: "claude-attention-\(event.ts)", cwd: event.cwd)
    }

    // VSCode path: alert on each attention event once it is at least attentionGrace
    // old AND still unresolved — a prompt you answered within the grace stays quiet.
    // Younger events wait for a later poll; lastVSNotify dedupes per project.
    private func processVSCodeAttention(_ events: [AwakeMonitor.VSCodeAttention]) {
        let ripe = Date().addingTimeInterval(-attentionGrace)
        for ev in events.sorted(by: { $0.time < $1.time }) {
            let last = lastVSNotify[ev.project] ?? appLaunch
            guard ev.time > last, ev.time <= ripe else { continue }
            lastVSNotify[ev.project] = ev.time
            if ev.resolved { continue }
            postAttentionNotification(
                project: ev.project, message: ev.message,
                id: "vscode-\(ev.project)-\(Int(ev.time.timeIntervalSince1970))", cwd: nil)
        }
    }

    // Last activity time for a session, written per-cwd by notify-attention.sh.
    // The sanitiser mirrors the hook's `tr -c 'A-Za-z0-9' '_'`.
    private func activityTs(forCwd cwd: String) -> Int {
        var safe = ""
        for ch in cwd { safe.append(ch.isASCII && (ch.isLetter || ch.isNumber) ? ch : "_") }
        let path = "/tmp/claude-activity-" + safe
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
        return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    // Shared notification poster for both the terminal (hook/marker) and VSCode
    // (extension-log) paths. `id` keeps back-to-back waits from collapsing.
    private func postAttentionNotification(project: String?, message: String?,
                                           id: String, cwd: String?) {
        let content = UNMutableNotificationContent()
        let p = (project?.isEmpty == false) ? project : nil
        content.title = p.map { "Claude · \($0)" } ?? "Claude Code"
        content.body = (message?.isEmpty == false) ? message! : "Claude is waiting for you"
        content.sound = .default
        if let cwd { content.userInfo = ["cwd": cwd] }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func activateVSCode() {
        for id in ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"] {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.openApplication(
                    at: url, configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
    }

    // Show the banner even though AwakeBar is an accessory (LSUIElement) app, and
    // bring VSCode forward when the banner is clicked. Both are nonisolated to
    // satisfy UNUserNotificationCenterDelegate; UI work hops to the main actor.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.activateVSCode() }
        }
        completionHandler()
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu-bar only: no Dock icon, no Cmd-Tab
app.run()
