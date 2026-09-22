import Testing
import Foundation
@testable import AwakeBar

// Unit tests for the pure parsing helpers in AwakeMonitor — the logic that turns
// raw `pmset` lines and VSCode extension-log text into the values the menu reads.
// Everything here is deterministic input → output; nothing touches the live Mac
// state, so these run anywhere `swift test` does.

// MARK: - parseHolder

@Suite struct ParseHolderTests {
    @Test func extractsPidAndName() {
        let r = AwakeMonitor.parseHolder(
            line: "   pid 12345(caffeinate): [System] PreventUserIdleSystemSleep")
        #expect(r?.pid == 12345)
        #expect(r?.name == "caffeinate")
    }

    @Test func handlesNameWithSpacesAndDots() {
        let r = AwakeMonitor.parseHolder(
            line: "   pid 42(com.apple.WebKit): [System] NoIdleSleepAssertion")
        #expect(r?.pid == 42)
        #expect(r?.name == "com.apple.WebKit")
    }

    @Test func returnsNilWhenNoParens() {
        #expect(AwakeMonitor.parseHolder(line: "No assertions held.") == nil)
    }

    @Test func returnsNilForEmptyName() {
        #expect(AwakeMonitor.parseHolder(line: "   pid 99(): [System] ...") == nil)
    }

    @Test func returnsNilWhenNoDigitsBeforeParen() {
        #expect(AwakeMonitor.parseHolder(line: "   pid (caffeinate): [System] ...") == nil)
    }
}

// MARK: - lineTime

@Suite struct LineTimeTests {
    // Build the expected Date from the same components in the current zone, so the
    // assertion is timezone-independent (the parser uses Calendar.current).
    private func date(_ y: Int, _ mo: Int, _ d: Int,
                      _ h: Int, _ mi: Int, _ s: Int, _ ms: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d
        c.hour = h; c.minute = mi; c.second = s; c.nanosecond = ms * 1_000_000
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        return cal.date(from: c)!
    }

    @Test func parsesLeadingTimestamp() {
        let line: Substring = "2026-05-30 14:52:10.123 [info] [remote-bridge] ready"[...]
        #expect(AwakeMonitor.lineTime(line) == date(2026, 5, 30, 14, 52, 10, 123))
    }

    @Test func rejectsTooShortLine() {
        #expect(AwakeMonitor.lineTime("2026-05-30"[...]) == nil)
    }

    @Test func rejectsNonNumericPrefix() {
        // 23 chars long, but not a timestamp — the numeric fields fail to parse.
        #expect(AwakeMonitor.lineTime("this is a long log line"[...]) == nil)
    }
}

// MARK: - notifyMessage

@Suite struct NotifyMessageTests {
    @Test func extractsMessageValue() {
        let line: Substring =
            #"...{"type":"show_notification","message":"Claude is requesting permission"}"#[...]
        #expect(AwakeMonitor.notifyMessage(in: line) == "Claude is requesting permission")
    }

    @Test func stopsAtFirstClosingQuote() {
        let line: Substring = #"x "message":"hello" "other":"world""#[...]
        #expect(AwakeMonitor.notifyMessage(in: line) == "hello")
    }

    @Test func returnsNilWhenAbsent() {
        #expect(AwakeMonitor.notifyMessage(in: #"{"type":"other"}"#[...]) == nil)
    }
}

// MARK: - lastCwd

@Suite struct LastCwdTests {
    @Test func readsSpawnLineCwd() {
        let log = "Spawning Claude with SDK query function - cwd: /Users/jp/Sites/awakebar, foo"
        #expect(AwakeMonitor.lastCwd(in: Data(log.utf8)) == "/Users/jp/Sites/awakebar")
    }

    @Test func readsJsonCwd() {
        let log = #"prefix {"cwd":"/Users/jp/proj"} suffix"#
        #expect(AwakeMonitor.lastCwd(in: Data(log.utf8)) == "/Users/jp/proj")
    }

    @Test func laterAnchorWins() {
        // A spawn line, then a newer JSON cwd: the one appearing later in the
        // bytes is the live session's real cwd.
        let log = """
        Spawning Claude with SDK query function - cwd: /old/path,
        later {"cwd":"/new/path"}
        """
        #expect(AwakeMonitor.lastCwd(in: Data(log.utf8)) == "/new/path")
    }

    @Test func ignoresNonAbsolutePath() {
        // Only paths starting with "/" are trusted; a relative value is rejected.
        let log = #"{"cwd":"relative/path"}"#
        #expect(AwakeMonitor.lastCwd(in: Data(log.utf8)) == nil)
    }

    @Test func returnsNilWhenNoAnchor() {
        #expect(AwakeMonitor.lastCwd(in: Data("nothing here".utf8)) == nil)
    }
}

// MARK: - projectLabel

