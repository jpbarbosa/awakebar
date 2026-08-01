import Testing
import Foundation
@testable import AwakeBar

// Unit tests for the pure date/formatting helpers PlanLimits still owns. The
// numbers themselves are produced by UsageLedger (see UsageLedgerTests); these
// just cover the shared countdown + timestamp parsing the menu renders with.

// MARK: - countdown

@Suite struct PlanLimitsCountdownTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func ahead(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }

    @Test func formatsHoursAndMinutes() {
        // 2h47m, matching the /usage "Resets in 2 hr 47 min".
        #expect(PlanLimits.countdown(to: ahead(2 * 3600 + 47 * 60), now: now) == "in 2h 47m")
    }

    @Test func formatsMinutesOnly() {
        #expect(PlanLimits.countdown(to: ahead(5 * 60), now: now) == "in 5m")
    }

    @Test func collapsesSubMinuteAndPast() {
        #expect(PlanLimits.countdown(to: ahead(30), now: now) == "in <1m")
        #expect(PlanLimits.countdown(to: ahead(-10), now: now) == "now")
    }
}

// MARK: - parseDate

@Suite struct PlanLimitsParseDateTests {
    @Test func parsesWithAndWithoutFractionalSeconds() {
        let plain = PlanLimits.parseDate("2026-06-01T06:59:00Z")
        let frac  = PlanLimits.parseDate("2026-06-01T06:59:00.000Z")
        #expect(plain != nil)
        #expect(plain == frac)
    }

    @Test func rejectsGarbage() {
        #expect(PlanLimits.parseDate("not a date") == nil)
    }

    // The cases below pin the hand-rolled UTC fast path against the
    // ISO8601DateFormatter it bypasses — the two must not drift apart.

    @Test func fastPathAgreesWithTheFormatter() {
        // Fractional digits are weighted, not just counted, and the epoch/civil
        // arithmetic has to survive leap years and century boundaries.
        let cases: [(String, TimeInterval)] = [
            ("1970-01-01T00:00:00Z",     0),
            ("2000-01-01T00:00:00Z",     946_684_800),
            ("2024-02-29T12:00:00Z",     1_709_208_000),   // leap day
            ("2026-12-31T23:59:59Z",     1_798_761_599),
            ("2026-06-01T06:59:00.250Z", 1_780_297_140.25),
        ]
        for (string, expected) in cases {
            let parsed = PlanLimits.parseDate(string)
            #expect(parsed != nil, "failed to parse \(string)")
            #expect(abs((parsed?.timeIntervalSince1970 ?? .nan) - expected) < 0.0005,
                    "\(string) parsed as \(parsed?.timeIntervalSince1970 ?? .nan), expected \(expected)")
        }
    }

    @Test func fallsBackToTheFormatterForNonUTCOffsets() {
        // The fast path only accepts a trailing `Z`; this shape must still parse.
        let offset = PlanLimits.parseDate("2026-06-01T06:59:00+02:00")
        #expect(offset == PlanLimits.parseDate("2026-06-01T04:59:00Z"))
    }

    @Test func rejectsOutOfRangeAndMalformedComponents() {
        for bad in ["2026-13-01T00:00:00Z",   // month
                    "2026-06-01T25:00:00Z",   // hour
                    "2026-06-01T06:70:00Z",   // minute
                    "2026-06-01T06:59:60Z",   // leap second — formatter rejects it too
                    "2026-06-01T06:59:00",    // no zone
                    "2026-06-01T06:59:00.xxZ",
                    "2026-06-01X06:59:00Z"] {
            #expect(PlanLimits.parseDate(bad) == nil, "\(bad) should not parse")
        }
    }
}
