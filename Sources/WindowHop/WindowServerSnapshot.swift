import AppKit

struct WindowServerEntry {
    let number: CGWindowID
    let pid: pid_t
    let title: String?
    let bounds: CGRect
    let onScreen: Bool
}

/// Public Window Server metadata supplies startup stacking order and Space visibility.
struct WindowServerSnapshot {
    var entries: [WindowServerEntry]

    static func capture() -> Self {
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return Self(entries: list.compactMap { info in
            guard let number = info[kCGWindowNumber as String] as? NSNumber,
                  let pid = info[kCGWindowOwnerPID as String] as? NSNumber,
                  let layer = info[kCGWindowLayer as String] as? NSNumber, layer.intValue == 0,
                  let rawBounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: rawBounds) else { return nil }
            return WindowServerEntry(number: number.uint32Value, pid: pid.int32Value,
                                     title: info[kCGWindowName as String] as? String, bounds: bounds,
                                     onScreen: (info[kCGWindowIsOnscreen as String] as? Bool) ?? false)
        })
    }

    func match(pid: pid_t, title: String, bounds: CGRect?, previousNumber: CGWindowID?) -> WindowServerEntry? {
        let candidates = entries.filter { $0.pid == pid }
        if let previousNumber, let known = candidates.first(where: { $0.number == previousNumber }) { return known }
        let byBounds = candidates.filter { candidate in
            guard let bounds else { return false }
            return abs(candidate.bounds.minX - bounds.minX) < 2 && abs(candidate.bounds.minY - bounds.minY) < 2 &&
                abs(candidate.bounds.width - bounds.width) < 2 && abs(candidate.bounds.height - bounds.height) < 2
        }
        let exact = byBounds.filter { $0.title == title }
        if exact.count == 1 { return exact[0] }
        if byBounds.count == 1 { return byBounds[0] }
        let byTitle = candidates.filter { $0.title == title }
        // Duplicate titles/rectangles are ambiguous; never guess and hide the wrong window.
        return byTitle.count == 1 ? byTitle[0] : nil
    }
}