@Suite struct ProjectLabelTests {
    @Test func usesCwdBasename() {
        let log = #"{"cwd":"/Users/jp/Sites/awakebar"}"#
        #expect(AwakeMonitor.projectLabel(in: Data(log.utf8)) == "awakebar")
    }

    @Test func fallsBackWhenNoCwd() {
        #expect(AwakeMonitor.projectLabel(in: Data("no cwd here".utf8)) == "Claude session")
    }
}

// MARK: - remoteSessions / collectSessions (the session-file path)

@Suite struct RemoteSessionsTests {
    private func session(_ project: String, bridged: Bool) -> AwakeMonitor.Session {
        AwakeMonitor.Session(pid: 1, name: nil, project: project,
                             cwd: "/Users/jp/Sites/" + project, lastActivity: nil,
                             entrypoint: "cli", bridgeConnected: bridged)
    }

    @Test func picksOnlyBridgedSessions() {
        let out = AwakeMonitor.remoteSessions(among: [
            session("awakebar", bridged: false),
            session("maru", bridged: true),
        ])
        #expect(out.map(\.project) == ["maru"])
        #expect(out.first?.cwd == "/Users/jp/Sites/maru")
    }

    @Test func dedupesByProject() {
        // Five sessions open on one folder are one Remote Control row.
        let out = AwakeMonitor.remoteSessions(among: (0..<5).map { _ in
            session("interadmin", bridged: true)
        })
        #expect(out.count == 1)
    }

    @Test func noneBridgedIsEmpty() {
        #expect(AwakeMonitor.remoteSessions(among: [session("a", bridged: false)]).isEmpty)
    }
}

@Suite struct CollectSessionsTests {
    // Session files are named by pid and only live pids count, so the fixtures are
    // named after this test process.
    private func withSessionDir(_ json: String, _ body: (String) -> Void) {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "awakebar-sessions-\(ProcessInfo.processInfo.globallyUniqueString)")
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let pid = ProcessInfo.processInfo.processIdentifier
        let path = (dir as NSString).appendingPathComponent("\(pid).json")
        try? json.write(toFile: path, atomically: true, encoding: .utf8)
        body(dir)
    }

    @Test func readsBridgeCwdAndUpdatedAt() {
        withSessionDir("""
        {"pid":1,"cwd":"/Users/jp/Sites/maru","entrypoint":"cli",
         "bridgeSessionId":"session_01ABC","updatedAt":1790000000000}
        """) { dir in
            let sessions = AwakeMonitor.collectSessions(inDirectory: dir)
            #expect(sessions.count == 1)
            #expect(sessions.first?.project == "maru")
            #expect(sessions.first?.bridgeConnected == true)
            #expect(sessions.first?.lastActivity == Date(timeIntervalSince1970: 1_790_000_000))
        }
    }

    @Test func noBridgeFieldIsNotConnected() {
        withSessionDir("""
        {"pid":1,"cwd":"/Users/jp/Sites/maru","entrypoint":"claude-vscode"}
        """) { dir in
            #expect(AwakeMonitor.collectSessions(inDirectory: dir).first?.bridgeConnected == false)
        }
    }

    @Test func emptyBridgeFieldIsNotConnected() {
        withSessionDir("""
        {"pid":1,"cwd":"/Users/jp/Sites/maru","bridgeSessionId":""}
        """) { dir in
            #expect(AwakeMonitor.collectSessions(inDirectory: dir).first?.bridgeConnected == false)
        }
    }

    @Test func deadPidIsSkipped() {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "awakebar-sessions-\(ProcessInfo.processInfo.globallyUniqueString)")
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // PID 0 is never a live user process, so kill(0, 0) cannot vouch for it.
        try? "{\"cwd\":\"/x\",\"bridgeSessionId\":\"s\"}"
            .write(toFile: (dir as NSString).appendingPathComponent("0.json"),
                   atomically: true, encoding: .utf8)
        #expect(AwakeMonitor.collectSessions(inDirectory: dir).isEmpty)
    }
}

// MARK: - appLabel

@Suite struct AppLabelTests {
    @Test func mapsTheEntrypointsClaudeCodeWrites() {
        // "cli" is what a terminal session actually writes; "claude-cli" is kept
        // because an older Claude Code wrote that.
        #expect(AwakeMonitor.appLabel(forEntrypoint: "cli") == "Terminal")
        #expect(AwakeMonitor.appLabel(forEntrypoint: "claude-cli") == "Terminal")
        #expect(AwakeMonitor.appLabel(forEntrypoint: "claude-vscode") == "VS Code")
        #expect(AwakeMonitor.appLabel(forEntrypoint: "something-new") == "something-new")
        #expect(AwakeMonitor.appLabel(forEntrypoint: nil) == nil)
    }
}

// MARK: - shouldHoldRemote (the remote idle-cap decision)

