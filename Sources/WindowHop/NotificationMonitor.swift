import AppKit
import ApplicationServices

enum NotificationSwitchPreference {
    static let key = "notificationSwitchEnabled"
    static let shortcutTitle = "Command+Option+N"
    static func load(from defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: key) }
    static func save(_ enabled: Bool, to defaults: UserDefaults = .standard) { defaults.set(enabled, forKey: key) }
}

struct NotificationApp: Equatable {
    let bundleIdentifier: String
    let name: String
}

struct NotificationBanner {
    let identifier: String
    let app: NotificationApp?
}

struct NotificationTarget: Equatable {
    let app: NotificationApp
    let detectedAt: TimeInterval
}

/// Main-thread state. Only opaque banner IDs and app identities survive a scan.
struct NotificationHistory {
    static let lifetime: TimeInterval = 120
    private var seen = Set<String>()
    private var seenOrder: [String] = []
    private var seeded = false
    private(set) var target: NotificationTarget?
    private(set) var message = "Waiting for a new notification."

    mutating func ingest(_ banners: [NotificationBanner], now: TimeInterval) {
        let fresh = banners.filter { !seen.contains($0.identifier) }
        for banner in fresh where seen.insert(banner.identifier).inserted { seenOrder.append(banner.identifier) }
        if seenOrder.count > 256 {
            for id in seenOrder.prefix(seenOrder.count - 256) { seen.remove(id) }
            seenOrder = Array(seenOrder.suffix(256))
        }
        // Existing banners at enable/start are not new arrivals.
        guard seeded else { seeded = true; return }
        guard !fresh.isEmpty else { expire(now: now); return }
        let apps = Set(fresh.compactMap { $0.app?.bundleIdentifier })
        guard fresh.allSatisfy({ $0.app != nil }), apps.count == 1, let app = fresh.first?.app else {
            target = nil
            message = "The latest notification could not be matched to one running app."
            return
        }
        target = NotificationTarget(app: app, detectedAt: now)
        message = "Latest notification: \(app.name)"
    }

    mutating func expire(now: TimeInterval) {
        if let target, now - target.detectedAt >= Self.lifetime {
            self.target = nil
            message = "No notification detected in the last two minutes."
        }
    }
}

/// The source prefix is supplied by Notification Centre, not the message title.
/// Match exact app names at the prefix boundary; never search message contents.
enum NotificationSourceResolver {
    static func resolve(description: String, apps: [NotificationApp]) -> NotificationApp? {
        let matches = apps.filter { description == $0.name || description.hasPrefix($0.name + ", ") }
        let identifiers = Set(matches.map(\.bundleIdentifier))
        guard identifiers.count == 1 else { return nil }
        return matches.first
    }
}

struct NotificationScan {
    let pid: pid_t?
    /// nil means unavailable or Notification Centre is open, rather than an empty desktop.
    let banners: [NotificationBanner]?
}

/// Notification Centre's accessibility structure is undocumented. Fail closed if it changes.
struct NotificationBannerScanner {
    func scan(apps: [NotificationApp]) -> NotificationScan {
        guard let process = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else {
            return NotificationScan(pid: nil, banners: nil)
        }
        let root = AXUIElementCreateApplication(process.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.05)
        guard let expanded: Bool = axValue(root, "AXExpanded"), !expanded,
              let windows: [AXUIElement] = axValue(root, kAXWindowsAttribute) else {
            return NotificationScan(pid: process.processIdentifier, banners: nil)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        var remaining = 128
        var banners: [NotificationBanner] = []
        func visit(_ element: AXUIElement, depth: Int) -> Bool {
            guard remaining > 0, depth < 12, ProcessInfo.processInfo.systemUptime < deadline else { return false }
            remaining -= 1
            AXUIElementSetMessagingTimeout(element, 0.05)
            let subrole: String? = axValue(element, kAXSubroleAttribute)
            if subrole == "AXNotificationCenterBanner" {
                guard let identifier: String = axValue(element, kAXIdentifierAttribute), !identifier.isEmpty else { return false }
                let description: String = axValue(element, kAXDescriptionAttribute) ?? ""
                banners.append(NotificationBanner(identifier: identifier,
                    app: NotificationSourceResolver.resolve(description: description, apps: apps)))
                return true
            }
            var childrenValue: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue)
            guard result == .success || result == .noValue || result == .attributeUnsupported else { return false }
            let children = childrenValue as? [AXUIElement] ?? []
            for child in children { if !visit(child, depth: depth + 1) { return false } }
            return true
        }
        for window in windows {
            if !visit(window, depth: 0) { return NotificationScan(pid: process.processIdentifier, banners: nil) }
        }
        // Opening the drawer during a scan must not import notification history.
        guard let stillExpanded: Bool = axValue(root, "AXExpanded"), !stillExpanded else {
            return NotificationScan(pid: process.processIdentifier, banners: nil)
        }
        return NotificationScan(pid: process.processIdentifier, banners: banners)
    }
}

/// Accessibility events trigger scans; a one-second timer recovers missed events/restarts.
/// All AX reads run on a bounded background worker, never inside the keyboard callback.
final class NotificationMonitor {
    private let queue = DispatchQueue(label: "WindowHop.notifications", qos: .utility)
    private var timer: Timer?
    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var generation: UInt64 = 0
    private var scanning = false
    private var running = false
    private var history = NotificationHistory()
    var onChange: ((NotificationTarget?, String) -> Void)?
    var target: NotificationTarget? {
        history.expire(now: ProcessInfo.processInfo.systemUptime)
        return history.target
    }

    func start() {
        guard !running else { return }
        running = true
        generation &+= 1
        history = NotificationHistory()
        publish()
        requestScan()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.requestScan() }
    }

    func stop() {
        guard running else { return }
        running = false
        generation &+= 1
        timer?.invalidate(); timer = nil
        removeObserver()
        history = NotificationHistory()
        onChange?(nil, "Notification switching is off or paused.")
    }

    private func requestScan() {
        guard running, !scanning else { return }
        scanning = true
        let request = generation
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> NotificationApp? in
            guard app.activationPolicy == .regular, !app.isTerminated, app.processIdentifier != getpid(),
                  let id = app.bundleIdentifier, let name = app.localizedName, !name.isEmpty else { return nil }
            return NotificationApp(bundleIdentifier: id, name: name)
        }
        queue.async { [weak self] in
            let result = NotificationBannerScanner().scan(apps: apps)
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanning = false
                guard self.running, self.generation == request else { return }
                self.observe(pid: result.pid)
                let now = ProcessInfo.processInfo.systemUptime
                if let banners = result.banners { self.history.ingest(banners, now: now) }
                else { self.history.expire(now: now) }
                self.publish()
            }
        }
    }

    private func publish() { onChange?(history.target, history.message) }

    private func observe(pid: pid_t?) {
        guard observedPID != pid else { return }
        removeObserver()
        guard let pid else { return }
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, context in
            guard let context else { return }
            Unmanaged<NotificationMonitor>.fromOpaque(context).takeUnretainedValue().requestScan()
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.05)
        for name in [kAXLayoutChangedNotification, kAXWindowCreatedNotification] {
            AXObserverAddNotification(created, application, name as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
        observer = created
        observedPID = pid
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
    }

    private func removeObserver() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil
        observedPID = nil
    }

    deinit { timer?.invalidate(); removeObserver() }
}
