import Cocoa
import UserNotifications    // UNUserNotificationCenter, for "Claude is waiting" alerts

// MARK: - Notification coordinator
//
// Owns every "Claude is waiting / task finished / VSCode permission prompt"
// notification: scheduling, the grace-period deferral, posting, and withdrawing
// a delivered banner once the session resumes. Lifted out of AppDelegate, which
// now just drives the menu bar and power assertions and hands each fresh
// snapshot here via processSnapshot.
//
// All state is touched only on the main actor. The kqueue watchers fire on
// their own queues and hop back here before touching anything.
@MainActor
final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    // MARK: Settings (persisted; read by AppDelegate's menu)

    // The "Clear alerts when resumed" menu toggle. On by default; when off we keep
    // tracking delivered alerts but never withdraw them, so flipping it back on
    // resumes clearing for the next session that resumes. Persisted across launches.
    private static let autoClearKey = "autoClearAlerts"
    private(set) var autoClearAlerts = true

    // The "Notify When Task Finishes" toggle. Persisted; default on.
    private static let notifyDoneKey = "notifyOnTaskDone"
    private(set) var notifyOnDone = true

    // How long a session must stay blocked before we alert — the "Notification
    // Delay" submenu lets the user pick from graceChoices. Persisted; default 10s.
    private static let graceKey = "attentionGraceSeconds"
    static let graceChoices: [TimeInterval] = [5, 10]
    private(set) var attentionGrace: TimeInterval = 10

    // MARK: Terminal marker paths
    //
    // Two notifications ride one pipeline: watch a marker notify-attention.sh
    // writes, defer the alert by attentionGrace, fire only if the session hasn't
    // shown activity meanwhile (a per-cwd activity marker the hook bumps on
    // prompt/tool/stop — so one busy session can't silence another's alert), and
    // track the delivered id so it can be withdrawn once the session resumes. They
    // differ only in the knobs MarkerPath carries plus a per-path gate and message
    // (see handle / handleAttention / handleDone). lastTs dedupes: only a strictly
    // newer ts fires, so a marker from before launch stays silent.
    //
    //   • attention — Claude is blocked on you. Fires on every fresh event.
    //   • done      — a turn ended. Gated on notifyOnDone + a real-task duration
    //                 (>= minTaskDuration), so a quick reply stays quiet.
    @MainActor
    private final class MarkerPath {
        let marker: String                 // the /tmp file to watch
        let idPrefix: String               // notification-id namespace
        var lastTs = 0                     // dedup cursor (primed at launch)
        var pending: DispatchWorkItem?     // the deferred-alert work item, if any
        // Delivered alerts by cwd, for later withdrawal. A LIST per cwd, not one
        // tuple: a session can deliver several banners before it resumes (two real
        // tasks finish back to back, two waits in a row), and overwriting would
        // orphan the earlier id so neither the resume nor the age sweep could ever
        // withdraw it — the same fix deliveredVSCode carries (see below).
        var delivered: [String: [(id: String, ts: Int)]] = [:]
        var watcher: AttentionWatcher?
        init(marker: String, idPrefix: String) {
            self.marker = marker
            self.idPrefix = idPrefix
        }
    }
    private let attention: MarkerPath
    private let done: MarkerPath
    private static let minTaskDuration: TimeInterval = 30
    // A delivered "Task finished" banner is pure FYI: unlike a waiting alert you may
    // never return to that session, so the resume signal that normally clears it
    // (clearResumedByCwd) may never come — and the banner piles up in Notification
    // Center. Withdraw one this old even if its session never resumed, mirroring the
    // age-sweep staleVSCodeAlertAge applies to prompts that never log a resolve.
    private static let staleDoneAlertAge: TimeInterval = 5 * 60

    // VSCode permission prompts surfaced via the extension log (see AwakeMonitor).
    // appLaunch floors out events logged before launch; lastVSNotify is the
    // per-project high-water of handled events so none is alerted twice.
    private let appLaunch = Date()
    private var lastVSNotify: [String: Date] = [:]

    // Delivered VSCode permission alerts we may withdraw once resolved, keyed by
    // project → a LIST of (id, event time): cleared per-entry when that event shows
    // resolved or ages out (see clearResumedAttentions). A list, not one tuple, so
    // two prompts in the same project don't orphan the earlier id — that orphaning
    // is what left duplicate banners stuck in Notification Center. (The terminal
    // paths apply the same list-per-key fix on MarkerPath.delivered, above.)
    private var deliveredVSCode: [String: [(id: String, time: Date)]] = [:]
    // A delivered VSCode alert whose event has aged past this without ever showing
    // resolved (e.g. a permission prompt you denied or ignored, which logs no
    // resolve marker) is withdrawn as stale — it matches the freshness window past
    // which collectVSCodeAttention stops emitting the event, so no later resolve
    // can arrive to clear it the normal way.
    private static let staleVSCodeAlertAge: TimeInterval = 5 * 60

    // MARK: Lifecycle

    // Side-effect seams, defaulted to the real system so AppDelegate constructs
    // with no arguments. Tests inject a recording sink, temp marker paths, and a
    // synchronous scheduler that hands back the deferred work item to fire by hand.
    private let sink: NotificationSink
    private let scheduleAfter: (TimeInterval, DispatchWorkItem) -> Void

    init(sink: NotificationSink = .system,
         scheduleAfter: @escaping (TimeInterval, DispatchWorkItem) -> Void = {
             DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1)
         },
         attentionMarker: String = Contract.attentionMarker,
         doneMarker: String = Contract.doneMarker) {
        self.sink = sink
        self.scheduleAfter = scheduleAfter
        self.attention = MarkerPath(marker: attentionMarker, idPrefix: "claude-attention")
        self.done = MarkerPath(marker: doneMarker, idPrefix: "claude-done")
        super.init()
        // register makes bool(forKey:) return the default when the user has never
        // set the key, so the defaults below hold until they toggle something.
        UserDefaults.standard.register(defaults: [Self.autoClearKey: true,
                                                  Self.notifyDoneKey: true,
                                                  Self.graceKey: 10.0])
        autoClearAlerts = UserDefaults.standard.bool(forKey: Self.autoClearKey)
        notifyOnDone = UserDefaults.standard.bool(forKey: Self.notifyDoneKey)
        let savedGrace = UserDefaults.standard.double(forKey: Self.graceKey)
        attentionGrace = Self.graceChoices.contains(savedGrace) ? savedGrace : 10
    }

    // Authorize, drop stale banners, prime the dedup cursors from any markers left
    // by a previous run BEFORE arming the watches (so launch never replays a stale
    // alert), then arm both kqueue watchers.
    func start() {
        setUpNotifications()
        prime(attention)
        attention.watcher = AttentionWatcher(path: attention.marker) { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handleAttention() } }
        }
        attention.watcher?.start()
        prime(done)
        done.watcher = AttentionWatcher(path: done.marker) { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handleDone() } }
        }
        done.watcher?.start()
    }

    // Fed every refresh by AppDelegate: surface any VSCode permission prompts and
    // withdraw delivered alerts whose sessions have since resumed.
    func processSnapshot(_ snapshot: AwakeMonitor.Snapshot) {
        processVSCodeAttention(snapshot.vscodeAttention)
        clearResumedAttentions()
    }

    // MARK: Menu actions (AppDelegate re-renders after each)

    // Toggle whether resumed sessions auto-clear their delivered alerts. Turning
    // it back on lets us withdraw anything that has since resumed right away.
    func toggleAutoClear() {
        autoClearAlerts.toggle()
        UserDefaults.standard.set(autoClearAlerts, forKey: Self.autoClearKey)
        if autoClearAlerts { clearResumedAttentions() }
    }

    func toggleNotifyOnDone() {
        notifyOnDone.toggle()
        UserDefaults.standard.set(notifyOnDone, forKey: Self.notifyDoneKey)
    }

    // Pick the alert delay. Takes effect on the next event (an already-scheduled
    // alert keeps its old timing). Returns whether it actually changed, so the
    // caller can skip a redundant re-render on a no-op tap.
    @discardableResult
    func setGrace(_ seconds: TimeInterval) -> Bool {
        guard seconds != attentionGrace else { return false }
        attentionGrace = seconds
        UserDefaults.standard.set(seconds, forKey: Self.graceKey)
        return true
    }

    // MARK: Setup

    private func setUpNotifications() {
        let real = UNUserNotificationCenter.current()
        real.delegate = self
        // Drop any banners left over from a previous run. The delivered-alert maps
        // (MarkerPath.delivered and deliveredVSCode) are in-memory, so anything
        // delivered before this launch is untrackable and could never be withdrawn —
        // a guaranteed zombie. Honor the toggle: auto-clear off = never withdraw.
        if autoClearAlerts { sink.withdrawAll() }
        real.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                NSLog("AwakeBar: notification auth error: %@", error.localizedDescription)
            } else {
                NSLog("AwakeBar: notification auth granted = %@", granted ? "yes" : "no")
            }
        }
    }

    // MARK: Marker-driven notifications

    // The marker notify-attention.sh writes; `ts` is the dedup key (unix sec).
    // All fields but ts are optional so a partial read (a write caught mid-flight)
    // simply fails to decode and is retried on the next event, never crashes.
    private struct AttentionEvent: Decodable {
        var project: String?
        var message: String?
        var cwd: String?
        var ts: Int
        var dur: Int?      // turn length in seconds (done marker only); nil/-1 = unknown
    }

    // Decode a marker file, or nil if it's absent or a partial write that doesn't
    // parse (retried on the next event, never a crash). Shared by the attention
    // and done markers, which carry the same shape.
    private func readMarker(at path: String) -> AttentionEvent? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(AttentionEvent.self, from: data)
    }

    // Record a marker's current ts without alerting, so one written before this
    // launch can't fire at startup.
    private func prime(_ p: MarkerPath) {
        if let event = readMarker(at: p.marker) { p.lastTs = event.ts }
    }

    // Called on the main actor whenever a marker changes. Dedupe on ts, run the
    // path's `accept` gate, then defer the alert by attentionGrace; deliver() drops
    // it if the session engaged meanwhile. A newer event cancels and reschedules.
    // `message` is resolved now — it can't change before the alert fires.
    private func handle(_ p: MarkerPath, accept: (AttentionEvent) -> Bool = { _ in true },
                        message: (AttentionEvent) -> String?) {
        guard let event = readMarker(at: p.marker), event.ts > p.lastTs else { return }
        p.lastTs = event.ts
        guard accept(event) else { return }
        let body = message(event)
        p.pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.deliver(p, event: event, message: body) }
        p.pending = item
        scheduleAfter(attentionGrace, item)
    }

    // Fired attentionGrace after the event. If that session has shown activity past
    // the event (you approved a prompt, typed, or resumed it), stay quiet — you're
    // on it. Otherwise post and track the id so it auto-withdraws on a later resume.
    private func deliver(_ p: MarkerPath, event: AttentionEvent, message: String?) {
        p.pending = nil
        if let cwd = event.cwd, activityTs(forCwd: cwd) > event.ts { return }
        let id = "\(p.idPrefix)-\(event.ts)"
        postAttentionNotification(project: event.project, message: message,
                                  id: id, cwd: event.cwd)
        if let cwd = event.cwd { p.delivered[cwd, default: []].append((id, event.ts)) }
    }

    // Claude is blocked on you — alert on every fresh event, carrying its message.
    // (internal, not private, so AwakeBarTests can drive it with a temp marker.)
    func handleAttention() {
        handle(attention, message: { $0.message })
    }

    // A turn ended. Gate on the toggle (checked before the cursor advances, so
    // turning the feature off never consumes an event) and on whether the turn ran
    // long enough to be a real task — a quick reply stays quiet, an unknown -1
    // duration errs toward notifying. Body stamps the turn's finish time (the event
    // ts, not when the deferred banner posts) so a banner you find later still says
    // when it actually finished.
    // (internal, not private, so AwakeBarTests can drive it with a temp marker.)
    func handleDone() {
        guard notifyOnDone else { return }
        handle(done,
               accept: { AwakeMonitor.isRealTask(durationSeconds: $0.dur ?? -1,
                                                 minimum: Self.minTaskDuration) },
               message: { "Task finished at \(Self.clockTime($0.ts))" })
    }

    // MARK: Withdrawing resumed alerts

    // Withdraw an already-delivered terminal-path alert once that session resumes
    // after you acted: the per-cwd activity marker passing the event ts is the
    // same signal deliver() uses to stay quiet before the alert fires, applied
    // here a step later — once polled (≤10s), not the instant it bumps.
    // (internal, not private, so AwakeBarTests can drive the resume/withdraw path.)
    func clearResumedAttentions() {
        guard autoClearAlerts else { return }
        // Waiting alerts and task-finished banners clear on the identical signal:
        // once that cwd's activity marker passes the event ts (you sent a new
        // prompt / resumed the session), withdraw the banner.
        clearResumedByCwd(&attention.delivered)
        clearResumedByCwd(&done.delivered)
        // ...but a finished task is one you may never return to, so that resume may
        // never come. Sweep any done banner that has simply aged past
        // staleDoneAlertAge so completed-task FYIs don't pile up unanswered.
        let doneCut = Int(Date().timeIntervalSince1970 - Self.staleDoneAlertAge)
        for (cwd, entries) in done.delivered {
            let stale = entries.filter { $0.ts < doneCut }
            guard !stale.isEmpty else { continue }
            sink.withdraw(stale.map(\.id))
            let rest = entries.filter { $0.ts >= doneCut }
            done.delivered[cwd] = rest.isEmpty ? nil : rest
        }
        // VSCode permission alerts that never showed resolved (denied/ignored
        // prompts log no resolve marker) would otherwise linger forever once their
        // event ages out of the freshness window. Sweep those stale banners by age.
        let staleCut = Date().addingTimeInterval(-Self.staleVSCodeAlertAge)
        for (project, entries) in deliveredVSCode {
            let stale = entries.filter { $0.time < staleCut }
            guard !stale.isEmpty else { continue }
            sink.withdraw(stale.map(\.id))
            let rest = entries.filter { $0.time >= staleCut }
            deliveredVSCode[project] = rest.isEmpty ? nil : rest
        }
    }

    // Withdraw and forget every delivered alert in a per-cwd map whose session has
    // shown activity past its event ts. Shared by the waiting and task-finished
    // maps (see clearResumedAttentions).
    private func clearResumedByCwd(_ map: inout [String: [(id: String, ts: Int)]]) {
        for (cwd, entries) in map {
            let activity = activityTs(forCwd: cwd)
            let resumed = entries.filter { activity > $0.ts }
            guard !resumed.isEmpty else { continue }
            sink.withdraw(resumed.map(\.id))
            let rest = entries.filter { activity <= $0.ts }
            map[cwd] = rest.isEmpty ? nil : rest
        }
    }

    // VSCode path: alert on each attention event once it is at least attentionGrace
    // old AND still unresolved — a prompt you answered within the grace stays quiet.
    // Younger events wait for a later poll; lastVSNotify dedupes per project.
    private func processVSCodeAttention(_ events: [AwakeMonitor.VSCodeAttention]) {
        // Withdraw a delivered prompt alert once that same event shows resolved —
        // you answered it in the editor and the session is running again. The
        // resolve markers are recomputed per poll by collectVSCodeAttention, so the
        // line we alerted on reappears flipped to resolved while still within the
        // 5-minute freshness window.
        if autoClearAlerts {
            for ev in events where ev.resolved {
                guard let entries = deliveredVSCode[ev.project] else { continue }
                let hit = entries.filter { $0.time == ev.time }
                guard !hit.isEmpty else { continue }
                sink.withdraw(hit.map(\.id))
                let rest = entries.filter { $0.time != ev.time }
                deliveredVSCode[ev.project] = rest.isEmpty ? nil : rest
            }
        }
        let ripe = Date().addingTimeInterval(-attentionGrace)
        for ev in events.sorted(by: { $0.time < $1.time }) {
            let last = lastVSNotify[ev.project] ?? appLaunch
            guard ev.time > last, ev.time <= ripe else { continue }
            lastVSNotify[ev.project] = ev.time
            if ev.resolved { continue }
            let id = "vscode-\(ev.project)-\(Int(ev.time.timeIntervalSince1970))"
            postAttentionNotification(
                project: ev.project, message: ev.message, id: id, cwd: nil)
            deliveredVSCode[ev.project, default: []].append((id, ev.time))
        }
    }

    // Last activity time for a session, written per-cwd by notify-attention.sh.
    private func activityTs(forCwd cwd: String) -> Int {
        AwakeMonitor.activityTs(forCwd: cwd)
    }

    // MARK: Posting

    // Shared notification poster for both the terminal (hook/marker) and VSCode
    // (extension-log) paths. `id` keeps back-to-back waits from collapsing.
    private func postAttentionNotification(project: String?, message: String?,
                                           id: String, cwd: String?) {
        let content = UNMutableNotificationContent()
        let p = (project?.isEmpty == false) ? project : nil
        content.title = p.map { "Claude · \($0)" } ?? "Claude Code"
        let raw = (message?.isEmpty == false) ? message! : "Claude is waiting for you"
        content.body = Self.tightenBody(raw)
        content.sound = .default
        // Stack alerts from the same session under one header in Notification
        // Center instead of listing every repeat — group by cwd (terminal) and
        // fall back to the project name (VSCode path has no cwd).
        content.threadIdentifier = cwd ?? p ?? "claude"
        if let cwd { content.userInfo = ["cwd": cwd] }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        sink.post(request)
    }

    // The notification body comes from Claude Code, which prefixes "Claude" — the
    // title already carries it. Strip that leading "Claude"/"Claude is " so the
    // body doesn't echo the title ("Claude is requesting permission to use Bash"
    // -> "Requesting permission to use Bash"), keeping the rest intact.
    nonisolated static func tightenBody(_ raw: String) -> String {
        for prefix in ["Claude is ", "Claude "] where raw.hasPrefix(prefix) {
            let rest = raw.dropFirst(prefix.count)
            return "\(rest.prefix(1).uppercased())\(rest.dropFirst())"
        }
        return raw
    }

    // Format a marker ts (unix seconds) as a short wall-clock time for the
    // "Task finished at …" body — e.g. "18:09" or "6:09 PM". Short style follows
    // the user's 12/24-hour setting, the same one the menu-bar clock obeys.
    nonisolated static func clockTime(_ ts: Int) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    private func activateVSCode() {
        for id in ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"] {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.openApplication(
                    at: url, configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    // Show the banner even though AwakeBar is an accessory (LSUIElement) app, and
    // bring VSCode forward when the banner is clicked. Both are nonisolated to
    // satisfy the protocol; UI work hops to the main actor.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.activateVSCode() }
        }
        completionHandler()
    }
}

// MARK: - Notification sink
//
// The three notification-center side effects the coordinator performs, behind a
// value type so tests can substitute recorders. `.system` drives the real
// UNUserNotificationCenter; it is a computed property (not a stored static) so
// its non-Sendable closures aren't shared global state.
struct NotificationSink {
    var post: (UNNotificationRequest) -> Void
    var withdraw: ([String]) -> Void
    var withdrawAll: () -> Void

    static var system: NotificationSink {
        NotificationSink(
            post: { UNUserNotificationCenter.current().add($0) },
            withdraw: { UNUserNotificationCenter.current()
                .removeDeliveredNotifications(withIdentifiers: $0) },
            withdrawAll: { UNUserNotificationCenter.current().removeAllDeliveredNotifications() })
    }
}
