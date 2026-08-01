import Foundation

// MARK: - Plan limits (the `/usage` screen) — shared types + formatting
//
// The value types the plan-usage menu renders, plus the pure date/countdown
// helpers. The numbers themselves are produced locally by `UsageLedger` (an
// estimate from Claude Code's JSONL transcripts — see that file for why we don't
// hit the `/api/oauth/usage` endpoint or the Keychain anymore). Kept here, and
// kept internal, so both `UsageLedger` and `AwakeBarTests` share one shape.
enum PlanLimits {
    // One usage window: how much of the allowance is spent and when it resets.
    // `utilization` is a percentage (0–100); `resetsAt` is nil when unknown.
    struct Window: Sendable, Equatable {
        let utilization: Double
        let resetsAt: Date?
    }

    // The plan-usage snapshot. Each bucket is nil when it doesn't apply — the
    // local estimate fills only `fiveHour`/`sevenDay`, leaving the per-model
    // weekly buckets nil so their menu rows stay hidden.
    struct Usage: Sendable, Equatable {
        var fiveHour: Window?
        var sevenDay: Window?
        var sevenDayOpus: Window?
        var sevenDaySonnet: Window?

        var isEmpty: Bool {
            fiveHour == nil && sevenDay == nil && sevenDayOpus == nil && sevenDaySonnet == nil
        }
    }

    // MARK: Dates (pure, testable)

    // Days from 1970-01-01 to a proleptic-Gregorian y/m/d (Hinnant's
    // days_from_civil). Pure integer math: a Calendar here would pull in exactly
    // the ICU machinery `parseFixedUTC` exists to avoid.
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400                                             // [0, 399]
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1  // [0, 365]
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy                     // [0, 146096]
        return era * 146097 + doe - 719468
    }

    // `2026-07-31T21:14:59.831Z` and `2026-07-31T21:14:59Z` — the only two shapes
    // Claude Code writes. Anything else (a numeric offset, a missing `Z`) returns
    // nil so the formatter fallback can handle it.
    private static func parseFixedUTC(_ b: UnsafeBufferPointer<UInt8>) -> Date? {
        func digits(_ lo: Int, _ hi: Int) -> Int? {
            var v = 0
            for i in lo..<hi {
                let d = Int(b[i]) - 48
                guard d >= 0, d <= 9 else { return nil }
                v = v * 10 + d
            }
            return v
        }
        guard b.count >= 20, b[b.count - 1] == UInt8(ascii: "Z"),
              b[4] == UInt8(ascii: "-"), b[7] == UInt8(ascii: "-"),
              b[10] == UInt8(ascii: "T"), b[13] == UInt8(ascii: ":"),
              b[16] == UInt8(ascii: ":"),
              let year = digits(0, 4), let month = digits(5, 7), let day = digits(8, 10),
              let hour = digits(11, 13), let minute = digits(14, 16),
              let second = digits(17, 19),
              1...12 ~= month, 1...31 ~= day,
              // `second <= 59`, not 60: a leap second is one of the shapes the
              // formatter rejects, so decline it here and let the fallback agree.
              hour <= 23, minute <= 59, second <= 59
        else { return nil }

        var fraction = 0.0
        if b.count > 20 {
            guard b[19] == UInt8(ascii: ".") else { return nil }
            var scale = 0.1
            for i in 20..<(b.count - 1) {
                let d = Int(b[i]) - 48
                guard d >= 0, d <= 9 else { return nil }
                fraction += Double(d) * scale
                scale /= 10
            }
        }
        let secs = daysFromCivil(year: year, month: month, day: day) * 86_400
                 + hour * 3_600 + minute * 60 + second
        return Date(timeIntervalSince1970: Double(secs) + fraction)
    }

    // Parse a transcript `timestamp` — ISO-8601, with or without fractional
    // seconds. ISO8601DateFormatter isn't Sendable, so it can't be hoisted into a
    // shared static under strict concurrency, and *constructing* one costs an ICU
    // locale + calendar init. At ~250k calls per ledger scan that made this app the
    // machine's top CPU consumer, so the common UTC shape is parsed by hand and the
    // formatter is kept only as the fallback for everything else.
    static func parseDate(_ string: String) -> Date? {
        var s = string
        if let date = s.withUTF8({ parseFixedUTC($0) }) { return date }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: string) { return date }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: string)
    }

    // MARK: Formatting (pure, testable)

    // "in 2h 47m" countdown to a reset, matching the `/usage` wording. Past or
    // imminent resets collapse to "now". (internal so tests can drive it.)
    static func countdown(to date: Date, now: Date) -> String {
        let secs = Int(date.timeIntervalSince(now))
        guard secs > 0 else { return "now" }
        let h = secs / 3600, m = (secs % 3600) / 60
        if h > 0 { return "in \(h)h \(m)m" }
        if m > 0 { return "in \(m)m" }
        return "in <1m"
    }
}
