import AppKit
import ApplicationServices
import ScreenCaptureKit

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

/// All AX calls run on this serial queue, never in the keyboard callback or UI thread.
final class WindowCatalog {
    private let queue = DispatchQueue(label: "WindowHop.accessibility", qos: .userInitiated)
    private let previewQueue = DispatchQueue(label: "WindowHop.previews", qos: .userInitiated)
    private let reconciliationInterval: DispatchTimeInterval = .seconds(5)
    private var records: [WindowRecord] = []
    private var serial: UInt64 = 0
    private var lastFocus: UUID?
    private var observers: [pid_t: AXObserver] = [:]
    private var timer: DispatchSourceTimer?
    private let refreshLock = NSLock()
    private let previewRequestLock = NSLock()
    private var refreshPending = false
    private var refreshAgain = false
    private var iconCache: [pid_t: NSImage] = [:]
    private var previewRequestNumber: UInt64 = 0
    var onUpdate: (([WindowRecord], UUID?) -> Void)?
    var onPreviews: (([UUID: NSImage]) -> Void)?

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
            DispatchQueue.main.async { self.onUpdate?([], nil) }
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
        var current: UUID?
        var oldRecordsByElement: [CFHashCode: [WindowRecord]] = [:]
        for record in records {
            oldRecordsByElement[CFHash(record.element), default: []].append(record)
        }
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
                guard let attributes = windowAttributes(window),
                      attributes.role == kAXWindowRole,
                      attributes.subrole == kAXStandardWindowSubrole || attributes.subrole == kAXDialogSubrole else { continue }
                let old = oldRecordsByElement[CFHash(window)]?.first { CFEqual($0.element, window) }
                let id = old?.id ?? UUID()
                let title = attributes.title
                let displayTitle = title.isEmpty ? "Untitled window" : title
                var record = WindowRecord(id: id, pid: pid, element: window,
                    appName: app.localizedName ?? "App", title: displayTitle,
                    minimized: attributes.minimized,
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

    private func windowAttributes(_ element: AXUIElement) -> (role: String, subrole: String, title: String, minimized: Bool)? {
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

    /// Returns window numbers for the macOS 13 CoreGraphics fallback.
    /// Accessibility remains the source of truth for which windows are switchable.
    private func visibleWindowIDs() -> [pid_t: [(id: CGWindowID, title: String)]] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                     kCGNullWindowID) as? [[String: Any]] else { return [:] }
        var result: [pid_t: [(id: CGWindowID, title: String)]] = [:]
        for info in list {
            guard let pidNumber = info[kCGWindowOwnerPID as String] as? NSNumber,
                  let windowNumber = info[kCGWindowNumber as String] as? NSNumber,
                  let layer = info[kCGWindowLayer as String] as? NSNumber,
                  layer.intValue == 0 else { continue }
            let title = info[kCGWindowName as String] as? String ?? ""
            result[pid_t(pidNumber.int32Value), default: []].append((CGWindowID(windowNumber.uint32Value), title))
        }
        return result
    }

    private func matchingWindowID(title: String, candidates: inout [(id: CGWindowID, title: String)]) -> CGWindowID? {
        guard let match = candidates.firstIndex(where: { candidate in
            candidate.title == title || (candidate.title.isEmpty && title == "Untitled window")
        }) else { return nil }
        return candidates.remove(at: match).id
    }

    /// Captures the selected window first and publishes each thumbnail as soon as
    /// it is ready. Fresh cache entries can be excluded by the caller.
    func requestPreviews(for records: [WindowRecord], selected: UUID?, excluding cachedIDs: Set<UUID>) {
        let requestNumber = nextPreviewRequestNumber()
        var pending = records.filter { !cachedIDs.contains($0.id) && !$0.hidden && !$0.minimized }
        if let selected, let index = pending.firstIndex(where: { $0.id == selected }), index != 0 {
            pending.insert(pending.remove(at: index), at: 0)
        }
        guard !pending.isEmpty else { return }
        guard CGPreflightScreenCaptureAccess() else {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrentPreviewRequest(requestNumber) else { return }
                self.onPreviews?([:])
            }
            return
        }

