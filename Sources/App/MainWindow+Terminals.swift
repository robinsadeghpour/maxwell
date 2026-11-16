import AppKit

/// Plain terminals in the window: opening one, naming it, finding it, closing it (with Undo, and a
/// question first when a command is still running), and bringing them back after a restart.
extension MainWindowController {
    /// A new terminal at the top of the sidebar, in the session's folder (or the one ⌘T would start in), opened in the pane.
    /// `command`: run first in the new terminal's shell, which stays open after it.
    func openShell(in folder: String? = nil, command: String? = nil) {
        dismissOverlays()
        let state = store.state
        let here = current.flatMap { state.sessions[$0]?.cwd } ?? shell(current)?.cwd
        let usable = { (f: String?) in f.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } }
        let dir = usable(folder) ?? usable(here) ?? folderHere(state) ?? Paths.home.path
        open(makeShell(in: dir, command: command))
        saveShells()
    }

    /// A terminal's shell and row, not yet shown. `at`: its place in the list (the end by default).
    func makeShell(in dir: String, command: String? = nil, at index: Int? = nil) -> String {
        let size = root.sessionPane.content.bounds.size
        shellsMade += 1
        let id = "shell-\(shellsMade)"
        let shellThen = command.map { "/bin/zsh -lc " + Self.shellQuote($0 + "; exec /bin/zsh -l") }
        let t = TerminalView(frame: NSRect(origin: .zero, size: size == .zero ? NSSize(width: 800, height: 600) : size), workingDirectory: dir,
                             command: shellThen, env: [TerminalHosts.envKey: TerminalHosts.tag(id)])
        t.onExit = { [weak self] in self?.closeShell(id) }
        t.onCwd = { [weak self] in if let self { self.render(self.store.state); self.saveShells() } }
        t.onOpenURL = { raw, cwd in
            if raw.hasPrefix("http://") || raw.hasPrefix("https://") { if let u = URL(string: raw) { NSWorkspace.shared.open(u) }; return }
            // Folders too: they open in Finder.
            if let u = FileLink.resolve(raw, bases: [cwd ?? dir], home: Paths.home.path, isFile: { FileManager.default.fileExists(atPath: $0) }) {
                NSWorkspace.shared.open(u)
            }
        }
        shells.insert((id, t), at: min(index ?? shells.count, shells.count))
        return id
    }

    /// The terminals open when Maxwell last quit, fresh shells in the same folders, with their names.
    func restoreShells() {
        for saved in SavedTerminals.load().terminals {
            shellNames[makeShell(in: Self.reopenFolder(saved.folder))] = saved.name
        }
        if !shells.isEmpty { mark("reopened \(shells.count) terminal\(shells.count == 1 ? "" : "s")") }
    }

    private static func reopenFolder(_ folder: String) -> String {
        SavedTerminals.reopenFolder(folder, home: Paths.home.path) { FileManager.default.fileExists(atPath: $0) }
    }

    func saveShells() {
        SavedTerminals(terminals: shells.map { .init(folder: $0.view.cwd ?? Paths.home.path, name: shellNames[$0.id]) }).save()
    }

    func shellMenu(_ id: String) -> NSMenu {
        let m = NSMenu()
        m.addItem(MenuAction("Rename…") { [weak self] in self?.renameShell(id) })
        m.addItem(.separator())
        m.addItem(MenuAction("Close Terminal") { [weak self] in self?.requestCloseShell(id) })
        return m
    }

    /// Your own name for a terminal; it stays after a restart. Empty goes back to the folder's name.
    func renameShell(_ id: String) {
        guard let t = shell(id) else { return }
        askName("Rename Terminal", note: "Shown in the list, tabs and search. Leave it empty to go back to the folder's name.",
                current: shellNames[id] ?? "", placeholder: Self.folderName(t.cwd)) { [weak self] text in
            guard let self else { return }
            let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
            self.shellNames[id] = name.isEmpty ? nil : name
            self.saveShells()
            self.render(self.store.state)
        }
    }

    /// Closing a terminal you asked to close: a command still running (a dev server, a build) is
    /// asked about first, as Terminal and Ghostty do. Undo brings the terminal back in its place.
    func requestCloseShell(_ id: String) {
        guard let t = shell(id) else { return }
        let title = shellNames[id] ?? Self.folderName(t.cwd)
        mark("close terminal \(title): \(t.hasRunningCommand ? "a command is running, asking" : "at its prompt")")
        guard t.hasRunningCommand, let w = window else { return closeShellWithUndo(id, title: title) }
        let a = NSAlert()
        a.messageText = "“\(title)” is still running a command. Close it anyway?"
        a.informativeText = "Closing the terminal ends what runs in it."
        a.addButton(withTitle: "Close Terminal")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: w) { [weak self] r in
            if r == .alertFirstButtonReturn { self?.closeShellWithUndo(id, title: title) }
        }
    }

    private func closeShellWithUndo(_ id: String, title: String) {
        guard let index = shells.firstIndex(where: { $0.id == id }) else { return }
        let folder = shells[index].view.cwd ?? Paths.home.path, name = shellNames[id]
        closeShell(id)
        root.status.show(toast: "Closed “\(title)”.", action: ("Undo", { [weak self] in
            guard let self else { return }
            let back = self.makeShell(in: Self.reopenFolder(folder), at: index)
            self.shellNames[back] = name
            self.saveShells()
            self.open(back)
        }), seconds: 10)
    }

    /// Ends a terminal's shell and drops its row and tab; the pane goes to the last terminal or session.
    func closeShell(_ id: String) {
        guard let i = shells.firstIndex(where: { $0.id == id }) else { return }
        shells.remove(at: i).view.removeFromSuperview()
        shellNames[id] = nil
        visited.removeAll { $0 == id }
        saveShells()
        if current == id { current = shells.last?.id ?? visited.first }
        if let next = current { open(next) } else { render(store.state); syncViewer() }
    }

    /// The terminals in the sidebar; one running `claude` is shown as that session's row instead.
    func shellRows() -> [ShellRow] {
        let busy = Set(hosted.values)
        return shells.filter { !busy.contains($0.id) }.map { sh in
            let dir = sh.view.cwd ?? Paths.home.path
            return ShellRow(id: sh.id, title: shellNames[sh.id] ?? Self.folderName(dir), detail: (dir as NSString).abbreviatingWithTildeInPath)
        }
    }

    /// Search finds terminals by name and folder.
    func terminalSearchItems() -> [SearchItem] {
        shellRows().map { row in
            let recent = visited.firstIndex(of: row.id).map { 16 - $0 * 2 } ?? 0
            return SearchItem(kind: .terminal, title: row.title, fields: [(row.title, 3, ""), (row.detail, 2, "")],
                              detail: "terminal · \(row.detail)", boost: recent) { [weak self] in self?.open(row.id) }
        }
    }

    static func folderName(_ dir: String?) -> String {
        guard let dir, dir != Paths.home.path else { return "~" }
        return (dir as NSString).lastPathComponent
    }
}
