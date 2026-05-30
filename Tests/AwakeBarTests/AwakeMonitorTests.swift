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

// MARK: - connectedProject (drives the file-reading path with sample logs)

@Suite struct ConnectedProjectTests {
    // Write `contents` to a unique temp file, run `body` with its path, then clean
    // up — connectedProject reads the file itself, so it needs a real path.
    private func withLog(_ contents: String,
                         _ body: (String) -> Void) {
        let dir = NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent(
            "awakebar-test-\(ProcessInfo.processInfo.globallyUniqueString).log")
        try? contents.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        body(path)
    }

    @Test func connectedReturnsProjectBasename() {
        withLog("""
        2026-05-30 14:00:00.000 [remote-bridge] v2 transport connected
        2026-05-30 14:00:01.000 Spawning Claude with SDK query function - cwd: /Users/jp/Sites/awakebar, x
        """) { path in
            #expect(AwakeMonitor.connectedProject(inTailOf: path) == "awakebar")
        }
    }

    @Test func teardownAfterConnectReturnsNil() {
        withLog("""
        2026-05-30 14:00:00.000 [remote-bridge] v2 transport connected
        2026-05-30 14:00:01.000 Spawning Claude with SDK query function - cwd: /Users/jp/Sites/awakebar, x
        2026-05-30 14:05:00.000 [remote-bridge] Torn down
        """) { path in
            #expect(AwakeMonitor.connectedProject(inTailOf: path) == nil)
        }
    }

    @Test func bridgeTrafficWithoutMarkersCountsAsConnected() {
        // No lifecycle marker survives in the tail, but bridge traffic is present —
        // treated as a connected session past its handshake.
        withLog("""
        2026-05-30 14:00:00.000 [remote-bridge] forwarding message
        2026-05-30 14:00:01.000 {"cwd":"/Users/jp/proj"}
        """) { path in
            #expect(AwakeMonitor.connectedProject(inTailOf: path) == "proj")
        }
    }

    @Test func noBridgeContentReturnsNil() {
        withLog("""
        2026-05-30 14:00:00.000 [info] ordinary log line
        2026-05-30 14:00:01.000 [info] nothing bridge-related here
        """) { path in
            #expect(AwakeMonitor.connectedProject(inTailOf: path) == nil)
        }
    }
}
