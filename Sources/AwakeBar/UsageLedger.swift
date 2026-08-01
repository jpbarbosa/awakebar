import Foundation

// MARK: - Local usage ledger (the estimated /usage bars, no auth)
//
// Estimates the 5-hour and weekly plan-limit bars from Claude Code's *own* JSONL
// transcripts in `~/.claude/projects/**/*.jsonl` — the same files `ccusage`
// reads — so the menu needs no OAuth token, no Keychain prompt, and no network.
// This is the default and the fallback. The exact `/api/oauth/usage` numbers are
// available too, behind "Connect Claude Account…" (see UsageOAuth) — but that
// needs a login, so the estimate is what shows until you connect (and what we
// fall back to if a grant dies). We don't read *Claude Code's* Keychain token for
// it: that re-prompts on every rotation; UsageOAuth runs our own login instead.
// The transcripts also work in the VSCode extension (which runs Claude headless,
// so its status line — the other local source of these numbers — never renders).
//
// The catch: Anthropic's real limit is in opaque internal units we can't compute
// locally. So instead of a published denominator we **self-calibrate** — a
// window's utilisation is its cost as a fraction of the largest same-length
// window you've ever run. It needs no magic numbers and adapts to your plan, at
// the cost of being an estimate (and reading 100% whenever you set a new peak).
// Hence the "(est.)" the menu shows. Cost is the proxy for "limit units": it
// tracks the limit far better than raw token count (a cache read is ~1/10th the
// weight of fresh input).
//
// The pure pieces (`cost`, `parse`, `estimate`, `rollingPeak`) are internal so
// AwakeBarTests can drive them without touching the filesystem.
enum UsageLedger {
    // One deduped assistant response: when it happened and its USD-equivalent
    // cost (the limit-unit proxy, never shown as money).
    struct Entry: Sendable, Equatable {
        let ts: Date
        let cost: Double
    }

    static let fiveHours: TimeInterval = 5 * 3600
    static let sevenDays: TimeInterval = 7 * 86400

    // MARK: Cost model (pure, tested)

    // Per-Mtok prices as (input, output, cacheWrite, cacheRead); cacheWrite ≈
    // 1.25× input and cacheRead ≈ 0.1× input, matching Anthropic's published
    // multipliers. Matched by substring so model id drift (`claude-opus-4-…`)
    // still resolves; anything unrecognised is priced as Sonnet (the mid tier).
    private static let prices: [(needle: String, rate: (Double, Double, Double, Double))] = [
        ("opus",   (15, 75, 18.75, 1.50)),
        ("haiku",  (1,  5,  1.25,  0.10)),
        ("sonnet", (3,  15, 3.75,  0.30)),
    ]

    static func cost(model: String?, input: Int, output: Int, cacheWrite: Int, cacheRead: Int) -> Double {
        let m = (model ?? "").lowercased()
        let r = prices.first { m.contains($0.needle) }?.rate ?? prices.last!.rate
        return (Double(input) * r.0 + Double(output) * r.1
              + Double(cacheWrite) * r.2 + Double(cacheRead) * r.3) / 1_000_000
    }

    // MARK: Line parse (pure, tested)

    // Parse one JSONL line into (dedupKey, Entry), or nil unless it's an
    // assistant line carrying `message.usage` and a timestamp. The dedup key is
    // `<message.id>|<requestId>` — streaming writes 2–10 lines per request and
    // without it you multi-count (the same dedup `ccusage` uses).
    static func parse(line: Data) -> (key: String, entry: Entry)? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "assistant",
              let msg = obj["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any],
              let tsString = obj["timestamp"] as? String,
              let ts = PlanLimits.parseDate(tsString) else { return nil }
        func tok(_ key: String) -> Int {
            if let i = usage[key] as? Int { return i }
            if let d = usage[key] as? Double { return Int(d) }
            return 0
        }
        let entry = Entry(ts: ts, cost: cost(model: msg["model"] as? String,
                                             input: tok("input_tokens"),
                                             output: tok("output_tokens"),
                                             cacheWrite: tok("cache_creation_input_tokens"),
                                             cacheRead: tok("cache_read_input_tokens")))
        let id = msg["id"] as? String ?? ""
        let rid = obj["requestId"] as? String ?? ""
        return ("\(id)|\(rid)", entry)
    }

    // MARK: Estimate (pure, tested)

    // Build the two bars from a deduped, time-sorted entry list. Only `fiveHour`
    // and `sevenDay` are filled — the local data can't separate the per-model
    // weekly buckets — so those menu rows stay hidden (the Usage decoder already
    // treats absent buckets as nil).
    static func estimate(from entries: [Entry], now: Date) -> PlanLimits.Usage {
        var usage = PlanLimits.Usage()
        usage.fiveHour = window(entries, length: fiveHours, now: now)
        usage.sevenDay = window(entries, length: sevenDays, now: now)
        return usage
    }

