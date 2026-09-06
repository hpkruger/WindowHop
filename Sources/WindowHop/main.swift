import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let catalog = WindowCatalog()
    let keyboard = KeyboardTap()
    let model = SwitcherModel()
    let setup = SetupModel()
    var panel: SwitcherPanel!
    var setupWindow: NSWindow?
    var status: NSStatusItem!
    var windows: [WindowRecord] = []
    var current: UUID?
    var session: SwitchSession<UUID>?
    var permissionTimer: Timer?
    var paused = false
    var fixtureWindows: [NSWindow] = []

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
                                     ("Settings…", #selector(showSetup), ","),
                                     ("Pause \(setup.shortcut.title)", #selector(togglePause(_:)), ""),
                                     ("Quit WindowHop", #selector(quit), "q")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self; menu.addItem(item)
        }
        status.menu = menu
        catalog.onUpdate = { [weak self] records, current in
            guard let self else { return }
            self.windows = records; self.current = current; self.setup.count = records.count
        }
        keyboard.onStep = { [weak self] backwards in self?.step(backwards: backwards) ?? false }
        keyboard.onCommit = { [weak self] in self?.commit() }
        keyboard.onCancel = { [weak self] in self?.dismiss() }
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
        setup.preview = { [weak self] in self?.preview() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(workspaceChanged),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(lockOrSleep),
            name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(lockOrSleep),
            name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        checkPermissions()
        catalog.start()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.checkPermissions() }
        if !setup.trusted || !UserDefaults.standard.bool(forKey: "hasLaunched") { showSetup() }
        UserDefaults.standard.set(true, forKey: "hasLaunched")
    }

    func checkPermissions() {
        setup.trusted = AXIsProcessTrusted()
        if setup.trusted && !paused {
            setup.keyboardReady = keyboard.start()
        } else { keyboard.stop(); setup.keyboardReady = false }
        status.menu?.items.first { $0.action == #selector(togglePause(_:)) }?.title = "\(paused ? "Resume" : "Pause") \(setup.shortcut.title)"
        status.button?.toolTip = paused ? "WindowHop — paused" : setup.keyboardReady ? "WindowHop — \(setup.shortcut.title)" : "WindowHop — Accessibility permission needed"
    }

    func step(backwards: Bool) -> Bool {
        if session == nil {
            guard !windows.isEmpty else { return false }
            model.windows = windows
            session = SwitchSession(ids: windows.map(\.id), current: current, backwards: backwards)
        } else { session?.step(backwards: backwards) }
        model.selected = session?.selected
        panel.present(count: model.windows.count)
        return true
    }

    func commit() {
        let target = model.windows.first { $0.id == session?.selected }
        dismiss()
        guard let target else { return }
        catalog.activate(target) { [weak self] error in
            if let error { self?.setup.message = error; self?.showSetup() }
        }
    }

    func dismiss() { keyboard.endGesture(); session = nil; panel?.orderOut(nil) }
    @objc func workspaceChanged() { keyboard.cancel(); catalog.requestRefresh() }
    @objc func lockOrSleep() { keyboard.cancel() }
    @objc func preview() {
        // Menu previews can be dismissed by clicking a target or opening Settings.
        dismiss()
        setupWindow?.orderOut(nil)
        if step(backwards: false) { keyboard.beginPreview() } else { showSetup() }
    }
    @objc func togglePause(_ sender: NSMenuItem) {
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
            window.contentView = NSHostingView(rootView: SetupView(model: setup))
            window.center(); setupWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        setupWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { keyboard.stop() }
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
