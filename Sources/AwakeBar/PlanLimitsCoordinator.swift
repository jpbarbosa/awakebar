import Foundation

// MARK: - Plan limits coordinator
//
// Owns the plan-usage panel: the persisted opt-in, the throttle, and the
// last-known usage the menu renders. AppDelegate owns one of these (mirroring
// NotificationCoordinator) and drives it from the same refresh cadence.
//
// Two data sources, with the live one preferred when present:
//   • Estimate — UsageLedger over the JSONL transcripts. No auth, always works,
//     approximate. The fallback (and the only source until you connect).
//   • Live — the exact `/usage` numbers from `/api/oauth/usage`, reached with a
//     token AwakeBar mints via its own OAuth login (UsageOAuth + TokenStore).
//     Connected → the menu shows real numbers and the per-model weekly rows.
//
// The file walk and the network both run off the main actor, at most once per
// `minInterval`; a 429 extends a live-only cooldown but never surfaces as an
// error (we keep showing the last-good numbers).
@MainActor
final class PlanLimitsCoordinator {
    // Persisted opt-in. Off by default; the key name is unchanged so anyone who
    // already enabled the panel keeps it enabled.
    private static let enabledKey = "planUsageEnabled"

    enum Status: Equatable {
        case off        // feature disabled
        case loading    // enabled, no result yet
        case ready      // have usage to show
        case noData     // nothing in the windows / no transcripts
    }

    // Which source the rendered `usage` came from — drives the "(est.)" label.
    enum Source { case estimate, live }

    private(set) var usage: PlanLimits.Usage?
    private(set) var status: Status
    private(set) var source: Source = .estimate
    // A live grant went dead (refresh rejected); the menu offers "Reconnect".
    private(set) var needsReauth = false

    // Re-render hook, set by AppDelegate, so an async result repaints the menu the
    // same way a snapshot refresh does.
    var onUpdate: (@MainActor () -> Void)?

    // Recompute at most this often no matter how often refreshIfDue() fires — the
    // bars move slowly and this is also ≥ the usage endpoint's safe poll floor.
    private let minInterval: TimeInterval = 5 * 60

    private var inFlight = false
    private var lastScan: Date?

    // The two source snapshots kept separately so we can prefer live and fall back
    // to the estimate. `liveUsage` is non-nil once a live fetch has *succeeded*
    // (even if empty), so an empty live result reads as "no usage" rather than
    // silently reverting to the estimate.
    private var estimateUsage: PlanLimits.Usage?
    private var liveUsage: PlanLimits.Usage?

    // The live OAuth token (loaded from our own Keychain item at launch), a 429
    // back-off window, and the PKCE verifier in flight during a connect.
    private var token: UsageOAuth.Token?
    private var liveCooldownUntil: Date?
    private var pendingVerifier: String?

    // ~/.claude/projects — one JSONL file per session.
    private let projectsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects", isDirectory: true)

    init() {
        status = UserDefaults.standard.bool(forKey: Self.enabledKey) ? .loading : .off
        token = TokenStore.load()
    }

    var enabled: Bool { status != .off }
    var connected: Bool { token != nil }
    var showingEstimate: Bool { source == .estimate }

