import Foundation
import Darwin   // kill(2), to test whether a Claude session PID is still alive

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

    // Absolute path for `rel` resolved under the user's home directory.
    private static func home(_ rel: String) -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(rel)
    }

    // The hook script itself — its presence distinguishes "idle" from "not set up".
    static let hookScriptPath = home(".claude/keep-awake.sh")

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
            guard let data = tailData(ofFile: log) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            let project = projectLabel(in: data)
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
    // (internal, not private, so AwakeBarTests can exercise the parser directly.)
    static func lineTime(_ line: Substring) -> Date? {
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
    // (internal, not private, so AwakeBarTests can exercise the parser directly.)
    static func notifyMessage(in line: Substring) -> String? {
        guard let r = line.range(of: "\"message\":\"") else { return nil }
        let rest = line[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    // True when some ~/.claude/sessions/<pid>.json is named by a live PID.
    private static func hasLiveSession() -> Bool {
        let dir = home(".claude/sessions")
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
        let root = home("Library/Application Support/Code/logs")
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
    // (internal, not private, so AwakeBarTests can drive it with sample logs.)
    static func connectedProject(inTailOf path: String) -> String? {
        guard let data = tailData(ofFile: path) else { return nil }

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

        return projectLabel(in: data)
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
    // (internal, not private, so AwakeBarTests can exercise the parser directly.)
    static func lastCwd(in data: Data) -> String? {
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

    // The project label for a log tail: the basename of the most recent cwd, or a
    // generic name when none survived in the tail. Used by both the remote-control
    // and attention-notification scans.
    static func projectLabel(in data: Data) -> String {
        lastCwd(in: data).map { ($0 as NSString).lastPathComponent } ?? "Claude session"
    }

    // How much of a (potentially multi-MB) log to read from the end. 2 MiB is far
    // more than one session's handshake + recent traffic, and a backwards byte
    // search over it stays fast.
    private static let maxTailBytes = 1 << 21

    // Last `maxTailBytes` of a file as raw bytes (the whole file if it is smaller).
    private static func tailData(ofFile path: String) -> Data? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        guard let end = try? fh.seekToEnd() else { return nil }
        let start = end > UInt64(maxTailBytes) ? end - UInt64(maxTailBytes) : 0
        try? fh.seek(toOffset: start)
        return (try? fh.readToEnd()) ?? Data()
    }

    // Parses a `pmset` per-process line: "   pid 123(name): [...] ...".
    // (internal, not private, so AwakeBarTests can exercise the parser directly.)
    static func parseHolder(line: String) -> (pid: Int, name: String)? {
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
