import Foundation

/// Which projects the rail shows, Dock-style: kept projects always, even with no sessions;
/// the others while one of their sessions is open (not ended), or while they are the open scope.
enum RailPlan {
    /// One project's sessions, as the rail counts them.
    struct Counts: Equatable {
        var needsYou = 0
        var yourTurn = 0
        /// Sessions that haven't ended: running, waiting or quiet. Recently closed ones don't count.
        var open = 0

        init(needsYou: Int = 0, yourTurn: Int = 0, open: Int = 0) { (self.needsYou, self.yourTurn, self.open) = (needsYou, yourTurn, open) }
        /// From the sidebar group of each of the project's sessions.
        init(_ groups: [PhaseGroup]) {
            self.init(needsYou: groups.filter { $0 == .needsYou }.count, yourTurn: groups.filter { $0 == .yourTurn }.count,
                      open: groups.filter { $0 != .recentlyClosed }.count)
        }
    }

    /// Every project in ⌘-number order: kept ones in their order, then the rest by config rule,
    /// then by name. A kept project is listed with or without sessions, so its key never moves.
    static func order(live: [String], pinned: [String], ruleOrder: [String]) -> [String] {
        var names = pinned
        let rest = live.filter { !pinned.contains($0) }.sorted { a, b in
            let ia = ruleOrder.firstIndex(of: a) ?? Int.max, ib = ruleOrder.firstIndex(of: b) ?? Int.max
            return ia != ib ? ia < ib : a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
        names += rest
        return names
    }

    /// The projects on the rail, in rail order: kept ones, then the others that have an open
    /// session, those that need you first. `names` is `order(…)`.
    static func onRail(_ names: [String], pinned: [String], counts: [String: Counts], scope: String?) -> [String] {
        let kept = names.filter { pinned.contains($0) }
        let others = names.filter { n in !pinned.contains(n) && ((counts[n]?.open ?? 0) > 0 || n == scope) }
        let waiting = { (n: String) in (counts[n]?.needsYou ?? 0) + (counts[n]?.yourTurn ?? 0) }
        // Stable within each half: a key only moves when it starts or stops waiting on you.
        return kept + others.filter { waiting($0) > 0 } + others.filter { waiting($0) == 0 }
    }
}
