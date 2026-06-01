import Testing
import Foundation
@testable import AwakeBar

// Unit tests for the pure pieces of PlanLimits — the parts that turn a raw
// /api/oauth/usage body (and the Keychain blob) into the values the menu renders.
// The Keychain read and the network call aren't exercised here (they need a live
// account); everything below is deterministic input → output.

// MARK: - decode

@Suite struct PlanLimitsDecodeTests {
    private func usage(_ json: String) -> PlanLimits.Usage? {
        PlanLimits.decode(Data(json.utf8))
    }

    @Test func decodesAllBucketsLikeTheUsageScreen() {
        let u = usage("""
        {
          "five_hour":  { "utilization": 26, "resets_at": "2026-06-01T06:59:00Z" },
          "seven_day":  { "utilization": 17, "resets_at": "2026-06-06T06:59:00Z" },
          "seven_day_opus": null,
          "seven_day_sonnet": { "utilization": 0, "resets_at": "2026-06-06T06:59:00Z" }
        }
        """)
        #expect(u?.fiveHour?.utilization == 26)
        #expect(u?.sevenDay?.utilization == 17)
        // A null per-model bucket ("haven't used yet") decodes to nil, not 0.
        #expect(u?.sevenDayOpus == nil)
        // A present 0% bucket is distinct from absent — it's a real Window(0).
        #expect(u?.sevenDaySonnet?.utilization == 0)
        #expect(u?.sevenDaySonnet != nil)
    }

    @Test func parsesResetTimestamp() {
        let u = usage(#"{ "five_hour": { "utilization": 26, "resets_at": "2026-06-01T06:59:00Z" } }"#)
        #expect(u?.fiveHour?.resetsAt == PlanLimits.parseDate("2026-06-01T06:59:00Z"))
    }

    @Test func acceptsFractionalUtilizationAndCamelCaseKeys() {
        // Tolerant of unverified spellings: camelCase keys + used_percentage.
        let u = usage(#"{ "fiveHour": { "used_percentage": 26.5, "resetsAt": "2026-06-01T06:59:00Z" } }"#)
        #expect(u?.fiveHour?.utilization == 26.5)
        #expect(u?.fiveHour?.resetsAt != nil)
    }

    @Test func acceptsEpochSecondsReset() {
        let u = usage(#"{ "five_hour": { "utilization": 10, "resets_at": 1780000000 } }"#)
        #expect(u?.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_780_000_000))
    }

    @Test func windowWithoutUtilizationIsDropped() {
        // No usable utilization → that bucket is nil (here the only bucket, so nil).
        #expect(usage(#"{ "five_hour": { "resets_at": "2026-06-01T06:59:00Z" } }"#) == nil)
    }

    @Test func emptyOrUnknownBodyIsNil() {
        #expect(usage("{}") == nil)
        #expect(usage(#"{ "something_else": 1 }"#) == nil)
        #expect(PlanLimits.decode(Data("not json".utf8)) == nil)
    }
}

// MARK: - credential(fromKeychainBlob:)

@Suite struct PlanLimitsCredentialTests {
    private func cred(_ json: String) -> PlanLimits.Credential? {
        PlanLimits.credential(fromKeychainBlob: Data(json.utf8))
    }

    @Test func extractsNestedTokenAndPlan() {
        let c = cred(#"""
        { "claudeAiOauth": { "accessToken": "sk-ant-oat01-abc", "expiresAt": 1,
          "subscriptionType": "max", "rateLimitTier": "default_max_5x" } }
        """#)
        #expect(c?.token == "sk-ant-oat01-abc")
        #expect(c?.planLabel == "Max (5x)")
    }

    @Test func acceptsFlatAccessToken() {
        #expect(cred(#"{ "accessToken": "sk-ant-oat01-xyz" }"#)?.token == "sk-ant-oat01-xyz")
    }

    @Test func tokenWithoutPlanFields() {
        let c = cred(#"{ "claudeAiOauth": { "accessToken": "sk-ant-oat01-abc" } }"#)
        #expect(c?.token == "sk-ant-oat01-abc")
        #expect(c?.planLabel == nil)
    }

    @Test func rejectsJsonWithoutToken() {
        #expect(cred(#"{ "claudeAiOauth": { "refreshToken": "r" } }"#) == nil)
        #expect(cred("{}") == nil)
    }

    @Test func acceptsBareOpaqueToken() {
        // A non-JSON value is treated as the raw token only if it's a single word.
        #expect(PlanLimits.credential(fromKeychainBlob: Data("sk-ant-oat01-bareraw0001".utf8))?.token
                == "sk-ant-oat01-bareraw0001")
        #expect(PlanLimits.credential(fromKeychainBlob: Data("two words here".utf8)) == nil)
    }
}

// MARK: - planLabel

@Suite struct PlanLimitsPlanLabelTests {
    @Test func titleCasesTypeAndAppendsMultiplier() {
        #expect(PlanLimits.planLabel(subscriptionType: "max", rateLimitTier: "default_max_5x") == "Max (5x)")
        #expect(PlanLimits.planLabel(subscriptionType: "max", rateLimitTier: "claude_max_20x") == "Max (20x)")
        #expect(PlanLimits.planLabel(subscriptionType: "pro", rateLimitTier: nil) == "Pro")
    }

    @Test func tierWithoutMultiplierIsJustTheName() {
        #expect(PlanLimits.planLabel(subscriptionType: "max", rateLimitTier: "default") == "Max")
    }

    @Test func nilOrEmptyTypeIsNil() {
        #expect(PlanLimits.planLabel(subscriptionType: nil, rateLimitTier: "default_max_5x") == nil)
        #expect(PlanLimits.planLabel(subscriptionType: "", rateLimitTier: nil) == nil)
    }
}

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
