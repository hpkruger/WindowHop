import Foundation

/// Owned by the main thread. Discovery never overwrites event/gesture history.
struct WindowSwitchState<ID: Hashable> {
    private(set) var order: [ID] = []
    private(set) var current: ID?
    private(set) var revision: UInt64 = 0
    private(set) var pending: ID?
    private var confirmedOrder: [ID]?
    private var confirmedCurrent: ID?

    mutating func reconcile(_ seedOrder: [ID]) {
        let live = Set(seedOrder)
        order.removeAll { !live.contains($0) }
        let known = Set(order)
        order.append(contentsOf: seedOrder.filter { !known.contains($0) })
        if let current, !live.contains(current), pending == nil { self.current = nil }
        confirmedOrder = confirmedOrder?.filter { live.contains($0) }
    }

    mutating func observe(_ id: ID?) {
        guard pending == nil, id != current else { return }
        current = id
        if let id { promote(id) }
        revision &+= 1
    }

    @discardableResult
    mutating func beginActivation(_ id: ID) -> UInt64 {
        if pending == nil { confirmedOrder = order; confirmedCurrent = current }
        pending = id
        current = id
        promote(id)
        revision &+= 1
        return revision
    }

    /// Old completions cannot undo a newer quick switch.
    @discardableResult
    mutating func finishActivation(revision expected: UInt64, succeeded: Bool) -> Bool {
        guard revision == expected, pending != nil else { return false }
        if !succeeded {
            let baseline = confirmedOrder ?? []
            let known = Set(baseline)
            order = baseline + order.filter { !known.contains($0) }
            current = confirmedCurrent.flatMap { order.contains($0) ? $0 : nil }
        }
        pending = nil
        confirmedOrder = nil
        confirmedCurrent = nil
        revision &+= 1
        return true
    }

    private mutating func promote(_ id: ID) {
        order.removeAll { $0 == id }
        order.insert(id, at: 0)
    }
}

enum WindowScope: String, CaseIterable {
    case currentSpace, allSpaces
    var title: String { self == .currentSpace ? "Current Space" : "All Spaces" }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: "windowScope") ?? "") ?? .currentSpace
    }
    func save(to defaults: UserDefaults = .standard) { defaults.set(rawValue, forKey: "windowScope") }

    func includes(onScreen: Bool?, minimized: Bool, hidden: Bool) -> Bool {
        // Public APIs cannot assign hidden/minimized or unmatched windows to a Space.
        // Preserve access to them rather than silently dropping switchable windows.
        self == .allSpaces || onScreen != false || minimized || hidden
    }
}
