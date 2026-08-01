import Testing
import Foundation
@testable import AwakeBar

// Unit tests for the pure pieces of UsageLedger — the cost model, the per-line
// parse + dedup key, the self-calibrated rolling peak, and the window estimate.
// The filesystem scan isn't exercised here (it needs real transcripts); all of
// the below is deterministic input → output.

// MARK: - cost

@Suite struct UsageLedgerCostTests {
    @Test func pricesEachTierFromOneMtokOfInput() {
        // 1 Mtok of plain input → the tier's input rate, in dollars.
        #expect(UsageLedger.cost(model: "claude-opus-4-8", input: 1_000_000, output: 0, cacheWrite: 0, cacheRead: 0) == 15)
        #expect(UsageLedger.cost(model: "claude-sonnet-4-6", input: 1_000_000, output: 0, cacheWrite: 0, cacheRead: 0) == 3)
        #expect(UsageLedger.cost(model: "claude-haiku-4-5", input: 1_000_000, output: 0, cacheWrite: 0, cacheRead: 0) == 1)
    }

    @Test func unknownModelPricesAsSonnet() {
        #expect(UsageLedger.cost(model: "some-future-model", input: 1_000_000, output: 0, cacheWrite: 0, cacheRead: 0) == 3)
        #expect(UsageLedger.cost(model: nil, input: 1_000_000, output: 0, cacheWrite: 0, cacheRead: 0) == 3)
    }

    @Test func sumsAllFourTokenClasses() {
        // Opus, 1 Mtok of each class → 15 + 75 + 18.75 + 1.50.
        let c = UsageLedger.cost(model: "claude-opus-4", input: 1_000_000, output: 1_000_000,
                                 cacheWrite: 1_000_000, cacheRead: 1_000_000)
        #expect(abs(c - 110.25) < 1e-9)
    }
}

// MARK: - parse

@Suite struct UsageLedgerParseTests {
    private func line(_ json: String) -> (key: String, entry: UsageLedger.Entry)? {
        UsageLedger.parse(line: Data(json.utf8))
    }

