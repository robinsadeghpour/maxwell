import AppKit

/// ⌘N: folder, account (default: most room), name. ⏎ starts `claude --bg` and attaches.
final class NewSessionPanel: MXView, NSTextFieldDelegate {
    struct Choice { var accounts: [Account]; var defaultAccount: AccountID?; var folders: [String] }
    private var choice = Choice(accounts: [], defaultAccount: nil, folders: [])
    private var folder: String = ""
    private var account: AccountID?
    private let name = NSTextField()
    private let folderButton = MXButton("Choose folder…", hint: "⌘O")
    private let start = MXButton("Start", hint: "⏎", primary: true)
    private let cancel = MXButton("Cancel", hint: "esc")
    private var accountButtons: [MXButton] = []
    private var folderButtons: [MXButton] = []
    private var message: String?
    var onStart: ((Account, String, String) -> Void)?
    var onClose: (() -> Void)?
    static let width: CGFloat = 560

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        name.isBordered = false
        name.drawsBackground = false
        name.focusRingType = .none
        name.font = Fonts.mono()
        name.delegate = self
        folderButton.action = { [weak self] in self?.chooseFolder() }
        start.action = { [weak self] in self?.submit() }
        cancel.action = { [weak self] in self?.dismiss() }
        [name, folderButton, start, cancel].forEach(addSubview)
        lookChanged()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func lookChanged() {
        super.lookChanged()
        name.textColor = t.fg
    }

    func present(_ c: Choice, in host: NSView) {
        choice = c
        account = c.defaultAccount ?? c.accounts.first?.id
        folder = c.folders.first ?? Paths.home.path
        message = nil
        rebuild()
        name.stringValue = suggestedName()
        frame = NSRect(x: (host.bounds.width - Self.width) / 2, y: 64, width: Self.width, height: height)
        host.addSubview(self)
        Motion.appear(self)
        window?.makeFirstResponder(name)
    }

    func show(error: String) {
        message = error
        needsDisplay = true
    }

    private var height: CGFloat { 40 + 3 * 34 + CGFloat(min(5, choice.folders.count)) * 26 + 64 }

    private func suggestedName() -> String {
        let base = (folder as NSString).lastPathComponent.lowercased().replacingOccurrences(of: " ", with: "-")
        return "\(base)-\(String(format: "%02x", Int.random(in: 0..<256)))"
    }

    private func rebuild() {
        accountButtons.forEach { $0.removeFromSuperview() }
        folderButtons.forEach { $0.removeFromSuperview() }
        accountButtons = choice.accounts.enumerated().map { i, a in
            let left = a.usedPercent.map { " \(100 - Int(min($0, 100)))% left" } ?? ""
            let b = MXButton(a.name + left, hint: "⌘\(i + 1)") { [weak self] in self?.account = a.id; self?.refreshButtons() }
            addSubview(b)
            return b
        }
        folderButtons = choice.folders.prefix(5).map { f in
            let b = MXButton((f as NSString).abbreviatingWithTildeInPath) { [weak self] in
                self?.folder = f
                self?.name.stringValue = self?.suggestedName() ?? ""
                self?.refreshButtons()
            }
            addSubview(b)
            return b
        }
        refreshButtons()
        needsLayout = true
    }

    private func refreshButtons() {
        for (i, a) in choice.accounts.enumerated() { accountButtons[i].isOn = a.id == account }
        for (i, f) in choice.folders.prefix(5).enumerated() { folderButtons[i].isOn = f == folder }
        needsDisplay = true
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.directoryURL = URL(fileURLWithPath: folder)
        p.beginSheetModal(for: window!) { [weak self] r in
            guard r == .OK, let self, let u = p.url else { return }
            self.folder = u.path
            if !self.choice.folders.contains(u.path) { self.choice.folders.insert(u.path, at: 0) }
            self.rebuild()
            self.name.stringValue = self.suggestedName()
            self.frame.size.height = self.height
            self.window?.makeFirstResponder(self.name)
        }
    }

    private func submit() {
        guard let a = choice.accounts.first(where: { $0.id == account }) else { return }
        let n = name.stringValue.trimmingCharacters(in: .whitespaces)
        onStart?(a, folder, n.isEmpty ? suggestedName() : n)
    }

    func dismiss() {
        removeFromSuperview()
        onClose?()
    }

    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)): submit(); return true
        case #selector(NSResponder.cancelOperation(_:)): dismiss(); return true
        default: return false
        }
    }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard e.modifierFlags.contains(.command), let k = e.charactersIgnoringModifiers else { return false }
        if k == "o" { chooseFolder(); return true }
        if let n = Int(k), (1...choice.accounts.count).contains(n) { account = choice.accounts[n - 1].id; refreshButtons(); return true }
        return false
    }

    override func layout() {
        super.layout()
        let labelW: CGFloat = 80, x0: CGFloat = 14 + labelW
        var y: CGFloat = 40
        var x = x0
        for b in accountButtons {
            let s = b.intrinsicContentSize
            b.frame = NSRect(x: x, y: y + 6, width: s.width, height: s.height)
            x += s.width + 6
        }
        y += 34
        let fs = folderButton.intrinsicContentSize
        folderButton.frame = NSRect(x: x0, y: y + 6, width: fs.width, height: fs.height)
        y += 34
        for b in folderButtons {
            let s = b.intrinsicContentSize
            b.frame = NSRect(x: x0, y: y + 2, width: min(s.width, bounds.width - x0 - 14), height: s.height)
            y += 26
        }
        y += 6
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
        Text.draw("claude --bg in the folder, attached here", in: NSRect(x: 150, y: 6, width: bounds.width - 164, height: 24), color: t.fg3, align: .right)
        t.hair2.setFill(); NSRect(x: 0, y: 35, width: bounds.width, height: 1).fill()
        var y: CGFloat = 40
        Text.draw("account", in: NSRect(x: 14, y: y, width: 80, height: 34), color: t.fg2)
        y += 34
        Text.draw("folder", in: NSRect(x: 14, y: y, width: 80, height: 34), color: t.fg2)
        y += 34 + CGFloat(min(5, choice.folders.count)) * 26 + 6
        Text.draw("name", in: NSRect(x: 14, y: y, width: 80, height: 32), color: t.fg2)
        t.hair.setFill(); NSRect(x: 94, y: y + 28, width: bounds.width - 108, height: 1).fill()
        if let message {
            Text.draw(message, in: NSRect(x: 14, y: bounds.height - 34, width: bounds.width - 200, height: 22), color: t.on)
        }
    }
}
