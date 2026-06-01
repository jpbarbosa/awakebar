import Testing
import Foundation
import UserNotifications
@testable import AwakeBar

// Behavioural tests for the terminal-marker notification pipeline (the attention
// and task-finished paths unified behind handle/deliver). The coordinator is
// driven through its seams: a recording NotificationSink stands in for
// UNUserNotificationCenter, a capturing scheduler hands back the deferred work
// item so the grace period fires on demand, and temp files stand in for the
// /tmp markers — so nothing here posts a real banner or touches the live markers.

// Records the side effects the coordinator would send to Notification Center.
// A plain (non-isolated) class: the tests drive it single-threaded on the main
// actor, and its closures must be callable from the sink's non-isolated context.
private final class Recorder {
    var posted: [UNNotificationRequest] = []
    var withdrawn: [String] = []
    var withdrewAll = false

    var sink: NotificationSink {
        NotificationSink(
            post: { self.posted.append($0) },
            withdraw: { self.withdrawn.append(contentsOf: $0) },
            withdrawAll: { self.withdrewAll = true })
    }
    var postedIds: [String] { posted.map(\.identifier) }
    func body(of id: String) -> String? {
        posted.first { $0.identifier == id }?.content.body
    }
}

// Captures the deferred work items instead of scheduling them on a real queue, so
// a test can fire the grace period synchronously (skipping cancelled items, the
// way a real queue would).
private final class CaptureScheduler {
    var items: [DispatchWorkItem] = []
    func schedule(_ delay: TimeInterval, _ item: DispatchWorkItem) { items.append(item) }
    func fireDue() { items.forEach { if !$0.isCancelled { $0.perform() } } }
}

@MainActor
struct NotificationCoordinatorTests {
    // MARK: helpers

