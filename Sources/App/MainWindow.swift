import AppKit

/// Per-session viewer state: the file or artifact shown, and whether it is pinned.
struct ViewerState { var item: ViewerItem?; var pinned = false; var scanned = false }

final class MainWindowController: NSWindowController, SessionPaneDelegate, NSWindowDelegate {
    let store: Store
    let root = RootView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900))
    private var terminals: [SessionID: TerminalView] = [:]
    private var detached = Set<SessionID>()
    private var visited: [SessionID] = []
    private(set) var current: SessionID?
    private var viewers: [SessionID: ViewerState] = [:]
    private let search = SearchPanel(frame: .zero)
    private let glass = NSVisualEffectView()
    private var doubleShift: DoubleShift?
    private var overlayMonitor: Any?
    let updater = Updater()
    private let newPanel = NewSessionPanel(frame: .zero)
    let closeSheet = CloseSheet(frame: .zero)
    private lazy var settings = SettingsWindowController()
    private(set) var actions: [Action] = []
    private(set) var tooltips: Tooltips!
    private var ageTimer: Timer?
    var onConfigEdit: ((String, String) -> Void)?
    /// The project the sidebar shows; nil is "All" (only what needs you, every project).
    private(set) var scope: String? = UserDefaults.standard.string(forKey: "Maxwell.project")
    private(set) var projectNames: [String] = []
    private var projectRoots: [String: [String]] = [:]
    private var projects = Projects(rules: [])
    /// ⌘\ overrides the viewer for the current session; nil follows "is a file open".
    private var viewerForced: Bool?

    init(store: Store) {
        self.store = store
        let w = MXWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isOpaque = false
        w.backgroundColor = .clear
        w.toolbar = NSToolbar()
        w.toolbarStyle = .unifiedCompact
        w.minSize = NSSize(width: 900, height: 480)
        // Glass behind everything; the root view's tint sits on it.
        // With `background-blur` set, the material steps aside for a window blur of that radius.
        let content = NSView(frame: w.contentLayoutRect)
        glass.material = .underWindowBackground
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.frame = content.bounds
        glass.autoresizingMask = [.width, .height]
        root.autoresizingMask = [.width, .height]
        root.frame = content.bounds
        content.addSubview(glass)
        content.addSubview(root)
        w.contentView = content
        super.init(window: w)
        WindowPlacement.restore(w)
        w.delegate = self
        loadPanelLayout()
        root.onWidthsChanged = { [weak self] in self?.savePanelLayout() }
        root.onLayoutChanged = { [weak self] in self?.savePanelLayout(); self?.updateDim() }
        root.onSettled = { [weak self] in self?.updateDim() }
        root.onShowPanel = { [weak self] p in self?.focusPanel(p) }
        ProjectLogos.shared.onChange = { [weak self] in
            guard let self else { return }
            self.root.rail.needsDisplay = true; self.root.sidebar.mark.needsDisplay = true
            if self.settings.window?.isVisible == true { self.settings.view.update(self.settingsModel) }
        }
        w.onFocusChange = { [weak self] in self?.updateDim() }
        wire()
        actions = makeActions()
        tooltips = Tooltips(window: w)
        Tooltips.shortcut = { [weak self] id in self?.actions.first { $0.id == id }?.shortcut?.display }
        // Ages and the Idle fold move with the clock, not only with events.
        ageTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.render(self.store.state)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func wire() {
        root.sidebar.list.onOpen = { [weak self] in self?.open($0) }
        root.sidebar.list.onCloseAllSafe = { [weak self] in self?.closeAllSafe() }
        root.sidebar.list.onReopen = { [weak self] in self?.reopen($0) }
        root.sidebar.list.onNotSafe = { [weak self] in self?.notSafe($0) }
        root.sidebar.list.menuFor = { [weak self] in self?.sessionMenu($0) }
        root.sidebar.list.onSuggestion = { [weak self] id, project, accept in
            if accept { self?.store.moveProject(id, to: project) } else { self?.store.dismissSuggestion(id, project) }
        }
        root.sidebar.list.onBadge = { [weak self] id, b in
            if let a = b.badge.action { self?.store.runPluginAction(b.plugin, a, session: id) }
        }
        store.onPluginsChanged = { [weak self] in self?.pluginsChanged() }
        root.pluginPanel.onRun = { [weak self] plugin, action, session, item in self?.store.runPluginAction(plugin, action, session: session, item: item) }
        root.pluginPanel.onSelectSession = { [weak self] in self?.open($0) }
        root.pluginPanel.onOpenURL = { NSWorkspace.shared.open($0) }
        root.pluginPanel.onRestart = { [weak self] in self?.store.plugins.restart($0) }
        store.plugins.onStartSession = { [weak self] _, prompt, name, cwd, model, done in
            guard let self, self.startHere(prompt: prompt, name: name, cwd: cwd, model: model, done: done) else {
                return done(.failure(.init(message: "No folder to start in. Open a session in the project first.")))
            }
        }
        root.pluginPanel.onSettings = { [weak self] _ in self?.showSettings(.plugins) }
        root.sidebar.list.onDragSession = { [weak self] on in
            guard let self else { return }
            self.root.rail.sessionDrag = on
            if on { self.root.peekRail() }
        }
        root.rail.onDropSession = { [weak self] id, project in self?.moveSession(id, to: project) }
        closeSheet.onClose = { [weak self] in self?.focusMain() }
        closeSheet.onConfirm = { [weak self] in self?.performClose($0) }
        root.rail.onSelect = { [weak self] in self?.setScope($0) }
        root.rail.onPin = { [weak self] name, pin, at in self?.pin(name, pin, at: at) }
        root.rail.onConfig = { [weak self] k, v in self?.onConfigEdit?(k, v) }
        root.sidebar.tabs.onSelect = { [weak self] in self?.setScope($0) }
        root.titleBar.onSelect = { [weak self] in self?.open($0) }
        root.titleBar.onCloseTab = { [weak self] in self?.forget($0) }
        root.titleBar.plus.action = { [weak self] in self?.showNewSession() }
        root.titleBar.palette.action = { [weak self] in self?.showSearch() }
        root.titleBar.gear.action = { [weak self] in self?.showSettings() }
        root.sessionPane.delegate = self
        root.viewerPane.pin.action = { [weak self] in self?.togglePin() }
        root.viewerPane.clear.action = { [weak self] in self?.clearViewer() }
        root.viewerPane.treeButton.action = { [weak self] in self?.toggleTree() }
        root.viewerPane.onTreeSelect = { [weak self] url in self?.showFile(url, for: self?.current) }
        store.onChange = { [weak self] in self?.render($0) }
        store.onViewerItem = { [weak self] id, item, reload in self?.itemSeen(id, item, reload: reload) }
        root.viewerPane.reload.action = { [weak self] in self?.reloadArtifact() }
        root.viewerPane.external.action = { [weak self] in self?.openInBrowser() }
        root.viewerPane.viewer.artifact.onOpenExternal = { [weak self] url, a in self?.openExternally(url, account: a) }
        root.viewerPane.viewer.onLink = { [weak self] url in
            guard let self else { return }
            self.openWebLink(url, session: self.current)
        }
        store.onBrought = { [weak self] s, why in
            guard let self else { return }
            if let why { return self.toast("“\(s.title)” didn't move: \(why)") }
            self.toast("“\(s.title)” now runs in Maxwell.")
            if self.current == s.id { self.open(s.id) }
        }
        search.onClose = { [weak self] in self?.focusMain() }
        doubleShift = DoubleShift { [weak self] in
            guard let self, self.window?.isKeyWindow == true || quietTest, self.search.superview == nil else { return }
            self.showSearch()
        }
        // Esc closes the open overlay wherever focus went, and a click outside it closes it too.
        overlayMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] e in
            guard let self, e.window === self.window, let top = self.topOverlay else { return e }
            if e.type == .keyDown {
                guard e.keyCode == 53 else { return e }
                self.dismiss(top)
                return nil
            }
            if top !== self.closeSheet, !top.frame.contains(top.superview!.convert(e.locationInWindow, from: nil)) { self.dismiss(top) }
            return e
        }
        updater.onReady = { [weak self] v in self?.root.status.update = v; self?.refreshSettings() }
        root.status.onUpdate = { [weak self] in self?.updater.install() }
        newPanel.onClose = { [weak self] in self?.focusMain() }
        newPanel.onStart = { [weak self] a, f, n in self?.startSession(account: a, folder: f, name: n) }
        TerminalView.isAppShortcut = { [weak self] e in self?.actions.contains { $0.shortcut?.matches(e) == true } ?? false }
    }

    // MARK: render

    func render(_ state: AppState) {
        let now = Date(), rules = store.config.rules
        if projects.rules != store.config.projects { projects = Projects(rules: store.config.projects) }
        let all = state.grouped(now: now, rules: rules)
        // One rail entry per project with live sessions; config rules first, in config order.
        var byProject: [String: [(PhaseGroup, Session)]] = [:]
        for (g, list) in all { for s in list { byProject[state.project(s, in: projects), default: []].append((g, s)) } }
        // ⌘1–⌘9 follow the pinned order, then the rest alphabetically, so a key never moves
        // when an unpinned project appears on or leaves the rail.
        let pins = pinnedNames
        let ruleOrder = store.config.projects.map(\.name)
        projectNames = byProject.keys.sorted { a, b in
            let pa = pins.firstIndex(of: a) ?? Int.max, pb = pins.firstIndex(of: b) ?? Int.max
            if pa != pb { return pa < pb }
            let ia = ruleOrder.firstIndex(of: a) ?? Int.max, ib = ruleOrder.firstIndex(of: b) ?? Int.max
            return ia != ib ? ia < ib : a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
        if let s = scope, !projectNames.contains(s), !byProject.isEmpty { scope = nil }
        func entry(_ name: String?, _ items: [(PhaseGroup, Session)]) -> ProjectEntry {
            var e = ProjectEntry(name: name, needsYou: items.filter { $0.0 == .needsYou }.count, yourTurn: items.filter { $0.0 == .yourTurn }.count, total: items.count)
            if let name {
                e.pinned = pins.contains(name)
                e.key = projectNames.firstIndex(of: name).flatMap { $0 < 9 ? $0 + 1 : nil }
                // A session moved here from another project's folder says nothing about this one's logo.
                e.roots = Array(Set(items.filter { state.moved[$0.1.id] == nil }.map { self.repoRoot($0.1.cwd) ?? $0.1.cwd })).sorted()
            }
            return e
        }
        let every = projectNames.map { entry($0, byProject[$0] ?? []) }
        projectRoots = Dictionary(uniqueKeysWithValues: every.compactMap { e in e.name.map { ($0, e.roots) } })
        let allEntry = entry(nil, all.flatMap { g, l in l.map { (g, $0) } })
        // Pinned projects always; others while they need him, or while they are the open scope.
        let onRail = every.filter { $0.pinned }
            + every.filter { !$0.pinned && ($0.needsYou + $0.yourTurn > 0 || $0.name == scope) }.sorted { $0.needsYou + $0.yourTurn > $1.needsYou + $1.yourTurn }
        root.rail.entries = [allEntry] + onRail
        root.rail.everyProject = every
        root.sidebar.elsewhere = scope == nil ? 0 : every.filter { $0.name != scope }.reduce(0) { $0 + $1.needsYou }
        titleProjectMenu()
        root.rail.selected = scope
        let entries = [allEntry] + every
        root.sidebar.tabs.entries = entries
        root.sidebar.tabs.selected = scope

        let shown: [(PhaseGroup, [Session])] = scope.map { p in all.compactMap { g, l in
            let k = l.filter { state.project($0, in: projects) == p }; return k.isEmpty ? nil : (g, k)
        } } ?? all.filter { $0.0.needsHim }
        let rows = shown.map { g, list in (g, list.map { s in
            Row(session: s, group: g, detail: detail(s, state: state),
                checks: g == .safeToClose ? state.checks(s, now: now, rules: rules) : [], closedAt: g == .recentlyClosed ? state.closed[s.id]?.at : nil,
                suggestion: g == .recentlyClosed ? nil : state.suggestion(s, in: projects), badges: badges(s, state: state))
        }) }
        let hours = Int(store.config.idleAfter / 3600)
        root.sidebar.list.idleNote = hours >= 48 && hours % 24 == 0 ? "quiet \(hours / 24)d+" : "quiet \(hours)h+"
        root.sidebar.list.emptyText = scope == nil
            ? ["Nothing needs you.", "", "Every session is working, stopped", "or safe. Pick a project on the left", "to see all of its sessions."]
            : ["No sessions in \(scope!).", "", "⌘N starts one."]
        var perAccount: [AccountID: Int] = [:]
        for s in state.sessions.values where s.phase != .ended { perAccount[s.accountId, default: 0] += 1 }
        root.sidebar.update(scope: scope ?? "All projects", groups: rows)
        root.sidebar.mark.roots = every.first { $0.name == scope }?.roots ?? []
        root.sidebar.mark.monogram = scope.map { String($0.prefix(2)) } ?? ""
        root.sidebar.mark.project = scope
        root.usage.accounts = state.accounts
        root.usage.counts = perAccount
        root.sidebar.list.current = current
        root.status.counts = PhaseGroup.allCases.map { g in (g, all.first { $0.0 == g }?.1.count ?? 0) }
        root.titleBar.tabs = visited.compactMap { id in state.sessions[id].map { TitleBar.Tab(id: id, title: $0.title, group: state.group($0, now: now, rules: rules) ?? .idle) } }
        root.titleBar.current = current
        let s = current.flatMap { state.sessions[$0] ?? state.closed[$0]?.session }
        root.sessionPane.show(s, group: s.flatMap { state.group($0, now: now, rules: rules) },
                              blockers: s.map { state.checks($0, now: now, rules: rules).filter { $0.outcome != .pass }.map { "\($0.title): \($0.detail)" } } ?? [],
                              project: s.map { state.project($0, in: projects) },
                              account: s.flatMap { state.account($0.accountId) },
                              terminal: current.flatMap { detached.contains($0) ? nil : terminals[$0] },
                              summary: PhaseGroup.allCases.filter { !$0.folds }.map { g in (g, (scope == nil ? all : shown).first { $0.0 == g }?.1.count ?? 0) })
        root.viewerPane.setRoot(s?.cwd)
        NSApp.dockTile.badgeLabel = {
            let n = state.sessions.values.filter { if case .needsYou = $0.phase { return true }; return false }.count
            return n > 0 ? "\(n)" : nil
        }()
    }

    /// Plugin badges for a row, plugin by plugin in name order.
    private func badges(_ s: Session, state: AppState) -> [RowBadge] {
        (state.notes[s.id] ?? [:]).sorted { $0.key < $1.key }.flatMap { pid, note in
            note.badges.map { b in
                // A badge's tooltip also lists the plugin's fields for the session.
                var badge = b
                let fields = note.fields.map { "\($0.label): \($0.value)" }
                if !fields.isEmpty { badge.tooltip = ([b.tooltip ?? b.text] + fields).joined(separator: "\n") }
                return RowBadge(plugin: pid, badge: badge, actionTitle: b.action.flatMap { a in store.plugins.manifest(pid)?.actions.first { $0.id == a }?.title })
            }
        }
    }

    /// Whether a plugin's action can run now: the plugin runs, and a session action applies to the session.
    private func pluginActionEnabled(_ m: PluginManifest, _ a: PluginManifest.ActionDecl, session: SessionID?) -> Bool {
        guard store.plugins.status[m.id]?.isRunning == true else { return false }
        guard a.scope == .session else { return true }
        guard let id = session, let note = store.state.notes[id]?[m.id] else { return false }
        return note.actions?.contains(a.id) ?? true
    }

    /// Repo roots by folder (where a project's logo is searched; a folder outside git is its
    /// own root). Render runs every minute and on every event, the disk walk once.
    private var roots: [String: String?] = [:]
    private func repoRoot(_ cwd: String) -> String? {
        if let r = roots[cwd] { return r }
        let r = Projects.repoRoot(cwd)
        roots[cwd] = .some(r)
        return r
    }

    /// Right-click on a row: open, rename, move to another project, bring in, close.
    private func sessionMenu(_ s: Session) -> NSMenu {
        let state = store.state
        let current = state.project(s, in: projects), home = projects.name(for: s.cwd)
        let m = NSMenu()
        m.addItem(MenuAction("Open") { [weak self] in self?.open(s.id) })
        m.addItem(MenuAction("Rename…") { [weak self] in self?.rename(s.id) })
        m.addItem(MenuAction("Suggest a Title") { [weak self] in self?.suggestTitle(s.id) })
        m.addItem(.separator())
        let move = NSMenuItem(title: "Move to Project", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        var names = pinnedNames
        for n in projectNames where !names.contains(n) { names.append(n) }
        for n in names where n != current { sub.addItem(MenuAction(n) { [weak self] in self?.moveSession(s.id, to: n) }) }
        move.submenu = sub
        move.isEnabled = sub.numberOfItems > 0
        m.addItem(move)
        if current != home { m.addItem(MenuAction("Move back to \(home)") { [weak self] in self?.store.moveProject(s.id, to: nil) }) }
        m.addItem(.separator())
        if case .elsewhere = s.reach {
            m.addItem(MenuAction("Bring into Maxwell") { [weak self] in self?.bringIn(s.id, force: false) })
            let close = MenuAction("Close Session (runs in another terminal)") {}
            close.isEnabled = false
            close.action = nil
            m.addItem(close)
        } else if s.phase != .ended {
            let close = MenuAction("Close Session") { [weak self] in self?.close(s.id) }
            close.keyEquivalent = "\u{8}"
            close.keyEquivalentModifierMask = .command
            m.addItem(close)
        }
        let pluginItems = store.plugins.manifests.flatMap { pm in
            pm.actions.filter { $0.scope == .session && pluginActionEnabled(pm, $0, session: s.id) }.map { a in
                MenuAction(a.title) { [weak self] in self?.store.runPluginAction(pm.id, a.id, session: s.id) }
            }
        }
        if !pluginItems.isEmpty { m.addItem(.separator()); pluginItems.forEach { m.addItem($0) } }
        return m
    }

    /// Your own title for a session, kept in Maxwell. Empty goes back to the automatic one.
    func rename(_ id: SessionID) {
        guard let s = store.state.sessions[id], let w = window else { return }
        let a = NSAlert()
        a.messageText = "Rename Session"
        a.informativeText = "Shown in the list, tabs and search. Leave it empty to go back to the automatic title."
        let field = NSTextField(string: s.named?.byYou == true ? s.title : "")
        field.placeholderString = s.title
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        a.accessoryView = field
        a.addButton(withTitle: "Rename")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        a.beginSheetModal(for: w) { [weak self] r in
            guard r == .alertFirstButtonReturn else { return }
            self?.store.rename(id, to: field.stringValue)
        }
    }

    func suggestTitle(_ id: SessionID) {
        guard let s = store.state.sessions[id] else { return }
        if s.named?.byYou == true { store.rename(id, to: "") }
        toast("Asking Haiku for a title…")
        store.suggestTitle(store.state.sessions[id] ?? s) { [weak self] t in
            self?.toast(t.map { "Titled “\($0)”." } ?? "Couldn't get a title. Try again in a moment.")
        }
    }

    /// Moving a session to its folder's own project is a move back: no record of a move remains.
    func moveSession(_ id: SessionID, to project: String) {
        guard let s = store.state.sessions[id] ?? store.state.closed[id]?.session else { return }
        store.moveProject(id, to: project == projects.name(for: s.cwd) ? nil : project)
    }

    /// The row's second line: what a title alone does not say.
    private func detail(_ s: Session, state: AppState) -> String {
        var parts: [String] = []
        let project = state.project(s, in: projects)
        if scope == nil { parts.append(project) }
        // A shared checkout's branch is not this session's; only a worktree's branch says what it works on.
        if projects.isWorktree(s.cwd), let b = s.branch ?? s.doneCheck?.branch { parts.append(b) }
        else if scope != nil, case let folder = (s.cwd as NSString).lastPathComponent, folder.lowercased() != project.lowercased() { parts.append(folder) }
        if s.untitled, let m = s.lastMessage?.split(separator: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            parts.append(String(m.replacingOccurrences(of: "**", with: "").prefix(80)))
        }
        parts.insert(state.account(s.accountId)?.name ?? s.accountId, at: min(parts.count, scope == nil ? 1 : 0))
        return parts.joined(separator: " · ")
    }

    /// Ghostty dims an unfocused split; Maxwell dims the terminal or viewer you are not in.
    func updateDim() {
        guard let w = window else { return }
        let fr = w.firstResponder as? NSView
        let inViewer = fr.map { $0.isDescendant(of: root.viewerPane) } ?? false
        let inSession = fr.map { $0.isDescendant(of: root.sessionPane) } ?? false
        root.sessionDim.isHidden = inSession || current == nil
        root.viewerDim.isHidden = inViewer || !root.isShown(.viewer)
    }

    func windowDidMove(_ n: Notification) { if let w = window { WindowPlacement.save(w) } }
    func windowDidChangeScreen(_ n: Notification) { loadPanelLayout() }

    // MARK: panels

    private var screenKey: String { window?.screen.map(WindowPlacement.key) ?? "default" }
    private var loadingLayout = false
    private func loadPanelLayout() {
        loadingLayout = true
        root.panels = PanelLayout.load(screen: screenKey)
        loadingLayout = false
    }
    /// Test runs (--snap) arrange panels for a capture and must not change the saved layout.
    private func savePanelLayout() {
        if !loadingLayout, !CommandLine.arguments.contains("--snap") { root.panels.save(screen: screenKey) }
    }

    /// ⌥⌘ number, JetBrains style: shows a hidden panel and focuses it; hides a focused one.
    func togglePanel(_ p: PanelID) {
        if !root.isShown(p) {
            root.setHidden(p, false)
            if p == .viewer, !root.viewerOpen { viewerForced = true; syncViewer() }
            focusPanel(p)
        } else if p == .usage || p == .system || isFocused(p) {
            root.setHidden(p, true)
            focusMain()
        } else {
            focusPanel(p)
        }
    }

    private func isFocused(_ p: PanelID) -> Bool {
        guard let fr = window?.firstResponder as? NSView else { return false }
        return fr.isDescendant(of: root.content(p))
    }

    func focusPanel(_ p: PanelID) {
        switch p {
        case .sessions: focus(1)
        case .viewer: focus(3)
        case .usage, .system, .plugins: break
        }
    }

    func movePanel(_ p: PanelID, to d: Dock) {
        root.panels.move(p, to: d)
        toast("\(p.title) moved to the \(d.rawValue).")
    }

    /// The Dock's "Keep in Dock". With no pins in the config yet, every project counts as pinned,
    /// so the first unpin keeps the rest where they were.
    func pin(_ name: String, _ on: Bool, at index: Int?) {
        var pins = pinnedNames
        pins.removeAll { $0 == name }
        if on { pins.insert(name, at: min(index ?? pins.count, pins.count)) }
        onConfigEdit?("project-pin", pins.joined(separator: "\n") + "\n")
    }

    /// Pinned projects in rail order; every known project while the config pins none.
    private var pinnedNames: [String] {
        store.config.pinned.isEmpty ? projectNames : store.config.pinned
    }
    func windowDidEndLiveResize(_ n: Notification) { if let w = window { WindowPlacement.save(w) } }
    func windowDidBecomeKey(_ n: Notification) { updateDim() }

    /// Menu titles follow the rail: "Project 2" reads "Acme".
    private func titleProjectMenu() {
        guard let m = NSApp.mainMenu?.items.first(where: { $0.title == "Projects" })?.submenu else { return }
        for item in m.items {
            guard let n = Int(item.title.replacingOccurrences(of: "Project ", with: "")) ?? (item.tag > 0 ? item.tag : nil) else { continue }
            item.tag = n
            item.title = projectNames.indices.contains(n - 1) ? projectNames[n - 1] : "Project \(n)"
            item.isHidden = !projectNames.indices.contains(n - 1)
        }
    }

    func setScope(_ name: String?) {
        scope = name
        UserDefaults.standard.set(name, forKey: "Maxwell.project")
        render(store.state)
    }

    /// ⌘0 is All, ⌘1–⌘9 the projects in rail order.
    func selectProject(_ n: Int) {
        root.peekRail(for: 0.9)
        if n == 0 { return setScope(nil) }
        guard projectNames.indices.contains(n - 1) else { return toast("No project \(n).") }
        setScope(projectNames[n - 1])
    }

    // MARK: sessions

    func open(_ id: SessionID) {
        guard let s = store.state.sessions[id] else { return }
        current = id
        // Opening a session from another project switches the rail to it, so its row is in the list.
        let p = store.state.project(s, in: projects)
        if let sc = scope, sc != p { scope = p; UserDefaults.standard.set(p, forKey: "Maxwell.project") }
        visited.removeAll { $0 == id }
        visited.insert(id, at: 0)
        if visited.count > 8 { visited.removeLast() }
        if case .background(let short) = s.reach, terminals[id] == nil, let a = store.state.account(s.accountId) {
            attach(s, short: short, account: a)
        }
        viewerForced = nil
        render(store.state)
        showViewer(for: id)
        if let t = terminals[id], !detached.contains(id) { window?.makeFirstResponder(t) }
    }

    private func attach(_ s: Session, short: String, account a: Account) {
        let size = root.sessionPane.content.bounds.size
        let t = TerminalView(frame: NSRect(origin: .zero, size: size == .zero ? NSSize(width: 800, height: 600) : size),
                             workingDirectory: s.cwd.isEmpty ? Paths.home.path : s.cwd,
                             command: "\(ClaudeCLI.claudePath) attach \(short)",
                             env: a.configDirEnv.map { ["CLAUDE_CONFIG_DIR": $0] } ?? [:])
        let id = s.id
        t.onExit = { [weak self] in
            self?.detached.insert(id)
            if let self { self.render(self.store.state) }
        }
        t.onOpenURL = { [weak self] url, cwd in self?.openURL(url, cwd: cwd, session: id) }
        terminals[id] = t
        detached.remove(id)
    }

    func reattach(_ id: SessionID) {
        if let t = terminals.removeValue(forKey: id) { t.removeFromSuperview() }
        detached.remove(id)
        open(id)
    }

    /// Closing a tab frees its terminal; the session keeps running.
    func forget(_ id: SessionID) {
        if let t = terminals.removeValue(forKey: id) { t.removeFromSuperview() }
        visited.removeAll { $0 == id }
        if current == id { current = visited.first }
        render(store.state)
        syncViewer()
    }

    func step(_ d: Int) {
        let ids = root.sidebar.list.sessionIds
        guard !ids.isEmpty else { return }
        let i = ids.firstIndex(of: current ?? "") ?? (d > 0 ? -1 : ids.count)
        open(ids[(i + d + ids.count) % ids.count])
    }

    func nextNeedsYou() {
        let ids = store.state.grouped(now: Date(), rules: store.config.rules).first { $0.0 == .needsYou }?.1.map(\.id) ?? []
        guard !ids.isEmpty else { return toast("Nothing needs you.") }
        let i = ids.firstIndex(of: current ?? "") ?? -1
        open(ids[(i + 1) % ids.count])
    }

    func roomiest(for id: SessionID) -> Account? {
        guard let s = store.state.sessions[id] else { return nil }
        return store.state.roomiest(now: Date(), excluding: s.accountId)
    }

    func scheduledResume(_ id: SessionID) -> Date? { store.scheduledResumes[id] }

    // MARK: bringing terminal sessions in

    func bringInQueued(_ id: SessionID) -> Bool { store.bringQueue.contains(id) }

    func bringIn(_ id: SessionID, force: Bool) {
        guard let s = store.state.sessions[id] else { return }
        if !force, !store.canBringInNow(s) {
            toast("“\(s.title)” moves into Maxwell when this turn ends.")
        } else {
            toast("Moving “\(s.title)” into Maxwell…")
        }
        store.bringIn(s, force: force)
        render(store.state)
    }

    /// Every session with a live process in another terminal: idle ones move now, working ones
    /// as soon as their turn ends. The terminal tabs are left at a shell prompt.
    func bringAllIn() {
        let state = store.state
        let candidates = state.sessions.values.filter { if case .elsewhere = $0.reach { return true }; return false }
        toast("Looking for sessions in other terminals…")
        DispatchQueue.global().async { [weak self] in
            let live = candidates.filter { s in state.account(s.accountId).flatMap { ClaudeCLI.terminalProcess(sessionId: s.id, account: $0) } != nil }
            DispatchQueue.main.async { self?.confirmBringIn(live) }
        }
    }

    private func confirmBringIn(_ live: [Session]) {
        guard !live.isEmpty else { return toast("No sessions are running in other terminals.") }
        let busy = live.filter { !store.canBringInNow($0) }
        let a = NSAlert()
        a.messageText = "Bring \(live.count) terminal session\(live.count == 1 ? "" : "s") into Maxwell?"
        a.informativeText = """
        Each one keeps its conversation, account, folder and permission mode. \(live.count - busy.count) move now.         \(busy.isEmpty ? "" : "\(busy.count) are in the middle of a turn and move as soon as it ends. ")        Their terminal tabs are left at a shell prompt, so you can close the terminal afterwards.
        """
        a.addButton(withTitle: "Bring Them In")
        a.addButton(withTitle: "Cancel")
        guard let w = window else { return }
        a.beginSheetModal(for: w) { [weak self] r in
            guard r == .alertFirstButtonReturn, let self else { return }
            // One at a time, a moment apart, so thirty sessions don't all start at once.
            for (i, s) in live.sorted(by: { $0.lastEventAt > $1.lastEventAt }).enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 2) { self.store.bringIn(s) }
            }
            self.toast("Moving \(live.count - busy.count) now; \(busy.count) after their turn.")
            self.render(self.store.state)
        }
    }

    func resume(_ id: SessionID) {
        guard let s = store.state.sessions[id] else { return }
        var reset: Date?
        if case .limited(let d) = s.phase { reset = d }
        let when = reset ?? Date()
        store.scheduleResume(s, at: when) { [weak self] s in self?.send("continue", to: s.id) }
        toast(when > Date() ? "Will send \"continue\" at \(Format.clock.string(from: when))." : "Sent \"continue\".")
    }

    /// Types a line into the session's terminal, attaching first if needed.
    private func send(_ line: String, to id: SessionID) {
        if terminals[id] == nil || detached.contains(id) { reattach(id) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.terminals[id]?.sendLine(line) }
    }

    func move(_ id: SessionID) {
        guard let s = store.state.sessions[id], let target = roomiest(for: id) else { return toast("No account has room right now.") }
        toast("Starting on \(target.name)…")
        store.move(s, to: target) { [weak self] r in
            switch r {
            case .success(let newId): self?.toast("Moved to \(target.name) with a handover prompt."); self?.open(newId)
            case .failure(let e): self?.toast("Move failed: \(e)")
            }
        }
    }

    /// ⇧⌘⌫ (⌘⌫ itself belongs to the terminal: delete to line start), the row menu and the banner button. Safe sessions close at once; any other asks
    /// first and says what is still open. Either way it is `claude stop`, with Undo.
    func close(_ id: SessionID) {
        guard let s = store.state.sessions[id], s.phase != .ended else { return }
        if case .elsewhere = s.reach { return toast("“\(s.title)” runs in another terminal. Bring it into Maxwell first, or close it there.") }
        let open = store.checks(s).filter { $0.outcome != .pass }
        guard !open.isEmpty, let w = window else { return closeNow(s) }
        let a = NSAlert()
        a.messageText = s.phase == .working ? "“\(s.title)” is still working. Close it anyway?" : "Close “\(s.title)”?"
        let reasons = open.prefix(4).map { "• \($0.title): \($0.detail)" }.joined(separator: "\n")
        a.informativeText = "Not safe to close yet:\n\(reasons)\n\nClaude stops, and the conversation is kept. Undo right after, or reopen it from Recently closed for 7 days."
        a.addButton(withTitle: "Close Session")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: w) { [weak self] r in
            guard r == .alertFirstButtonReturn, let self, let fresh = self.store.state.sessions[id] else { return }
            self.closeNow(fresh)
        }
    }

    private func closeNow(_ s: Session) {
        store.closeNow(s.id) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .closed:
                self.forget(s.id)
                mark("close: \(s.title)")
                self.root.status.show(toast: "Closed “\(s.title)”. The conversation is kept.", action: ("Undo", { [weak self] in self?.reopen(s.id) }), seconds: 10)
            case .skipped(let why), .failed(let why): self.toast("Couldn't close “\(s.title)”: \(why)")
            }
        }
    }

    /// Opens the confirm sheet for every session safe to close. `onlyNamed` limits it to names
    /// with that prefix (test runs use "mxtest").
    func closeAllSafe(onlyNamed prefix: String? = nil) {
        let safe = store.safeToClose().filter { prefix.map($0.name.hasPrefix) ?? true }.sorted { $0.lastEventAt > $1.lastEventAt }
        guard !safe.isEmpty else { return toast("Nothing is safe to close yet.") }
        presentClose(safe)
    }

    private func presentClose(_ sessions: [Session]) {
        dismissOverlays()
        let items = sessions.map { s in
            CloseSheet.Item(id: s.id, title: s.title, detail: detail(s, state: store.state), checks: store.checks(s), hash: s.lastMessage.map(Reply.hash))
        }
        closeSheet.present(items, in: root)
    }

    private func performClose(_ items: [CloseSheet.Item]) {
        toast("Checking \(items.count) again before closing…")
        store.close(items.map { ($0.id, $0.hash) }) { [weak self] results in
            guard let self else { return }
            var closed: [SessionID] = [], notes: [String] = []
            for (s, outcome) in results {
                switch outcome {
                case .closed: closed.append(s.id); self.forget(s.id)
                case .skipped(let why): notes.append("skipped \(s.title): \(why)")
                case .failed(let why): notes.append("\(s.title) failed: \(why)")
                }
            }
            let head = closed.isEmpty ? "Closed none." : "Closed \(closed.count) (claude stop, conversation kept)."
            let text = ([head] + notes).joined(separator: " · ")
            mark("close: \(text)")
            if closed.isEmpty { return self.toast(text) }
            self.root.status.show(toast: text, action: ("Undo", { [weak self] in closed.forEach { self?.reopen($0) } }), seconds: 10)
        }
    }

    /// Undo and Recently closed: `claude attach` starts the stopped session again, in its pane.
    func reopen(_ id: SessionID) {
        store.reopened(id)
        guard store.state.sessions[id] != nil else { return toast("Can't reopen: no record of that session.") }
        reattach(id)
        toast("Reopened \(store.state.sessions[id]?.title ?? id).")
    }

    func notSafe(_ id: SessionID) {
        let url = store.markNotSafe(id)
        root.sidebar.list.setExpanded(id, false)
        render(store.state)
        toast("Marked not safe until it does something new. Evidence logged" + (url.map { "; test fixture \($0.lastPathComponent)" } ?? "") + ".")
    }

    // MARK: new session

    func showNewSession() {
        dismissOverlays()
        let state = store.state
        var folders: [String] = []
        for s in state.sessions.values.sorted(by: { $0.lastEventAt > $1.lastEventAt }) where !s.cwd.isEmpty && !folders.contains(s.cwd) {
            folders.append(s.cwd)
        }
        if let c = current.flatMap({ state.sessions[$0]?.cwd }) { folders.removeAll { $0 == c }; folders.insert(c, at: 0) }
        newPanel.present(.init(accounts: state.accounts, defaultAccount: state.roomiest(now: Date())?.id, folders: Array(folders.prefix(5))), in: root)
    }

    func startSession(account: Account, folder: String, name: String, model: String? = nil) {
        newPanel.show(error: "Starting \(name) on \(account.name)…")
        store.newSession(account: account, cwd: folder, name: name, model: model) { [weak self] r in
            guard let self else { return }
            switch r {
            case .success(let id):
                self.newPanel.dismiss()
                self.toast("Started \(name) on \(account.name).")
                self.open(id)
            case .failure(.untrusted):
                self.newPanel.show(error: "Not trusted on \(account.name) yet. Run claude there once and accept.")
            case .failure(let e):
                self.newPanel.show(error: "\(e)")
            }
        }
    }

    // MARK: viewer

    /// The viewer shows the current session's file or artifact and is open exactly when there is one,
    /// unless ⌘\\ overrode that for this session.
    private func syncViewer(reload: Bool = false) {
        let v = current.flatMap { viewers[$0] } ?? ViewerState()
        root.viewerPane.show(v.item, account: current.flatMap(account(of:)), pinned: v.pinned, reload: reload)
        root.setViewer(open: viewerForced ?? (v.item != nil), animated: window?.isVisible == true)
        updateDim()
    }

    /// The account a session runs on: its artifacts open signed in to it.
    private func account(of id: SessionID) -> Account? {
        store.state.sessions[id].flatMap { store.state.account($0.accountId) }
    }

    func toggleViewer() {
        viewerForced = !root.viewerOpen
        syncViewer()
    }

    private func showViewer(for id: SessionID) {
        var v = viewers[id] ?? ViewerState()
        syncViewer()
        guard !v.scanned, let s = store.state.sessions[id] else { return }
        v.scanned = true
        viewers[id] = v
        guard store.config.autoOpen, let path = Transcripts.path(s, account: store.state.account(s.accountId)) else { return }
        DispatchQueue.global().async { [weak self] in
            let item = Transcripts.lastItem(transcript: path, cwd: s.cwd)
            DispatchQueue.main.async { if let item { self?.itemSeen(id, item, reload: false) } }
        }
    }

    /// A session wrote or named a file, or published, opened or named an artifact.
    /// A republish of what the viewer shows reloads it in place, pinned or not.
    private func itemSeen(_ id: SessionID, _ item: ViewerItem, reload: Bool) {
        var v = viewers[id] ?? ViewerState()
        if item.same(as: v.item) {
            // Keep the title the page gave; take the transcript's when there was none.
            if case .artifact(let l, let t?) = item, case .artifact(_, nil)? = v.item { v.item = .artifact(l, title: t) }
            viewers[id] = v
            if reload, id == current { syncViewer(reload: true) }
            return
        }
        guard store.config.autoOpen, !v.pinned else { return }
        if item.artifact != nil, store.config.artifacts != "viewer" { return }
        v.item = item
        viewers[id] = v
        if id == current { viewerForced = nil; syncViewer() }
    }

    func showFile(_ url: URL, for id: SessionID?) { show(.file(url), for: id) }

    func show(_ item: ViewerItem, for id: SessionID?) {
        guard let id else { return }
        var v = viewers[id] ?? ViewerState()
        v.item = item
        viewers[id] = v
        if id == current { viewerForced = nil; syncViewer() }
    }

    /// A web link from a session's terminal or file: an artifact opens beside the session, signed in
    /// to its account (or in that account's browser, with `artifacts = browser`); the rest goes to the browser.
    private func openWebLink(_ url: URL, session id: SessionID?) {
        let a = id.flatMap(account(of:))
        if let link = ArtifactLink.parse(url.absoluteString) {
            mark("artifact link \(link.id) -> \(store.config.artifacts) as \(a?.name ?? "none")")
            if store.config.artifacts == "viewer", a != nil { return show(.artifact(link, title: nil), for: id) }
        }
        if let a { openExternally(url, account: a) } else { NSWorkspace.shared.open(url) }
    }

    /// In the browser this account's links go to (Settings › Accounts).
    func openExternally(_ url: URL, account a: Account) {
        let choice = store.config.browser(for: a.name)
        if let why = Browsers.open(url, with: choice) { toast(why) }
        else if choice != .systemDefault { toast("Opened in \(choice.title()) for \(a.name).") }
    }

    func openInBrowser() {
        guard let id = current, let link = viewers[id]?.item?.artifact, let a = account(of: id) else { return toast("No artifact open.") }
        openExternally(link.url, account: a)
    }

    func reloadArtifact() {
        guard let id = current, viewers[id]?.item?.artifact != nil else { return toast("No artifact open.") }
        root.viewerPane.viewer.artifact.reload()
    }

    /// ⌘-click in a terminal: files open in that session's viewer, web links as above.
    private func openURL(_ raw: String, cwd: String?, session id: SessionID) {
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            if let u = URL(string: raw) { openWebLink(u, session: id) }
            return
        }
        var path = raw.hasPrefix("file://") ? (URL(string: raw)?.path ?? raw) : raw
        if let r = path.range(of: #":\d+(:\d+)?$"#, options: .regularExpression) { path.removeSubrange(r) }
        path = (path as NSString).expandingTildeInPath
        // A relative path is the session's: its cwd moves into a worktree while the terminal's
        // (where `claude attach` started) stays put, so try the session first.
        let bases = path.hasPrefix("/") ? [""] : [store.state.sessions[id]?.cwd, cwd, Paths.home.path].compactMap { $0 }
        let found = bases.lazy.map { URL(fileURLWithPath: ($0 as NSString).appendingPathComponent(path)).standardizedFileURL }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        mark("cmd-click \(raw) -> \(found?.path ?? "not found")")
        guard let url = found else { return toast("No such file: \(raw)") }
        showFile(url, for: id)
    }

    func togglePin() {
        guard let id = current, var v = viewers[id], v.item != nil else { return }
        v.pinned.toggle()
        viewers[id] = v
        syncViewer()
        let what = v.item?.artifact != nil ? "artifacts" : "files"
        toast(v.pinned ? "Pinned. New \(what) from this session wait until you unpin." : "Unpinned.")
    }

    func clearViewer() {
        guard let id = current else { return }
        viewers[id] = ViewerState(item: nil, pinned: false, scanned: true)
        viewerForced = nil
        syncViewer()
    }

    func toggleTree() {
        onConfigEdit?("file-tree", store.config.showTree ? "false" : "true")
    }

    // MARK: overlays, focus, toast

    func toast(_ s: String) { root.status.show(toast: s) }

    private var pluginSignature = ""
    private var pluginRun: [PluginID: PluginStatus.Run] = [:]
    /// Plugins changed: new actions and menu when the set changed, a toast when one stops for good.
    private func pluginsChanged() {
        let host = store.plugins
        let sig = host.manifests.filter { store.config.pluginEnabled($0.id) }.map { "\($0.id)@\($0.version)" }.joined(separator: ",")
        if sig != pluginSignature { pluginSignature = sig; rebuildActions() }
        for (id, st) in host.status {
            if case .failed(let why) = st.run, pluginRun[id] != st.run { toast("\(host.manifest(id)?.name ?? id) stopped: \(why). Settings › Plugins can restart it.") }
            pluginRun[id] = st.run
        }
        root.pluginPanel.update(host: host, state: store.state)
        root.setPluginPanels(!host.panels.isEmpty || host.manifests.contains { !$0.panels.isEmpty && store.config.pluginEnabled($0.id) })
        refreshSettings()
        render(store.state)
    }

    /// ⌘K: the same search, limited to actions.
    func showPalette() { showSearch(query: "> ") }

    /// ⌘P or Shift twice: sessions, projects and actions, what needs him first.
    func showSearch(query: String = "") {
        dismissOverlays()
        search.present(searchItems(), query: query, in: root)
        let transcripts = store.state.sessions.values.compactMap { Transcripts.path($0, account: store.state.account($0.accountId)) }
        TouchedFiles.shared.refresh(transcripts) { [weak self] in
            guard let self, self.search.superview != nil else { return }
            self.search.replace(self.searchItems())
        }
    }

    private func searchItems() -> [SearchItem] {
        let state = store.state, now = Date()
        var items: [SearchItem] = []
        for (g, list) in state.grouped(now: now, rules: store.config.rules) {
            for s in list {
                let acct = state.account(s.accountId)?.name ?? s.accountId
                let project = state.project(s, in: projects)
                let files = Transcripts.path(s, account: state.account(s.accountId)).map { TouchedFiles.shared.files($0) } ?? []
                let recent = visited.firstIndex(of: s.id).map { 16 - $0 * 2 } ?? 0
                let boost = (g == .needsYou ? 30 : g == .yourTurn ? 20 : g == .working ? 4 : 0) + recent
                items.append(SearchItem(kind: .session, title: s.title, fields: [
                    (s.title, 3, ""), (project, 2, ""), (s.branch ?? s.doneCheck?.branch ?? "", 2, "branch"), (acct, 1, ""),
                    (s.lastMessage ?? "", 1, "said"), (files.joined(separator: " "), 1, "edited"), (s.name, 1, ""),
                    (s.hookTitle != s.title ? s.hookTitle ?? "" : "", 2, "was"), (s.firstPrompt ?? "", 1, "asked"),
                ], detail: "\(project.lowercased()) · \(acct) · \(Format.age(s.lastEventAt, now: now))", group: g, boost: boost) { [weak self] in self?.open(s.id) })
            }
        }
        for (i, name) in projectNames.enumerated() {
            items.append(SearchItem(kind: .project, title: name, fields: [(name, 3, "")], detail: i < 9 ? "project ⌘\(i + 1)" : "project", boost: 2) { [weak self] in self?.setScope(name) })
        }
        for a in actions {
            items.append(SearchItem(kind: .action, title: a.title, fields: [(a.title, 2, ""), (a.menu, 1, "")], detail: a.shortcut?.display ?? "", enabled: a.isEnabled(), run: a.run))
        }
        return items
    }

    /// Test hook: the tooltip a pointer resting at `p` (top-left origin) would show. False when nothing has one.
    func showTooltip(at p: NSPoint, inSettings: Bool, cold: Bool) -> Bool {
        let (w, tips) = inSettings ? (settings.window, settings.tooltips) : (window, tooltips)
        guard let w, let tips else { return false }
        tips.frozen = true
        return tips.hover(at: NSPoint(x: p.x, y: w.frame.height - p.y), immediately: !cold)
    }

    func showSettings(_ section: SettingsSection? = nil) {
        let v = settings.view
        v.onSet = { [weak self] k, val in self?.onConfigEdit?(k, val) }
        v.onPreview = { [weak self] k, val in self?.preview(k, val) }
        v.onAppearance = { [weak self] in self?.setAppearance($0) }
        v.onInstallHooks = { [weak self] in self?.installHooks() }
        v.onUninstallHooks = { [weak self] in self?.uninstallHooks() }
        v.onAddAccount = { [weak self] in self?.addAccount() }
        v.onBrowser = { [weak self] account, choice in self?.onConfigEdit?("browser:\(account)", choice?.line ?? "") }
        v.onRunAction = { [weak self] id in self?.actions.first { $0.id == id }?.run() }
        v.onPluginSecret = { [weak self] id, key, value in
            self?.store.plugins.setSecret(id, key, value)
            self?.refreshSettings()
        }
        v.onPluginRestart = { [weak self] in self?.store.plugins.restart($0) }
        settings.show(settingsModel, section: section)
    }

    private var settingsModel: SettingsModel {
        SettingsModel(config: store.config, hookStatus: hookStatus, accounts: store.state.accounts, projects: projectNames, projectRoots: projectRoots,
                      actions: actions.map { ($0.id, $0.title, $0.menu, $0.shortcut?.display ?? "") }.sorted { $0.menu < $1.menu },
                      themeName: Look.theme.name, systemDark: SystemAppearance.isDark,
                      updateReady: updater.ready?.version, updateStatus: updateStatus,
                      plugins: store.plugins.manifests.map { m in
                          PluginInfo(manifest: m, status: store.plugins.status[m.id] ?? PluginStatus(run: .off),
                                     secretsSet: Set(m.settings.filter { $0.type == .secret && store.plugins.secrets.get(m.id, $0.key) != nil }.map(\.key)))
                      },
                      brokenPlugins: store.plugins.broken.map { ($0.dir.lastPathComponent, "\($0.why)") },
                      pluginsFolder: (store.plugins.paths.user.path as NSString).abbreviatingWithTildeInPath)
    }

    /// Adds `account = <name> <dir>` for a folder that holds a Claude login.
    func addAccount() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.showsHiddenFiles = true
        p.directoryURL = Paths.home
        p.message = "Pick the account's CLAUDE_CONFIG_DIR (a folder like ~/.claude-work)"
        guard p.runModal() == .OK, let url = p.url else { return }
        let name = url.lastPathComponent.replacingOccurrences(of: ".claude-", with: "").replacingOccurrences(of: ".claude", with: "default")
        let lines = store.config.accounts.map { "\($0.name) \(($0.configDir.path as NSString).abbreviatingWithTildeInPath)" }
            + ["\(name) \((url.path as NSString).abbreviatingWithTildeInPath)"]
        onConfigEdit?("account", lines.joined(separator: "\n") + "\n")
        toast("Added account \(name).")
    }

    var hookStatus: String {
        let files = HookInstaller.settingsFiles(store.config.accounts)
        let installed = files.filter { ((try? String(contentsOf: $0, encoding: .utf8)) ?? "").contains(HookInstaller.marker) }.count
        return installed == files.count && !files.isEmpty ? "installed in \(installed) settings file\(installed == 1 ? "" : "s")" : "not installed (\(installed)/\(files.count))"
    }

    func installHooks() {
        do {
            let r = try HookInstaller.install(accounts: store.config.accounts, bundledHook: bundledHookURL())
            NSLog("install-hooks:\n%@", r.description)
            toast("Hooks installed. Backups sit next to each settings file.")
        } catch { toast("Install failed: \(error)") }
        refreshSettings()
    }

    func uninstallHooks() {
        do {
            _ = try HookInstaller.uninstall(accounts: store.config.accounts)
            toast("Hooks removed.")
        } catch { toast("Uninstall failed: \(error)") }
        refreshSettings()
    }

    func refreshSettings() {
        if settings.window?.isVisible == true { settings.view.update(settingsModel) }
    }

    private var topOverlay: NSView? { [closeSheet, newPanel, search].first { $0.superview != nil } }

    private func dismiss(_ v: NSView) {
        if v === search { search.dismiss() } else if v === newPanel { newPanel.dismiss() } else if v === closeSheet { closeSheet.dismiss() }
    }

    /// Where ⌘T starts: the open session's folder when it belongs to the project on screen,
    /// else that project's most recent folder of its own. Nil when the project has none.
    private func folderHere(_ state: AppState) -> String? {
        let inScope = { (s: Session) in !s.cwd.isEmpty && (self.scope == nil || state.project(s, in: self.projects) == self.scope) }
        if let s = current.flatMap({ state.sessions[$0] }), inScope(s) { return s.cwd }
        let own = state.sessions.values.filter { inScope($0) && (self.scope == nil || self.projects.name(for: $0.cwd) == self.scope) }
        guard let recent = own.max(by: { $0.lastEventAt < $1.lastEventAt }) else { return nil }
        return scope == nil ? recent.cwd : (repoRoot(recent.cwd) ?? recent.cwd)
    }

    private var updateStatus: String?

    func checkForUpdates() {
        guard Updater.isRelease else { return toast("Maxwell Dev doesn't update itself. Releases go to Maxwell.") }
        toast("Checking for updates…")
        updateStatus = "Checking…"; refreshSettings()
        updater.check { [weak self] r in
            guard let self else { return }
            switch r {
            case .upToDate: self.updateStatus = "\(Updater.current) is the latest."
            case .ready(let v): self.updateStatus = nil; self.toast("v\(v) is ready. Restart to update, bottom right.")
            case .failed(let m): self.updateStatus = m
            }
            if let s = self.updateStatus { self.toast(s) }
            self.refreshSettings()
        }
    }

    /// ⌘T: a new session in the current session's folder on the account with the most room, no questions.
    func newSessionHere() {
        dismissOverlays()
        guard startHere(prompt: nil, name: nil, cwd: nil, model: nil, done: { _ in }) else { return showNewSession() }
    }

    /// ⌘T and a plugin's `session/start`: the current folder (or `cwd`), the account with the most room.
    /// False when there is no folder or account to start in.
    @discardableResult
    func startHere(prompt: String?, name: String?, cwd: String?, model: String?, done: @escaping (Result<SessionID, PluginHost.StartFailure>) -> Void) -> Bool {
        let state = store.state
        guard let folder = cwd ?? folderHere(state), let a = state.roomiest(now: Date()) ?? state.accounts.first else { return false }
        let base = name ?? (folder as NSString).lastPathComponent.lowercased().replacingOccurrences(of: " ", with: "-")
        let name = "\(base)-\(String(format: "%02x", Int.random(in: 0..<256)))"
        toast("Starting \(name) on \(a.name)…")
        store.newSession(account: a, cwd: folder, name: name, model: model, prompt: prompt) { [weak self] r in
            guard let self else { return }
            switch r {
            case .success(let id): self.toast("Started \(name) on \(a.name)."); self.open(id); done(.success(id))
            case .failure(.untrusted):
                let why = "Not trusted on \(a.name) yet. Run claude there once and accept."
                self.toast(why); done(.failure(.init(message: why)))
            case .failure(let e): self.toast("\(e)"); done(.failure(.init(message: "\(e)")))
            }
        }
        return true
    }

    private func dismissOverlays() {
        if search.superview != nil { search.removeFromSuperview() }
        if newPanel.superview != nil { newPanel.removeFromSuperview() }
        if closeSheet.superview != nil { closeSheet.removeFromSuperview() }
    }

    func focusMain() {
        if let id = current, let t = terminals[id], !detached.contains(id) { window?.makeFirstResponder(t) }
        else { window?.makeFirstResponder(root.sidebar.list) }
    }

    func focus(_ pane: Int) {
        switch pane {
        case 1: window?.makeFirstResponder(root.sidebar.list)
        case 2: focusMain()
        default: if root.viewerPane.viewer.current != nil || root.viewerPane.viewer.currentArtifact != nil { window?.makeFirstResponder(root.viewerPane.viewer.container.subviews.first { !$0.isHidden }) }
        }
    }

    /// Ghostty config from the theme tokens. In dark themes the terminal draws no background of
    /// its own, so the glass shows through. Light themes get an opaque paper sheet: Ghostty's
    /// minimum-contrast measures against the terminal's own background, and only then turns
    /// Claude Code's dark-theme white text into ink.
    static func ghosttyConfig(_ t: Theme, fontSize: CGFloat) -> String {
        """
        font-family = \(Fonts.family)
        font-size = \(Int(fontSize))
        background = \(t.dark ? t.background.hex : t.panel.hex)
        background-opacity = \(t.dark ? 0 : 1)
        foreground = \(t.terminalForeground.hex)
        cursor-color = \(t.terminalCursor.hex)
        selection-background = \(t.terminalSelection.hex)
        selection-foreground = \(t.terminalForeground.hex)
        window-padding-x = 10
        window-padding-y = 6
        window-padding-balance = true
        cursor-style = bar
        shell-integration = zsh
        scrollback-limit = 20000000
        confirm-close-surface = false
        mouse-hide-while-typing = true
        \(t.dark ? "" : "minimum-contrast = 3.5")
        """
    }

    /// Config keys that change the layout rather than the colours.
    func applyLayout(_ c: Config) {
        root.opacity = c.backgroundOpacity.map { CGFloat($0) }
        root.sidebar.list.compact = c.rowStyle == "compact"
        root.railMode = c.projectNav == "tabs" ? .off : c.rail == "shown" ? .shown : .auto
        root.rail.mode = c.rail
        root.railDelay = c.railDelay
        root.rail.logoStyle = c.logoStyle
        root.sidebar.showTabs = c.projectNav == "tabs"
        let logos = ProjectLogos.shared
        let style = ProjectLogos.Style(rawValue: c.logoStyle) ?? .engraved
        if logos.style != style || logos.overrides != c.logos { logos.style = style; logos.overrides = c.logos; logos.reset() }
        root.rail.needsDisplay = true
        Motion.off = c.motion == "off"
        applyGlass(c)
    }

    /// Tint from `background-opacity`, frost from `background-blur` (or the theme's), else the macOS material.
    func applyGlass(_ c: Config, opacity: Double? = nil, blur: Double?? = nil) {
        root.opacity = (opacity ?? c.backgroundOpacity).map { CGFloat($0) }
        let radius: Double? = blur ?? c.backgroundBlur ?? Look.theme.backgroundBlur.map(Double.init)
        glass.isHidden = radius != nil
        if let w = window { WindowBlur.set(w, radius: Int(radius ?? 0)) }
    }

    /// Settings sliders preview here; the config is written when the slider is released.
    func preview(_ key: String, _ v: Double?) {
        switch key {
        case "background-opacity": applyGlass(store.config, opacity: v)
        case "background-blur": applyGlass(store.config, blur: .some(v))
        default: break
        }
    }

    /// The theme for the current appearance: the fixed `theme =`, or the light/dark pair.
    func themeName(_ c: Config) -> String { c.theme(systemDark: SystemAppearance.isDark) }

    /// Light, Dark or System. A fixed `theme =` moves into its side of the pair first, so the switch works.
    func setAppearance(_ mode: String) {
        if let o = store.config.themeOverride {
            onConfigEdit?(Theme.load(o).dark ? "theme-dark" : "theme-light", o)
            onConfigEdit?("theme", "")
        }
        onConfigEdit?("appearance", mode)
    }

    func toggleLightDark() { setAppearance(Look.theme.dark ? "light" : "dark") }

    func applyLook(_ c: Config) {
        applyLayout(c)
        Metrics.fontSize = CGFloat(c.fontSize - 1)
        let theme = Theme.load(themeName(c))
        Look.set(theme)
        window?.appearance = theme.appearance
        root.viewerPane.viewer.setTheme(theme, fontSize: Metrics.fontSize, prose: c.viewerFont)
        root.viewerPane.showTree = c.showTree
        GhosttyRuntime.shared.update(configText: Self.ghosttyConfig(theme, fontSize: CGFloat(c.terminalFontSize)), surfaces: Array(terminals.values))
        root.needsLayout = true
        root.needsDisplay = true
        render(store.state)
        refreshSettings()
    }

    // MARK: actions

    /// Actions and the menu bar again, for plugins that came or went.
    func rebuildActions() {
        actions = makeActions()
        NSApp.mainMenu = MenuBuilder.build(actions)
    }

    private func makeActions() -> [Action] {
        let hasCurrent: () -> Bool = { [weak self] in self?.current != nil }
        let hasArtifact: () -> Bool = { [weak self] in
            guard let self, let id = self.current else { return false }
            return self.viewers[id]?.item?.artifact != nil
        }
        let limited: () -> Bool = { [weak self] in
            guard let self, let id = self.current, case .limited = self.store.state.sessions[id]?.phase else { return false }
            return true
        }
        var list: [Action] = [
            Action(id: "new-session", title: "New Session…", menu: "Session", shortcut: Shortcut("cmd+n")) { [weak self] in self?.showNewSession() },
            Action(id: "new-session-here", title: "New Session Here", menu: "Session", shortcut: Shortcut("cmd+t")) { [weak self] in self?.newSessionHere() },
            Action(id: "search", title: "Search Everywhere…", menu: "View", shortcut: Shortcut("cmd+p")) { [weak self] in self?.showSearch() },
            Action(id: "palette", title: "All Actions…", menu: "View", shortcut: Shortcut("cmd+k")) { [weak self] in self?.showPalette() },
            Action(id: "next-session", title: "Next Session", menu: "Session", shortcut: Shortcut("cmd+]")) { [weak self] in self?.step(1) },
            Action(id: "prev-session", title: "Previous Session", menu: "Session", shortcut: Shortcut("cmd+[")) { [weak self] in self?.step(-1) },
            Action(id: "next-needs-you", title: "Next Session That Needs You", menu: "Session", shortcut: Shortcut("cmd+j")) { [weak self] in self?.nextNeedsYou() },
            Action(id: "reattach", title: "Reattach Terminal", menu: "Session", shortcut: Shortcut("cmd+r"), isEnabled: hasCurrent) { [weak self] in
                if let id = self?.current { self?.reattach(id) }
            },
            Action(id: "resume", title: "Resume When the Limit Resets", menu: "Session", shortcut: Shortcut("cmd+shift+r"), isEnabled: limited) { [weak self] in
                if let id = self?.current { self?.resume(id) }
            },
            Action(id: "move", title: "Move to the Account With Most Room", menu: "Session", shortcut: Shortcut("cmd+shift+m"), isEnabled: limited) { [weak self] in
                if let id = self?.current { self?.move(id) }
            },
            Action(id: "undo-close", title: "Undo Close", menu: "Session", shortcut: Shortcut("cmd+z"), isEnabled: { [weak self] in self?.root.status.toastAction != nil }) { [weak self] in
                self?.root.status.runToastAction()
            },
            Action(id: "close-session", title: "Close Session", menu: "Session", shortcut: Shortcut("cmd+shift+backspace"), isEnabled: hasCurrent) { [weak self] in
                if let id = self?.current { self?.close(id) }
            },
            Action(id: "close-all-safe", title: "Close All Safe Sessions", menu: "Session", shortcut: Shortcut("cmd+shift+x")) { [weak self] in self?.closeAllSafe() },
            Action(id: "close-tab", title: "Close Tab (session keeps running)", menu: "Session", shortcut: Shortcut("cmd+w"), isEnabled: hasCurrent) { [weak self] in
                if let id = self?.current { self?.forget(id) }
            },
            Action(id: "recheck", title: "Re-run Done Checks", menu: "Session", shortcut: Shortcut("cmd+shift+d")) { [weak self] in
                self?.store.recheckAll(); self?.toast("Checking worktrees and PRs…")
            },
            Action(id: "toggle-idle", title: "Show or Hide Idle Sessions", menu: "View", shortcut: Shortcut("cmd+shift+i")) { [weak self] in
                self?.root.sidebar.list.toggleIdle()
            },
            Action(id: "focus-terminal", title: "Focus Terminal", menu: "Panels", shortcut: Shortcut("cmd+alt+2")) { [weak self] in self?.focus(2) },
            Action(id: "toggle-left", title: "Show or Hide Left Panels", menu: "Panels", shortcut: Shortcut("cmd+b")) { [weak self] in self?.root.toggleArea(.left) },
            Action(id: "toggle-right", title: "Show or Hide Right Panels", menu: "Panels", shortcut: Shortcut("cmd+alt+b")) { [weak self] in self?.root.toggleArea(.right) },
            Action(id: "toggle-bottom", title: "Show or Hide Bottom Panel", menu: "Panels", shortcut: Shortcut("cmd+alt+j")) { [weak self] in self?.root.toggleArea(.bottom) },
            Action(id: "reset-panels", title: "Reset Panel Layout", menu: "Panels") { [weak self] in self?.root.panels = PanelLayout() },
            Action(id: "project-all", title: "All Projects: What Needs You", menu: "Projects", shortcut: Shortcut("cmd+0")) { [weak self] in self?.selectProject(0) },
            Action(id: "toggle-viewer", title: "Show or Hide Viewer", menu: "View", shortcut: Shortcut("cmd+\\")) { [weak self] in self?.toggleViewer() },
            Action(id: "pin", title: "Pin or Unpin File", menu: "View", shortcut: Shortcut("cmd+alt+p"), isEnabled: hasCurrent) { [weak self] in self?.togglePin() },
            Action(id: "reload-artifact", title: "Reload Artifact", menu: "View", shortcut: Shortcut("cmd+alt+r"), isEnabled: hasArtifact) { [weak self] in self?.reloadArtifact() },
            Action(id: "open-in-browser", title: "Open Artifact in Browser", menu: "View", shortcut: Shortcut("cmd+shift+o"), isEnabled: hasArtifact) { [weak self] in self?.openInBrowser() },
            Action(id: "toggle-tree", title: "Show or Hide File Tree", menu: "View", shortcut: Shortcut("cmd+shift+t")) { [weak self] in self?.toggleTree() },
            Action(id: "font-bigger", title: "Bigger Terminal Text", menu: "View", shortcut: Shortcut("cmd+=")) { [weak self] in
                guard let self else { return }; self.onConfigEdit?("terminal-font-size", "\(Int(min(28, self.store.config.terminalFontSize + 1)))")
            },
            Action(id: "font-smaller", title: "Smaller Terminal Text", menu: "View", shortcut: Shortcut("cmd+-")) { [weak self] in
                guard let self else { return }; self.onConfigEdit?("terminal-font-size", "\(Int(max(8, self.store.config.terminalFontSize - 1)))")
            },
        ]
        let pluginPanel: () -> Bool = { [weak self] in self?.root.hasPluginPanels == true }
        for p in PanelID.allCases {
            list.append(Action(id: "panel-\(p.rawValue)", title: "\(p.title) Panel", menu: "Panels", shortcut: Shortcut("cmd+alt+\(p.key)"),
                               isEnabled: p == .plugins ? pluginPanel : { true }) { [weak self] in self?.togglePanel(p) })
        }
        for p in PanelID.allCases {
            for d in Dock.allCases {
                list.append(Action(id: "move-\(p.rawValue)-\(d.rawValue)", title: "Move \(p.title) to \(d.title)", menu: "Panels") { [weak self] in self?.movePanel(p, to: d) })
            }
        }
        for n in 1...9 {
            list.append(Action(id: "project-\(n)", title: "Project \(n)", menu: "Projects", shortcut: Shortcut("cmd+\(n)")) { [weak self] in self?.selectProject(n) })
        }
        list += [
            Action(id: "appearance-toggle", title: "Switch Light and Dark", menu: "View", shortcut: Shortcut("cmd+shift+l")) { [weak self] in self?.toggleLightDark() },
            Action(id: "appearance-system", title: "Appearance: Follow System", menu: "View") { [weak self] in self?.setAppearance("system") },
            Action(id: "appearance-light", title: "Appearance: Light", menu: "View") { [weak self] in self?.setAppearance("light") },
            Action(id: "appearance-dark", title: "Appearance: Dark", menu: "View") { [weak self] in self?.setAppearance("dark") },
        ]
        list += [
            Action(id: "settings", title: "Settings…", menu: "Maxwell", shortcut: Shortcut("cmd+,")) { [weak self] in self?.showSettings() },
            Action(id: "open-config", title: "Open Config File", menu: "Maxwell", shortcut: Shortcut("cmd+shift+,")) { NSWorkspace.shared.open(Paths.configFile) },
            Action(id: "toggle-rail", title: "Keep Projects Rail Shown", menu: "Projects", shortcut: Shortcut("cmd+ctrl+p"),
                   isChecked: { [weak self] in self?.store.config.rail == "shown" }) { [weak self] in
                guard let self else { return }; self.onConfigEdit?("rail", self.store.config.rail == "shown" ? "auto" : "shown")
            },
            Action(id: "bring-all-in", title: "Bring Terminal Sessions into Maxwell…", menu: "Session") { [weak self] in self?.bringAllIn() },
            Action(id: "check-updates", title: "Check for Updates…", menu: "Maxwell") { [weak self] in self?.checkForUpdates() },
            Action(id: "install-update", title: "Restart to Update", menu: "Maxwell", isEnabled: { [weak self] in self?.updater.ready != nil }) { [weak self] in self?.updater.install() },
            Action(id: "install-hooks", title: "Install Hooks", menu: "Maxwell", shortcut: Shortcut("cmd+shift+h")) { [weak self] in self?.installHooks() },
            Action(id: "uninstall-hooks", title: "Uninstall Hooks", menu: "Maxwell", shortcut: Shortcut("cmd+shift+u")) { [weak self] in self?.uninstallHooks() },
        ]
        // Plugin actions: menu, ⌘K and a default shortcut unless a built-in one already has it.
        let taken = Set(list.compactMap { $0.shortcut?.display })
        for m in store.plugins.manifests where store.config.pluginEnabled(m.id) {
            for a in m.actions {
                let key = a.shortcut.flatMap(Shortcut.init).flatMap { taken.contains($0.display) ? nil : $0 }
                list.append(Action(id: "\(m.id).\(a.id)", title: a.title, menu: "Plugins", shortcut: key,
                                   isEnabled: { [weak self] in self.map { $0.pluginActionEnabled(m, a, session: $0.current) } ?? false }) { [weak self] in
                    guard let self else { return }
                    self.store.runPluginAction(m.id, a.id, session: a.scope == .session ? self.current : nil)
                })
            }
        }
        let binds = store.config.keybinds
        return list.map { a in
            var a = a
            if let spec = binds[a.id] { a.shortcut = spec == "none" ? nil : Shortcut(spec) }
            return a
        }
    }
}
