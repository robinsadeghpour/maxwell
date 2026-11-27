import CoreGraphics

/// How the title bar's one row of tabs is shared between the session tabs (left of the line) and
/// the current session's documents (right of it). Beside the viewer the line is the pane line, so
/// the documents head the viewer. In a narrow window, when the document on show can't be read
/// there, the documents may take empty title bar to the left, never a session tab, ⌄ or +; past
/// that its name is cut in the middle. Session tabs keep `sessionLeast`; those that don't fit wait in ⌄.
enum TitleRow {
    static let sessionLeast: CGFloat = 120, sessionMost: CGFloat = 220
    /// The ⌄ that lists the session tabs out of sight.
    static let list: CGFloat = 26

    /// Where the line goes beside the viewer: the pane line (`line`) while the documents get the
    /// least they need (`docsLeast`) between it and `end`; otherwise left of it, as far as they
    /// need, but never past `tabsEnd`, where the session tabs and + end.
    static func split(line: CGFloat, tabsEnd: CGFloat, end: CGFloat, docsLeast: CGFloat) -> CGFloat {
        guard end - line < docsLeast else { return line }
        return min(line, max(tabsEnd, end - docsLeast))
    }

    /// Where the line goes while the session fills the window and its document on show waits after
    /// the session tabs: as far right as the document needs (`docsLeast`), leaving at least one
    /// session tab and what follows them (`reserve`, the + button) room. `start` is where the session
    /// tabs begin and `end` where the document's room ends.
    static func peekSplit(start: CGFloat, end: CGFloat, docsLeast: CGFloat, reserve: CGFloat) -> CGFloat {
        max(start + sessionLeast + reserve, end - docsLeast)
    }

    struct Sessions: Equatable {
        /// The tabs on show, by index, in their order.
        var shown: [Int]
        var width: CGFloat
        /// Some tabs wait in ⌄.
        var overflow: Bool
    }

    /// Which of `count` session tabs show in `room`, and how wide. All of them when each gets
    /// `sessionLeast`; otherwise as many as fit beside ⌄, the one on show always among them.
    static func sessions(count: Int, current: Int?, room: CGFloat) -> Sessions {
        guard count > 0, room > 0 else { return Sessions(shown: [], width: 0, overflow: false) }
        if CGFloat(count) * sessionLeast <= room {
            return Sessions(shown: Array(0..<count), width: min(sessionMost, room / CGFloat(count)), overflow: false)
        }
        let fit = max(1, min(count, Int((room - list) / sessionLeast)))
        var shown = Array(0..<fit)
        if let c = current, c >= fit { shown[fit - 1] = c }
        return Sessions(shown: shown, width: max(0, min(sessionMost, (room - list) / CGFloat(fit))), overflow: true)
    }
}
