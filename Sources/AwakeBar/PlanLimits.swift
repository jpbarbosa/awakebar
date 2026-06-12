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

    // Parse a transcript `timestamp` — ISO-8601, with or without fractional
    // seconds. Built locally per call (ISO8601DateFormatter isn't Sendable, so it
    // can't be a shared static under strict concurrency); it runs rarely.
    static func parseDate(_ string: String) -> Date? {
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
