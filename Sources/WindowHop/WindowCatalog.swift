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
    private let reconciliationInterval: DispatchTimeInterval = .seconds(5)
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
        // Accessibility calls can block while an app is busy. A one-second full
        // scan keeps every process hot even when nothing on the desktop changes.
        // Notifications still request an immediate reconciliation for interactive
        // changes; this timer is only the periodic safety net.
        timer.schedule(deadline: .now(), repeating: reconciliationInterval, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.requestRefresh() }
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
        var oldRecordsByElement: [CFHashCode: [WindowRecord]] = [:]
        for record in records {
            oldRecordsByElement[CFHash(record.element), default: []].append(record)
        }
        var iconCache: [pid_t: NSImage] = [:]
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for app in apps {
            let pid = app.processIdentifier
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.15)
            observe(pid: pid, application: application)
            let windows: [AXUIElement] = axValue(application, kAXWindowsAttribute) ?? []
            let focused: AXUIElement? = pid == frontPID ? axValue(application, kAXFocusedWindowAttribute) : nil
            let icon = iconCache[pid] ?? app.icon
            if let icon { iconCache[pid] = icon }
            for window in windows {
                AXUIElementSetMessagingTimeout(window, 0.15)
                let role: String = axValue(window, kAXRoleAttribute) ?? ""
                let subrole: String = axValue(window, kAXSubroleAttribute) ?? ""
                guard role == kAXWindowRole,
                      subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole else { continue }
                let old = oldRecordsByElement[CFHash(window)]?.first { CFEqual($0.element, window) }
                let id = old?.id ?? UUID()
                let title: String = axValue(window, kAXTitleAttribute) ?? ""
                var record = WindowRecord(id: id, pid: pid, element: window,
                    appName: app.localizedName ?? "App", title: title.isEmpty ? "Untitled window" : title,
                    minimized: axValue(window, kAXMinimizedAttribute) ?? false,
                    hidden: app.isHidden, icon: icon, lastUsed: old?.lastUsed ?? 0)
                if let focused, CFEqual(focused, window) {
                    current = id
                    if lastFocus != id { serial += 1; record.lastUsed = serial }
                }
                next.append(record)
            }
        }
        let focusChanged = current != lastFocus
        lastFocus = current
        let sorted = next.sorted {
            if $0.lastUsed != $1.lastUsed { return $0.lastUsed > $1.lastUsed }
            let lhs = $0.appName + $0.title
            let rhs = $1.appName + $1.title
            return lhs == rhs ? $0.id.uuidString < $1.id.uuidString : lhs < rhs
        }
        let changed = focusChanged || !sameCatalog(records, sorted)
        records = sorted
        let result = records
        guard changed else { return }
        DispatchQueue.main.async { self.onUpdate?(result, current) }
    }

    private func sameCatalog(_ lhs: [WindowRecord], _ rhs: [WindowRecord]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            left.id == right.id && left.pid == right.pid &&
            left.appName == right.appName && left.title == right.title &&
            left.minimized == right.minimized && left.hidden == right.hidden
        }
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
