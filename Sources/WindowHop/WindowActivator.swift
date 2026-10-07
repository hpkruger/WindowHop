import AppKit
import ApplicationServices

protocol WindowActivationDriver {
    func prepare(_ record: WindowRecord) -> String?
    func activateApplication(_ record: WindowRecord, completion: @escaping (Bool) -> Void)
    func raise(_ record: WindowRecord)
    func isFocused(_ record: WindowRecord) -> Bool
}

struct SystemWindowActivationDriver: WindowActivationDriver {
    func prepare(_ record: WindowRecord) -> String? {
        AXUIElementSetMessagingTimeout(record.element, 0.06)
        guard NSRunningApplication(processIdentifier: record.pid)?.isTerminated == false else { return "That app has closed." }
        if axValue(record.element, kAXMinimizedAttribute) == true {
            let result = AXUIElementSetAttributeValue(record.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            guard result == .success else { return "macOS could not restore this window (\(result.rawValue))." }
        }
        // Select the desired window before app activation can expose its previous window.
        raise(record)
        return nil
    }

    func activateApplication(_ record: WindowRecord, completion: @escaping (Bool) -> Void) {
        guard let app = NSRunningApplication(processIdentifier: record.pid), !app.isTerminated else {
            completion(false); return
        }
        app.unhide()
        completion(app.isActive || app.activate(options: [.activateIgnoringOtherApps]))
    }

    func raise(_ record: WindowRecord) {
        AXUIElementSetAttributeValue(record.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(record.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(record.element, kAXRaiseAction as CFString)
    }

    func isFocused(_ record: WindowRecord) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == record.pid else { return false }
        let application = AXUIElementCreateApplication(record.pid)
        AXUIElementSetMessagingTimeout(application, 0.06)
        guard let focused: AXUIElement = axValue(application, kAXFocusedWindowAttribute) else { return false }
        return CFEqual(focused, record.element)
    }
}

/// Activation never queues behind discovery. A newer request invalidates all old retries.
final class WindowActivator {
    private let queue = DispatchQueue(label: "WindowHop.activation", qos: .userInteractive)
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private let driver: WindowActivationDriver
    private let timeout: TimeInterval

    init(driver: WindowActivationDriver = SystemWindowActivationDriver(), timeout: TimeInterval = 1.5) {
        self.driver = driver
        self.timeout = timeout
    }

    func cancel() {
        lock.lock(); generation &+= 1; lock.unlock()
    }

    func activate(_ record: WindowRecord, completion: @escaping (String?) -> Void) {
        lock.lock(); generation &+= 1; let request = generation; lock.unlock()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        queue.async {
            guard self.isCurrent(request) else { return }
            if let error = self.driver.prepare(record) {
                self.complete(request, error: error, completion: completion); return
            }
            DispatchQueue.main.async {
                guard self.isCurrent(request) else { return }
                self.driver.activateApplication(record) { activated in
                    guard activated else {
                        self.complete(request, error: "macOS could not activate this app.", completion: completion); return
                    }
                    self.queue.async { self.verify(record, request: request, deadline: deadline, completion: completion) }
                }
            }
        }
    }

    private func verify(_ record: WindowRecord, request: UInt64, deadline: TimeInterval, completion: @escaping (String?) -> Void) {
        guard isCurrent(request) else { return }
        if driver.isFocused(record) { complete(request, error: nil, completion: completion); return }
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            complete(request, error: "The selected window did not receive focus.", completion: completion); return
        }
        guard isCurrent(request) else { return }
        driver.raise(record)
        queue.asyncAfter(deadline: .now() + 0.04) {
            self.verify(record, request: request, deadline: deadline, completion: completion)
        }
    }

    private func complete(_ request: UInt64, error: String?, completion: @escaping (String?) -> Void) {
        DispatchQueue.main.async {
            guard self.isCurrent(request) else { return }
            completion(error)
        }
    }

    private func isCurrent(_ request: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return request == generation
    }
}
