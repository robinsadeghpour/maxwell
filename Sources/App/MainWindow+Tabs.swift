import AppKit

/// The title bar: the session and terminal tabs (which are in the row and what shows when one
/// closes, by `TabRow`'s rules), and the current session's document tabs and buttons.
extension MainWindowController {
    func wireTitleBar() {
        let bar = root.titleBar
        bar.onSelect = { [weak self] in self?.open($0) }
        bar.onFill = { [weak self] _ in self?.root.toggleFill(.session) }
        bar.onCloseTab = { [weak self] in self?.forget($0) }
        bar.plus.action = { [weak self] in self?.showNewSession() }
        bar.palette.action = { [weak self] in self?.showSearch() }
        bar.gear.action = { [weak self] in self?.showSettings() }
        bar.leftToggle.action = { [weak self] in self?.toggleSide(.left) }
        bar.rightToggle.action = { [weak self] in self?.toggleSide(.right) }
        let docs = root.viewerPane.header
        docs.onTab = { [weak self] in self?.tabAction($0) }
        docs.onKeepToggle = { [weak self] in self?.togglePin() }
        docs.treeButton.action = { [weak self] in self?.toggleTree() }
        docs.reload.action = { [weak self] in self?.reloadArtifact() }
    }

    /// Each tab with its session's title and state; a plain terminal's with its name.
    func renderTabs(_ state: AppState, now: Date) {
        let terminalTabs = Dictionary(uniqueKeysWithValues: shellRows().map { ($0.id, $0.title) })
        root.titleBar.tabs = tabRow.order.compactMap { id in
            if let title = terminalTabs[id] { return TitleBar.Tab(id: id, title: title, group: nil) }
            return state.sessions[id].map { TitleBar.Tab(id: id, title: $0.title, group: state.group($0, now: now, rules: store.config.rules) ?? .idle) }
        }
        root.titleBar.current = current
    }

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
