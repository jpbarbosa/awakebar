import Cocoa
import ServiceManagement   // SMAppService, for the "Open at Login" toggle
import UserNotifications    // UNUserNotificationCenter, for "Claude is waiting" alerts

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate,
                         UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var snap = AwakeMonitor.Snapshot()
    private var timer: Timer?
    private var lastAwake: Bool?
    private var hookLastActive: Date?

    // Collection runs here, off the main thread, so opening the menu never
    // blocks on `pmset` or on scanning Claude Code's logs.
    private let refreshQueue = DispatchQueue(label: "io.jp7.awakebar.refresh",
                                             qos: .utility)
    private var refreshing = false
    // Skip rebuilding the menu when nothing the user can see has changed —
    // important because a refresh may land while the menu is open.
    private var lastMenuSignature: String?

    // Power assertions AwakeBar holds itself. The remote one tracks Remote
    // Control automatically — so the Mac stays awake even in the gap between
    // turns the event-driven keep-awake hook can't cover. The manual one is the
    // user's "Keep awake" menu toggle, not persisted (resets to off on launch).
    private let remoteAssertion = PowerAssertion("AwakeBar: Remote Control session connected")
    private let manualAssertion = PowerAssertion("AwakeBar: Keep awake (manual)")
    private var manualKeepAwake = false

    // Native "Claude is waiting for you" notifications. notify-attention.sh writes
    // attentionMarkerPath when a session is blocked on the user; the watcher fires
    // the moment it changes. Rather than alert at once, we wait attentionGrace and
    // alert only if the user hasn't engaged with THAT session meanwhile — detected
    // via a per-cwd activity marker the same hook bumps on prompt/tool/stop events
    // (so one busy session can't silence another's alert). lastAttentionTs dedupes:
    // only a strictly newer ts is considered, so a marker from before launch stays
    // silent.
    private let attentionMarkerPath = "/tmp/claude-attention.json"
    private var attentionWatcher: AttentionWatcher?
    private var lastAttentionTs = 0
    private var pendingAlert: DispatchWorkItem?
    private var pendingDone: DispatchWorkItem?
    // How long a session must stay blocked before we alert — the "Alert delay"
    // submenu lets the user pick from graceChoices. Persisted across launches
    // (loaded in applicationDidFinishLaunching, default 10s).
    private static let graceKey = "attentionGraceSeconds"
    private static let graceChoices: [TimeInterval] = [5, 10]
    private var attentionGrace: TimeInterval = 10

    // "Task finished" notifications. notify-attention.sh writes doneMarkerPath on
    // every turn end (Stop), stamping how long the turn ran; the watcher fires the
    // moment it changes. We notify when that duration is at least minTaskDuration —
    // it was a real task, not a quick reply — so it pings the instant the task ends
    // whatever window you're in, rather than waiting on you to go idle. A duration
    // of -1 (start unknown) errs toward notifying. lastDoneTs dedupes (primed
    // before the watch arms); the menu toggle persists.
    private let doneMarkerPath = "/tmp/claude-done.json"
    private var doneWatcher: AttentionWatcher?
    private var lastDoneTs = 0
    private static let minTaskDuration: TimeInterval = 30
    private static let notifyDoneKey = "notifyOnTaskDone"
    private var notifyOnDone = true

    // How long a remote-controlled session may stay idle (no prompt/tool/stop
    // activity) before AwakeBar releases its remote hold and lets the Mac sleep.
    // The "Remote Idle Timeout" submenu picks from remoteIdleChoices; 0 = Off
    // (hold as long as the bridge is connected). Persisted; default 1h. AwakeBar
    // also writes the chosen window to idleWindowFile so keep-awake.sh's own
    // between-turns caffeinate expires on the same window (see writeIdleWindow).
    private static let remoteIdleKey = "remoteIdleTimeoutSeconds"
    private static let remoteIdleChoices: [(label: String, seconds: TimeInterval)] =
        [("Off", 0), ("30 Minutes", 1800), ("1 Hour", 3600), ("2 Hours", 7200)]
    private static let idleWindowFile = "/tmp/claude-keep-awake.idle"
    private var remoteIdleTimeout: TimeInterval = 3600

    // VSCode permission prompts surfaced via the extension log (see AwakeMonitor).
    // appLaunch floors out events logged before launch; lastVSNotify is the
    // per-project high-water of handled events so none is alerted twice.
    private let appLaunch = Date()
    private var lastVSNotify: [String: Date] = [:]

    // Delivered "Claude is waiting" alerts we may withdraw once the session
    // resumes after you act, so a stale banner doesn't linger in Notification
    // Center. Terminal path: keyed by cwd → (id, event ts), cleared when that
    // cwd's activity marker passes ts — the same "you're on it" signal
    // fireIfStillWaiting uses to suppress the alert before it fires. VSCode path:
    // keyed by project → a LIST of (id, event time), cleared per-entry when that
    // event shows resolved or ages out (see clearResumedAttentions). A list, not
    // one tuple, so two prompts in the same project don't orphan the earlier id —
    // that orphaning is what left duplicate banners stuck in Notification Center.
    private var deliveredByCwd: [String: (id: String, ts: Int)] = [:]
    private var deliveredVSCode: [String: [(id: String, time: Date)]] = [:]
    // A delivered VSCode alert whose event has aged past this without ever showing
    // resolved (e.g. a permission prompt you denied or ignored, which logs no
    // resolve marker) is withdrawn as stale — it matches the freshness window past
    // which collectVSCodeAttention stops emitting the event, so no later resolve
    // can arrive to clear it the normal way.
    private static let staleVSCodeAlertAge: TimeInterval = 5 * 60
    // Delivered "Task finished" banners, withdrawn the same way as the terminal
    // waiting alerts: keyed by cwd → (id, done ts), cleared once that cwd's
    // activity marker passes ts (you sent a new prompt = resumed the session).
    private var deliveredDoneByCwd: [String: (id: String, ts: Int)] = [:]
    // The "Clear alerts when resumed" menu toggle. On by default; when off we keep
    // tracking delivered alerts but never withdraw them, so flipping it back on
    // resumes clearing for the next session that resumes. Persisted across launches
    // via UserDefaults (loaded in applicationDidFinishLaunching, default on).
    private static let autoClearKey = "autoClearAlerts"
    private var autoClearAlerts = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Restore the persisted "Clear alerts when resumed" choice. register makes
        // bool(forKey:) return true when the user has never set it, so the default
        // stays on.
        UserDefaults.standard.register(defaults: [Self.autoClearKey: true,
                                                  Self.graceKey: 10.0,
                                                  Self.remoteIdleKey: 3600.0,
                                                  Self.notifyDoneKey: true])
        autoClearAlerts = UserDefaults.standard.bool(forKey: Self.autoClearKey)
        notifyOnDone = UserDefaults.standard.bool(forKey: Self.notifyDoneKey)
        let savedGrace = UserDefaults.standard.double(forKey: Self.graceKey)
        attentionGrace = Self.graceChoices.contains(savedGrace) ? savedGrace : 10
        let savedIdle = UserDefaults.standard.double(forKey: Self.remoteIdleKey)
        remoteIdleTimeout = Self.remoteIdleChoices.contains { $0.seconds == savedIdle }
            ? savedIdle : 3600
        writeIdleWindow()   // publish the window for keep-awake.sh before any turn

        // Create the status item HERE, not in a property initializer — doing it
        // before the app finishes launching can leave the item not displayed.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.delegate = self
        // Don't auto-disable action-less items — the info rows stay "enabled"
        // so AppKit renders them at full/secondary label color instead of the
        // dimmed "disabled command" gray.
        menu.autoenablesItems = false
        statusItem.menu = menu

        // Render something immediately, then fill in real state asynchronously.
        updateButton(awake: false)
        rebuildMenu(awake: false)
        refresh()
        NSLog("AwakeBar: launched; status item button = %@",
              statusItem.button != nil ? "ok" : "nil")

        // The timer fires on the main run loop, so it is safe to assume
        // main-actor isolation here rather than hop with a Task.
        timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }

        // Alert when Claude Code is blocked waiting on the user. Prime the dedup
        // cursor from any marker left by a previous run BEFORE arming the watch,
        // so launching AwakeBar never replays a stale "Claude is waiting" alert.
        setUpNotifications()
        primeAttention()
        attentionWatcher = AttentionWatcher(path: attentionMarkerPath) { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handleAttention() }
            }
        }
        attentionWatcher?.start()

        // Same kqueue pattern for the "task finished" marker (see handleDone).
        primeDone()
        doneWatcher = AttentionWatcher(path: doneMarkerPath) { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handleDone() }
            }
        }
        doneWatcher?.start()
    }

    // Refresh the moment the menu opens. The refresh is async, so the menu
    // appears instantly with the last poll's data (≤10s old) and updates in
    // place a moment later if anything changed.
    func menuWillOpen(_ menu: NSMenu) { refresh() }

    // Kick off a background collection; coalesce so overlapping triggers (the
    // 5s timer and a menu open) don't pile up.
    private func refresh() {
        if refreshing { return }
        refreshing = true
        refreshQueue.async { [weak self] in
            let snapshot = AwakeMonitor.collect()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.refreshing = false
                    self.apply(snapshot)
                }
            }
        }
    }

    private func apply(_ snapshot: AwakeMonitor.Snapshot) {
        snap = snapshot
        if snapshot.hookActive { hookLastActive = Date() }
        // Track Remote Control automatically, but drop the hold once the session
        // has been idle past the timeout so the Mac can sleep (the manual hold is
        // driven by the menu toggle). Then reflect everything in the icon/menu.
        remoteAssertion.set(shouldHoldRemote(snapshot))
        processVSCodeAttention(snapshot.vscodeAttention)
        clearResumedAttentions()
        render()
    }

    // Whether to keep AwakeBar's remote hold for this snapshot. Idle is measured
    // against the most recent session activity (per-cwd markers) and the last
    // observed hook turn, so a live turn or recent prompt keeps it held.
    private func shouldHoldRemote(_ snapshot: AwakeMonitor.Snapshot) -> Bool {
        let lastActivity = [snapshot.remoteLastActivity, hookLastActive]
            .compactMap { $0 }.max()
        return AwakeMonitor.shouldHoldRemote(
            connected: snapshot.remoteControlActive, timeout: remoteIdleTimeout,
            lastActivity: lastActivity, now: Date(), hookActive: snapshot.hookActive)
    }

    // Publish the idle window for keep-awake.sh: it restarts its between-turns
    // caffeinate with -t = this many seconds, so the hook's own hold expires on
    // the same window. Off removes the file, restoring the hook's default 4h cap.
    private func writeIdleWindow() {
        if remoteIdleTimeout > 0 {
            try? String(Int(remoteIdleTimeout)).write(
                toFile: Self.idleWindowFile, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(atPath: Self.idleWindowFile)
        }
    }

    // Reflect current state — the snapshot plus the assertions we hold — in the
    // icon and menu. Called after every refresh and whenever a toggle changes.
    private func render() {
        // Awake means a real external assertion OR one we are holding ourselves.
        let awake = snap.state == .awake || remoteAssertion.held || manualAssertion.held

        updateButton(awake: awake)

        if awake != lastAwake {
            let names = snap.holders
                .map { $0.isClaudeHook ? "\($0.name)(claude-hook)" : $0.name }
                .joined(separator: ", ")
            NSLog("AwakeBar: state = %@, holders = [%@]",
                  awake ? "awake" : "canSleep", names)
            lastAwake = awake
        }

        let signature = menuSignature(awake: awake)
        if signature != lastMenuSignature {
            lastMenuSignature = signature
            rebuildMenu(awake: awake)
        }
    }

    private func updateButton(awake: Bool) {
        guard let button = statusItem.button else { return }
        let forced = manualAssertion.held
        if let image = statusImage(awake: awake, forced: forced) {
            button.image = image
            button.title = ""
        } else {
            // Never leave the item empty (invisible) if SF Symbols fail.
            button.image = nil
            button.title = awake ? "☕︎" : "Zz"
        }
        button.toolTip = forced ? "Keep awake is on — Mac forced awake"
                       : awake  ? "Mac is being kept awake"
                                : "Mac can sleep normally"
    }

    // The menu-bar cup. Normally a template image, so it adapts to the menu bar
    // (black/white, inverts when the menu is open). When the manual "Keep
    // awake" hold is on, a red dot is composited at the bottom-right; that
    // forces a *non-template* image (template images are drawn monochrome by
    // the system, which would erase the red), so the cup itself is redrawn in
    // the menu bar's label colour to still look right.
    private func statusImage(awake: Bool, forced: Bool) -> NSImage? {
        let symbol = awake ? "cup.and.saucer.fill" : "cup.and.saucer"
        guard let base = NSImage(systemSymbolName: symbol,
                                 accessibilityDescription: "Keep-awake status")
        else { return nil }
        guard forced else {
            return nudgedDown(base, template: true)
        }
        let size = base.size
        let badged = NSImage(size: size)
        let appearance = statusItem.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            badged.lockFocus()
            // Cup: recolour the template glyph to the menu bar's label colour.
            let rect = NSRect(origin: .zero, size: size)
            base.draw(in: rect.offsetBy(dx: 0, dy: -iconVerticalNudge))
            NSColor.labelColor.set()
            rect.fill(using: .sourceAtop)
            // Red badge, tangent to the bottom-right corner.
            let d = (size.height * 0.46).rounded()
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: size.width - d, y: 0, width: d, height: d)).fill()
            badged.unlockFocus()
        }
        badged.isTemplate = false
        return badged
    }

    // The saucer gives cup.and.saucer a low optical centre, so the glyph reads
    // as sitting high in the bar even though its box is centred. Shift the whole
    // glyph down a couple of points within a same-size canvas (no rescaling, so
    // the menu bar still centres the box) to correct the impression.
    private let iconVerticalNudge: CGFloat = 0.5  // points down (~1px on Retina)

    private func nudgedDown(_ image: NSImage, template: Bool) -> NSImage {
        let size = image.size
        let shifted = NSImage(size: size)
        shifted.lockFocus()
        // Bottom-left origin: "down" on screen is a negative y offset.
        image.draw(in: NSRect(origin: .zero, size: size)
                        .offsetBy(dx: 0, dy: -iconVerticalNudge))
        shifted.unlockFocus()
        shifted.isTemplate = template
        return shifted
    }

    // A fingerprint of everything rebuildMenu renders (minus volatile relative
    // ages, so an idle menu doesn't flicker every poll). When unchanged, the
    // menu is left alone.
    private func menuSignature(awake: Bool) -> String {
        let holders = snap.holders
            .map { "\($0.name)|\($0.isClaudeHook)" }
            .joined(separator: ",")
        return [
            String(awake),
            String(snap.hookInstalled),
            String(snap.hookActive),
            String(describing: snap.hookReason),
            String(snap.remoteControlActive),
            String(remoteAssertion.held),
            String(manualAssertion.held),
            String(autoClearAlerts),
            String(notifyOnDone),
            String(attentionGrace),
            String(remoteIdleTimeout),
            snap.remoteProjects.joined(separator: ","),
            holders,
        ].joined(separator: "~")
    }

    private func rebuildMenu(awake: Bool) {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        // Headline — primary status: full-contrast label color, flat icon.
        let header = infoItem(awake ? "Mac is being kept awake"
                                    : "Mac can sleep normally",
                              color: .labelColor)
        // The cup shares the same fixed leading slot as every other row, so the
        // headline lines up with the status dots and the controls below.
        let cup = NSImage(
            systemSymbolName: awake ? "cup.and.saucer.fill" : "cup.and.saucer",
            accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        header.image = leadingSlot(cup, template: true)
        menu.addItem(header)

        // Claude Code hook + live remote-control status — secondary info.
        menu.addItem(.separator())
        menu.addItem(infoItem(claudeHookStatusText(), color: .secondaryLabelColor,
                              status: snap.hookActive))
        if snap.remoteControlActive {
            // Connected but the hold released means the session went idle past the
            // timeout — the bridge is still up, we've just stopped forcing awake.
            let idle = !remoteAssertion.held
            menu.addItem(infoItem(idle ? "Remote Control: idle (sleep allowed)"
                                       : "Remote Control: Active",
                                  color: .secondaryLabelColor, status: !idle))
            for project in snap.remoteProjects {
                // Spacer where the parent has its dot, so each project's name lines
                // up flush-left with the "Remote Control:" label above it.
                let row = infoItem(project, color: .secondaryLabelColor)
                row.image = spacerSlot()
                menu.addItem(row)
            }
        } else {
            menu.addItem(infoItem("Remote Control: Off", color: .secondaryLabelColor,
                                  status: false))
        }

        var keptAwakeBy = snap.holders.map {
            $0.isClaudeHook ? "\($0.name) (Claude Code Hook)" : $0.name
        }
        if remoteAssertion.held {
            keptAwakeBy.append("AwakeBar (Remote Control session)")
        }
        if manualAssertion.held {
            keptAwakeBy.append("AwakeBar (manual)")
        }
        if awake && !keptAwakeBy.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Kept awake by"))
            for label in keptAwakeBy {
                let row = infoItem(label, color: .secondaryLabelColor)
                row.image = spacerSlot()   // align with the other rows' text column
                menu.addItem(row)
            }
        }

        menu.addItem(.separator())

        // Manual override: hold the Mac awake regardless of Claude/remote state.
        let keepAwake = NSMenuItem(title: "Force Stay Awake",
                                   action: #selector(toggleKeepAwake), keyEquivalent: "")
        keepAwake.target = self
        keepAwake.toolTip = "Force the Mac awake until turned off, regardless of Claude or Remote Control (the display may still sleep)"
        keepAwake.image = checkmarkSlot(manualKeepAwake)
        menu.addItem(keepAwake)

        // Notify when a task finishes — gated on how long the turn ran (real tasks
        // ping, quick replies don't), independent of which window you're in.
        let notifyDone = NSMenuItem(title: "Notify When Task Finishes",
                                    action: #selector(toggleNotifyOnDone), keyEquivalent: "")
        notifyDone.target = self
        notifyDone.toolTip = "Post a notification when a task (a turn longer than ~30s) finishes, whatever window you're in"
        notifyDone.image = checkmarkSlot(notifyOnDone)
        menu.addItem(notifyDone)

        // Withdraw a delivered "Claude is waiting" alert once that session resumes
        // after you act. On by default; turn off to keep alerts in Notification
        // Center as a record.
        let autoClear = NSMenuItem(title: "Clear Notifications When Resumed",
                                   action: #selector(toggleAutoClear), keyEquivalent: "")
        autoClear.target = self
        autoClear.toolTip = "Withdraw a \u{201C}Claude is waiting\u{201D} notification once that session starts running again"
        autoClear.image = checkmarkSlot(autoClearAlerts)
        menu.addItem(autoClear)

        // How long a blocked session waits before alerting — answer within the
        // delay and no notification fires. A checkmark marks the active choice.
        let delay = NSMenuItem(title: "Notification Delay", action: nil, keyEquivalent: "")
        let delaySub = NSMenu()
        delaySub.autoenablesItems = false
        for seconds in Self.graceChoices {
            let choice = NSMenuItem(title: "\(Int(seconds)) Seconds",
                                    action: #selector(setGrace(_:)), keyEquivalent: "")
            choice.target = self
            choice.tag = Int(seconds)
            choice.state = attentionGrace == seconds ? .on : .off
            delaySub.addItem(choice)
        }
        delay.submenu = delaySub
        delay.image = spacerSlot()
        menu.addItem(delay)

        // How long a remote session may idle before the Mac is allowed to sleep —
        // a turn or prompt resets the timer. A checkmark marks the active choice.
        let idleTimeout = NSMenuItem(title: "Remote Idle Timeout", action: nil,
                                     keyEquivalent: "")
        idleTimeout.toolTip = "Let the Mac sleep after this long with no activity on a remote-controlled session (a turn resets the timer). Off keeps it awake as long as the bridge is connected."
        let idleSub = NSMenu()
        idleSub.autoenablesItems = false
        for choice in Self.remoteIdleChoices {
            let item = NSMenuItem(title: choice.label,
                                  action: #selector(setRemoteIdle(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(choice.seconds)
            item.state = remoteIdleTimeout == choice.seconds ? .on : .off
            idleSub.addItem(item)
        }
        idleTimeout.submenu = idleSub
        idleTimeout.image = spacerSlot()
        menu.addItem(idleTimeout)

        let login = NSMenuItem(title: "Open at Login",
                               action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.image = checkmarkSlot(SMAppService.mainApp.status == .enabled)
        menu.addItem(login)

        // Set Quit apart from the settings above, per macOS menu convention.
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit AwakeBar",
                              action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        // Power glyph in the shared leading slot — a familiar "turn off" cue.
        let power = NSImage(systemSymbolName: "power", accessibilityDescription: "Quit")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        quit.image = leadingSlot(power, template: true)
        menu.addItem(quit)
    }

    // A non-interactive informational row, drawn at an explicit color via
    // attributedTitle — rather than the dimmed "disabled command" gray a
    // plain disabled item would get.
    private func infoItem(_ text: String, color: NSColor, indent: Int = 0,
                          status: Bool? = nil) -> NSMenuItem {
        // Left enabled (the menu has autoenablesItems = false) so AppKit does
        // not dim it; with no action it is still effectively non-interactive.
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.indentationLevel = indent
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.foregroundColor: color,
                         .font: NSFont.menuFont(ofSize: 0)])
        if let status, indent == 0 {
            item.image = leadingSlot(statusDot(active: status), template: false)
        }
        return item
    }

    // A small leading status dot for info rows: filled green when the subsystem
    // is active, a dim hollow ring when not — shape plus color, so it still reads
    // in grayscale (the row's text stays the primary signal). isTemplate is
    // cleared so the menu honours the palette tint instead of recolouring it.
    private func statusDot(active: Bool) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
            .applying(NSImage.SymbolConfiguration(
                paletteColors: [active ? .systemGreen : .tertiaryLabelColor]))
        let dot = NSImage(systemSymbolName: active ? "circle.fill" : "circle",
                          accessibilityDescription: active ? "active" : "inactive")?
            .withSymbolConfiguration(config)
        dot?.isTemplate = false
        return dot
    }

    // Every top-level content row gets a leading image of this exact size — a
    // status dot, the header cup, or a transparent spacer — so their titles share
    // one image column and line up, the way Apple's own menus that mix checkmarks
    // and icons do. (Without this, imaged rows indent right of plain rows.)
    private static let leadingSlotSize = NSSize(width: 16, height: 16)

    // Draw `symbol` centred (aspect-fit, never upscaled) into a fixed-size slot.
    // nil yields a transparent spacer. template:true keeps the menu's automatic
    // label-colour tinting (used for the cup); false preserves a colour the dot
    // already carries.
    private func leadingSlot(_ symbol: NSImage?, template: Bool) -> NSImage {
        let size = Self.leadingSlotSize
        let slot = NSImage(size: size)
        slot.lockFocus()
        if let symbol, symbol.size.width > 0, symbol.size.height > 0 {
            let s = symbol.size
            let scale = min(size.width / s.width, size.height / s.height, 1)
            let w = s.width * scale, h = s.height * scale
            symbol.draw(in: NSRect(x: (size.width - w) / 2, y: (size.height - h) / 2,
                                   width: w, height: h))
        }
        slot.unlockFocus()
        slot.isTemplate = template
        return slot
    }

    private func spacerSlot() -> NSImage { leadingSlot(nil, template: false) }

    // A checkmark drawn into the same leading slot as the dots, so a ticked row
    // lines up with the status rows instead of sitting in AppKit's separate state
    // column. Off rows get a blank spacer of equal width. We forgo NSMenuItem's
    // native .state in the main menu for this — the pay-off is one aligned column.
    private func checkmarkSlot(_ on: Bool) -> NSImage {
        guard on else { return spacerSlot() }
        let check = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "on")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        return leadingSlot(check, template: true)
    }

    // The always-present Claude line. Between turns the hook's caffeinate is
    // gone, so this reports the last time it ran rather than just "idle".
    private func claudeHookStatusText() -> String {
        if !snap.hookInstalled {
            return "Claude Code Hook: not installed"
        }
        if snap.hookActive {
            switch snap.hookReason {
            case .turn:
                return "Claude Code Hook: Claude is working"
            case .remote:
                // The reason file can be stale if remote control dropped
                // between turns — verify against the live check.
                return snap.remoteControlActive
                    ? "Claude Code Hook: holding for a remote session"
                    : "Claude Code Hook: keeping the Mac awake now"
            case .unknown:
                return "Claude Code Hook: keeping the Mac awake now"
            }
        }
        if let last = hookLastActive {
            return "Claude Code Hook: idle (last active \(Self.relativeAge(last)))"
        }
        return "Claude Code Hook: idle"
    }

    private static func relativeAge(_ date: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(date)))
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change the login item"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    // Toggle the manual "Keep awake" hold and re-render immediately.
    @objc private func toggleKeepAwake() {
        manualKeepAwake.toggle()
        manualAssertion.set(manualKeepAwake)
        render()
    }

    // Toggle whether resumed sessions auto-clear their delivered alerts. Turning
    // it back on lets the next refresh withdraw anything that has since resumed.
    @objc private func toggleAutoClear() {
        autoClearAlerts.toggle()
        UserDefaults.standard.set(autoClearAlerts, forKey: Self.autoClearKey)
        if autoClearAlerts { clearResumedAttentions() }
        render()
    }

    // Toggle "Notify When Task Finishes" and persist it.
    @objc private func toggleNotifyOnDone() {
        notifyOnDone.toggle()
        UserDefaults.standard.set(notifyOnDone, forKey: Self.notifyDoneKey)
        render()
    }

    // Pick the alert delay from the submenu. The tag carries the seconds; takes
    // effect on the next event (an already-scheduled alert keeps its old timing).
    @objc private func setGrace(_ sender: NSMenuItem) {
        let seconds = TimeInterval(sender.tag)
        guard seconds != attentionGrace else { return }
        attentionGrace = seconds
        UserDefaults.standard.set(seconds, forKey: Self.graceKey)
        render()
    }

    // Pick the remote idle timeout. Persists, republishes the window for the hook,
    // and re-evaluates the hold right away so the change takes effect immediately.
    @objc private func setRemoteIdle(_ sender: NSMenuItem) {
        let seconds = TimeInterval(sender.tag)
        guard seconds != remoteIdleTimeout else { return }
        remoteIdleTimeout = seconds
        UserDefaults.standard.set(seconds, forKey: Self.remoteIdleKey)
        writeIdleWindow()
        remoteAssertion.set(shouldHoldRemote(snap))
        render()
    }

    @objc private func quit() {
        remoteAssertion.set(false)   // don't leak assertions
        manualAssertion.set(false)
        NSApp.terminate(nil)
    }

    // MARK: Attention notifications

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

    private func setUpNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Drop any banners left over from a previous run. The deliveredByCwd /
        // deliveredVSCode tracking maps are in-memory, so anything delivered before
        // this launch is untrackable and could never be withdrawn — a guaranteed
        // zombie. Honor the toggle: with auto-clear off we promise never to withdraw.
        if autoClearAlerts { center.removeAllDeliveredNotifications() }
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                NSLog("AwakeBar: notification auth error: %@", error.localizedDescription)
            } else {
                NSLog("AwakeBar: notification auth granted = %@", granted ? "yes" : "no")
            }
        }
    }

    private func readAttentionMarker() -> AttentionEvent? {
        guard let data = FileManager.default.contents(atPath: attentionMarkerPath)
        else { return nil }
        return try? JSONDecoder().decode(AttentionEvent.self, from: data)
    }

    // Record the current marker's ts without alerting, so a marker written before
    // this launch can't fire a notification at startup.
    private func primeAttention() {
        if let event = readAttentionMarker() { lastAttentionTs = event.ts }
    }

    // Called on the main actor whenever the marker changes. Defers the alert by
    // the grace period; fireIfStillWaiting then drops it if the user engaged with
    // that session meanwhile. A newer event cancels and reschedules.
    private func handleAttention() {
        guard let event = readAttentionMarker(), event.ts > lastAttentionTs
        else { return }
        lastAttentionTs = event.ts
        pendingAlert?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.fireIfStillWaiting(event) }
        pendingAlert = item
        DispatchQueue.main.asyncAfter(deadline: .now() + attentionGrace, execute: item)
    }

    // Fired attentionGrace after the event. If the session has since shown
    // activity past the event (you approved a prompt, typed, or the turn ended),
    // stay quiet — you're on it. Otherwise alert.
    private func fireIfStillWaiting(_ event: AttentionEvent) {
        pendingAlert = nil
        if let cwd = event.cwd, activityTs(forCwd: cwd) > event.ts { return }
        let id = "claude-attention-\(event.ts)"
        postAttentionNotification(project: event.project, message: event.message,
                                  id: id, cwd: event.cwd)
        if let cwd = event.cwd { deliveredByCwd[cwd] = (id, event.ts) }
    }

    // MARK: Task-finished notifications

    private func readDoneMarker() -> AttentionEvent? {
        guard let data = FileManager.default.contents(atPath: doneMarkerPath)
        else { return nil }
        return try? JSONDecoder().decode(AttentionEvent.self, from: data)
    }

    // Record the current done marker's ts without alerting, so a turn that ended
    // before this launch can't fire a "task finished" alert at startup.
    private func primeDone() {
        if let event = readDoneMarker() { lastDoneTs = event.ts }
    }

    // Called on the main actor whenever the done marker changes (every turn end).
    // Alerts only if the feature is on, the event is new, and the turn ran at least
    // minTaskDuration — that "was this a real task" gate replaces any presence
    // check, so it fires the instant a long task ends whatever window you're in,
    // while a quick reply stays quiet. A duration of -1 (start unknown) errs toward
    // notifying. Like the waiting alerts it's withdrawn once you resume the session
    // (see clearResumedAttentions) when Clear Notifications When Resumed is on.
    private func handleDone() {
        guard notifyOnDone,
              let event = readDoneMarker(), event.ts > lastDoneTs else { return }
        lastDoneTs = event.ts
        let dur = event.dur ?? -1
        guard AwakeMonitor.isRealTask(durationSeconds: dur,
                                      minimum: Self.minTaskDuration) else { return }
        // Defer by the same grace as the waiting alerts (the Notification Delay
        // menu): if you resume the session within the window you saw it finish, so
        // fireDoneIfStillAway suppresses the banner outright instead of the poll
        // having to flash-then-withdraw it. A newer turn cancels and reschedules.
        pendingDone?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.fireDoneIfStillAway(event) }
        pendingDone = item
        DispatchQueue.main.asyncAfter(deadline: .now() + attentionGrace, execute: item)
    }

    // Fired attentionGrace after the turn ended. If you've resumed that session
    // meanwhile (activity past the event), stay quiet — you watched it finish.
    // Otherwise post; clearResumedAttentions still withdraws it for a later resume.
    private func fireDoneIfStillAway(_ event: AttentionEvent) {
        pendingDone = nil
        if let cwd = event.cwd, activityTs(forCwd: cwd) > event.ts { return }
        let id = "claude-done-\(event.ts)"
        postAttentionNotification(project: event.project, message: "Task finished",
                                  id: id, cwd: event.cwd)
        // Track so it auto-withdraws once you resume that session.
        if let cwd = event.cwd { deliveredDoneByCwd[cwd] = (id, event.ts) }
    }

    // Withdraw an already-delivered terminal-path alert once that session resumes
    // after you acted: the per-cwd activity marker passing the event ts is the
    // same signal fireIfStillWaiting uses to stay quiet before the alert fires,
    // applied here a step later — once polled (≤10s), not the instant it bumps.
    private func clearResumedAttentions() {
        guard autoClearAlerts else { return }
        let center = UNUserNotificationCenter.current()
        for (cwd, entry) in deliveredByCwd where activityTs(forCwd: cwd) > entry.ts {
            center.removeDeliveredNotifications(withIdentifiers: [entry.id])
            deliveredByCwd[cwd] = nil
        }
        // Task-finished banners clear the same way: once you send a new prompt in
        // that session (activity passes the done timestamp), withdraw the banner.
        for (cwd, entry) in deliveredDoneByCwd where activityTs(forCwd: cwd) > entry.ts {
            center.removeDeliveredNotifications(withIdentifiers: [entry.id])
            deliveredDoneByCwd[cwd] = nil
        }
        // VSCode permission alerts that never showed resolved (denied/ignored
        // prompts log no resolve marker) would otherwise linger forever once their
        // event ages out of the freshness window. Sweep those stale banners by age.
        let staleCut = Date().addingTimeInterval(-Self.staleVSCodeAlertAge)
        for (project, entries) in deliveredVSCode {
            let stale = entries.filter { $0.time < staleCut }
            guard !stale.isEmpty else { continue }
            center.removeDeliveredNotifications(withIdentifiers: stale.map(\.id))
            let rest = entries.filter { $0.time >= staleCut }
            deliveredVSCode[project] = rest.isEmpty ? nil : rest
        }
    }

    // VSCode path: alert on each attention event once it is at least attentionGrace
    // old AND still unresolved — a prompt you answered within the grace stays quiet.
    // Younger events wait for a later poll; lastVSNotify dedupes per project.
    private func processVSCodeAttention(_ events: [AwakeMonitor.VSCodeAttention]) {
        let center = UNUserNotificationCenter.current()
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
                center.removeDeliveredNotifications(withIdentifiers: hit.map(\.id))
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
        UNUserNotificationCenter.current().add(request)
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

    private func activateVSCode() {
        for id in ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"] {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.openApplication(
                    at: url, configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
    }

    // Show the banner even though AwakeBar is an accessory (LSUIElement) app, and
    // bring VSCode forward when the banner is clicked. Both are nonisolated to
    // satisfy UNUserNotificationCenterDelegate; UI work hops to the main actor.
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
