import AppKit

/// The tool windows around the terminal: which show, where, the plugins' own, and filling the window.
extension MainWindowController {
    var screenKey: String { window?.screen.map(WindowPlacement.key) ?? "default" }

    func loadPanelLayout() {
        loadingLayout = true
        root.panels = PanelLayout.load(screen: screenKey)
        loadingLayout = false
    }
    /// Test runs (--snap) arrange panels for a capture and must not change the saved layout.
    func savePanelLayout() {
        if !loadingLayout, !CommandLine.arguments.contains("--snap") { root.panels.save(screen: screenKey) }
    }

    /// A stripe or status bar button: an open panel closes, a closed one opens and takes focus.
    func stripeClicked(_ p: PanelID) {
        guard root.isShown(p) else { return togglePanel(p) }
        root.setHidden(p, true)
        if p == .viewer { viewerForced = nil }
        focusMain()
    }

    /// ⌥⌘ number, JetBrains style: shows a hidden panel and focuses it; hides a focused one.
    func togglePanel(_ p: PanelID) {
        if !root.isShown(p) {
            root.setHidden(p, false)
            if p == .viewer, !root.viewerOpen { viewerForced = true; syncViewer() }
            focusPanel(p)
        } else if !p.flexible || isFocused(p) {
            root.setHidden(p, true)
            focusMain()
        } else {
            focusPanel(p)
        }
        updateBadges()
    }

    /// The title bar's side buttons, ⌘B and ⌥⌘B: hide a side, or bring back what it last showed.
    func toggleSide(_ d: Dock) {
        if !root.shown(d).isEmpty {
            if root.shown(d).contains(.viewer) { viewerForced = nil }
            root.toggleArea(d)
            return focusMain()
        }
        let ps = root.panels.panels(d, among: root.present)
        guard let p = root.lastShown[d].flatMap({ ps.contains($0) ? $0 : nil }) ?? ps.first(where: \.flexible) ?? ps.first else { return }
        togglePanel(p)
    }

    private func isFocused(_ p: PanelID) -> Bool {
        guard let fr = window?.firstResponder as? NSView, let v = root.content(p) else { return false }
        return fr.isDescendant(of: v)
    }

    func focusPanel(_ p: PanelID) {
        switch p {
        case .sessions: focus(1)
        case .viewer: focus(3)
        default: if let v = root.content(p) as? PluginPanel { window?.makeFirstResponder(v) }
        }
    }

    func movePanel(_ p: PanelID, to d: Dock) {
        root.move(p, to: d)
        toast("\(root.title(p)) moved to the \(d.rawValue).")
    }

    // MARK: filling the window

    /// ⇧⌘↩: the half the keyboard is in fills the window (the session, the viewer or a plugin's
    /// panel), or everything comes back.
    func toggleFill() {
        if root.filling != nil { root.filling = nil; return }
        let fr = window?.firstResponder as? NSView
        let holding = Dock.allCases.first { d in root.shown(d).contains { p in p.canFill && root.content(p).map { fr?.isDescendant(of: $0) == true } ?? false } }
        if let d = holding { return root.toggleFill(.panel(d)) }
        if current != nil { return root.toggleFill(.session) }
        if let d = [Dock.right, .bottom, .left].first(where: { root.shown($0).contains(where: \.canFill) }) { root.toggleFill(.panel(d)) }
    }

    /// The keyboard follows: into what fills the window (what it covers is hidden and must not
    /// keep the keyboard, or AppKit takes it away for good), and back to where it was afterwards.
    func fillingChanged(_ f: WindowFill?) {
        let fr = window?.firstResponder as? NSView
        switch f {
        case nil:
            if let v = focusBeforeFill, v.window != nil { window?.makeFirstResponder(v) } else { focusMain() }
            focusBeforeFill = nil
        case .session?:
            if focusBeforeFill == nil { focusBeforeFill = fr }
            if fr?.isDescendant(of: root.sessionPane) != true {
                if let id = current, let t = terminal(for: id) ?? shell(id), !detached.contains(id) { window?.makeFirstResponder(t) } else { window?.makeFirstResponder(nil) }
            }
        case .panel(let d)?:
            if focusBeforeFill == nil { focusBeforeFill = fr }
            let fills = root.shown(d).first(where: \.canFill) ?? .viewer
            let isInside = { [root] (v: NSView?) in root.shown(d).contains { p in root.content(p).map { v?.isDescendant(of: $0) == true } ?? false } }
            if !isInside(fr) { focusPanel(fills) }
            // A panel with nothing to focus (an empty viewer) still takes the keyboard from what it covers.
            if !isInside(window?.firstResponder as? NSView) { window?.makeFirstResponder(root.content(fills)) }
        }
        updateDim()
    }

    // MARK: plugin panels

    /// One tool window per panel an enabled plugin contributes, kept across updates.
    func syncPluginPanels() {
        let host = store.plugins
        var next: [PanelID: PluginPanel] = [:]
        for m in host.manifests where store.config.pluginEnabled(m) && host.status[m.id].map({ $0.run != .off }) ?? false {
            for p in m.panels {
                let id = PanelID.plugin(m.id, p.id)
                let v = root.pluginPanels[id] ?? makePluginPanel(m, p.id, title: p.title)
                v.update(host: host)
                next[id] = v
            }
        }
        root.setPluginPanels(next)
        updateBadges()
    }

    private func makePluginPanel(_ m: PluginManifest, _ panel: String, title: String) -> PluginPanel {
        let v = PluginPanel(plugin: m.id, panel: panel, title: title)
        v.icon = m.iconURL.flatMap(NSImage.init(contentsOf:))
        v.onRun = { [weak self] plugin, action, session, item in self?.store.runPluginAction(plugin, action, session: session, item: item) }
        v.onSelectSession = { [weak self] in self?.open($0) }
        v.onOpenURL = { NSWorkspace.shared.open($0) }
        v.onRestart = { [weak self] in self?.store.plugins.restart($0) }
        v.onSettings = { [weak self] _ in self?.showSettings(.plugins) }
        return v
    }

    /// The stripe's marks: what needs you in each plugin panel, a stopped plugin, and a dot on the
    /// viewer when a session opened something while another panel was on show.
    func updateBadges() {
        if root.isShown(.viewer) { viewerNews = false }
        var b: [PanelID: Stripe.Badge] = [:]
        for (id, v) in root.pluginPanels {
            if v.stopped { b[id] = .warning } else if v.needsYou > 0 { b[id] = .count(v.needsYou) }
        }
        if viewerNews { b[.viewer] = .dot }
        root.badges = b
    }

    /// ⌥⌘ numbers for Maxwell's panels (⌥⌘6 the first plugin panel), moving any of them, in the
    /// menu and ⌘K.
    func panelActions() -> [Action] {
        var list: [Action] = []
        let plugins = root.panels.order.filter { root.pluginPanels[$0] != nil }
        for p in PanelID.builtIn + plugins {
            let key = p.key ?? plugins.firstIndex(of: p).flatMap { $0 < 4 ? 6 + $0 : nil }
            list.append(Action(id: "panel-\(p.rawValue)", title: "\(root.title(p)) Panel", menu: "Panels",
                               shortcut: key.flatMap { Shortcut("cmd+alt+\($0)") }) { [weak self] in self?.togglePanel(p) })
        }
        for p in PanelID.builtIn + plugins where p.movable {
            for d in Dock.allCases {
                list.append(Action(id: "move-\(p.rawValue)-\(d.rawValue)", title: "Move \(root.title(p)) to \(d.title)", menu: "Panels") { [weak self] in self?.movePanel(p, to: d) })
            }
        }
        return list
    }
}