    // Flip the feature. On → kick an immediate refresh; off → forget the cached
    // usage so nothing lingers (the token stays in the Keychain for re-enable).
    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on {
            if status == .off { status = .loading }
            refresh(force: true)
        } else {
            status = .off
            usage = nil
            lastScan = nil
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
    // token, enables the panel if needed, and kicks a live fetch. `completion` runs
    // on the main actor.
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
                self.liveUsage = nil
                if self.status == .off {
                    UserDefaults.standard.set(true, forKey: Self.enabledKey)
                    self.status = .loading
                }
                self.refresh(force: true)
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    // Forget the token and revert to the estimate. Keeps the panel enabled.
    func disconnect() {
        TokenStore.clear()
        token = nil
        liveUsage = nil
        liveCooldownUntil = nil
        needsReauth = false
        pendingVerifier = nil
        refresh(force: true)
    }

    // MARK: Refresh

    private func refresh(force: Bool) {
        guard enabled, !inFlight else { return }
        let now = Date()
        if !force, let last = lastScan, now.timeIntervalSince(last) < minInterval { return }

        inFlight = true
        lastScan = now
        let dir = projectsDir
        let tok = token
        // Skip the (expensive) transcript scan when a healthy live snapshot already
        // covers us; we only need the estimate as a fallback.
        let needEstimate = tok == nil || liveUsage == nil
        let tryLive = tok != nil && (liveCooldownUntil.map { now >= $0 } ?? true)

        Task.detached(priority: .utility) {
            var estimate: PlanLimits.Usage? = nil
            var estimateCount = -1   // -1 = didn't scan this cycle
            if needEstimate {
                let entries = UsageLedger.scan(projectsDir: dir)
                estimate = UsageLedger.estimate(from: entries, now: Date())
                estimateCount = entries.count
            }
            var live: UsageOAuth.LiveOutcome? = nil
            if tryLive, let tok { live = await UsageOAuth.runLive(token: tok) }
            await MainActor.run {
                self.apply(estimate: estimate, estimateCount: estimateCount, live: live)
            }
        }
    }

    private func apply(estimate: PlanLimits.Usage?, estimateCount: Int,
                       live: UsageOAuth.LiveOutcome?) {
        inFlight = false
        if estimateCount > 0 { estimateUsage = estimate }
        else if estimateCount == 0 { estimateUsage = nil }
        // estimateCount < 0: we didn't scan; leave estimateUsage as-is.

        if let live { applyLiveOutcome(live) }
        recomputeRendered()

        // Logs status + source + utilisations/reset epochs only — no transcript or
        // token content. Lets a live run be verified from the unified log.
        NSLog("AwakeBar: plan usage (%@) = %@", source == .live ? "live" : "est", menuSignature)
        onUpdate?()
    }

    private func applyLiveOutcome(_ outcome: UsageOAuth.LiveOutcome) {
        switch outcome {
        case .usage(let u, let refreshed):
            persistIfPresent(refreshed)
            liveUsage = u
            liveCooldownUntil = nil
            needsReauth = false
        case .rateLimited(let retryAfter, let refreshed):
            persistIfPresent(refreshed)
            liveCooldownUntil = Date().addingTimeInterval(retryAfter ?? 300)
            // keep the last-good liveUsage
        case .failed(let refreshed):
            persistIfPresent(refreshed)
            // keep the last-good liveUsage
        case .authRevoked:
            TokenStore.clear()
            token = nil
            liveUsage = nil
            needsReauth = true
        }
    }

    private func persistIfPresent(_ token: UsageOAuth.Token?) {
        guard let token else { return }
        self.token = token
        TokenStore.save(token)
    }

    // Pick what the menu shows: a successful live snapshot wins; otherwise the
    // estimate; otherwise nothing. `source` flags which, for the header label.
    private func recomputeRendered() {
        if connected, let live = liveUsage {
            usage = live.isEmpty ? nil : live
            source = .live
        } else if let est = estimateUsage, !est.isEmpty {
            usage = est
            source = .estimate
        } else {
            usage = nil
            source = connected ? .live : .estimate
        }
        status = usage != nil ? .ready : .noData
    }

    // A stable fingerprint of what the plan rows render, so the menu only rebuilds
    // when a value actually changes. Carries the source/auth state too, so a
    // connect/disconnect (or a real↔estimate switch) repaints.
    var menuSignature: String {
        func f(_ w: PlanLimits.Window?) -> String {
            w.map { "\(Int($0.utilization.rounded()))@\(Int($0.resetsAt?.timeIntervalSince1970 ?? 0))" }
                ?? "-"
        }
        return [String(describing: status),
                source == .live ? "live" : "est",
                connected ? "c" : "-",
                needsReauth ? "r" : "-",
                f(usage?.fiveHour), f(usage?.sevenDay),
                f(usage?.sevenDayOpus), f(usage?.sevenDaySonnet)]
            .joined(separator: ",")
    }
}
