import Foundation
import Security   // SecItemCopyMatching, to read Claude Code's OAuth token

// MARK: - Plan limits (the `/usage` screen)
//
// Reproduces Claude Code's plan-usage view — the 5-hour and weekly limit bars
// with their reset times — by reading the same read-only endpoint `/usage`
// itself uses (UsageAPI in Contract.swift). This is an *undocumented* surface
// reached with the user's own Claude Code OAuth token, so everything risky is
// quarantined here behind PlanLimitsCoordinator's flag + throttle:
//
//  * We never call `/v1/messages` — that would spend real generation quota and
//    look like activity; the usage endpoint is read-only and returns every bar.
//  * The `User-Agent: claude-code/<ver>` header is mandatory — without it the
//    endpoint 429s persistently. On a 429 the coordinator backs off for a long
//    cooldown rather than retry-storming (the endpoint sends no Retry-After).
//  * The token is read fresh per call and never logged; a 401 means it rotated,
//    and we just skip the cycle (Claude Code refreshes it on its next run).
//
// The pure pieces (`decode`, `accessToken(fromKeychainBlob:)`, `countdown`) are
// internal, not private, so AwakeBarTests can drive them without a live account.
enum PlanLimits {
    // One usage window: how much of the allowance is spent and when it resets.
    // `utilization` is a percentage (0–100); `resetsAt` is nil if the body
    // carried no/unparseable reset.
    struct Window: Sendable, Equatable {
        let utilization: Double
        let resetsAt: Date?
    }

    // The plan-usage snapshot. Each bucket is nil when the body omits it or sends
    // null (e.g. a per-model weekly limit you haven't touched — "haven't used
    // Sonnet yet" arrives as a null `seven_day_sonnet`).
    struct Usage: Sendable, Equatable {
        var fiveHour: Window?
        var sevenDay: Window?
        var sevenDayOpus: Window?
        var sevenDaySonnet: Window?

        var isEmpty: Bool {
            fiveHour == nil && sevenDay == nil && sevenDayOpus == nil && sevenDaySonnet == nil
        }
    }

    // Outcome of one fetch attempt — the coordinator maps these to menu states.
    enum FetchResult: Sendable {
        case ok(Usage, plan: String?)
        case noToken        // Keychain item/token unavailable (not signed in?)
        case unauthorized   // 401/403 — token rotated/expired; skip this cycle
        case rateLimited    // 429 — enter the long cooldown
        case failed(String) // network or parse error
    }

    // MARK: Fetch (network — not unit-tested)

    // Hit the usage endpoint with Claude Code's own headers. Runs entirely off
    // the main actor (the coordinator calls it from a detached Task), so the
    // Keychain read and the request never block the menu.
    static func fetch(userAgent: String) async -> FetchResult {
        guard let cred = readCredential() else { return .noToken }

        var req = URLRequest(url: UsageAPI.endpoint)
        req.httpMethod = "GET"
        req.setValue("Bearer \(cred.token)", forHTTPHeaderField: "Authorization")
        req.setValue(UsageAPI.betaHeader, forHTTPHeaderField: "anthropic-beta")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .failed("no HTTP response") }
            switch http.statusCode {
            case 200:
                guard let usage = decode(data) else { return .failed("unparseable usage body") }
                return .ok(usage, plan: cred.planLabel)
            case 401, 403: return .unauthorized
            case 429:      return .rateLimited
            default:       return .failed("HTTP \(http.statusCode)")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: Keychain

    // A credential read from the Keychain: the access token plus a display label
    // for the plan (derived from subscriptionType / rateLimitTier), when present.
    struct Credential: Sendable {
        let token: String
        let planLabel: String?
    }

    // The credential from the login Keychain, or nil if absent. Reading another
    // app's generic-password item triggers a one-time macOS access prompt the
    // first time; "Always Allow" persists it (so long as AwakeBar's signing
    // identity is stable — build.sh signs every build).
    static func readCredential() -> Credential? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: UsageAPI.keychainService,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return credential(fromKeychainBlob: data)
    }

    // Pull the access token and plan label out of the Keychain value. The blob is
    // JSON — `{ "claudeAiOauth": { "accessToken", "subscriptionType",
    // "rateLimitTier", … } }` — but stay lenient (nested, flat, or a bare token).
    static func credential(fromKeychainBlob data: Data) -> Credential? {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let oauth = obj["claudeAiOauth"] as? [String: Any]
            guard let token = (oauth?["accessToken"] ?? obj["accessToken"]) as? String,
                  !token.isEmpty else { return nil }
            return Credential(token: token,
                              planLabel: planLabel(subscriptionType: oauth?["subscriptionType"] as? String,
                                                   rateLimitTier: oauth?["rateLimitTier"] as? String))
        }
        // Not JSON — maybe the raw token itself. Accept only a single opaque word.
        let raw = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (raw.count >= 20 && !raw.contains(where: \.isWhitespace))
            ? Credential(token: raw, planLabel: nil) : nil
    }

    // "Max (5x)" from the credential's subscriptionType, with any "Nx" multiplier
    // found in rateLimitTier appended; nil when there's no subscription type.
    // (internal + pure, so tests can drive it.)
    static func planLabel(subscriptionType: String?, rateLimitTier: String?) -> String? {
        guard let type = subscriptionType?.trimmingCharacters(in: .whitespaces), !type.isEmpty
        else { return nil }
        let name = type.split { $0 == "_" || $0 == " " }
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
        if let tier = rateLimitTier, let mult = multiplier(in: tier) { return "\(name) (\(mult))" }
        return name
    }

    // The "5x"/"20x" token in a rate-limit-tier string like "default_max_5x".
    private static func multiplier(in tier: String) -> String? {
        tier.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .first { $0.count >= 2 && $0.hasSuffix("x") && $0.dropLast().allSatisfy(\.isNumber) }
    }

    // MARK: Decode (pure, testable)

    // Decode the usage body into `Usage`. Tolerant of unverified key spellings
    // (snake_case vs camelCase, `utilization` vs `used_percentage`) and of
    // null/absent buckets, so the first real response can't crash the parser.
    static func decode(_ data: Data) -> Usage? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        func window(_ keys: String...) -> Window? {
            guard let w = keys.lazy.compactMap({ obj[$0] as? [String: Any] }).first
            else { return nil }
            let util = (w["utilization"] ?? w["used_percentage"] ?? w["usedPercentage"]) as? Double
            guard let util else { return nil }
            return Window(utilization: util, resetsAt: reset(w["resets_at"] ?? w["resetsAt"]))
        }

        var usage = Usage()
        usage.fiveHour      = window("five_hour", "fiveHour")
        usage.sevenDay      = window("seven_day", "sevenDay")
        usage.sevenDayOpus  = window("seven_day_opus", "sevenDayOpus")
        usage.sevenDaySonnet = window("seven_day_sonnet", "sevenDaySonnet")
        return usage.isEmpty ? nil : usage
    }

    // A reset timestamp that may arrive as an ISO-8601 string or epoch seconds.
    private static func reset(_ value: Any?) -> Date? {
        if let s = value as? String { return parseDate(s) }
        if let n = value as? Double { return Date(timeIntervalSince1970: n) }
        return nil
    }

    // Built locally per call (ISO8601DateFormatter isn't Sendable, so it can't be
    // a shared static under strict concurrency) — decode runs rarely, so the cost
    // is irrelevant.
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
