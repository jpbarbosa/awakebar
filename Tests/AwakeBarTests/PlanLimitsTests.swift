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
}
