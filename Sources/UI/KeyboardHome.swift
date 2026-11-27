/// Which part of the window has the keyboard, as far as giving it back goes.
enum KeyboardHome: Equatable {
    /// The session's terminal.
    case terminal
    /// The session pane without a terminal (it ended, or isn't attached): it takes the keyboard
    /// itself, so letters don't land in the session list, where they are commands.
    case sessionPane
    /// The session list, when no session is open.
    case sessionList
    case panel(PanelID)

    /// Where the keyboard goes after AppKit took it from a view that hid or went (the viewer
    /// swapped its page for a PDF or an artifact, a terminal ended): back into the panel it was
    /// in while that panel is still on screen; otherwise the session's terminal, its pane, or the
    /// session list, in that order.
    static func afterLosing(_ was: KeyboardHome?, panelOnScreen: (PanelID) -> Bool, hasTerminal: Bool, hasSession: Bool) -> KeyboardHome {
        if case .panel(let p)? = was, panelOnScreen(p) { return .panel(p) }
        if hasTerminal { return .terminal }
        return hasSession ? .sessionPane : .sessionList
    }
}
