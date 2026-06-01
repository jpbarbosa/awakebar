import Foundation

// MARK: - Plan limits coordinator
//
// Owns the lifecycle around PlanLimits: the persisted opt-in, the throttle that
// keeps the API call rare, the 429 cooldown, and the last-known usage the menu
// renders. AppDelegate owns one of these (mirroring NotificationCoordinator) and
// drives it from the same refresh cadence.
//
// Safety lives here, not in the menu: while disabled we touch neither the
// Keychain nor the network; while enabled we fetch at most once per `minInterval`
// no matter how often refreshIfDue() is called, and a 429 parks us for a long
// `cooldown` (the endpoint sends no Retry-After and stays stuck if hammered).
@MainActor
final class PlanLimitsCoordinator {
    // Persisted opt-in. Off by default — enabling it is the user's explicit
    // consent and the moment the one-time Keychain access prompt appears.
    private static let enabledKey = "planUsageEnabled"

    enum Status: Equatable {
        case off            // feature disabled
        case loading        // enabled, no result yet
        case ready          // have usage to show
        case noToken        // couldn't find the OAuth token (signed out?)
        case unauthorized   // token rejected (rotated) — transient
        case rateLimited    // backing off after a 429
        case error          // last fetch failed
    }

    private(set) var usage: PlanLimits.Usage?
    private(set) var planLabel: String?   // e.g. "Max (5x)", from the credential
    private(set) var status: Status

    // Re-render hook, set by AppDelegate, so an async fetch result repaints the
    // menu the same way a snapshot refresh does.
    var onUpdate: (@MainActor () -> Void)?

    // The data only moves every few hours, so call the API at most this often
    // even though refreshIfDue() runs on the app's 10s cadence.
    private let minInterval: TimeInterval = 10 * 60
    // A 429 has no Retry-After and persists; back off hard rather than retry.
    private let cooldown: TimeInterval = 45 * 60

    private var inFlight = false
    private var lastAttempt: Date?
    private var cooldownUntil: Date?

    init() {
        status = UserDefaults.standard.bool(forKey: Self.enabledKey) ? .loading : .off
    }

    var enabled: Bool { status != .off }

    // Flip the feature. On → kick an immediate fetch (and the Keychain prompt);
    // off → forget the cached usage so nothing lingers in the menu.
    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on {
            if status == .off { status = .loading }
            refresh(force: true)
        } else {
            status = .off
            usage = nil
            planLabel = nil
            cooldownUntil = nil
            lastAttempt = nil
        }
    }

    // Called on the app's refresh cadence and on menu-open; a no-op unless a
    // fetch is genuinely due, so the network call stays rare regardless of how
    // often this fires.
    func refreshIfDue() { refresh(force: false) }

    private func refresh(force: Bool) {
        guard enabled, !inFlight else { return }
        let now = Date()
        if let until = cooldownUntil, now < until { return }
        if !force, let last = lastAttempt, now.timeIntervalSince(last) < minInterval { return }

        inFlight = true
        lastAttempt = now
        let userAgent = UsageAPI.userAgent
        // Detached so the Keychain read + request run off the main actor; the
        // result is applied back on it.
        Task.detached(priority: .utility) {
            let result = await PlanLimits.fetch(userAgent: userAgent)
            await MainActor.run { self.apply(result) }
        }
    }

    private func apply(_ result: PlanLimits.FetchResult) {
        inFlight = false
        switch result {
        case .ok(let u, let plan):
            usage = u
            if let plan { planLabel = plan }   // keep last known across transient errors
            status = .ready
            cooldownUntil = nil
        case .noToken:      status = .noToken
        case .unauthorized: status = .unauthorized
        case .rateLimited:
            status = .rateLimited
            cooldownUntil = Date().addingTimeInterval(cooldown)
        case .failed(let why): status = .error
            NSLog("AwakeBar: plan usage fetch failed — %@", why)
        }
        // Logs status + utilisations/reset epochs only (see menuSignature) — never
        // the token. Lets a live run be verified from the unified log.
        NSLog("AwakeBar: plan usage = %@", menuSignature)
        onUpdate?()
    }

    // A stable fingerprint of what the plan rows render, so the menu only rebuilds
    // when a value actually changes (reset times are absolute, so they don't churn
    // the way a live countdown would).
    var menuSignature: String {
        func f(_ w: PlanLimits.Window?) -> String {
            w.map { "\(Int($0.utilization.rounded()))@\(Int($0.resetsAt?.timeIntervalSince1970 ?? 0))" }
                ?? "-"
        }
        let u = usage
        return [String(describing: status), planLabel ?? "",
                f(u?.fiveHour), f(u?.sevenDay), f(u?.sevenDayOpus), f(u?.sevenDaySonnet)]
            .joined(separator: ",")
    }
}
