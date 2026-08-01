import Foundation

// MARK: - Plan limits (the `/usage` screen) — shared types + formatting
//
// The value types the plan-usage menu renders, plus the pure date/countdown
// helpers. The numbers themselves come from `/api/oauth/usage` via `UsageOAuth`.
// Kept here, and kept internal, so the decoder, the menu and AwakeBarTests share
// one shape.
enum PlanLimits {
    // One usage window: how much of the allowance is spent and when it resets.
    // `utilization` is a percentage (0–100); `resetsAt` is nil when unknown.
    struct Window: Sendable, Equatable {
        let utilization: Double
        let resetsAt: Date?
    }

    // The plan-usage snapshot. Each bucket is nil when the payload omits it — a
    // plan without per-model weekly limits leaves those two nil, and their menu
    // rows stay hidden.
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

    // Parse a `resets_at` — ISO-8601, with or without fractional seconds. A handful
    // of calls per fetch, so the formatter is fine here; it isn't Sendable, hence
    // built per call rather than hoisted into a shared static.
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
