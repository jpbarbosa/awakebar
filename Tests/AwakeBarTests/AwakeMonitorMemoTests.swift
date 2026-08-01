import Testing
import Foundation
@testable import AwakeBar

// The log memo backing AwakeMonitor.collect(). The failure that matters is a
// stale hit — a permission prompt appended to a log the memo decided not to
// re-read would never reach a notification — so these lean on that direction.

@Suite struct AwakeMonitorStampTests {
    private func tempFile(_ contents: String) throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stamp-\(UUID().uuidString).log")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    @Test func appendingMovesTheStamp() throws {
        let path = try tempFile("one\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let before = AwakeMonitor.Stamp.of(path)
        let fh = FileHandle(forWritingAtPath: path)!
        try fh.seekToEnd()
        try fh.write(contentsOf: Data("two\n".utf8))
        try fh.close()
        #expect(AwakeMonitor.Stamp.of(path) != before)
    }

    @Test func anUntouchedFileKeepsItsStamp() throws {
        let path = try tempFile("one\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(AwakeMonitor.Stamp.of(path) == AwakeMonitor.Stamp.of(path))
    }

    @Test func aMissingFileStampsWithoutThrowing() {
        // Logs vanish when a VSCode window closes mid-tick; that must not trap.
        let gone = AwakeMonitor.Stamp.of("/nope/does/not/exist.log")
        #expect(gone == AwakeMonitor.Stamp.of("/nope/also/missing.log"))
    }
}

@Suite struct AwakeMonitorLogMemoTests {
    private func tempFile(_ contents: String) throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("memo-\(UUID().uuidString).log")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    @Test func reusesTheParseUntilTheFileMoves() throws {
        let path = try tempFile("one\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let memo = AwakeMonitor.LogMemo()
        var computes = 0
        func events() -> [AwakeMonitor.VSCodeAttention] {
            computes += 1
            let body = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            return [AwakeMonitor.VSCodeAttention(project: "p", message: body,
                                                 time: Date(), resolved: false)]
        }

        _ = memo.attentionEvents(for: path, compute: events)
        _ = memo.attentionEvents(for: path, compute: events)
        #expect(computes == 1, "unchanged file should not be re-parsed")

        // Append, as the extension does — the memo must notice and re-parse.
        let fh = FileHandle(forWritingAtPath: path)!
        try fh.seekToEnd()
        try fh.write(contentsOf: Data("two\n".utf8))
        try fh.close()

        let after = memo.attentionEvents(for: path, compute: events)
        #expect(computes == 2, "an appended log must be re-parsed")
        #expect(after.first?.message.contains("two") == true)
    }

    @Test func remoteAndAttentionCachesAreIndependent() throws {
        let path = try tempFile("x\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let memo = AwakeMonitor.LogMemo()
        var remoteComputes = 0
        // A nil remote session is a real answer (bridge down), not a cache miss —
        // it must be remembered rather than recomputed every tick.
        for _ in 0..<3 {
            _ = memo.remoteSession(for: path) { remoteComputes += 1; return nil }
        }
        #expect(remoteComputes == 1)
        var attentionComputes = 0
        _ = memo.attentionEvents(for: path) { attentionComputes += 1; return [] }
        #expect(attentionComputes == 1, "the remote cache must not satisfy an attention lookup")
    }

    @Test func theWalkIsReusedWithinItsTTLAndRefreshedAfter() throws {
        let memo = AwakeMonitor.LogMemo()
        var walks = 0
        func walk() -> [String] { walks += 1; return ["/a.log"] }

        _ = memo.logs(ttl: 60, compute: walk)
        _ = memo.logs(ttl: 60, compute: walk)
        #expect(walks == 1, "a walk inside the TTL should be reused")

        // A zero TTL is always expired — the next call must walk again.
        _ = memo.logs(ttl: 0, compute: walk)
        #expect(walks == 2)
    }

    @Test func logsThatLeaveTheWalkAreForgotten() throws {
        let path = try tempFile("x\n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let memo = AwakeMonitor.LogMemo()
        var computes = 0
        func events() -> [AwakeMonitor.VSCodeAttention] { computes += 1; return [] }

        _ = memo.logs(ttl: 60) { [path] }
        _ = memo.attentionEvents(for: path, compute: events)
        #expect(computes == 1)

        // The window closed: the next walk drops it, so its tail must not be held.
        _ = memo.logs(ttl: 0) { [] }
        _ = memo.attentionEvents(for: path, compute: events)
        #expect(computes == 2, "an evicted log should not still be cached")
    }
}