    @Test func parsesAssistantUsageLine() {
        let r = line(#"""
        {"type":"assistant","requestId":"req1","timestamp":"2026-06-01T06:00:00Z",
         "message":{"id":"msg1","model":"claude-sonnet-4",
         "usage":{"input_tokens":1000000,"output_tokens":0,
                  "cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """#)
        #expect(r?.key == "msg1|req1")
        #expect(r?.entry.cost == 3)
        #expect(r?.entry.ts == PlanLimits.parseDate("2026-06-01T06:00:00Z"))
    }

    @Test func skipsNonAssistantOrUsagelessLines() {
        // user line, assistant-without-usage, and non-JSON all yield nil.
        #expect(line(#"{"type":"user","message":{"content":"hi"}}"#) == nil)
        #expect(line(#"{"type":"assistant","timestamp":"2026-06-01T06:00:00Z","message":{"id":"m"}}"#) == nil)
        #expect(line("not json") == nil)
    }

    @Test func requiresAParseableTimestamp() {
        #expect(line(#"{"type":"assistant","message":{"id":"m","usage":{"input_tokens":1}}}"#) == nil)
    }
}

// MARK: - rollingPeak

@Suite struct UsageLedgerPeakTests {
    private func e(_ tsSecs: TimeInterval, _ cost: Double) -> UsageLedger.Entry {
        UsageLedger.Entry(ts: Date(timeIntervalSince1970: tsSecs), cost: cost)
    }

    @Test func findsLargestSlidingWindowSum() {
        // Three entries within 2h sum to 6; a lone later entry is 10. Over a 5h
        // window the peak is the lone 10, not the clustered 6.
        let entries = [e(0, 1), e(3600, 2), e(7200, 3), e(100_000, 10)]
        #expect(UsageLedger.rollingPeak(entries, length: 5 * 3600) == 10)
    }

    @Test func clusterWithinWindowSumsTogether() {
        // All three inside the 5h window → 1 + 2 + 3.
        let entries = [e(0, 1), e(3600, 2), e(7200, 3)]
        #expect(UsageLedger.rollingPeak(entries, length: 5 * 3600) == 6)
    }

    @Test func emptyIsZero() {
        #expect(UsageLedger.rollingPeak([], length: 5 * 3600) == 0)
    }
}

// MARK: - estimate / window

@Suite struct UsageLedgerEstimateTests {
    private func e(_ tsSecs: TimeInterval, _ cost: Double) -> UsageLedger.Entry {
        UsageLedger.Entry(ts: Date(timeIntervalSince1970: tsSecs), cost: cost)
    }

    @Test func currentWindowUtilisationIsFractionOfHistoricalPeak() {
        // Past peak block sums to 8; the current 5h window holds 4 → 50%.
        let now = Date(timeIntervalSince1970: 1_000_000)
        let entries = [
            e(0, 5), e(60, 3),                              // historical peak block = 8
            e(1_000_000 - 600, 4),                          // in the current 5h window
        ]
        let u = UsageLedger.estimate(from: entries, now: now)
        #expect(u.fiveHour?.utilization == 50)
        // Reset = oldest entry still in the window + 5h.
        #expect(u.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_000_000 - 600 + 5 * 3600))
        // Local data never fills the per-model weekly buckets.
        #expect(u.sevenDayOpus == nil)
        #expect(u.sevenDaySonnet == nil)
    }

    @Test func utilisationClampsAtAHundredOnANewPeak() {
        // The only activity is in the current window, so it *is* the peak → 100%.
        let now = Date(timeIntervalSince1970: 1_000_000)
        let u = UsageLedger.estimate(from: [e(1_000_000 - 300, 9)], now: now)
        #expect(u.fiveHour?.utilization == 100)
    }

    @Test func emptyWindowsAreNil() {
        // All activity is older than a week → both windows empty.
        let now = Date(timeIntervalSince1970: 10 * 86400)
        let u = UsageLedger.estimate(from: [e(0, 5)], now: now)
        #expect(u.fiveHour == nil)
        #expect(u.sevenDay == nil)
        #expect(u.isEmpty)
    }
}

// MARK: - Cache (incremental scan)

// These do touch the filesystem — a temp dir of synthetic transcripts — because
// the whole point of the cache is its interaction with file stat.
@Suite struct UsageLedgerCacheTests {
    private func line(id: String, req: String, ts: String, input: Int = 1_000_000) -> String {
        #"{"type":"assistant","requestId":"\#(req)","timestamp":"\#(ts)","message":"# +
        #"{"id":"\#(id)","model":"claude-sonnet-4","usage":{"input_tokens":\#(input),"# +
        #""output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
    }

    private func makeDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func scansDedupesAndSortsAcrossFiles() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // b.jsonl repeats a.jsonl's first response (a forked session) — it must be
        // counted once — and the two files are walked in unspecified order, so the
        // result also has to come back sorted.
        try [line(id: "m2", req: "r2", ts: "2026-06-01T08:00:00Z"),
             line(id: "m1", req: "r1", ts: "2026-06-01T06:00:00Z")]
            .joined(separator: "\n").write(to: dir.appendingPathComponent("a.jsonl"),
                                           atomically: true, encoding: .utf8)
        try [line(id: "m1", req: "r1", ts: "2026-06-01T06:00:00Z"),
             line(id: "m3", req: "r3", ts: "2026-06-01T07:00:00Z")]
            .joined(separator: "\n").write(to: dir.appendingPathComponent("b.jsonl"),
                                           atomically: true, encoding: .utf8)

        let entries = await UsageLedger.Cache().scan(projectsDir: dir)
        #expect(entries.count == 3)
        #expect(entries.map(\.ts) == entries.map(\.ts).sorted())
    }

    @Test func rereadsOnlyWhenMtimeOrSizeMoves() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.jsonl")
        try line(id: "m1", req: "r1", ts: "2026-06-01T06:00:00Z")
            .write(to: file, atomically: true, encoding: .utf8)

        let cache = UsageLedger.Cache()
        #expect(await cache.scan(projectsDir: dir).count == 1)

        // Rewrite with different content but restore the original (mtime, size) —
        // the cache key. A stale result here is the proof the file was *not*
        // re-read; without the cache this would return the new timestamp.
        let stat = try FileManager.default.attributesOfItem(atPath: file.path)
        let original = stat[.modificationDate] as! Date
        try line(id: "m9", req: "r9", ts: "2026-06-02T06:00:00Z")
            .write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: original], ofItemAtPath: file.path)

        let cached = await cache.scan(projectsDir: dir)
        #expect(cached.first?.ts == PlanLimits.parseDate("2026-06-01T06:00:00Z"))

        // Now let the mtime move: the new content must be picked up.
        try FileManager.default.setAttributes([.modificationDate: original.addingTimeInterval(60)],
                                              ofItemAtPath: file.path)
        let refreshed = await cache.scan(projectsDir: dir)
        #expect(refreshed.first?.ts == PlanLimits.parseDate("2026-06-02T06:00:00Z"))
    }

    @Test func droppedTranscriptsLeaveTheLedger() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.jsonl")
        try line(id: "m1", req: "r1", ts: "2026-06-01T06:00:00Z")
            .write(to: file, atomically: true, encoding: .utf8)

        let cache = UsageLedger.Cache()
        #expect(await cache.scan(projectsDir: dir).count == 1)
        try FileManager.default.removeItem(at: file)
        #expect(await cache.scan(projectsDir: dir).isEmpty)
    }
}
