import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let catalog = WindowCatalog()
    let keyboard = KeyboardTap()
    let activator = WindowActivator()
    let notificationMonitor = NotificationMonitor()
    private var sessionInactive = false
    private var switchState = WindowSwitchState<AXUIElement>()
    private var windowIndices: [AXUIElement: Int] = [:]
    private var undiscoveredFocus: [AXUIElement] = []
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
    private var previewCache = WindowPreviewCache()
    private let previewLoader = WindowPreviewLoader()

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
            self.updateWindowHistory(records)
            self.setup.count = self.availableWindows.count
            self.previewCache.reconcile(records)
            let livePIDs = Set(records.map(\.pid))
            self.focusQueues = self.focusQueues.filter { livePIDs.contains($0.key) }
            self.sampleFocus()
            self.refreshVisibility()
        }
        catalog.onFocusEvent = { [weak self] element, pid in
            guard let self, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            self.focusRequest &+= 1
            if let element, element != AXUIElementCreateApplication(pid) {
                self.observeFocus(element)
                if self.currentWindow != nil { return }
            } else {
                self.switchState.observe(nil)
            }
            self.sampleFocus()
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
            self.dismiss()
            if !enabled { self.previewCache = WindowPreviewCache() }
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

    func step(backwards: Bool, fromMenu: Bool = false) -> Bool {
        if session == nil {
            let available = availableWindows
            guard !available.isEmpty else { return false }
            model.windows = available
            model.openedFromMenu = fromMenu
            session = SwitchSession(ids: available.map(\.id), current: currentWindow?.id, backwards: backwards,
                                    frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
            if model.showPreviews {
                let previews = previewCache.previews(for: available)
                model.previews = previews.display
                previewLoader.start(previews.pending, selected: session?.selected) { [weak self] window, image in
                    guard let self else { return }
                    if let image {
                        self.previewCache.store(image, for: window)
                        self.model.previews[window.id] = .image(image)
                    } else if self.model.previews[window.id] == nil {
                        self.model.previews[window.id] = .unavailable
                    }
                }
            }
        } else {
            session?.step(backwards: backwards)
            if model.showPreviews { previewLoader.selected = session?.selected }
        }
        model.selected = session?.selected
        panel.present(showPreviews: model.showPreviews)
        return true
    }

    func commit(frontmostPID: pid_t? = NSWorkspace.shared.frontmostApplication?.processIdentifier) {
        validateSession(frontmostPID: frontmostPID)
        guard let selected = session?.selected else { return }
        dismiss()
        guard let target = windows.first(where: { $0.id == selected }) else { return }
        activateWindow(target)
    }

    private func activateWindow(_ target: WindowRecord) {
        // Commit intent synchronously, before any AX work, for rapid A → B → A.
        let revision = switchState.beginActivation(target.element)
        activationPIDs.insert(target.pid)
        activator.activate(target) { [weak self] error in
            guard let self, self.switchState.finishActivation(revision: revision, succeeded: error == nil) else { return }
            self.activationPIDs.removeAll()
            if let error {
                self.checkPermissions()
                self.setup.message = error
            } else if self.session != nil, NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid {
                // Verification may precede the workspace notification during a rapid switch.
                self.session?.frontmostPID = target.pid
            }
            self.sampleFocus()
            self.catalog.requestRefresh()
        }
    }

    func dismiss() {
        keyboard.endGesture()
        previewLoader.cancel()
        session = nil
        panel?.orderOut(nil)
        model.previews.removeAll()
    }
    @objc func workspaceChanged(_ notification: Notification) {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let announced = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           announced.processIdentifier != pid { return }
        applicationActivated(pid)
        sampleFocus()
        catalog.requestRefresh()
    }

    func applicationActivated(_ pid: pid_t?) {
        validateSession(frontmostPID: pid)
        if !activationPIDs.contains(pid ?? 0), currentWindow?.pid != pid {
            cancelActivation()
            switchState.observe(nil)
        }
    }

    // AX focus and workspace activation can arrive in either order. Compare
    // against the app that owned the gesture, independently of the MRU list.
    private func validateSession(frontmostPID pid: pid_t?) {
        guard let session else { return }
        if let pid, activationPIDs.contains(pid) {
            self.session?.frontmostPID = pid
        } else if session.frontmostPID != pid {
            dismiss()
            cancelActivation()
        }
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
        // An explicit app jump uses its most recent window even on another Space.
        if let window = orderedWindows.first(where: { $0.pid == app.processIdentifier }) {
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

    func updateWindowHistory(_ records: [WindowRecord]) {
        windows = records
        windowIndices.removeAll(keepingCapacity: true)
        for index in records.indices { windowIndices[records[index].element] = index }
        undiscoveredFocus.removeAll { windowIndices[$0] != nil }
        switchState.reconcile(records.map(\.element) + undiscoveredFocus)
    }

    func observeFocus(_ element: AXUIElement) {
        switchState.observe(element)
        if switchState.pending == nil, currentWindow == nil {
            // A focus event may beat several scans. Keep its place until the AX
            // window appears, bounding references to elements that never qualify.
            undiscoveredFocus.removeAll { $0 == element }
            undiscoveredFocus.append(element)
            if undiscoveredFocus.count > 32 { undiscoveredFocus.removeFirst() }
        }
    }

    var currentWindow: WindowRecord? {
        guard let current = switchState.current, let index = windowIndices[current] else { return nil }
        return windows[index]
    }

    private var orderedWindows: [WindowRecord] {
        switchState.order.compactMap { windowIndices[$0] }.map { windows[$0] }
    }

    var availableWindows: [WindowRecord] {
        orderedWindows.filter {
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
                if let focused { self.observeFocus(focused) }
            }
        }
    }
    @objc func preview() {
        // Menu previews can be dismissed by clicking a target or opening Settings.
        dismiss()
        setupWindow?.orderOut(nil)
        if step(backwards: false, fromMenu: true) { keyboard.beginPreview() } else { checkPermissions() }
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