    // One window: cost in the trailing `length` as a fraction of the historical
    // peak for that length, clamped to 0–100. `resetsAt` is when the window's
    // oldest still-counted entry ages out (i.e. when this load starts to fall if
    // you stop now); nil when nothing falls in the window.
    private static func window(_ entries: [Entry], length: TimeInterval, now: Date) -> PlanLimits.Window? {
        let cutoff = now.addingTimeInterval(-length)
        let inWindow = entries.filter { $0.ts >= cutoff }
        guard !inWindow.isEmpty else { return nil }
        let peak = rollingPeak(entries, length: length)
        let sum = inWindow.reduce(0) { $0 + $1.cost }
        let util = peak > 0 ? min(100, 100 * sum / peak) : 0
        let reset = inWindow.map(\.ts).min().map { $0.addingTimeInterval(length) }
        return PlanLimits.Window(utilization: util, resetsAt: reset)
    }

    // Largest total cost over any `length`-long sliding window across all history
    // — the self-calibrated denominator. O(n) two-pointer sweep; `entries` must be
    // sorted ascending by time.
    static func rollingPeak(_ entries: [Entry], length: TimeInterval) -> Double {
        var peak = 0.0, sum = 0.0, lo = 0
        for hi in entries.indices {
            sum += entries[hi].cost
            while entries[hi].ts.timeIntervalSince(entries[lo].ts) > length {
                sum -= entries[lo].cost
                lo += 1
            }
            peak = max(peak, sum)
        }
        return peak
    }

    // MARK: Scan (IO — not unit-tested)

    // Walk the transcripts, dedup, return entries sorted by time. The rolling peak
    // spans all history, so every file has to be *accounted for* on every scan —
    // but re-*reading* them all doesn't: a 3 GB corpus re-parsed every 5 minutes is
    // what made this the top CPU process on the machine. `Cache` keeps each file's
    // parsed rows and re-reads only those whose (mtime, size) moved, which in a
    // steady state is the one transcript currently being written.
    //
    // A byte pre-filter still skips lines that can't carry usage before the JSON
    // parse — though only ~60% of them, not the ~95% this comment used to claim.
    private static let usageMarker = Data(#""usage""#.utf8)

    // One parsed usage line: the dedup key, hashed, plus the entry itself.
    // Hashed because keeping ~250k `<message.id>|<requestId>` strings resident
    // costs ~20 MB in a menu-bar app; a 64-bit collision would drop a single
    // response from an estimate that is self-calibrated anyway. `Hasher` is seeded
    // per process, which is fine — this cache never outlives the process.
    private struct Row: Sendable {
        let key: UInt64
        let entry: Entry
    }

    // Owns the cross-refresh cache. An actor because `scan` runs on a detached
    // task; the coordinator's `inFlight` flag already serialises callers, but the
    // compiler can't see that.
    actor Cache {
        static let shared = Cache()

        private struct CachedFile: Sendable {
            let mtime: Date
            let size: Int
            let rows: [Row]
        }
        private var files: [String: CachedFile] = [:]

        private static let stat: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]

        func scan(projectsDir: URL) -> [Entry] {
            let fm = FileManager.default
            guard let walker = fm.enumerator(at: projectsDir,
                                             includingPropertiesForKeys: Array(Self.stat))
            else { return [] }

            var fresh: [String: CachedFile] = [:]
            var seen = Set<UInt64>()
            var entries: [Entry] = []

            for case let url as URL in walker where url.pathExtension == "jsonl" {
                let values = try? url.resourceValues(forKeys: Self.stat)
                let mtime = values?.contentModificationDate ?? .distantPast
                let size = values?.fileSize ?? -1

                let file: CachedFile
                if let hit = files[url.path], hit.mtime == mtime, hit.size == size {
                    file = hit
                } else {
                    file = CachedFile(mtime: mtime, size: size, rows: Self.rows(of: url))
                }
                fresh[url.path] = file
                // Cross-file dedup survives the cache: a forked session replays
                // earlier responses into a new transcript.
                for row in file.rows where seen.insert(row.key).inserted {
                    entries.append(row.entry)
                }
            }
            // Rebuilt rather than mutated so deleted transcripts drop out.
            files = fresh
            return entries.sorted { $0.ts < $1.ts }
        }

        // Parse one transcript, deduped within the file (streaming writes 2–10
        // lines per request). Mapped rather than read: these run to tens of MB and
        // the old whole-file loads were most of the app's 600 MB resident peak.
        private static func rows(of url: URL) -> [Row] {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
            var rows: [Row] = []
            var local = Set<UInt64>()
            for slice in data.split(separator: UInt8(ascii: "\n")) {
                let line = Data(slice)
                guard line.range(of: UsageLedger.usageMarker) != nil,
                      let parsed = UsageLedger.parse(line: line) else { continue }
                var hasher = Hasher()
                hasher.combine(parsed.key)
                let key = UInt64(bitPattern: Int64(hasher.finalize()))
                guard local.insert(key).inserted else { continue }
                rows.append(Row(key: key, entry: parsed.entry))
            }
            return rows
        }
    }
}