        if #available(macOS 14.0, *) {
            requestScreenCaptureKitPreviews(for: pending, requestNumber: requestNumber)
        } else {
            requestLegacyPreviews(for: pending, requestNumber: requestNumber)
        }
    }

    @available(macOS 14.0, *)
    private func requestScreenCaptureKitPreviews(for records: [WindowRecord], requestNumber: UInt64) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self, self.isCurrentPreviewRequest(requestNumber) else { return }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
            var windowsByPID = Dictionary(grouping: content.windows.filter { $0.windowLayer == 0 }) {
                $0.owningApplication?.processID ?? 0
            }
            let configuration = SCStreamConfiguration()
            configuration.width = 448
            configuration.height = 296
            configuration.scalesToFit = true
            configuration.preservesAspectRatio = true
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true

            for record in records {
                guard self.isCurrentPreviewRequest(requestNumber), !Task.isCancelled,
                      var candidates = windowsByPID[record.pid],
                      let window = self.matchingWindow(title: record.title, candidates: &candidates) else { continue }
                windowsByPID[record.pid] = candidates
                let filter = SCContentFilter(desktopIndependentWindow: window)
                guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                               configuration: configuration),
                      self.isCurrentPreviewRequest(requestNumber), !Task.isCancelled else { continue }
                self.publishPreview(NSImage(cgImage: image, size: .zero), for: record.id,
                                    requestNumber: requestNumber)
            }
        }
    }

    @available(macOS 14.0, *)
    private func matchingWindow(title: String, candidates: inout [SCWindow]) -> SCWindow? {
        guard let match = candidates.firstIndex(where: { candidate in
            candidate.title == title || ((candidate.title ?? "").isEmpty && title == "Untitled window")
        }) else { return nil }
        return candidates.remove(at: match)
    }

    private func requestLegacyPreviews(for records: [WindowRecord], requestNumber: UInt64) {
        previewQueue.async {
            guard self.isCurrentPreviewRequest(requestNumber) else { return }
            var windowIDs = self.visibleWindowIDs()
            for record in records {
                guard self.isCurrentPreviewRequest(requestNumber) else { return }
                guard var candidates = windowIDs[record.pid],
                      let windowID = self.matchingWindowID(title: record.title, candidates: &candidates) else { continue }
                windowIDs[record.pid] = candidates
                guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID,
                                                          [.boundsIgnoreFraming, .nominalResolution]),
                      let preview = self.thumbnail(from: image) else { continue }
                self.publishPreview(preview, for: record.id, requestNumber: requestNumber)
            }
        }
    }

    private func publishPreview(_ preview: NSImage, for id: UUID, requestNumber: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrentPreviewRequest(requestNumber) else { return }
            self.onPreviews?([id: preview])
        }
    }

    func cancelPreviewRequests() {
        _ = nextPreviewRequestNumber()
    }

    private func nextPreviewRequestNumber() -> UInt64 {
        previewRequestLock.lock()
        previewRequestNumber &+= 1
        let number = previewRequestNumber
        previewRequestLock.unlock()
        return number
    }

    private func isCurrentPreviewRequest(_ number: UInt64) -> Bool {
        previewRequestLock.lock()
        let isCurrent = number == previewRequestNumber
        previewRequestLock.unlock()
        return isCurrent
    }

    private func thumbnail(from image: CGImage) -> NSImage? {
        let maximumPixelSize: CGFloat = 640
        let sourceSize = CGFloat(max(image.width, image.height))
        guard sourceSize > 0 else { return nil }
        let scale = min(1, maximumPixelSize / sourceSize)
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        let size = CGSize(width: width, height: height)
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        guard let scaledImage = context.makeImage() else { return nil }
        return NSImage(cgImage: scaledImage, size: size)
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
