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
// menu never blocks on `pmset` or on scanning Claude Code's logs. Collection is
// otherwise pure — it reads the world and returns a Sendable Snapshot — with one
// exception: `logMemo` caches the VSCode log walk and each log's parsed tail
// across ticks, and guards that state with its own lock.

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

    // One project whose Remote Control bridge is connected: a display label (the
    // cwd basename) and the full cwd. cwd is nil only when the session file
    // carried none.
    struct RemoteSession: Sendable {
        let project: String
        let cwd: String?
    }

    // One live local Claude Code session, read from ~/.claude/sessions/<pid>.json:
    // its friendly name (when Claude derived one), the project (cwd basename), the
    // full cwd, and the most recent activity from the per-cwd marker. Surfaced in
    // the menu's Sessions submenu — every live session, not just the
    // remote-controlled ones the Remote Control rows list.
    struct Session: Sendable {
        let pid: Int
        let name: String?
        let project: String
        let cwd: String?
        let lastActivity: Date?
        // The raw `entrypoint` from the session file — the source app. Map it for
        // display with appLabel(forEntrypoint:).
        let entrypoint: String?
        // True while Claude Code records a Remote Control bridge for this session.
        let bridgeConnected: Bool
    }

    // Friendly source-app label for a session's `entrypoint` (the field Claude Code
    // writes into ~/.claude/sessions/<pid>.json). Known values map to a readable
    // name; an unrecognised one falls through as-is so a new source still shows.
    // Note: VS Code-family forks (Cursor, Windsurf) share "claude-vscode", so this
    // names the family, not the exact editor. nil/empty → no label.
    static func appLabel(forEntrypoint entrypoint: String?) -> String? {
        guard let e = entrypoint, !e.isEmpty else { return nil }
        switch e {
        case "claude-vscode":                       return "VS Code"
        case "cli", "claude-cli":                   return "Terminal"
        case "claude-desktop", "claude-desktop-3p": return "Claude Desktop"
        default:                                     return e
        }
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

        // The VSCode windows that currently have Remote Control connected. Empty
        // means no remote session. Each carries the project label (cwd basename)
        // for display and the full cwd for looking up its activity marker.
        var remoteSessions: [RemoteSession] = []
        var remoteProjects: [String] { remoteSessions.map(\.project) }
        var remoteControlActive: Bool { !remoteSessions.isEmpty }

        // Most recent activity across the connected remote sessions; the app
        // releases its remote hold once this goes stale.
        var remoteLastActivity: Date?

        // Every live local Claude Code session (one per ~/.claude/sessions/<pid>.json
        // named by a live PID), most-recently-active first. A superset of
        // remoteSessions — the Sessions submenu lists these regardless of whether
        // the Remote Control bridge is connected.
        var sessions: [Session] = []

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

    // keep-awake.sh writes its caffeinate PID and the reason ("turn"/"remote")
    // into the marker files defined by the shared hook Contract.

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
        snap.sessions = collectSessions()
        snap.remoteSessions = remoteSessions(among: snap.sessions)
        snap.remoteLastActivity = snap.sessions
            .filter(\.bridgeConnected).compactMap(\.lastActivity).max()
        snap.vscodeAttention = collectVSCodeAttention()
        return snap
    }

    // The fields we render out of a ~/.claude/sessions/<pid>.json (the file holds
    // more — sessionId, version, entrypoint… — which JSONDecoder simply ignores).
    private struct SessionFile: Decodable {
        let cwd: String?
        let name: String?
        let entrypoint: String?
        // Present, and non-empty, while this session has a Remote Control bridge.
        let bridgeSessionId: String?
        // Last activity, epoch milliseconds. Claude Code bumps it on real activity
        // and does NOT heartbeat, so a session idle for hours keeps its old value.
        let updatedAt: Double?
    }

    // Every live local session, most-recently-active first: one per session file
    // named by a live PID. Feeds the Sessions submenu and, through
    // remoteSessions(among:), the Remote Control rows.
    //
    // Activity prefers the file's own `updatedAt` over the per-cwd marker: it is
    // per session rather than per folder, and needs no hook installed.
    static func collectSessions(inDirectory dir: String = Contract.sessionsDir) -> [Session] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir)
        else { return [] }
        var sessions: [Session] = []
        for file in files where file.hasSuffix(".json") {
            guard let pid = Int32(file.dropLast(5)), pid > 0, kill(pid, 0) == 0
            else { continue }
            let path = (dir as NSString).appendingPathComponent(file)
            guard let data = FileManager.default.contents(atPath: path),
                  let info = try? JSONDecoder().decode(SessionFile.self, from: data)
            else { continue }
            let project = info.cwd.map { ($0 as NSString).lastPathComponent } ?? "Claude session"
            let marker = info.cwd.flatMap { cwd -> Date? in
                let ts = activityTs(forCwd: cwd)
                return ts > 0 ? Date(timeIntervalSince1970: TimeInterval(ts)) : nil
            }
            let updated = info.updatedAt.map { Date(timeIntervalSince1970: $0 / 1000) }
            sessions.append(Session(pid: Int(pid), name: info.name, project: project,
                                    cwd: info.cwd, lastActivity: updated ?? marker,
                                    entrypoint: info.entrypoint,
                                    bridgeConnected: !(info.bridgeSessionId ?? "").isEmpty))
        }
        // Most-recently-active first; sessions with no activity marker sink to the
        // bottom, ordered by pid among themselves for a stable display.
        return sessions.sorted { a, b in
            let ta = a.lastActivity ?? .distantPast
            let tb = b.lastActivity ?? .distantPast
            return ta != tb ? ta > tb : a.pid < b.pid
        }
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
        guard let raw = try? String(contentsOfFile: Contract.hookPidFile, encoding: .utf8)
        else { return nil }
        return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // Why the hook is holding the Mac awake, per its sibling .reason file.
    private static func readHookReason() -> HookReason {
        guard let raw = try? String(contentsOfFile: Contract.hookReasonFile, encoding: .utf8)
        else { return .unknown }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines) {
        case Contract.reasonTurn:   return .turn
        case Contract.reasonRemote: return .remote
        default:                    return .unknown
        }
    }

    // The Remote Control rows: the bridge-connected subset of the live sessions,
    // deduped by project so two sessions in one folder list once. Reading Claude
    // Code's own session files is what makes this host-agnostic - the CLI, desktop
    // VSCode and a code-server tile all write `bridgeSessionId`. That field is
    // undocumented and has vanished once, so check it is still written before
    // looking anywhere else if detection stops.
    static func remoteSessions(among sessions: [Session]) -> [RemoteSession] {
        var seen = Set<String>()
        return sessions.filter(\.bridgeConnected).compactMap { session in
            guard seen.insert(session.project).inserted else { return nil }
            return RemoteSession(project: session.project, cwd: session.cwd)
        }
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
        for log in recentVSCodeLogs() {
            // The memo holds every event in the tail, unfiltered: `cutoff` moves
            // with the clock, so applying it inside would freeze events at the
            // age they had when the log was last parsed.
            events += logMemo.attentionEvents(for: log, compute: {
                attentionEvents(inTailOf: log)
            }).filter { $0.time >= cutoff }
        }
        return events
    }

    // Every attention event in a log's tail, regardless of age — one pass
    // collecting resolution times and notification lines, then pairing them.
    private static func attentionEvents(inTailOf log: String) -> [VSCodeAttention] {
        guard let data = tailData(ofFile: log) else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        let project = projectLabel(in: data)
        var resolveTimes: [Date] = []
        var notifs: [(time: Date, message: String)] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let isResolve = resolveMarkers.contains { line.contains($0) }
            let isNotify = line.contains(notifyMarker) && line.contains(notifyWanted)
            guard isResolve || isNotify, let t = lineTime(line) else { continue }
            if isResolve { resolveTimes.append(t) }
            if isNotify, let msg = notifyMessage(in: line) { notifs.append((t, msg)) }
        }
        return notifs.map { n in
            VSCodeAttention(project: project, message: n.message, time: n.time,
                            resolved: resolveTimes.contains { $0 > n.time })
        }
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
        let dir = Contract.sessionsDir
        guard let files = try? FileManager.default
            .contentsOfDirectory(atPath: dir) else { return false }
        for file in files where file.hasSuffix(".json") {
            if let pid = Int32(file.dropLast(5)), pid > 0, kill(pid, 0) == 0 { return true }
        }
        return false
    }

    // How stale a VSCode log may be and still count: a connected-but-idle
    // bridge can go quiet for many minutes (observed gaps up to ~13 min), so
    // the window is generous; the live-session gate above guards the rest.
    private static let remoteLogFreshness: TimeInterval = 30 * 60

    // MARK: Log-tail memo
    //
    // collect() runs on a 5 s timer, and the VSCode log work behind it dominated
    // the tick: ~70 ms walking the log tree (3.5k entries to find 2 live logs,
    // done once per caller) plus ~145 ms per log to re-read a 2 MiB tail and
    // re-scan it — all of it repeated whether or not a byte had been written.
    //
    // Both halves are memoised here: the walk on a short TTL, each log's derived
    // value on that file's (mtime, size). An unchanged log now costs one stat.
    //
    // Note the walk is *not* pruned by the session directory's name, which looks
    // like the obvious win — `logs/20260729T130556/…` is right there — and is
    // wrong: that stamp is when the VSCode window opened, not when its log was
    // last written, so a long-lived window's actively-written log gets skipped.
    // Measured: 79× faster and it found none of the live logs.

    // A file's cache identity — it has changed iff one of these moved. An append
    // always moves `size`, so a missed update would need a write that changed
    // neither byte count nor mtime.
    // (internal, not private, so AwakeBarTests can drive the memo directly.)
    struct Stamp: Equatable {
        let mtime: Date
        let size: Int

        static func of(_ path: String) -> Stamp {
            let a = try? FileManager.default.attributesOfItem(atPath: path)
            return Stamp(mtime: a?[.modificationDate] as? Date ?? .distantPast,
                         size: a?[.size] as? Int ?? -1)
        }
    }

    // collect() is documented as safe off the main thread, so this is behind a
    // lock rather than leaning on the caller's coalescing to serialise it.
    // (internal, not private, so AwakeBarTests can drive the memo directly.)
    final class LogMemo: @unchecked Sendable {
        private let lock = NSLock()
        private var walked: (logs: [String], at: Date)?
        private var attention: [String: (stamp: Stamp, value: [VSCodeAttention])] = [:]

        // The TTL only delays noticing a *brand-new* log file; new content in a
        // log we already know about is picked up on the next tick via its stamp.
        func logs(ttl: TimeInterval, compute: () -> [String]) -> [String] {
            lock.lock()
            if let walked, Date().timeIntervalSince(walked.at) < ttl {
                defer { lock.unlock() }
                return walked.logs
            }
            lock.unlock()

            let fresh = compute()
            lock.lock()
            walked = (fresh, Date())
            // Forget logs that dropped out of the walk, so a long-running app
            // doesn't hold tails from closed windows forever.
            let live = Set(fresh)
            attention = attention.filter { live.contains($0.key) }
            lock.unlock()
            return fresh
        }

        func attentionEvents(for path: String, compute: () -> [VSCodeAttention]) -> [VSCodeAttention] {
            let stamp = Stamp.of(path)
            lock.lock()
            if let hit = attention[path], hit.stamp == stamp {
                defer { lock.unlock() }
                return hit.value
            }
            lock.unlock()

            let fresh = compute()
            lock.lock()
            attention[path] = (stamp, fresh)
            lock.unlock()
            return fresh
        }
    }

    private static let logMemo = LogMemo()

    // How long a tree walk may be reused. Both callers in one collect() share it,
    // and at a 5 s tick this drops the walk from every tick to every third.
    private static let logWalkTTL: TimeInterval = 15

    // Claude Code VSCode extension-host logs modified within `remoteLogFreshness`,
    // memoised — every caller wants the same answer within a tick.
    private static func recentVSCodeLogs() -> [String] {
        logMemo.logs(ttl: logWalkTTL) { recentVSCodeLogs(within: remoteLogFreshness) }
    }

    // Claude Code VSCode extension-host logs modified within `seconds`.
    // (uncached — go through `recentVSCodeLogs()` unless you need a fresh walk.)
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

    // MARK: Remote idle

    // Last activity epoch for a session cwd, from the per-cwd marker
    // notify-attention.sh bumps on prompt/tool/stop events; 0 when none exists.
    // The marker path (and its cwd sanitiser) come from the shared Contract.
    static func activityTs(forCwd cwd: String) -> Int {
        let path = Contract.activityMarkerPath(forCwd: cwd)
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
        return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    // Whether AwakeBar should hold its remote assertion. Releases (false) once a
    // connected session has been idle past `timeout`, so an idle remote session
    // lets the Mac sleep. timeout <= 0 disables the cap (hold while connected).
    // While the keep-awake hook's caffeinate is live (hookActive), or when there
    // is no activity signal at all, it stays held — never forcing sleep blindly.
    static func shouldHoldRemote(connected: Bool, timeout: TimeInterval,
                                 lastActivity: Date?, now: Date,
                                 hookActive: Bool) -> Bool {
        guard connected else { return false }
        guard timeout > 0 else { return true }
        if hookActive { return true }
        guard let lastActivity else { return true }
        return now.timeIntervalSince(lastActivity) < timeout
    }

    // Whether a finished turn is worth a "task finished" notification: a real task
    // (ran at least `minimum` seconds) rather than a quick conversational reply. A
    // negative duration means the start wasn't recorded, so it errs toward
    // notifying rather than swallowing a turn that may well have been long.
    static func isRealTask(durationSeconds dur: Int, minimum: TimeInterval) -> Bool {
        dur < 0 || TimeInterval(dur) >= minimum
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
