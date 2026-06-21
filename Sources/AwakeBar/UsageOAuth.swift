import Foundation
import CryptoKit

// MARK: - Live /usage via AwakeBar's own OAuth login
//
// The exact `/usage` numbers come from `GET /api/oauth/usage`, which needs an
// OAuth bearer token. Rather than read Claude Code's Keychain item (which
// re-prompts on every token rotation), AwakeBar runs its OWN OAuth PKCE login —
// reusing Claude Code's public client id — and stores its own token (TokenStore).
// That's how the shipping CodeQuota app coexists with Claude Code without ever
// touching `Claude Code-credentials`.
//
// Flow (manual copy/paste, the version-stable one every reference uses):
//   1. pkce() → (verifier, challenge);  authorizeURL(challenge:state:) opens the
//      browser. The consent page shows a "code#state" string.
//   2. splitCode() + exchange() trade that code for a Token.
//   3. fetchUsage() reads the bars; runLive() wraps refresh-on-401 + proactive
//      refresh; refresh tokens rotate, so we always persist the newest.
//
// The pure pieces (base64URL, challenge, authorizeURL, splitCode, decodeToken,
// decodeUsage) are unit-tested; the URLSession calls are IO and aren't.
enum UsageOAuth {
    // MARK: Token

    // What we persist (in our own Keychain item). Sendable so it crosses into the
    // detached fetch task; Codable so TokenStore can blob it.
    struct Token: Sendable, Equatable, Codable {
        var access: String
        var refresh: String
        var expiresAt: Date
        // Refresh a touch early so a fetch never races the expiry.
        func expiresSoon(now: Date, buffer: TimeInterval = 300) -> Bool {
            now.addingTimeInterval(buffer) >= expiresAt
        }
    }

    enum TokenError: LocalizedError {
        case invalidCode            // empty/garbled paste
        case rateLimited            // 429 on every host
        case unreachable(Int?)      // transport failure (nil) or unexpected HTTP status
        case decode                 // 200 but unparseable body
        case authRevoked            // 400/401 — bad code or a dead grant

        var errorDescription: String? {
            switch self {
            case .invalidCode: return "That doesn't look like a valid authorization code."
            case .rateLimited: return "Claude's sign-in service is rate-limited right now. Wait a minute and try again."
            case .unreachable(let status):
                return status.map { "Couldn't reach the Claude sign-in service (HTTP \($0))." }
                    ?? "Couldn't reach the Claude sign-in service."
            case .decode:      return "The sign-in response couldn't be read."
            case .authRevoked: return "Claude rejected the code. Try connecting again."
            }
        }
    }

    // MARK: PKCE (pure)

    // RFC 7636 base64url: standard base64, +/→-_ , padding stripped.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func challenge(forVerifier verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    // Pure so tests can pin a known verifier/challenge; the wrapper supplies CSPRNG
    // bytes (UInt8.random uses SystemRandomNumberGenerator, secure on Apple OSes).
    static func pkce(randomBytes: Data) -> (verifier: String, challenge: String) {
        let verifier = base64URL(randomBytes)
        return (verifier, challenge(forVerifier: verifier))
    }

    static func pkce() -> (verifier: String, challenge: String) {
        pkce(randomBytes: Data((0..<32).map { _ in UInt8.random(in: UInt8.min...UInt8.max) }))
    }

    // MARK: Authorize URL + paste parsing (pure)

