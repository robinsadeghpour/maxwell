import Foundation

/// When Maxwell lets go of a session's terminal. Claude Code stops an idle background session only
/// while nothing is attached to it, so a terminal kept open off screen holds that session's memory
/// for as long as Maxwell runs. Opening the session attaches again.
enum TerminalRelease {
    /// How long a terminal stays attached after it was last on screen.
    static let after: TimeInterval = 10 * 60

    /// Attached sessions to let go now: not on screen, and last shown at least `after` ago
    /// (or never, which a terminal attached only to type into can be).
    static func due(attached: Set<SessionID>, lastShown: [SessionID: Date], onScreen: SessionID?, now: Date) -> [SessionID] {
        attached.filter { id in
            guard id != onScreen else { return false }
            guard let shown = lastShown[id] else { return true }
            return now.timeIntervalSince(shown) >= after
        }.sorted()
    }
}
