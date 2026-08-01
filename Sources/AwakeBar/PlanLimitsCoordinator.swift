import Foundation

// MARK: - Plan limits coordinator
//
// Owns the plan-usage panel: the persisted opt-in, the poll throttle, and the
// last-known usage the menu renders. AppDelegate owns one of these (mirroring
// NotificationCoordinator) and drives it from the same refresh cadence.
//
// One source: the exact `/usage` numbers from `/api/oauth/usage`, reached with a
// token AwakeBar mints via its own OAuth login (UsageOAuth + TokenStore). Until
// you connect, the panel says so and shows nothing — see DESIGN.md for why the
// local estimate that used to fill that gap was removed.
//
// The network runs off the main actor, at most once per `minInterval`; a 429
// extends a cooldown but never surfaces as an error (we keep showing the
// last-good numbers).
@MainActor
final class PlanLimitsCoordinator {
    // Persisted opt-in. Off by default; the key name is unchanged so anyone who
    // already enabled the panel keeps it enabled.
    private static let enabledKey = "planUsageEnabled"

    enum Status: Equatable {
        case off        // feature disabled
        case connect    // enabled, but no account connected yet
        case loading    // connected, no result yet
        case ready      // have usage to show
        case noData     // connected, but the account reports nothing
    }

    private(set) var usage: PlanLimits.Usage?
    private(set) var status: Status
    // A live grant went dead (refresh rejected); the menu offers "Reconnect".
    private(set) var needsReauth = false

    // Re-render hook, set by AppDelegate, so an async result repaints the menu the
    // same way a snapshot refresh does.
    var onUpdate: (@MainActor () -> Void)?

    // Poll at most this often no matter how often refreshIfDue() fires — the bars
    // move slowly and this is also ≥ the usage endpoint's safe poll floor.
    private let minInterval: TimeInterval = 5 * 60

    private var inFlight = false
    private var lastFetch: Date?

    // The OAuth token (loaded from our own Keychain item at launch), a 429 back-off
    // window, and the PKCE verifier in flight during a connect.
    private var token: UsageOAuth.Token?
    private var cooldownUntil: Date?
    private var pendingVerifier: String?

    init() {
        token = TokenStore.load()
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else { status = .off; return }
        status = token != nil ? .loading : .connect
    }

    var enabled: Bool { status != .off }
    var connected: Bool { token != nil }

    // Flip the feature. On → kick an immediate fetch; off → forget the cached usage
    // so nothing lingers (the token stays in the Keychain for re-enable).
    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on {
            if status == .off { status = connected ? .loading : .connect }
            refresh(force: true)
        } else {
            status = .off
            usage = nil
            lastFetch = nil
        }
    }

    func refreshIfDue() { refresh(force: false) }

    // MARK: Connect / disconnect

    // Start a login: generate PKCE, stash the verifier, return the authorize URL
    // for AppDelegate to open in the browser.
    func beginConnect() -> URL {
        let p = UsageOAuth.pkce()
        pendingVerifier = p.verifier
        return UsageOAuth.authorizeURL(challenge: p.challenge, state: p.verifier)
    }

    // Finish a login with the pasted "code#state". Exchanges off-actor, stores the
    // token, enables the panel if needed, and kicks a fetch. `completion` runs on
    // the main actor.
    func completeConnect(pastedCode: String,
                         completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        guard let verifier = pendingVerifier else {
            completion(.failure(UsageOAuth.TokenError.invalidCode)); return
        }
        let (code, state) = UsageOAuth.splitCode(pastedCode)
        guard !code.isEmpty else {
            completion(.failure(UsageOAuth.TokenError.invalidCode)); return
        }
        Task {
            do {
                // state should equal the verifier; fall back to it if the paste
                // omitted the "#state" half.
                let token = try await UsageOAuth.exchange(
                    code: code, state: state.isEmpty ? verifier : state, verifier: verifier)
                self.token = token
                TokenStore.save(token)
                self.pendingVerifier = nil
                self.needsReauth = false
                self.usage = nil
                if self.status == .off {
                    UserDefaults.standard.set(true, forKey: Self.enabledKey)
                }
                self.status = .loading
                self.refresh(force: true)
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    // Forget the token. Keeps the panel enabled, back on its "connect" prompt.
    func disconnect() {
        TokenStore.clear()
        token = nil
        usage = nil
        cooldownUntil = nil
        needsReauth = false
        pendingVerifier = nil
        lastFetch = nil
        if enabled { status = .connect }
        onUpdate?()
    }

    // MARK: Refresh

    private func refresh(force: Bool) {
        guard enabled, !inFlight else { return }
        // Nothing to fetch without a token; the menu already says to connect.
        guard let tok = token else { status = .connect; return }
        let now = Date()
        if !force, let last = lastFetch, now.timeIntervalSince(last) < minInterval { return }
        // A 429 back-off suppresses the request but not the throttle above, so a
        // cooled-down cycle costs nothing.
        if let until = cooldownUntil, now < until { return }

        inFlight = true
        lastFetch = now
        Task.detached(priority: .utility) {
            let outcome = await UsageOAuth.runLive(token: tok)
            await MainActor.run { self.apply(outcome) }
        }
    }

    private func apply(_ outcome: UsageOAuth.LiveOutcome) {
        inFlight = false
        switch outcome {
        case .usage(let u, let refreshed):
            persistIfPresent(refreshed)
            usage = u.isEmpty ? nil : u
            cooldownUntil = nil
            needsReauth = false
            status = usage != nil ? .ready : .noData
        case .rateLimited(let retryAfter, let refreshed):
            persistIfPresent(refreshed)
            cooldownUntil = Date().addingTimeInterval(retryAfter ?? 300)
            // keep the last-good usage on screen
        case .failed(let refreshed):
            persistIfPresent(refreshed)
            // keep the last-good usage on screen
        case .authRevoked:
            TokenStore.clear()
            token = nil
            usage = nil
            needsReauth = true
            status = .connect
        }

        // Logs status + utilisations/reset epochs only — no token content. Lets a
        // fetch be verified from the unified log.
        NSLog("AwakeBar: plan usage = %@", menuSignature)
        onUpdate?()
    }

    private func persistIfPresent(_ token: UsageOAuth.Token?) {
        guard let token else { return }
        self.token = token
        TokenStore.save(token)
    }

    // A stable fingerprint of what the plan rows render, so the menu only rebuilds
    // when a value actually changes. Carries the auth state too, so a connect or
    // disconnect repaints.
    var menuSignature: String {
        func f(_ w: PlanLimits.Window?) -> String {
            w.map { "\(Int($0.utilization.rounded()))@\(Int($0.resetsAt?.timeIntervalSince1970 ?? 0))" }
                ?? "-"
        }
        return [String(describing: status),
                connected ? "c" : "-",
                needsReauth ? "r" : "-",
                f(usage?.fiveHour), f(usage?.sevenDay),
                f(usage?.sevenDayOpus), f(usage?.sevenDaySonnet)]
            .joined(separator: ",")
    }
}
