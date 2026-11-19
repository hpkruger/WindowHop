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
    var windowNumber: CGWindowID?
    var onScreen: Bool?

    init(id: UUID, pid: pid_t, element: AXUIElement,
         appName: String, title: String, minimized: Bool, hidden: Bool,
         icon: NSImage?, lastUsed: UInt64) {
        self.id = id
        self.pid = pid
        self.element = element
        self.appName = appName
        self.title = title
        self.minimized = minimized
        self.hidden = hidden
        self.icon = icon
        self.lastUsed = lastUsed
    }
}

/// Discovery runs independently of focus tracking and activation.
final class WindowCatalog {
    private let queue = DispatchQueue(label: "WindowHop.accessibility", qos: .userInitiated)
    private let reconciliationInterval: DispatchTimeInterval = .seconds(5)
    private var records: [WindowRecord] = []
    private var observers: [pid_t: AXObserver] = [:]
    private var timer: DispatchSourceTimer?
    private let refreshLock = NSLock()
    private var refreshPending = false
    private var refreshAgain = false
    private var iconCache: [pid_t: NSImage] = [:]
    var onUpdate: (([WindowRecord]) -> Void)?
    // nil invalidates cached focus while a newly created window is being discovered.
    var onFocusEvent: ((AXUIElement?, pid_t) -> Void)?

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Accessibility calls can block while an app is busy. A five-second full
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
        if refreshPending {
            refreshAgain = true
            refreshLock.unlock()
            return
        }
        refreshPending = true
        refreshLock.unlock()
        queue.async {
            while true {
                self.refresh()
                self.refreshLock.lock()
                if self.refreshAgain {
                    self.refreshAgain = false
                    self.refreshLock.unlock()
                    continue
                }
                self.refreshPending = false
                self.refreshLock.unlock()
                return
            }
        }
    }

    private func refresh() {
        guard AXIsProcessTrusted() else {
            DispatchQueue.main.async { self.onUpdate?([]) }
            return
        }
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != getpid() && !$0.isTerminated
        }
        let livePIDs = Set(apps.map(\.processIdentifier))
        iconCache = iconCache.filter { livePIDs.contains($0.key) }
        for pid in Array(observers.keys) where !livePIDs.contains(pid) {
            if let observer = observers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
        }
        var next: [WindowRecord] = []
        let snapshot = WindowServerSnapshot.capture()
        var oldRecordsByElement: [CFHashCode: [WindowRecord]] = [:]
        for record in records {
            oldRecordsByElement[CFHash(record.element), default: []].append(record)
        }
        for app in apps {
            let pid = app.processIdentifier
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.15)
            observe(pid: pid, application: application)
            guard let windows: [AXUIElement] = axValue(application, kAXWindowsAttribute) else {
                // A transient AX timeout is not evidence that every window has closed.
                next.append(contentsOf: records.filter { $0.pid == pid })
                continue
            }
            let icon = iconCache[pid] ?? app.icon
            if let icon { iconCache[pid] = icon }
            for window in windows {
                AXUIElementSetMessagingTimeout(window, 0.15)
                let old = oldRecordsByElement[CFHash(window)]?.first { CFEqual($0.element, window) }
                let attributes = windowAttributes(window)
                guard let switchable = Self.isSwitchableWindow(role: attributes.role, subrole: attributes.subrole) else {
                    if let old { next.append(old) }
                    continue
                }
                guard switchable else { continue }
                let id = old?.id ?? UUID()
                let title = attributes.title
                let displayTitle = title.isEmpty ? "Untitled window" : title
                var record = WindowRecord(id: id, pid: pid, element: window,
                    appName: app.localizedName ?? "App", title: displayTitle,
                    minimized: attributes.minimized,
                    hidden: app.isHidden, icon: icon, lastUsed: old?.lastUsed ?? 0)
                let serverWindow = snapshot.match(pid: pid, title: title, bounds: windowBounds(window),
                                                  previousNumber: old?.windowNumber)
                record.windowNumber = serverWindow?.number
                record.onScreen = serverWindow?.onScreen
                next.append(record)
            }
        }
        let ranks = Dictionary(uniqueKeysWithValues: snapshot.entries.enumerated().map { ($0.element.number, $0.offset) })
        let previousRanks = Dictionary(uniqueKeysWithValues: records.enumerated().map { ($0.element.id, $0.offset) })
        records = next.sorted {
            let lhs = $0.windowNumber.flatMap { ranks[$0] } ?? Int.max
            let rhs = $1.windowNumber.flatMap { ranks[$0] } ?? Int.max
            if lhs != rhs { return lhs < rhs }
            return (previousRanks[$0.id] ?? Int.max) < (previousRanks[$1.id] ?? Int.max)
        }
        let result = records
        DispatchQueue.main.async { self.onUpdate?(result) }
    }

    private func windowBounds(_ element: AXUIElement) -> CGRect? {
        guard let position: AXValue = axValue(element, kAXPositionAttribute),
              let size: AXValue = axValue(element, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    // nil keeps the previous record until a scan can classify the window.
    static func isSwitchableWindow(role: String, subrole: String) -> Bool? {
        guard !role.isEmpty else { return nil }
        guard role == kAXWindowRole else { return false }
        guard !subrole.isEmpty else { return nil }
        return subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole
    }

    private func windowAttributes(_ element: AXUIElement) -> (role: String, subrole: String, title: String, minimized: Bool) {
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXMinimizedAttribute] as CFArray
        var copiedValues: CFArray?
        if AXUIElementCopyMultipleAttributeValues(element, names, [], &copiedValues) == .success,
           let values = copiedValues as? [Any], values.count == 4 {
            return (values[0] as? String ?? "", values[1] as? String ?? "",
                    values[2] as? String ?? "", values[3] as? Bool ?? false)
        }
        // Keep compatibility with apps that expose AX attributes but do not
        // implement the multiple-value API correctly.
        return (axValue(element, kAXRoleAttribute) ?? "",
                axValue(element, kAXSubroleAttribute) ?? "",
                axValue(element, kAXTitleAttribute) ?? "",
                axValue(element, kAXMinimizedAttribute) ?? false)
    }

    private func observe(pid: pid_t, application: AXUIElement) {
        guard observers[pid] == nil else { return }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, context in
            guard let context else { return }
            let catalog = Unmanaged<WindowCatalog>.fromOpaque(context).takeUnretainedValue()
            catalog.handleNotification(notification as String, element: element,
                                       refresh: catalog.requestRefresh)
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

    func handleNotification(_ notification: String, element: AXUIElement, refresh: () -> Void) {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        switch notification {
        case kAXWindowCreatedNotification:
            // Detaching a browser tab can create a focused window before discovery
            // finishes, without activating a different app. Do not keep treating the
            // original window as current: a quick switch would skip over it.
            // Creation alone does not prove focus, so resample rather than promote it.
            onFocusEvent?(nil, pid)
            refresh()
        case kAXFocusedWindowChangedNotification, kAXApplicationActivatedNotification:
            onFocusEvent?(element, pid)
        default:
            refresh()
        }
    }

}