@Suite struct ShouldHoldRemoteTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    @Test func notConnectedNeverHolds() {
        #expect(AwakeMonitor.shouldHoldRemote(
            connected: false, timeout: 3600, lastActivity: now, now: now,
            hookActive: false) == false)
    }

    @Test func timeoutOffAlwaysHoldsWhileConnected() {
        // Off (0) disables the cap — even ancient activity keeps the hold.
        #expect(AwakeMonitor.shouldHoldRemote(
            connected: true, timeout: 0, lastActivity: ago(99_999), now: now,
            hookActive: false) == true)
    }

    @Test func liveHookTurnHolds() {
        // A turn is running; never release mid-turn regardless of marker age.
        #expect(AwakeMonitor.shouldHoldRemote(
            connected: true, timeout: 3600, lastActivity: ago(99_999), now: now,
            hookActive: true) == true)
    }

    @Test func recentActivityHolds() {
        #expect(AwakeMonitor.shouldHoldRemote(
            connected: true, timeout: 3600, lastActivity: ago(60), now: now,
            hookActive: false) == true)
    }

    @Test func idlePastTimeoutReleases() {
        #expect(AwakeMonitor.shouldHoldRemote(
            connected: true, timeout: 3600, lastActivity: ago(3601), now: now,
            hookActive: false) == false)
    }

    @Test func noActivitySignalHolds() {
        // Without any activity signal we can't prove idleness — don't force sleep.
        #expect(AwakeMonitor.shouldHoldRemote(
            connected: true, timeout: 3600, lastActivity: nil, now: now,
            hookActive: false) == true)
    }
}

// MARK: - activityTs

@Suite struct ActivityTsTests {
    @Test func readsAndSanitizesMarker() {
        // notify-attention.sh keys markers by cwd with non-alphanumerics -> '_'.
        let cwd = "/Users/jp/Sites/awakebar-\(ProcessInfo.processInfo.globallyUniqueString)"
        var safe = ""
        for ch in cwd { safe.append(ch.isASCII && (ch.isLetter || ch.isNumber) ? ch : "_") }
        let path = "/tmp/claude-activity-" + safe
        try? "1700000000".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(AwakeMonitor.activityTs(forCwd: cwd) == 1_700_000_000)
    }

    @Test func missingMarkerIsZero() {
        let cwd = "/nope/\(ProcessInfo.processInfo.globallyUniqueString)"
        #expect(AwakeMonitor.activityTs(forCwd: cwd) == 0)
    }
}

// MARK: - tightenBody

// The notification body comes from Claude Code, which echoes "Claude" (already
// in the title) and uses wordy stock phrasing. tightenBody strips that down to
// the part that differs between alerts.
@Suite struct TightenBodyTests {
    @Test func keepsPermissionPhrasingMinusClaude() {
        #expect(NotificationCoordinator.tightenBody("Claude is requesting permission to use Bash")
            == "Requesting permission to use Bash")
        #expect(NotificationCoordinator.tightenBody("Claude needs your permission to use AskUserQuestion")
            == "Needs your permission to use AskUserQuestion")
    }

    @Test func dropsLeadingClaudeAndCapitalizes() {
        #expect(NotificationCoordinator.tightenBody(
            "Claude is waiting for your input") == "Waiting for your input")
        #expect(NotificationCoordinator.tightenBody("Claude is waiting for you") == "Waiting for you")
    }

    @Test func leavesUnprefixedBodyUnchanged() {
        #expect(NotificationCoordinator.tightenBody("Task finished") == "Task finished")
    }

    @Test func handlesDegenerateInputs() {
        #expect(NotificationCoordinator.tightenBody("") == "")
        // No trailing space: matches neither prefix, returned verbatim.
        #expect(NotificationCoordinator.tightenBody("Claude") == "Claude")
        // Bare prefix with nothing after it collapses to empty rather than crashing.
        #expect(NotificationCoordinator.tightenBody("Claude is ") == "")
    }
}

// MARK: - isRealTask

// The "was this a real task" gate behind the task-finished notification: a turn
// at least minTaskDuration (30s) long fires; quick replies stay quiet; an unknown
// duration (-1, start not recorded) errs toward notifying.
@Suite struct IsRealTaskTests {
    @Test func unknownDurationErrsTowardNotifying() {
        #expect(AwakeMonitor.isRealTask(durationSeconds: -1, minimum: 30))
    }

    @Test func quickReplyStaysQuiet() {
        #expect(!AwakeMonitor.isRealTask(durationSeconds: 0, minimum: 30))
        #expect(!AwakeMonitor.isRealTask(durationSeconds: 29, minimum: 30))
    }

    @Test func atOrPastThresholdFires() {
        #expect(AwakeMonitor.isRealTask(durationSeconds: 30, minimum: 30))   // boundary
        #expect(AwakeMonitor.isRealTask(durationSeconds: 31, minimum: 30))
    }
}