    private func tempFile() -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "awakebar-marker-\(ProcessInfo.processInfo.globallyUniqueString).json")
    }
    private func tempCwd() -> String {
        "/tmp/awakebar-test-\(ProcessInfo.processInfo.globallyUniqueString)"
    }
    private func writeMarker(_ path: String, project: String, message: String,
                             cwd: String, ts: Int, dur: Int? = nil) {
        var dict: [String: Any] = ["project": project, "message": message,
                                   "cwd": cwd, "ts": ts]
        if let dur { dict["dur"] = dur }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        try! data.write(to: URL(fileURLWithPath: path))
    }
    private func writeActivity(forCwd cwd: String, ts: Int) {
        try! "\(ts)".write(toFile: Contract.activityMarkerPath(forCwd: cwd),
                           atomically: true, encoding: .utf8)
    }
    private func clean(_ paths: String...) {
        for p in paths { try? FileManager.default.removeItem(atPath: p) }
    }
    // Normalize the persisted toggles (UserDefaults.standard survives across runs)
    // so each test starts from a known state regardless of what ran before.
    private func normalize(_ c: NotificationCoordinator, autoClear: Bool, notifyDone: Bool) {
        if c.autoClearAlerts != autoClear { c.toggleAutoClear() }
        if c.notifyOnDone != notifyDone { c.toggleNotifyOnDone() }
    }
    private func makeCoordinator(_ rec: Recorder, _ sched: CaptureScheduler,
                                 attention: String, done: String) -> NotificationCoordinator {
        NotificationCoordinator(sink: rec.sink, scheduleAfter: sched.schedule,
                                attentionMarker: attention, doneMarker: done)
    }

    // MARK: attention path

    @Test func attentionPostsTightenedAlertAfterGrace() {
        let rec = Recorder(), sched = CaptureScheduler()
        let marker = tempFile(), cwd = tempCwd()
        defer { clean(marker, Contract.activityMarkerPath(forCwd: cwd)) }
        let c = makeCoordinator(rec, sched, attention: marker, done: tempFile())
        normalize(c, autoClear: true, notifyDone: true)

        writeMarker(marker, project: "proj",
                    message: "Claude is requesting permission to use Bash", cwd: cwd, ts: 100)
        c.handleAttention()
        #expect(rec.posted.isEmpty)                 // deferred by the grace period
        sched.fireDue()
        #expect(rec.postedIds == ["claude-attention-100"])
        #expect(rec.body(of: "claude-attention-100") == "Requesting permission to use Bash")
    }

    @Test func attentionIgnoresNonNewerTimestamps() {
        let rec = Recorder(), sched = CaptureScheduler()
        let marker = tempFile(), cwd = tempCwd()
        defer { clean(marker, Contract.activityMarkerPath(forCwd: cwd)) }
        let c = makeCoordinator(rec, sched, attention: marker, done: tempFile())
        normalize(c, autoClear: true, notifyDone: true)

        writeMarker(marker, project: "p", message: "m", cwd: cwd, ts: 100)
        c.handleAttention()
        // Same ts, then older ts: neither is strictly newer, so neither schedules.
        writeMarker(marker, project: "p", message: "m", cwd: cwd, ts: 100)
        c.handleAttention()
        writeMarker(marker, project: "p", message: "m", cwd: cwd, ts: 50)
        c.handleAttention()
        #expect(sched.items.count == 1)
    }

    @Test func attentionSuppressedWhenSessionResumedBeforeFiring() {
        let rec = Recorder(), sched = CaptureScheduler()
        let marker = tempFile(), cwd = tempCwd()
        defer { clean(marker, Contract.activityMarkerPath(forCwd: cwd)) }
        let c = makeCoordinator(rec, sched, attention: marker, done: tempFile())
        normalize(c, autoClear: true, notifyDone: true)

        writeMarker(marker, project: "p", message: "m", cwd: cwd, ts: 100)
        c.handleAttention()
        writeActivity(forCwd: cwd, ts: 200)         // you engaged during the grace window
        sched.fireDue()
        #expect(rec.posted.isEmpty)
    }

    @Test func newerEventCancelsThePendingAlert() {
        let rec = Recorder(), sched = CaptureScheduler()
        let marker = tempFile(), cwd = tempCwd()
        defer { clean(marker, Contract.activityMarkerPath(forCwd: cwd)) }
        let c = makeCoordinator(rec, sched, attention: marker, done: tempFile())
        normalize(c, autoClear: true, notifyDone: true)

        writeMarker(marker, project: "p", message: "m", cwd: cwd, ts: 100)
        c.handleAttention()
        writeMarker(marker, project: "p", message: "m", cwd: cwd, ts: 200)
        c.handleAttention()
        #expect(sched.items.count == 2)
        #expect(sched.items[0].isCancelled)
        #expect(!sched.items[1].isCancelled)
        sched.fireDue()
        #expect(rec.postedIds == ["claude-attention-200"])   // only the live one posts
    }

    @Test func deliveredAlertWithdrawnOnceSessionResumes() {
        let rec = Recorder(), sched = CaptureScheduler()
        let marker = tempFile(), cwd = tempCwd()
        defer { clean(marker, Contract.activityMarkerPath(forCwd: cwd)) }
        let c = makeCoordinator(rec, sched, attention: marker, done: tempFile())
        normalize(c, autoClear: true, notifyDone: true)

        writeMarker(marker, project: "p", message: "m", cwd: cwd, ts: 100)
        c.handleAttention(); sched.fireDue()
        #expect(rec.postedIds == ["claude-attention-100"])

        writeActivity(forCwd: cwd, ts: 200)         // you resumed the session
        c.clearResumedAttentions()
        #expect(rec.withdrawn == ["claude-attention-100"])
    }

    // MARK: done path

    @Test func taskFinishedFiresOnlyForRealTasks() {
        let rec = Recorder(), sched = CaptureScheduler()
        let done = tempFile(), cwd = tempCwd()
        defer { clean(done, Contract.activityMarkerPath(forCwd: cwd)) }
        let c = makeCoordinator(rec, sched, attention: tempFile(), done: done)
        normalize(c, autoClear: true, notifyDone: true)

        // A quick reply (under the 30s threshold) consumes the event but doesn't alert.
        writeMarker(done, project: "p", message: "Task finished", cwd: cwd, ts: 100, dur: 10)
        c.handleDone()
        #expect(sched.items.isEmpty)

        // A real task (>= 30s) does alert, with the fixed body.
        writeMarker(done, project: "p", message: "Task finished", cwd: cwd, ts: 200, dur: 60)
        c.handleDone(); sched.fireDue()
        #expect(rec.postedIds == ["claude-done-200"])
        #expect(rec.body(of: "claude-done-200") == "Task finished")
    }

    @Test func notifyOnDoneOffDoesNotConsumeTheEvent() {
        let rec = Recorder(), sched = CaptureScheduler()
        let done = tempFile(), cwd = tempCwd()
        defer { clean(done, Contract.activityMarkerPath(forCwd: cwd)) }
        let c = makeCoordinator(rec, sched, attention: tempFile(), done: done)
        normalize(c, autoClear: true, notifyDone: false)   // feature off

        writeMarker(done, project: "p", message: "Task finished", cwd: cwd, ts: 100, dur: 60)
        c.handleDone()
        #expect(sched.items.isEmpty)                        // gated off before scheduling

        // Turn it on: the SAME marker must still fire — proving the cursor wasn't
        // advanced while the feature was off.
        c.toggleNotifyOnDone()
        c.handleDone(); sched.fireDue()
        #expect(rec.postedIds == ["claude-done-100"])
    }
}
