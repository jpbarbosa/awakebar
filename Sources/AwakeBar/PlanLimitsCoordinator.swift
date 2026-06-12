import Foundation

// MARK: - Plan limits coordinator
//
// Owns the lifecycle around the local plan-usage estimate: the persisted opt-in,
// a throttle that keeps the transcript scan rare, and the last-known usage the
// menu renders. AppDelegate owns one of these (mirroring NotificationCoordinator)
// and drives it from the same refresh cadence.
//
// This used to guard a Keychain read + `/api/oauth/usage` fetch with a 429
// cooldown; now there's no auth and no network, so all that's gone. The only cost
// is reading ~800 JSONL files, so we scan off the main actor and at most once per
// `minInterval` — the bars move on the scale of hours.
@MainActor
final class PlanLimitsCoordinator {
    // Persisted opt-in. Off by default; the key name is unchanged so anyone who
    // already enabled the old Keychain-backed panel keeps it enabled.
    private static let enabledKey = "planUsageEnabled"

    enum Status: Equatable {
        case off        // feature disabled
        case loading    // enabled, no scan result yet
        case ready      // have usage to show
        case noData     // no transcripts found / nothing in the windows
    }

    private(set) var usage: PlanLimits.Usage?
    private(set) var status: Status

    // Re-render hook, set by AppDelegate, so an async scan result repaints the
    // menu the same way a snapshot refresh does.
    var onUpdate: (@MainActor () -> Void)?

    // Scanning the transcripts is cheap but not free; the bars move slowly, so
    // recompute at most this often no matter how often refreshIfDue() is called.
    private let minInterval: TimeInterval = 5 * 60

    private var inFlight = false
    private var lastScan: Date?

    // ~/.claude/projects — one JSONL file per session.
    private let projectsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects", isDirectory: true)

    init() {
        status = UserDefaults.standard.bool(forKey: Self.enabledKey) ? .loading : .off
    }

    var enabled: Bool { status != .off }

    // Flip the feature. On → kick an immediate scan; off → forget the cached
    // usage so nothing lingers in the menu.
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

    // Called on the app's refresh cadence and on menu-open; a no-op unless a scan
    // is genuinely due, so the file walk stays rare regardless of how often this
    // fires.
    func refreshIfDue() { refresh(force: false) }

    private func refresh(force: Bool) {
        guard enabled, !inFlight else { return }
        let now = Date()
        if !force, let last = lastScan, now.timeIntervalSince(last) < minInterval { return }

        inFlight = true
        lastScan = now
        let dir = projectsDir
        // Detached so the file walk + parse run off the main actor; the result is
        // applied back on it.
        Task.detached(priority: .utility) {
            let entries = UsageLedger.scan(projectsDir: dir)
            let usage = UsageLedger.estimate(from: entries, now: Date())
            await MainActor.run { self.apply(usage, entryCount: entries.count) }
        }
    }

    private func apply(_ usage: PlanLimits.Usage, entryCount: Int) {
        inFlight = false
        if entryCount == 0 {
            status = .noData
            self.usage = nil
        } else {
            self.usage = usage
            status = usage.isEmpty ? .noData : .ready
        }
        // Logs status + utilisations/reset epochs only (see menuSignature) — no
        // transcript content. Lets a live run be verified from the unified log.
        NSLog("AwakeBar: plan usage (est) = %@", menuSignature)
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
        return [String(describing: status), f(usage?.fiveHour), f(usage?.sevenDay)]
            .joined(separator: ",")
    }
}
