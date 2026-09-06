import AppKit
import ApplicationServices

func axValue<T>(_ element: AXUIElement, _ attribute: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value as? T
}

struct WindowRecord: Identifiable {
    let id: UUID
    let pid: pid_t
    let element: AXUIElement
    let appName: String
    let title: String
    let minimized: Bool
    let hidden: Bool
    let icon: NSImage?
    var lastUsed: UInt64
}

/// All AX calls run on this serial queue, never in the keyboard callback or UI thread.
final class WindowCatalog {
    private let queue = DispatchQueue(label: "WindowHop.accessibility", qos: .userInitiated)
    private var records: [WindowRecord] = []
    private var serial: UInt64 = 0
    private var lastFocus: UUID?
    private var observers: [pid_t: AXObserver] = [:]
    private var timer: DispatchSourceTimer?
    private let refreshLock = NSLock()
    private var refreshPending = false
    var onUpdate: (([WindowRecord], UUID?) -> Void)?

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1)
        timer.setEventHandler { [weak self] in self?.refresh() }
        self.timer = timer
        timer.resume()
    }

    func requestRefresh() {
        refreshLock.lock()
        guard !refreshPending else { refreshLock.unlock(); return }
        refreshPending = true
        refreshLock.unlock()
        queue.async {
            self.refresh()
            self.refreshLock.lock()
            self.refreshPending = false
            self.refreshLock.unlock()
        }
    }

    private func refresh() {
        guard AXIsProcessTrusted() else {
            DispatchQueue.main.async { self.onUpdate?([], nil) }
            return
        }
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != getpid() && !$0.isTerminated
        }
        let livePIDs = Set(apps.map(\.processIdentifier))
        for pid in Array(observers.keys) where !livePIDs.contains(pid) {
            if let observer = observers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
        }
        var next: [WindowRecord] = []
        var current: UUID?
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for app in apps {
            let pid = app.processIdentifier
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.15)
            observe(pid: pid, application: application)
            let windows: [AXUIElement] = axValue(application, kAXWindowsAttribute) ?? []
            let focused: AXUIElement? = pid == frontPID ? axValue(application, kAXFocusedWindowAttribute) : nil
            for window in windows {
                AXUIElementSetMessagingTimeout(window, 0.15)
                let role: String = axValue(window, kAXRoleAttribute) ?? ""
                let subrole: String = axValue(window, kAXSubroleAttribute) ?? ""
                guard role == kAXWindowRole,
                      subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole else { continue }
                let old = records.first { $0.pid == pid && CFEqual($0.element, window) }
                let id = old?.id ?? UUID()
                let title: String = axValue(window, kAXTitleAttribute) ?? ""
                var record = WindowRecord(id: id, pid: pid, element: window,
                    appName: app.localizedName ?? "App", title: title.isEmpty ? "Untitled window" : title,
                    minimized: axValue(window, kAXMinimizedAttribute) ?? false,
                    hidden: app.isHidden, icon: app.icon, lastUsed: old?.lastUsed ?? 0)
                if let focused, CFEqual(focused, window) {
                    current = id
                    if lastFocus != id { serial += 1; record.lastUsed = serial }
                }
                next.append(record)
            }
        }
        lastFocus = current
        records = next.sorted {
            if $0.lastUsed != $1.lastUsed { return $0.lastUsed > $1.lastUsed }
            let lhs = $0.appName + $0.title
            let rhs = $1.appName + $1.title
            return lhs == rhs ? $0.id.uuidString < $1.id.uuidString : lhs < rhs
        }
        let result = records
        DispatchQueue.main.async { self.onUpdate?(result, current) }
    }

    private func observe(pid: pid_t, application: AXUIElement) {
        guard observers[pid] == nil else { return }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, context in
            guard let context else { return }
            Unmanaged<WindowCatalog>.fromOpaque(context).takeUnretainedValue().requestRefresh()
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        for notification in [kAXFocusedWindowChangedNotification, kAXWindowCreatedNotification,
                             kAXApplicationActivatedNotification] {
            AXObserverAddNotification(observer, application, notification as CFString,
                Unmanaged.passUnretained(self).toOpaque())
        }
        observers[pid] = observer
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    func activate(_ record: WindowRecord, completion: @escaping (String?) -> Void) {
        queue.async {
            guard let app = NSRunningApplication(processIdentifier: record.pid), !app.isTerminated else {
                DispatchQueue.main.async { completion("That app has closed.") }; return
            }
            let minimized: Bool = axValue(record.element, kAXMinimizedAttribute) ?? false
            if minimized {
                let error = AXUIElementSetAttributeValue(record.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                guard error == .success else {
                    DispatchQueue.main.async { completion("macOS could not restore this window (\(error.rawValue)).") }; return
                }
            }
            DispatchQueue.main.async {
                app.unhide()
                app.activate(options: [.activateIgnoringOtherApps])
                // Give app activation and any Space transition a chance to begin before raising.
                self.queue.asyncAfter(deadline: .now() + 0.12) {
                    AXUIElementSetAttributeValue(record.element, kAXMainAttribute as CFString, kCFBooleanTrue)
                    let result = AXUIElementPerformAction(record.element, kAXRaiseAction as CFString)
                    DispatchQueue.main.async {
                        completion(result == .success ? nil : "This window is no longer available (\(result.rawValue)).")
                    }
                    self.refresh()
                }
            }
        }
    }
}