    // `state` is set to the verifier itself — unusual, but exactly what Claude's
    // flow expects (every reference does this).
    static func authorizeURL(challenge: String, state: String) -> URL {
        var c = URLComponents(url: UsageAPI.oauthAuthorizeURL, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            .init(name: "code", value: "true"),
            .init(name: "client_id", value: UsageAPI.oauthClientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: UsageAPI.oauthRedirectURI),
            .init(name: "scope", value: UsageAPI.oauthScope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        return c.url!
    }

    // The consent page hands back "<code>#<state>"; split it. A paste without the
    // "#state" half still yields the code (the caller falls back to the verifier).
    static func splitCode(_ pasted: String) -> (code: String, state: String) {
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        return (String(parts.first ?? ""), parts.count > 1 ? String(parts[1]) : "")
    }

    // MARK: Decoders (pure)

    // A token response → Token. `expires_in` may be Int or Double (default 3600);
    // a refresh response may omit `refresh_token` (reuse the previous one).
    static func decodeToken(_ data: Data, now: Date, previousRefresh: String? = nil) -> Token? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String, !access.isEmpty else { return nil }
        let expiresIn = (obj["expires_in"] as? Double)
            ?? (obj["expires_in"] as? Int).map(Double.init) ?? 3600
        let fresh = (obj["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Token(access: access,
                     refresh: fresh ?? previousRefresh ?? "",
                     expiresAt: now.addingTimeInterval(expiresIn))
    }

    // The usage payload → PlanLimits.Usage. Each window is `{utilization, resets_at}`
    // with utilization an integer 0–100; a null/absent bucket stays nil (so its
    // menu row hides). `extra_usage` and anything else is ignored.
    static func decodeUsage(_ data: Data) -> PlanLimits.Usage {
        var usage = PlanLimits.Usage()
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return usage }
        func window(_ key: String) -> PlanLimits.Window? {
            guard let w = obj[key] as? [String: Any] else { return nil }
            let util: Double
            if let d = w["utilization"] as? Double { util = d }
            else if let i = w["utilization"] as? Int { util = Double(i) }
            else { return nil }
            let reset = (w["resets_at"] as? String).flatMap(PlanLimits.parseDate)
            return PlanLimits.Window(utilization: min(100, max(0, util)), resetsAt: reset)
        }
        usage.fiveHour = window("five_hour")
        usage.sevenDay = window("seven_day")
        usage.sevenDayOpus = window("seven_day_opus")
        usage.sevenDaySonnet = window("seven_day_sonnet")
        return usage
    }

    // MARK: Network (IO — not unit-tested)

    // The outcome of one usage GET. 401 → caller refreshes; 429 → caller backs off
    // and keeps last-good; anything else → transient failure.
    enum UsageResult: Sendable {
        case success(PlanLimits.Usage)
        case unauthorized
        case rateLimited(retryAfter: TimeInterval?)
        case failed
    }

    static func fetchUsage(accessToken: String) async -> UsageResult {
        var req = URLRequest(url: UsageAPI.usageURL)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(UsageAPI.oauthBetaHeader, forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(UsageAPI.usageUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return .failed }
        switch http.statusCode {
        case 200: return .success(decodeUsage(data))
        case 401, 403: return .unauthorized
        case 429:
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            return .rateLimited(retryAfter: retry)
        default: return .failed
        }
    }

    static func exchange(code: String, state: String, verifier: String,
                         now: Date = Date()) async throws -> Token {
        try await postToken(body: [
            "code": code, "state": state, "grant_type": "authorization_code",
            "client_id": UsageAPI.oauthClientID, "redirect_uri": UsageAPI.oauthRedirectURI,
            "code_verifier": verifier,
        ], previousRefresh: nil, now: now)
    }

    static func refresh(_ token: Token, now: Date = Date()) async throws -> Token {
        try await postToken(body: [
            "grant_type": "refresh_token", "refresh_token": token.refresh,
            "client_id": UsageAPI.oauthClientID,
        ], previousRefresh: token.refresh, now: now)
    }

    // POST the token request, trying each host in turn. A 200 wins; a 400/401 is an
    // auth problem (bad code / dead grant) and stops — only transport errors and
    // other statuses fall through to the next host.
    private static func postToken(body: [String: String], previousRefresh: String?,
                                  now: Date) async throws -> Token {
        let payload = try JSONSerialization.data(withJSONObject: body)
        var lastError: TokenError = .unreachable(nil)
        var sawRateLimit = false
        for url in UsageAPI.oauthTokenURLs {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue(UsageAPI.usageUserAgent, forHTTPHeaderField: "User-Agent")
            req.httpBody = payload
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse else { lastError = .unreachable(nil); continue }
                switch http.statusCode {
                case 200:
                    guard let token = decodeToken(data, now: now, previousRefresh: previousRefresh)
                    else { throw TokenError.decode }
                    return token
                case 400, 401: throw TokenError.authRevoked   // bad code / dead grant
                case 429: sawRateLimit = true                 // try next host; it may be clear
                default: lastError = .unreachable(http.statusCode)
                }
            } catch let e as TokenError {
                throw e
            } catch {
                lastError = .unreachable(nil)   // transport (DNS/TLS) → try the next host
            }
        }
        throw sawRateLimit ? .rateLimited : lastError
    }

    // MARK: Orchestration (IO)

    // What one live cycle produced; Sendable so it crosses back to the main actor.
    enum LiveOutcome: Sendable {
        case usage(PlanLimits.Usage, refreshed: Token?)   // success (may be empty)
        case rateLimited(TimeInterval?, refreshed: Token?)
        case failed(refreshed: Token?)                    // transient
        case authRevoked                                  // grant dead → re-login
    }

    // Fetch usage with one proactive refresh (near expiry) and one reactive refresh
    // (on 401). `refreshed` carries a rotated token back so the caller can persist it.
    static func runLive(token: Token, now: Date = Date()) async -> LiveOutcome {
        var tok = token
        var refreshed: Token? = nil
        if tok.expiresSoon(now: now) {
            do { tok = try await refresh(tok); refreshed = tok }
            catch TokenError.authRevoked { return .authRevoked }
            catch { return .failed(refreshed: nil) }
        }
        switch await fetchUsage(accessToken: tok.access) {
        case .success(let u): return .usage(u, refreshed: refreshed)
        case .rateLimited(let ra): return .rateLimited(ra, refreshed: refreshed)
        case .failed: return .failed(refreshed: refreshed)
        case .unauthorized:
            do { tok = try await refresh(tok); refreshed = tok }
            catch TokenError.authRevoked { return .authRevoked }
            catch { return .failed(refreshed: refreshed) }
            switch await fetchUsage(accessToken: tok.access) {
            case .success(let u): return .usage(u, refreshed: refreshed)
            case .rateLimited(let ra): return .rateLimited(ra, refreshed: refreshed)
            default: return .failed(refreshed: refreshed)
            }
        }
    }
}
