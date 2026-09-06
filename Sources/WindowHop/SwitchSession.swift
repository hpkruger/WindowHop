import Foundation

/// Freeze ordering for the duration of a gesture; focus changes must not move its targets.
struct SwitchSession<ID: Equatable> {
    let ids: [ID]
    private(set) var index: Int
    var selected: ID? { ids.isEmpty ? nil : ids[index] }

    init(ids: [ID], current: ID?, backwards: Bool) {
        self.ids = ids
        index = current.flatMap { ids.firstIndex(of: $0) } ?? (backwards ? 0 : -1)
        step(backwards: backwards)
    }

    mutating func step(backwards: Bool) {
        guard !ids.isEmpty else { index = 0; return }
        index = (index + (backwards ? -1 : 1) + ids.count) % ids.count
    }

    mutating func select(_ id: ID) {
        if let position = ids.firstIndex(of: id) { index = position }
    }
}
