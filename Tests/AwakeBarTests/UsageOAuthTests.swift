import Testing
import Foundation
@testable import AwakeBar

// Unit tests for the pure pieces of UsageOAuth — the PKCE derivation, the
// authorize-URL shape, the pasted-code split, and the token/usage decoders. The
// URLSession calls (exchange/refresh/fetchUsage/runLive) and TokenStore are IO
// and aren't exercised here; everything below is deterministic input → output.

// MARK: - PKCE

@Suite struct UsageOAuthPKCETests {
    // RFC 7636 Appendix B test vector: this verifier hashes to this challenge.
    @Test func challengeMatchesRFC7636Vector() {
        #expect(UsageOAuth.challenge(forVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
                == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func base64URLIsURLSafeAndUnpadded() {
        // Bytes that force both a '+'(→'-') and a '/'(→'_') in standard base64, and
        // a length that would normally be '='-padded.
        let encoded = UsageOAuth.base64URL(Data([0xFB, 0xFF, 0xBF]))
        #expect(encoded == "-_-_")
        #expect(!encoded.contains("="))
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
    }

    @Test func pkceVerifierIsTheEncodedRandomBytes() {
        let bytes = Data((0..<32).map { UInt8($0) })
        let p = UsageOAuth.pkce(randomBytes: bytes)
        #expect(p.verifier == UsageOAuth.base64URL(bytes))
        #expect(p.challenge == UsageOAuth.challenge(forVerifier: p.verifier))
    }
}

// MARK: - authorizeURL

@Suite struct UsageOAuthAuthorizeURLTests {
    private func items(_ url: URL) -> [String: String] {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return Dictionary(uniqueKeysWithValues: (comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    @Test func carriesThePKCEAndClientParams() {
        let url = UsageOAuth.authorizeURL(challenge: "CHAL", state: "VERIFIER")
        #expect(url.absoluteString.hasPrefix("https://claude.ai/oauth/authorize"))
        let q = items(url)
        #expect(q["code"] == "true")
        #expect(q["client_id"] == UsageAPI.oauthClientID)
        #expect(q["response_type"] == "code")
        #expect(q["redirect_uri"] == UsageAPI.oauthRedirectURI)
        #expect(q["scope"] == UsageAPI.oauthScope)
        #expect(q["code_challenge"] == "CHAL")
        #expect(q["code_challenge_method"] == "S256")
        #expect(q["state"] == "VERIFIER")   // state is the verifier
    }
}

// MARK: - splitCode

@Suite struct UsageOAuthSplitCodeTests {
    @Test func splitsCodeAndStateOnHash() {
        let r = UsageOAuth.splitCode("the-code#the-state")
        #expect(r.code == "the-code")
        #expect(r.state == "the-state")
    }

    @Test func trimsWhitespaceAndToleratesAMissingState() {
        let r = UsageOAuth.splitCode("  bare-code\n")
        #expect(r.code == "bare-code")
        #expect(r.state == "")
    }
}

// MARK: - decodeToken

@Suite struct UsageOAuthTokenDecodeTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func decodesAccessRefreshAndExpiry() {
        let json = #"{"access_token":"at","refresh_token":"rt","expires_in":3600}"#
        let t = UsageOAuth.decodeToken(Data(json.utf8), now: now)
        #expect(t?.access == "at")
        #expect(t?.refresh == "rt")
        #expect(t?.expiresAt == now.addingTimeInterval(3600))
    }

    @Test func defaultsExpiryAndKeepsPreviousRefreshWhenAbsent() {
        // A refresh response may omit refresh_token and expires_in.
        let json = #"{"access_token":"newAT"}"#
        let t = UsageOAuth.decodeToken(Data(json.utf8), now: now, previousRefresh: "oldRT")
        #expect(t?.access == "newAT")
        #expect(t?.refresh == "oldRT")
        #expect(t?.expiresAt == now.addingTimeInterval(3600))
    }

    @Test func requiresANonEmptyAccessToken() {
        #expect(UsageOAuth.decodeToken(Data(#"{"refresh_token":"rt"}"#.utf8), now: now) == nil)
        #expect(UsageOAuth.decodeToken(Data(#"{"access_token":""}"#.utf8), now: now) == nil)
        #expect(UsageOAuth.decodeToken(Data("not json".utf8), now: now) == nil)
    }

    @Test func expiresSoonHonoursTheBuffer() {
        let t = UsageOAuth.Token(access: "a", refresh: "r", expiresAt: now.addingTimeInterval(120))
        #expect(t.expiresSoon(now: now))                       // within the 300s default
        #expect(!t.expiresSoon(now: now, buffer: 60))          // outside a 60s buffer
    }
}

// MARK: - decodeUsage

@Suite struct UsageOAuthUsageDecodeTests {
    @Test func mapsAllFourBucketsWithIntUtilisationAndISOReset() {
        let json = #"""
        {"five_hour":{"utilization":25,"resets_at":"2026-06-18T15:00:00Z"},
         "seven_day":{"utilization":40,"resets_at":"2026-06-22T00:00:00Z"},
         "seven_day_opus":{"utilization":3,"resets_at":"2026-06-21T03:00:00Z"},
         "seven_day_sonnet":{"utilization":1,"resets_at":"2026-06-20T03:00:00Z"},
         "extra_usage":{"is_enabled":false}}
        """#
        let u = UsageOAuth.decodeUsage(Data(json.utf8))
        #expect(u.fiveHour?.utilization == 25)
        #expect(u.fiveHour?.resetsAt == PlanLimits.parseDate("2026-06-18T15:00:00Z"))
        #expect(u.sevenDay?.utilization == 40)
        #expect(u.sevenDayOpus?.utilization == 3)
        #expect(u.sevenDaySonnet?.utilization == 1)
    }

    @Test func absentOrNullBucketsStayNil() {
        let json = #"{"five_hour":{"utilization":10,"resets_at":"2026-06-18T15:00:00Z"},"seven_day":null}"#
        let u = UsageOAuth.decodeUsage(Data(json.utf8))
        #expect(u.fiveHour != nil)
        #expect(u.sevenDay == nil)
        #expect(u.sevenDayOpus == nil)
        #expect(u.sevenDaySonnet == nil)
    }

    @Test func clampsUtilisationAndAcceptsFractionalAndMissingReset() {
        // A microsecond+offset reset (the endpoint's real format) parses; an
        // over-100 utilisation clamps; a window without a reset still decodes.
        let json = #"""
        {"five_hour":{"utilization":140.0,"resets_at":"2026-06-18T15:00:00.528743+00:00"},
         "seven_day":{"utilization":12}}
        """#
        let u = UsageOAuth.decodeUsage(Data(json.utf8))
        #expect(u.fiveHour?.utilization == 100)
        #expect(u.fiveHour?.resetsAt != nil)
        #expect(u.sevenDay?.utilization == 12)
        #expect(u.sevenDay?.resetsAt == nil)
    }

    @Test func emptyOnGarbage() {
        #expect(UsageOAuth.decodeUsage(Data("not json".utf8)).isEmpty)
    }
}
