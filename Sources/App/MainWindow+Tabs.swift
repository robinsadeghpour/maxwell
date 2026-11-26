import AppKit

/// The title bar's session and terminal tabs: which are in the row and what shows when one closes.
/// The rules are `TabRow`'s; this wires them to the window.
extension MainWindowController {
    /// `id` comes on show: its tab stays where it is, or opens beside the tab that was on show.
    func remember(_ id: SessionID) {
        tabRow.visit(id, from: current)
    }

    /// Closing a tab frees its terminal; the session keeps running. A plain terminal keeps running
    /// too, in its sidebar row. The tab visited most recently shows next.
    func forget(_ id: SessionID) {
        terminals.removeValue(forKey: id)?.removeFromSuperview()
        let next = tabRow.close(id)
        if current == id { current = next }
        render(store.state)
        syncViewer()
    }

    /// `claude` started in a Maxwell terminal: its row and tab take the terminal's place, and the
    /// pane follows. When it exits, the terminal's row and tab come back and the pane goes back to it.
    func followHostedTerminals(_ state: AppState) {
        let before = hosted
        hosted = terminalHosts.hosts(Array(state.sessions.values), terminalIds: shells.map(\.id))
        guard let c = current else { return }
        if shell(c) != nil, let sid = hosted.first(where: { $0.value == c })?.key {
            current = sid
            tabRow.replace(c, with: sid)
        } else if hosted[c] == nil, let shellId = before[c], shell(shellId) != nil {
            current = shellId
            tabRow.replace(c, with: shellId)
        }
    }
}
