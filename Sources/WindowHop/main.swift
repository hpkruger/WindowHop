import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private struct CachedPreview {
        let image: NSImage
        let title: String
        let capturedAt: Date
    }

    let catalog = WindowCatalog()
    let keyboard = KeyboardTap()
    let activator = WindowActivator()
    let notificationMonitor = NotificationMonitor()
    private var sessionInactive = false
    var switchState = WindowSwitchState<UUID>()
    private var activationPIDs = Set<pid_t>()
    private var focusRequest: UInt64 = 0
    private var focusQueues: [pid_t: DispatchQueue] = [:]
    private let visibilityQueue = DispatchQueue(label: "WindowHop.visibility", qos: .userInteractive)
    private var visibilityRequest: UInt64 = 0
    let model = SwitcherModel()
    let setup = SetupModel()
    var panel: SwitcherPanel!
    var setupWindow: NSWindow?
    var status: NSStatusItem!
    var windows: [WindowRecord] = []
    var session: SwitchSession<UUID>?
    var permissionTimer: Timer?
    var paused = false
    private var permissionProblemReported = false
    var fixtureWindows: [NSWindow] = []
    private var previewCache: [UUID: CachedPreview] = [:]
    private let previewCacheLifetime: TimeInterval = 10
    private let previewCacheLimit = 24

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--fixture") { launchFixture(); return }
        NSApp.setActivationPolicy(.accessory)
        keyboard.shortcut = setup.shortcut
        model.shortcut = setup.shortcut
        panel = SwitcherPanel(model: model)
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "WindowHop")
        let menu = NSMenu()
        for (title, action, key) in [("Show Windows", #selector(preview), ""),
                                     ("Switch to Notifying App", #selector(switchToNotifyingApp), ""),
                                     ("Settings…", #selector(showSetup), ","),
                                     ("Pause \(setup.shortcut.title)", #selector(togglePause(_:)), ""),
                                     ("Quit WindowHop", #selector(quit), "q")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self; menu.addItem(item)
        }
        status.menu = menu
        catalog.onUpdate = { [weak self] records in
            guard let self else { return }
            self.windows = records
            self.switchState.reconcile(records.map(\.id))
            self.setup.count = self.availableWindows.count
            let liveIDs = Set(records.map(\.id))
            self.previewCache = self.previewCache.filter { liveIDs.contains($0.key) }
            let livePIDs = Set(records.map(\.pid))
            self.focusQueues = self.focusQueues.filter { livePIDs.contains($0.key) }
            self.sampleFocus()
            self.refreshVisibility()
        }
        catalog.onFocusEvent = { [weak self] element, pid in
            guard let self, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            if let element, let window = self.windows.first(where: { $0.pid == pid && CFEqual($0.element, element) }) {
                self.focusRequest &+= 1
                self.switchState.observe(window.id)
            } else {
                // Until the focused-window query returns, the first MRU entry is
                // the previous window, not a reliable description of the current one.
                self.switchState.observe(nil)
                self.sampleFocus()
            }
        }
        catalog.onPreviews = { [weak self] previews in
            guard let self, self.setup.showPreviews else { return }
            let capturedAt = Date()
            for (id, image) in previews {
                guard let window = self.model.windows.first(where: { $0.id == id }) else { continue }
                self.previewCache[id] = CachedPreview(image: image, title: window.title, capturedAt: capturedAt)
            }
            self.trimPreviewCache()
            self.model.previews.merge(previews) { _, latest in latest }
        }
        keyboard.onStep = { [weak self] backwards in self?.step(backwards: backwards) ?? false }
        keyboard.onCommit = { [weak self] in self?.commit() }
        keyboard.onCancel = { [weak self] in self?.dismiss() }
        keyboard.onExternalInteraction = { [weak self] in self?.cancelActivation() }
        keyboard.onNotificationSwitch = { [weak self] in self?.switchToNotifyingApp() }
        notificationMonitor.onChange = { [weak self] target, message in
            guard let self else { return }
            self.setup.notificationStatus = message
            self.status.menu?.items.first { $0.action == #selector(self.switchToNotifyingApp) }?.title =
                target.map { "Switch to \($0.app.name) (\(NotificationSwitchPreference.shortcutTitle))" } ?? "Switch to Notifying App"
        }
        setup.notificationSwitchChanged = { [weak self] enabled in
            NotificationSwitchPreference.save(enabled)
            self?.updateNotificationMonitoring()
        }
        keyboard.pointerIsInside = { [weak self] point in
            guard let self, self.panel.isVisible else { return false }
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            return self.panel.frame.contains(CGPoint(x: point.x, y: top - point.y))
        }
        model.choose = { [weak self] id in self?.session?.select(id); self?.commit() }
        setup.openSettings = {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
        setup.retry = { [weak self] in self?.checkPermissions(); self?.catalog.requestRefresh() }
        setup.shortcutChanged = { [weak self] shortcut in
            guard let self else { return }
            self.keyboard.shortcut = shortcut
            self.model.shortcut = shortcut
            shortcut.save()
            self.checkPermissions()
        }
        setup.previewsChanged = { [weak self] enabled in
            guard let self else { return }
            WindowPreviewPreference.save(enabled)
            self.model.showPreviews = enabled
            self.model.previews.removeAll()
            if !enabled {
                self.previewCache.removeAll()
                self.catalog.cancelPreviewRequests()
            }
        }
        setup.openScreenRecordingSettings = {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
        setup.scopeChanged = { [weak self] scope in
            guard let self else { return }
            scope.save()
            self.dismiss()
            self.setup.count = self.availableWindows.count
            self.catalog.requestRefresh()
        }
        setup.preview = { [weak self] in self?.preview() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(workspaceChanged),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(lockOrSleep),
            name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(lockOrSleep),
            name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sessionResumed),
            name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sessionResumed),
            name: NSWorkspace.didWakeNotification, object: nil)
        checkPermissions()
        catalog.start()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.checkPermissions() }
    }

    func checkPermissions() {
        setup.trusted = AXIsProcessTrusted()
        if setup.trusted && !paused {
            setup.keyboardReady = keyboard.start()
        } else { keyboard.stop(); setup.keyboardReady = false }
        updateNotificationMonitoring()
        status.menu?.items.first { $0.action == #selector(togglePause(_:)) }?.title = "\(paused ? "Resume" : "Pause") \(setup.shortcut.title)"
        // Native status-item tooltips can linger over unrelated apps. Keep this
        // information in accessibility help and the menu without a hover popup.
        status.button?.toolTip = nil
        status.button?.setAccessibilityHelp(paused ? "WindowHop — paused" : setup.keyboardReady ? "WindowHop — \(setup.shortcut.title)" : "WindowHop — Accessibility permission needed")
        let permissionProblem = !setup.trusted || (!paused && !setup.keyboardReady)
        setup.message = !setup.trusted ? "Enable Accessibility access for WindowHop."
            : permissionProblem ? "WindowHop could not start its keyboard shortcut. Check Accessibility access, then quit and reopen WindowHop." : ""
        // Report once per permission failure, so dismissing Settings keeps it
        // dismissed until access recovers and a new failure occurs.
        let shouldShow = permissionProblem && !permissionProblemReported
        permissionProblemReported = permissionProblem
        if shouldShow { showSetup() }
    }

    func step(backwards: Bool) -> Bool {
        var startedSession = false
        if session == nil {
            let available = availableWindows
            guard !available.isEmpty else { return false }
            model.windows = available
            model.previews = model.showPreviews ? cachedPreviews(for: available) : [:]
            session = SwitchSession(ids: available.map(\.id), current: switchState.current, backwards: backwards)
            startedSession = true
        } else { session?.step(backwards: backwards) }
        model.selected = session?.selected
        panel.present(showPreviews: model.showPreviews)
        if model.showPreviews && startedSession {
            catalog.requestPreviews(for: model.windows, selected: model.selected,
                                    excluding: Set(model.previews.keys))
        }
        return true
    }

    func commit() {
        let target = model.windows.first { $0.id == session?.selected }
        dismiss()
        guard let target else { return }
        activateWindow(target)
    }

    private func activateWindow(_ target: WindowRecord) {
        // Commit intent synchronously, before any AX work, for rapid A → B → A.
        let revision = switchState.beginActivation(target.id)
        activationPIDs.insert(target.pid)
        activator.activate(target) { [weak self] error in
            guard let self, self.switchState.finishActivation(revision: revision, succeeded: error == nil) else { return }
            self.activationPIDs.removeAll()
            if let error {
                self.checkPermissions()
                self.setup.message = error
            }
            self.sampleFocus()
            self.catalog.requestRefresh()
        }
    }

    func dismiss() {
        keyboard.endGesture()
        catalog.cancelPreviewRequests()
        session = nil
        panel?.orderOut(nil)
        model.previews.removeAll()
    }
    @objc func workspaceChanged(_ notification: Notification) {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let announced = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           announced.processIdentifier != pid { return }
        // App activation from our previous commit must not dismiss the next gesture.
        let currentPID = windows.first { $0.id == switchState.current }?.pid
        if !activationPIDs.contains(pid ?? 0) && currentPID != pid {
            cancelActivation()
            keyboard.cancel()
            switchState.observe(nil)
        }
        sampleFocus()
        catalog.requestRefresh()
    }
    @objc func spaceChanged() {
        if switchState.pending == nil { keyboard.cancel() }
        refreshVisibility()
        catalog.requestRefresh()
        sampleFocus()
    }
    @objc func lockOrSleep() {
        cancelActivation(); keyboard.cancel()
        sessionInactive = true
        updateNotificationMonitoring()
    }
    @objc func sessionResumed() {
        sessionInactive = false
        updateNotificationMonitoring()
    }

    private func updateNotificationMonitoring() {
        let enabled = setup.notificationSwitchEnabled && setup.trusted && !paused && !sessionInactive
        keyboard.notificationSwitchEnabled = enabled
        if enabled { notificationMonitor.start() } else { notificationMonitor.stop() }
        status.menu?.items.first { $0.action == #selector(switchToNotifyingApp) }?.isHidden = !setup.notificationSwitchEnabled
    }

    @objc func switchToNotifyingApp() {
        guard keyboard.notificationSwitchEnabled else { return }
        cancelActivation()
        dismiss()
        guard let target = notificationMonitor.target else {
            setup.notificationStatus = "No recent notification could be matched to a running app."
            NSSound.beep()
            return
        }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: target.app.bundleIdentifier)
            .filter { !$0.isTerminated && $0.activationPolicy == .regular }
        // Multiple instances of the same bundle cannot be distinguished by a banner.
        guard apps.count == 1, let app = apps.first else {
            setup.notificationStatus = "The notifying app has closed or has multiple running instances."
            NSSound.beep()
            return
        }
        let records = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        // An explicit app jump uses its most recent window even on another Space.
        if let window = switchState.order.compactMap({ records[$0] }).first(where: { $0.pid == app.processIdentifier }) {
            activateWindow(window)
        } else {
            app.unhide()
            if !app.activate(options: [.activateIgnoringOtherApps]) {
                setup.notificationStatus = "macOS could not activate \(target.app.name)."
                NSSound.beep()
            }
            catalog.requestRefresh()
        }
    }

    private var availableWindows: [WindowRecord] {
        let byID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        return switchState.order.compactMap { byID[$0] }.filter {
            setup.scope.includes(onScreen: $0.onScreen, minimized: $0.minimized, hidden: $0.hidden)
        }
    }

    private func refreshVisibility() {
        visibilityRequest &+= 1
        let request = visibilityRequest
        visibilityQueue.async { [weak self] in
            let snapshot = WindowServerSnapshot.capture()
            let visibility = Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.number, $0.onScreen) })
            DispatchQueue.main.async { [weak self] in
                guard let self, self.visibilityRequest == request else { return }
                for index in self.windows.indices {
                    self.windows[index].onScreen = self.windows[index].windowNumber.flatMap { visibility[$0] }
                }
                self.setup.count = self.availableWindows.count
            }
        }
    }

    private func cancelActivation() {
        guard switchState.pending != nil else { return }
        activator.cancel()
        _ = switchState.finishActivation(revision: switchState.revision, succeeded: false)
        activationPIDs.removeAll()
        sampleFocus()
    }

    /// Per-app queues mean a hung background app cannot delay focus tracking elsewhere.
    private func sampleFocus() {
        guard switchState.pending == nil else { return }
        focusRequest &+= 1
        let request = focusRequest
        let revision = switchState.revision
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, pid != getpid() else {
            switchState.observe(nil); return
        }
        let queue = focusQueues[pid] ?? DispatchQueue(label: "WindowHop.focus.\(pid)", qos: .userInteractive)
        focusQueues[pid] = queue
        queue.async { [weak self] in
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.06)
            let focused: AXUIElement? = axValue(application, kAXFocusedWindowAttribute)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.focusRequest == request, self.switchState.revision == revision,
                      self.switchState.pending == nil,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                if let focused, let record = self.windows.first(where: { $0.pid == pid && CFEqual($0.element, focused) }) {
                    self.switchState.observe(record.id)
                } else if focused != nil {
                    self.switchState.observe(nil)
                }
            }
        }
    }
    @objc func preview() {
        // Menu previews can be dismissed by clicking a target or opening Settings.
        dismiss()
        setupWindow?.orderOut(nil)
        if step(backwards: false) { keyboard.beginPreview() } else { checkPermissions() }
    }
    @objc func togglePause(_ sender: NSMenuItem) {
        cancelActivation()
        paused.toggle()
        checkPermissions()
    }
    @objc func showSetup() {
        dismiss()
        if setupWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 570, height: 580),
                styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "WindowHop Settings"
            window.isReleasedWhenClosed = false
            let content = SetupView(model: setup)
            let idealHeight = NSHostingView(rootView: content).fittingSize.height
            let availableHeight = max(400, (NSScreen.main?.visibleFrame.height ?? 900) - 80)
            window.contentView = NSHostingView(rootView: ScrollView { content }
                .frame(width: 510, height: min(idealHeight, availableHeight)))
            window.center(); setupWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        setupWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { notificationMonitor.stop(); activator.cancel(); keyboard.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !CommandLine.arguments.contains("--fixture"), panel?.isVisible != true { showSetup() }
        return true
    }

    private func cachedPreviews(for windows: [WindowRecord]) -> [UUID: NSImage] {
        let cutoff = Date().addingTimeInterval(-previewCacheLifetime)
        let titles = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.title) })
        previewCache = previewCache.filter { id, entry in
            entry.capturedAt >= cutoff && titles[id] == entry.title
        }
        return previewCache.mapValues(\.image)
    }

    private func trimPreviewCache() {
        guard previewCache.count > previewCacheLimit else { return }
        let excess = previewCache.count - previewCacheLimit
        for id in previewCache.sorted(by: { $0.value.capturedAt < $1.value.capturedAt }).prefix(excess).map(\.key) {
            previewCache.removeValue(forKey: id)
        }
    }

    private func launchFixture() {
        NSApp.setActivationPolicy(.regular)
        for index in 1...3 {
            let window = NSWindow(contentRect: NSRect(x: 160 + index * 60, y: 200 + index * 45, width: 500, height: 260),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "WindowHop Test Window \(index)"
            window.isReleasedWhenClosed = false
            let label = NSTextField(labelWithString: "Test window \(index)\nUse Option+Tab to switch between these windows.")
            label.font = .systemFont(ofSize: 22); label.frame = NSRect(x: 30, y: 80, width: 450, height: 100)
            window.contentView?.addSubview(label)
            fixtureWindows.append(window); window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
