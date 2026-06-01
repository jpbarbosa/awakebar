import Cocoa
import ServiceManagement   // SMAppService, for the "Open at Login" toggle

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
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

    // All the "Claude is waiting / task finished / VSCode prompt" notification
    // logic lives here, lifted out of this controller.
    private let notifications = NotificationCoordinator()

    // How long a remote-controlled session may stay idle (no prompt/tool/stop
    // activity) before AwakeBar releases its remote hold and lets the Mac sleep.
    // The "Remote Idle Timeout" submenu picks from remoteIdleChoices; 0 = Off
    // (hold as long as the bridge is connected). Persisted; default 1h. AwakeBar
    // also writes the chosen window to the idle-window file so keep-awake.sh's own
    // between-turns caffeinate expires on the same window (see writeIdleWindow).
    private static let remoteIdleKey = "remoteIdleTimeoutSeconds"
    private static let remoteIdleChoices: [(label: String, seconds: TimeInterval)] =
        [("Off", 0), ("30 Minutes", 1800), ("1 Hour", 3600), ("2 Hours", 7200)]
    private var remoteIdleTimeout: TimeInterval = 3600

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Restore the persisted "Remote Idle Timeout" choice (the notification
        // settings are restored by NotificationCoordinator's own init).
        UserDefaults.standard.register(defaults: [Self.remoteIdleKey: 3600.0])
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

        // Arm the "Claude is waiting" / "task finished" watchers and authorize
        // notifications. The coordinator primes its dedup cursors first, so
        // launching AwakeBar never replays a stale alert.
        notifications.start()
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
        notifications.processSnapshot(snapshot)
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
                toFile: Contract.idleWindowFile, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(atPath: Contract.idleWindowFile)
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
            String(notifications.autoClearAlerts),
            String(notifications.notifyOnDone),
            String(notifications.attentionGrace),
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
        addToggle(to: menu, title: "Force Stay Awake", action: #selector(toggleKeepAwake),
                  on: manualKeepAwake,
                  toolTip: "Force the Mac awake until turned off, regardless of Claude or Remote Control (the display may still sleep)")

        // Notify when a task finishes — gated on how long the turn ran (real tasks
        // ping, quick replies don't), independent of which window you're in.
        addToggle(to: menu, title: "Notify When Task Finishes",
                  action: #selector(toggleNotifyOnDone), on: notifications.notifyOnDone,
                  toolTip: "Post a notification when a task (a turn longer than ~30s) finishes, whatever window you're in")

        // Withdraw a delivered "Claude is waiting" alert once that session resumes
        // after you act. On by default; turn off to keep alerts in Notification
        // Center as a record.
        addToggle(to: menu, title: "Clear Notifications When Resumed",
                  action: #selector(toggleAutoClear), on: notifications.autoClearAlerts,
                  toolTip: "Withdraw a \u{201C}Claude is waiting\u{201D} notification once that session starts running again")

        // How long a blocked session waits before alerting — answer within the
        // delay and no notification fires. A checkmark marks the active choice.
        addChoiceSubmenu(to: menu, title: "Notification Delay", action: #selector(setGrace(_:)),
                         choices: NotificationCoordinator.graceChoices.map {
                             (label: "\(Int($0)) Seconds", tag: Int($0)) },
                         selected: Int(notifications.attentionGrace))

        // How long a remote session may idle before the Mac is allowed to sleep —
        // a turn or prompt resets the timer. A checkmark marks the active choice.
        addChoiceSubmenu(to: menu, title: "Remote Idle Timeout",
                         action: #selector(setRemoteIdle(_:)),
                         choices: Self.remoteIdleChoices.map {
                             (label: $0.label, tag: Int($0.seconds)) },
                         selected: Int(remoteIdleTimeout),
                         toolTip: "Let the Mac sleep after this long with no activity on a remote-controlled session (a turn resets the timer). Off keeps it awake as long as the bridge is connected.")

        addToggle(to: menu, title: "Open at Login", action: #selector(toggleLogin),
                  on: SMAppService.mainApp.status == .enabled)

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

    // A checkmarked toggle row wired to `action`, the checkmark sharing the
    // leading slot — the shape every main-menu toggle uses.
    private func addToggle(to menu: NSMenu, title: String, action: Selector,
                           on: Bool, toolTip: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if !toolTip.isEmpty { item.toolTip = toolTip }
        item.image = checkmarkSlot(on)
        menu.addItem(item)
    }

    // A submenu of mutually-exclusive choices, each tagged with its integer value
    // and checkmarked when it is the active one. Used by Notification Delay and
    // Remote Idle Timeout.
    private func addChoiceSubmenu(to menu: NSMenu, title: String, action: Selector,
                                  choices: [(label: String, tag: Int)], selected: Int,
                                  toolTip: String = "") {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if !toolTip.isEmpty { parent.toolTip = toolTip }
        let sub = NSMenu()
        sub.autoenablesItems = false
        for choice in choices {
            let item = NSMenuItem(title: choice.label, action: action, keyEquivalent: "")
            item.target = self
            item.tag = choice.tag
            item.state = choice.tag == selected ? .on : .off
            sub.addItem(item)
        }
        parent.submenu = sub
        parent.image = spacerSlot()
        menu.addItem(parent)
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

    // Notification settings live on the coordinator; these menu actions forward to
    // it and re-render. setGrace only re-renders when the value actually changed.
    @objc private func toggleAutoClear() {
        notifications.toggleAutoClear()
        render()
    }

    @objc private func toggleNotifyOnDone() {
        notifications.toggleNotifyOnDone()
        render()
    }

    @objc private func setGrace(_ sender: NSMenuItem) {
        if notifications.setGrace(TimeInterval(sender.tag)) { render() }
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
}
