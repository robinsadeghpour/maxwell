import Foundation

/// The session and terminal tabs in the title bar. A tab stays where it opened, the way JetBrains
/// and VS Code keep editor tabs: visiting one never moves it. The row also remembers the order you
/// visited in, which decides what goes when it is full and what shows after you close the tab on show.
struct TabRow: Equatable {
    static let cap = 8
    /// Left to right, as shown.
    private(set) var order: [SessionID] = []
    /// The same tabs, most recently visited first.
    private(set) var recent: [SessionID] = []

    func contains(_ id: SessionID) -> Bool { order.contains(id) }

    /// `id` comes on show. A new tab opens right after the one on show (`current`), or at the end;
    /// a full row drops the tab visited longest ago.
    mutating func visit(_ id: SessionID, from current: SessionID?) {
        if !order.contains(id) {
            let at = current.flatMap { order.firstIndex(of: $0) }.map { $0 + 1 } ?? order.count
            order.insert(id, at: at)
        }
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        while order.count > Self.cap, let oldest = recent.last(where: { $0 != id }) { close(oldest) }
    }

    /// A terminal that started `claude` becomes that session's tab, in the same place, and back
    /// again when it exits. A tab the new id already had goes, so each id has one tab.
    mutating func replace(_ old: SessionID, with new: SessionID) {
        guard old != new else { return }
        guard order.contains(old) else { return visit(new, from: nil) }
        order.removeAll { $0 == new }
        recent.removeAll { $0 == new }
        order = order.map { $0 == old ? new : $0 }
        recent = recent.map { $0 == old ? new : $0 }
    }

    /// Closes a tab. Returns what to show if it was the one on show: the tab visited most recently.
    @discardableResult
    mutating func close(_ id: SessionID) -> SessionID? {
        order.removeAll { $0 == id }
        recent.removeAll { $0 == id }
        return recent.first
    }
}
