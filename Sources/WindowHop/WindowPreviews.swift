import AppKit
import ScreenCaptureKit

enum WindowPreview {
    case image(NSImage)
    case unavailable
}

struct WindowPreviewCache {
    private struct Entry {
        let image: NSImage
        let title: String
        let capturedAt: Date
    }

    private var entries: [UUID: Entry] = [:]

    mutating func store(_ image: NSImage, for window: WindowRecord, at date: Date = Date()) {
        entries[window.id] = Entry(image: image, title: window.title, capturedAt: date)
        if entries.count > 24, let oldest = entries.min(by: { $0.value.capturedAt < $1.value.capturedAt }) {
            entries.removeValue(forKey: oldest.key)
        }
    }

    mutating func reconcile(_ windows: [WindowRecord]) {
        let titles = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.title) })
        entries = entries.filter { titles[$0.key] == $0.value.title }
    }

    func previews(for windows: [WindowRecord], at date: Date = Date())
        -> (display: [UUID: WindowPreview], pending: [WindowRecord]) {
        var display: [UUID: WindowPreview] = [:]
        var pending: [WindowRecord] = []
        let cutoff = date.addingTimeInterval(-10)
        for window in windows {
            if let entry = entries[window.id], entry.title == window.title {
                display[window.id] = .image(entry.image)
                if entry.capturedAt >= cutoff { continue }
            }
            if !window.minimized && !window.hidden { pending.append(window) }
        }
        return (display, pending)
    }
}

/// The picker owns the queue on the main thread. The async capture functions do the
/// permission check, enumeration and image work on the background executor.
final class WindowPreviewLoader {
    typealias Capture = (WindowRecord) async -> NSImage?
    private let prepare: () async -> Capture?
    private var task: Task<Void, Never>?
    private var pending: [WindowRecord] = []
    var selected: UUID?

    init(prepare: @escaping () async -> Capture? = SystemWindowPreviews.prepare) {
        self.prepare = prepare
    }

    func start(_ windows: [WindowRecord], selected: UUID?, publish: @escaping (WindowRecord, NSImage?) -> Void) {
        cancel()
        guard !windows.isEmpty else { return }
        pending = windows.reversed()
        self.selected = selected
        let previous = task
        task = Task { @MainActor in
            // A canceled system screenshot may still be finishing when the picker reopens.
            await previous?.value
            guard !Task.isCancelled else { return }
            let capture = await prepare()
            while !Task.isCancelled, let window = nextWindow() {
                let image = await capture?(window)
                guard !Task.isCancelled else { return }
                publish(window, image)
            }
        }
    }

    func cancel() {
        task?.cancel()
        pending.removeAll()
        selected = nil
    }

    private func nextWindow() -> WindowRecord? {
        if let id = selected {
            selected = nil
            if let index = pending.firstIndex(where: { $0.id == id }) { return pending.remove(at: index) }
        }
        return pending.popLast()
    }
}

enum SystemWindowPreviews {
    typealias Candidate = (id: CGWindowID, title: String?)

    static func matchingID(for window: WindowRecord, in candidates: [Candidate]) -> CGWindowID? {
        if let id = window.windowNumber { return candidates.first { $0.id == id }?.id }
        let matches = candidates.filter {
            ($0.title?.isEmpty == false ? $0.title : "Untitled window") == window.title
        }
        return matches.count == 1 ? matches[0].id : nil
    }

    static func prepare() async -> WindowPreviewLoader.Capture? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        if #available(macOS 14.0, *) {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                else { return nil }
            let windows = content.windows.filter { $0.windowLayer == 0 }
            let byID = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0) })
            let byPID = Dictionary(grouping: windows, by: { $0.owningApplication?.processID ?? 0 })
                .mapValues { $0.map { (id: $0.windowID, title: $0.title) } }
            let configuration = SCStreamConfiguration()
            configuration.width = 448
            configuration.height = 296
            configuration.scalesToFit = true
            configuration.preservesAspectRatio = true
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true

            return { record in
                guard let candidates = byPID[record.pid], let id = matchingID(for: record, in: candidates),
                      let window = byID[id] else { return nil }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                               configuration: configuration) else { return nil }
                return NSImage(cgImage: image, size: .zero)
            }
        }

        let visible = WindowServerSnapshot.capture(onScreenOnly: true).entries
        let byPID = Dictionary(grouping: visible, by: \.pid).mapValues { $0.map { (id: $0.number, title: $0.title) } }
        return { record in
            guard let candidates = byPID[record.pid], let id = matchingID(for: record, in: candidates),
                  let image = CGWindowListCreateImage(.null, .optionIncludingWindow, id,
                                                      [.boundsIgnoreFraming, .nominalResolution]) else { return nil }
            return thumbnail(from: image)
        }
    }

    private static func thumbnail(from image: CGImage) -> NSImage? {
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
}
