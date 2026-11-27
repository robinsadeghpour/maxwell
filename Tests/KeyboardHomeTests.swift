import Foundation

/// A keyboard AppKit took away goes back where the user can see it, never into the session list's commands by surprise.
func keyboardHomeTests() {
    let viewerShown: (PanelID) -> Bool = { $0 == .viewer }
    check(KeyboardHome.afterLosing(.panel(.viewer), panelOnScreen: viewerShown, hasTerminal: true, hasSession: true) == .panel(.viewer),
          "the viewer swapped its page: the keyboard stays in the viewer, not in Claude's prompt")
    check(KeyboardHome.afterLosing(.panel(.viewer), panelOnScreen: { _ in false }, hasTerminal: true, hasSession: true) == .terminal,
          "the viewer hid: the keyboard goes to the terminal")
    check(KeyboardHome.afterLosing(.terminal, panelOnScreen: viewerShown, hasTerminal: false, hasSession: true) == .sessionPane,
          "the terminal ended: the session pane takes it, not the session list")
    check(KeyboardHome.afterLosing(nil, panelOnScreen: viewerShown, hasTerminal: false, hasSession: false) == .sessionList,
          "no session open: the session list")
    check(KeyboardHome.afterLosing(.panel(.plugin("linear", "tickets")), panelOnScreen: { _ in true }, hasTerminal: true, hasSession: true) == .panel(.plugin("linear", "tickets")),
          "a plugin panel still on screen keeps it too")
}
