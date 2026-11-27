import CoreGraphics

/// How the title bar's one row of tabs is shared between the session tabs (left of the line) and
/// the current session's documents (right of it). The line sits where the viewer begins; when the
/// documents can't show their tab on show whole there, it moves left, but never so far that the
/// session tab on show gets narrower than `sessionLeast`. Session tabs that don't fit wait in ⌄.
enum TitleRow {
    static let sessionLeast: CGFloat = 120, sessionMost: CGFloat = 220
    /// The ⌄ that lists the session tabs out of sight.
    static let list: CGFloat = 26

    /// Where the line between the groups goes. `line` is where the viewer begins, `start` where the
    /// session tabs begin, `end` where the documents' room ends, and `docsLeast` the least they need.
    /// `reserve` is what follows the session tabs (the + button).
    static func split(line: CGFloat, start: CGFloat, end: CGFloat, docsLeast: CGFloat, reserve: CGFloat) -> CGFloat {
        max(start + sessionLeast + reserve, min(line, end - docsLeast))
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
