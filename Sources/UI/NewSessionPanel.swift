import AppKit

/// ⌘N: project, account (default: most room), where, name. ⏎ starts `claude --bg` in the project's
/// folder and attaches; with Cloud, `claude --cloud "<task>"` from the branch's last push instead. The project comes first because the folder decides what Claude sees:
/// inside a project the panel opens on it; from All projects nothing is picked until you pick.
final class NewSessionPanel: MXView, NSTextFieldDelegate {
    struct Choice {
        var accounts: [Account]
        var defaultAccount: AccountID?
        /// Every folder on offer, best first: the open project's, then recent, then found on disk.
        var folders: [ProjectFolder]
        /// The folder to start with; nil from All projects, so the choice is never a guess.
        var preselected: String?
        /// Whether a folder belongs to a project; a session outside one (in ~) sees too much.
        var isProject: (String) -> Bool
        /// The project a folder picked with ⌘O belongs to.
        var projectName: (String) -> String
        /// Whether a folder builds for macOS (an Xcode project or Swift package), which a cloud machine can't.
        var buildsOnMac: (String) -> Bool = { _ in false }
        /// What a cloud session would start from in a folder (git, so the App answers).
        var cloudCheck: (String) -> CloudCheck = { _ in CloudCheck(branch: nil, note: nil, blocks: false) }
        /// Open on Cloud (Start in Cloud) instead of This Mac.
        var cloud = false
    }
    struct CloudCheck { var branch: String?; var note: String?; var blocks: Bool }
    /// The picked folder's check, while Cloud is on.
    private var check: CloudCheck?
    private var choice = Choice(accounts: [], defaultAccount: nil, folders: [], preselected: nil, isProject: { _ in true }, projectName: { $0 })
    private var cloud = false
    private let here = MXButton("This Mac", hint: "⌥⌘↓")
    private let there = MXButton("Cloud", hint: "⌥⌘↑")
    private var shown: [ProjectFolder] = []
    private var index: Int?
    private var account: AccountID?
    private var nameEdited = false
    private lazy var query = PlainField.make(font: Fonts.mono(Metrics.fontSize + 1), delegate: self)
    private lazy var name = PlainField.make(delegate: self)
    private let folderButton = MXButton("Other folder…", hint: "⌘O", small: true)
    private let start = MXButton("Start", hint: "⏎", primary: true)
    private let cancel = MXButton("Cancel", hint: "esc")
    private var accountButtons: [MXButton] = []
    private var message: String?
    var onStart: ((Account, String, String) -> Void)?
    /// Account, folder, task.
    var onStartCloud: ((Account, String, String) -> Void)?
    var onClose: (() -> Void)?
    static let width: CGFloat = 600
    private let maxRows = 7
    private static let header: CGFloat = 36
    private var listTop: CGFloat { Self.header + 36 }
    private var listBottom: CGFloat { listTop + CGFloat(maxRows) * Metrics.row }
    private var height: CGFloat { listBottom + 30 + 24 + 34 + 34 + 34 + 46 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        folderButton.action = { [weak self] in self?.chooseFolder() }
        start.action = { [weak self] in self?.submit() }
        cancel.action = { [weak self] in self?.dismiss() }
        here.action = { [weak self] in self?.setCloud(false) }
        there.action = { [weak self] in self?.setCloud(true) }
        [query, name, folderButton, start, cancel, here, there].forEach(addSubview)
        lookChanged()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func lookChanged() {
        super.lookChanged()
        query.textColor = t.fg
        name.textColor = t.fg
        PlainField.placeholder(query, "Type to find a project…", color: t.fg3)
        PlainField.placeholder(name, cloud ? "What it should do. It starts from the branch's last push." : "", color: t.fg3)
    }

    /// This Mac or Cloud. In the cloud the name row asks for the task, which `claude --cloud` needs.
    private func setCloud(_ on: Bool) {
        cloud = on
        recheck()
        here.isOn = !on
        there.isOn = on
        if on, !nameEdited { name.stringValue = "" }
        if !on, !nameEdited { name.stringValue = suggestedName() }
        lookChanged()
        message = nil
        needsDisplay = true
        if on { window?.makeFirstResponder(name) }
    }

    func present(_ c: Choice, in host: NSView) {
        choice = c
        account = c.defaultAccount ?? c.accounts.first?.id
        message = nil
        nameEdited = false
        query.stringValue = ""
        rebuildAccounts()
        filter()
        index = c.preselected.flatMap { p in shown.firstIndex { $0.path == p } }
        selectionChanged()
        setCloud(c.cloud)
        frame = NSRect(x: (host.bounds.width - Self.width) / 2, y: 64, width: Self.width, height: height)
        host.addSubview(self)
        Motion.appear(self)
        window?.makeFirstResponder(query)
    }

    func show(error: String) {
        message = error
        needsDisplay = true
    }

    private var folder: String? { index.flatMap { shown.indices.contains($0) ? shown[$0].path : nil } }

    private func suggestedName() -> String {
        guard let folder else { return "" }
        let base = (folder as NSString).lastPathComponent.lowercased().replacingOccurrences(of: " ", with: "-")
        return "\(base)-\(String(format: "%02x", Int.random(in: 0..<256)))"
    }

    /// Matches on the project's name first, then the folder's, then the whole path.
    private func filter() {
        let q = query.stringValue.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { shown = choice.folders; return }
        shown = choice.folders.compactMap { f -> (ProjectFolder, Int)? in
            let scores = [(f.project, 3), ((f.path as NSString).lastPathComponent, 3), ((f.path as NSString).abbreviatingWithTildeInPath, 1)]
                .compactMap { text, w in Fuzzy.match(q, in: text).map { $0.score * w } }
            return scores.max().map { (f, $0 + (f.lastUsed == nil ? 0 : 4)) }
        }.sorted { $0.1 > $1.1 }.map(\.0)
    }

    private func selectionChanged() {
        if !nameEdited, !cloud { name.stringValue = suggestedName() }
        recheck()
        message = nil
        needsDisplay = true
    }

    private func recheck() {
        check = cloud ? folder.map(choice.cloudCheck) : nil
        let task = !name.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        start.isEnabled = folder != nil && (!cloud || (task && check?.blocks != true))
    }

    /// What to say about the picked folder: nothing for a project, a warning for anything else.
    private var warning: String? {
        guard let folder else { return shown.isEmpty ? "No project matches. ⌘O picks any folder." : "Pick the project this session works on." }
        if cloud, choice.buildsOnMac(folder) { return "This builds for macOS. A cloud machine runs Linux, so it can't build or run it." }
        if cloud, let note = check?.note { return note }
        guard !choice.isProject(folder) else { return nil }
        return folder == Paths.home.path
            ? "This is your home folder, not a project: Claude would see all of it."
            : "Not a git project. Claude starts here and sees everything below it."
    }

    private func rebuildAccounts() {
        accountButtons.forEach { $0.removeFromSuperview() }
        accountButtons = choice.accounts.enumerated().map { i, a in
            let left = a.usedPercent.map { " \(100 - Int(min($0, 100)))% left" } ?? ""
            let b = MXButton(a.name + left, hint: "⌘\(i + 1)") { [weak self] in self?.account = a.id; self?.refreshAccounts() }
            addSubview(b)
            return b
        }
        refreshAccounts()
        needsLayout = true
    }

    private func refreshAccounts() {
        for (i, a) in choice.accounts.enumerated() { accountButtons[i].isOn = a.id == account }
        needsDisplay = true
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.directoryURL = URL(fileURLWithPath: folder ?? Paths.home.path)
        p.beginSheetModal(for: window!) { [weak self] r in
            guard r == .OK, let self, let u = p.url else { return }
            choice.folders.removeAll { $0.path == u.path }
            choice.folders.insert(ProjectFolder(project: choice.projectName(u.path), path: u.path, lastUsed: nil), at: 0)
            query.stringValue = ""
            filter()
            index = 0
            selectionChanged()
            window?.makeFirstResponder(query)
        }
    }

    private func submit() {
        guard let folder else { return show(error: "Pick a project first.") }
        guard let a = choice.accounts.first(where: { $0.id == account }) else { return }
        let n = name.stringValue.trimmingCharacters(in: .whitespaces)
        if cloud {
            guard !n.isEmpty else { window?.makeFirstResponder(name); return show(error: "Say what the cloud session should do.") }
            return (onStartCloud ?? { _, _, _ in })(a, folder, n)
        }
        onStart?(a, folder, n.isEmpty ? suggestedName() : n)
    }

    func dismiss() {
        removeFromSuperview()
        onClose?()
    }

    func controlTextDidChange(_ n: Notification) {
        if (n.object as? NSTextField) === name { nameEdited = !name.stringValue.isEmpty; recheck(); return }
        filter()
        index = shown.isEmpty ? nil : 0
        selectionChanged()
    }

    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)) where c === query: step(1); return true
        case #selector(NSResponder.moveUp(_:)) where c === query: step(-1); return true
        case #selector(NSResponder.insertNewline(_:)): submit(); return true
        case #selector(NSResponder.cancelOperation(_:)): dismiss(); return true
        default: return false
        }
    }

    private func step(_ d: Int) {
        guard !shown.isEmpty else { return }
        index = index.map { ($0 + d + shown.count) % shown.count } ?? (d > 0 ? 0 : shown.count - 1)
        selectionChanged()
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        guard p.y >= listTop, p.y < listBottom else { return super.mouseDown(with: e) }
        let i = first + Int((p.y - listTop) / Metrics.row)
        guard shown.indices.contains(i) else { return }
        index = i
        selectionChanged()
        if e.clickCount == 2 { submit() }
    }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard e.modifierFlags.contains(.command), let k = e.charactersIgnoringModifiers else { return false }
        if k == "o" { chooseFolder(); return true }
        if e.modifierFlags.contains(.option), e.keyCode == 126 { setCloud(true); return true }
        if e.modifierFlags.contains(.option), e.keyCode == 125 { setCloud(false); return true }
        if let n = Int(k), (1...choice.accounts.count).contains(n) { account = choice.accounts[n - 1].id; refreshAccounts(); return true }
        return false
    }

    private var first: Int { max(0, min((index ?? 0) - maxRows + 1, shown.count - maxRows)) }

    override func layout() {
        super.layout()
        let x0: CGFloat = 94
        query.frame = NSRect(x: x0, y: Self.header + 8, width: bounds.width - x0 - 14, height: 22)
        let fs = folderButton.intrinsicContentSize
        folderButton.frame = NSRect(x: x0, y: listBottom + 6, width: fs.width, height: fs.height)
        var y = listBottom + 30 + 24, x = x0
        for b in accountButtons {
            let s = b.intrinsicContentSize
            b.frame = NSRect(x: x, y: y + 6, width: s.width, height: s.height)
            x += s.width + 6
        }
        y += 34
        let hs = here.intrinsicContentSize, ts = there.intrinsicContentSize
        here.frame = NSRect(x: x0, y: y + 6, width: hs.width, height: hs.height)
        there.frame = NSRect(x: x0 + hs.width + 6, y: y + 6, width: ts.width, height: ts.height)
        y += 34
        name.frame = NSRect(x: x0, y: y + 6, width: bounds.width - x0 - 14, height: 20)
        let ss = start.intrinsicContentSize, cs = cancel.intrinsicContentSize
        start.frame = NSRect(x: bounds.width - 14 - ss.width, y: bounds.height - 12 - ss.height, width: ss.width, height: ss.height)
        cancel.frame = NSRect(x: start.frame.minX - 8 - cs.width, y: start.frame.minY, width: cs.width, height: cs.height)
    }

    override func draw(_ r: NSRect) {
        t.panel.setFill(); bounds.fill()
        t.hair.setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8); border.lineWidth = 1; border.stroke()
        Text.draw("New session", in: NSRect(x: 14, y: 6, width: 200, height: 24), color: t.fg, font: Fonts.mono(Metrics.fontSize, .semibold))
        let place: String
        if cloud {
            place = folder.map { "claude --cloud · " + ($0 as NSString).lastPathComponent + (check?.branch.map { " @ " + $0 } ?? "") } ?? "claude --cloud, shown here"
        } else {
            place = folder.map { "claude --bg in " + ($0 as NSString).abbreviatingWithTildeInPath } ?? "claude --bg, attached here"
        }
        Text.draw(place, in: NSRect(x: 150, y: 6, width: bounds.width - 164, height: 24), color: t.fg3, align: .right)
        t.hair2.setFill(); NSRect(x: 0, y: Self.header - 1, width: bounds.width, height: 1).fill()
        Text.draw("project", in: NSRect(x: 14, y: Self.header, width: 80, height: 36), color: t.fg2)
        t.hair.setFill(); NSRect(x: 94, y: Self.header + 32, width: bounds.width - 108, height: 1).fill()
        drawRows()
        if let warning {
            Text.draw(warning, in: NSRect(x: 94, y: listBottom + 30, width: bounds.width - 108, height: 24), color: folder == nil ? t.fg3 : t.on)
        }
        var y = listBottom + 30 + 24
        Text.draw("account", in: NSRect(x: 14, y: y, width: 80, height: 34), color: t.fg2)
        y += 34
        Text.draw("where", in: NSRect(x: 14, y: y, width: 80, height: 34), color: t.fg2)
        y += 34
        Text.draw(cloud ? "task" : "name", in: NSRect(x: 14, y: y, width: 80, height: 32), color: t.fg2)
        t.hair.setFill(); NSRect(x: 94, y: y + 28, width: bounds.width - 108, height: 1).fill()
        if let message {
            Text.draw(message, in: NSRect(x: 14, y: bounds.height - 34, width: bounds.width - 200, height: 22), color: t.on)
        }
    }

    /// Project name, then its folder; the recent ones carry how long ago.
    private func drawRows() {
        let small = Fonts.mono(Metrics.fontSize - 2)
        for (row, i) in (first..<min(shown.count, first + maxRows)).enumerated() {
            let f = shown[i]
            let rr = NSRect(x: 88, y: listTop + CGFloat(row) * Metrics.row, width: bounds.width - 96, height: Metrics.row)
            let sel = i == index
            if sel {
                t.rowSel.setFill(); NSBezierPath(roundedRect: rr, xRadius: 4, yRadius: 4).fill()
                t.fg.setFill(); NSRect(x: rr.minX, y: rr.minY + 6, width: 2, height: rr.height - 12).fill()
            }
            let age = f.lastUsed.map { Format.age($0) } ?? ""
            let ageW = Text.width(age, font: small)
            Text.draw(age, in: NSRect(x: rr.maxX - ageW - 8, y: rr.minY, width: ageW, height: rr.height), color: t.fg3, font: small)
            let nameW = min(180, Text.width(f.project, font: Fonts.mono()) + 4)
            Text.draw(f.project, in: NSRect(x: rr.minX + 10, y: rr.minY, width: nameW, height: rr.height), color: t.fg)
            let path = (f.path as NSString).abbreviatingWithTildeInPath
            Text.draw(path, in: NSRect(x: rr.minX + 20 + nameW, y: rr.minY, width: rr.width - nameW - ageW - 40, height: rr.height), color: t.fg3, font: small)
        }
    }
}
