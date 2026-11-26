import AppKit

/// One panel a plugin contributes (docs/plugins.md, `panel/set`), as a tool window of its own: its
/// name and count in the header, the plugin's status when it isn't simply running, and a list drawn
/// with the same rows, badges and buttons as the session list.
final class PluginPanel: MXView, PanelContent, TipSource {
    let plugin: PluginID
    let panel: String
    let id: PanelID
    private(set) var title: String
    /// The plugin's logo, beside the panel's name on the stripe.
    var icon: NSImage?
    private var view: PluginView?
    private var count = 0
    private var status = PluginStatus()
    private var name = ""
    private let scroll = NSScrollView()
    private let body = PluginListView(frame: .zero)
    private let headerLine = Fill { $0.hair2 }

    var onRun: ((PluginID, String, SessionID?, String?) -> Void)? { didSet { body.onRun = { [weak self] a, s, item in self.map { $0.onRun?($0.plugin, a, s, item) } } } }
    var onSelectSession: ((SessionID) -> Void)? { didSet { body.onSelectSession = onSelectSession } }
    var onOpenURL: ((URL) -> Void)? { didSet { body.onOpenURL = onOpenURL } }
    var onRestart: ((PluginID) -> Void)?
    var onSettings: ((PluginID) -> Void)?
    /// Room the panel's ⋯ takes at the header's right edge (set by the dock).
    var headerReserve: CGFloat = 70 { didSet { if headerReserve != oldValue { needsDisplay = true } } }

    var gripRect: NSRect { NSRect(x: 0, y: 0, width: max(0, bounds.width - headerReserve), height: Metrics.header) }
    func preferredExtent(along d: Dock) -> CGFloat? { nil }

    init(plugin: PluginID, panel: String, title: String) {
        self.plugin = plugin; self.panel = panel; self.title = title
        id = .plugin(plugin, panel)
        super.init(frame: .zero)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = body
        addSubview(scroll)
        addSubview(headerLine)
        body.onStatusButton = { [weak self] in
            guard let self else { return }
            if case .failed = self.status.run { self.onRestart?(self.plugin) } else { self.onSettings?(self.plugin) }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// How many items need you, for its stripe button.
    var needsYou: Int { count }
    var stopped: Bool { if case .failed = status.run { return true }; return false }

    func update(host: PluginHost) {
        let m = host.manifest(plugin)
        name = m?.name ?? plugin
        title = m?.panels.first { $0.id == panel }?.title ?? title
        view = host.panels[plugin]?[panel]
        count = host.counts[plugin]?[panel] ?? 0
        status = host.status[plugin] ?? PluginStatus()
        refreshBody()
        needsDisplay = true
    }

    private func refreshBody() {
        let st = status
        switch st.run {
        case .failed(let why): body.content = .message("\(name) stopped.", why, "Restart")
        case .stopped(let why): body.content = .message("\(name) stopped. Restarting…", why, nil)
        case .starting: body.content = .message("Starting \(name)…", nil, nil)
        case .off: body.content = .message("\(name) is off.", nil, "Settings…")
        case .running:
            if st.reported == .setup { body.content = .message(st.message ?? "\(name) needs setup.", "Settings › Plugins › \(name)", "Settings…"); break }
            switch view {
            case nil, .loading?: body.content = .message("Loading…", nil, nil)
            case .empty(let title, let text, let action)?: body.content = .empty(title, text, action)
            case .list(let sections)?: body.content = .list(sections)
            }
        }
        layoutBody()
    }

    private func layoutBody() {
        body.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: max(scroll.contentSize.height, body.contentHeight(width: scroll.contentSize.width)))
        body.needsDisplay = true
    }

    override func layout() {
        super.layout()
        headerLine.frame = NSRect(x: 0, y: Metrics.header - 1, width: bounds.width, height: 1)
        scroll.frame = NSRect(x: 0, y: Metrics.header, width: bounds.width, height: max(0, bounds.height - Metrics.header))
        layoutBody()
    }

    /// "LINEAR 3": the panel's title and how many of its items need you.
    private var label: String { count > 0 ? "\(title.uppercased()) \(count)" : title.uppercased() }
    private var labelRect: NSRect {
        let font = Fonts.mono(Metrics.fontSize - 2.5, .medium)
        return NSRect(x: 12, y: 0, width: Text.width(label, font: font) + 4, height: Metrics.header)
    }

    override func draw(_ r: NSRect) {
        let font = Fonts.mono(Metrics.fontSize - 2.5, .medium)
        Text.draw(label, in: labelRect, color: t.fg2, font: font)
        // The plugin's own one-line status, right-aligned, when it isn't simply running.
        if status.run == .running, let rep = status.reported, rep != .ok, rep != .setup {
            let x = labelRect.maxX + 8
            Text.draw(status.line, in: NSRect(x: x, y: 0, width: max(0, bounds.width - headerReserve - 8 - x), height: Metrics.header), color: t.fg3, font: font, align: .right)
        }
    }

    func tip(at p: NSPoint) -> (tip: Tip, rect: NSRect)? {
        guard labelRect.contains(p) else { return nil }
        return (Tip("\(title), from the \(name) plugin").adding(status.line), labelRect)
    }
}

/// The scrolling body: a status message, an empty state, or sections of two-line rows.
final class PluginListView: MXView, TipSource {
    enum Content: Equatable {
        case message(String, String?, String?)     // headline, detail, button
        case empty(String, String?, PluginView.Button?)
        case list([PluginView.Section])
    }
    var content: Content = .message("", nil, nil) { didSet { if content != oldValue { needsDisplay = true } } }
    var onRun: ((String, SessionID?, String?) -> Void)?
    var onSelectSession: ((SessionID) -> Void)?
    var onOpenURL: ((URL) -> Void)?
    var onStatusButton: (() -> Void)?
    private var hover: Hit?

    private enum Hit: Equatable {
        case row(String), button(String, String), statusButton
        var row: String? { switch self { case .row(let id), .button(let id, _): return id; case .statusButton: return nil } }
    }
    private static let section: CGFloat = 24

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    /// A row with a second line is two lines tall; one without stays one line, so a list of
    /// bare titles reads as a dense list instead of a column of blanks.
    private static func height(_ r: PluginView.Row) -> CGFloat { r.subtitle == nil ? 26 : Metrics.row2 }

    func contentHeight(width: CGFloat) -> CGFloat {
        guard case .list = content else { return 120 }
        return (layoutRows().rows.last?.rect.maxY ?? 0) + 10
    }

    /// Where a row's parts start: the status glyph, the key column and the title share x within
    /// a section, so titles line up even when keys differ in length.
    private struct Placed { var row: PluginView.Row; var rect: NSRect; var keyW: CGFloat; var glyph: Bool }
    private struct Layout { var sections: [(String, CGFloat)]; var rows: [Placed] }
    private func layoutRows() -> Layout {
        guard case .list(let sections) = content else { return Layout(sections: [], rows: []) }
        let font = Fonts.mono()
        var y: CGFloat = 6, heads: [(String, CGFloat)] = [], rows: [Placed] = []
        for s in sections where !s.rows.isEmpty {
            if !s.title.isEmpty { heads.append((s.title, y)); y += Self.section }
            let keyW = s.rows.compactMap(\.key).map { Text.width($0, font: font) }.max().map { $0 + 8 } ?? 0
            let glyph = s.rows.contains { $0.status != nil }
            for r in s.rows {
                let h = Self.height(r)
                rows.append(Placed(row: r, rect: NSRect(x: 0, y: y, width: bounds.width, height: h), keyW: keyW, glyph: glyph))
                y += h
            }
            y += 6
        }
        return Layout(sections: heads, rows: rows)
    }

    /// Action buttons, right-aligned and centred on the row. They show while the pointer is on
    /// the row; the first is the main one.
    private func buttonRects(_ row: PluginView.Row, in r: NSRect) -> [(PluginView.Button, NSRect)] {
        let small = Fonts.mono(Metrics.fontSize - 2)
        var right = r.maxX - 8
        var out: [(PluginView.Button, NSRect)] = []
        for b in row.actions.prefix(2) {
            let w = Text.width(b.title, font: small) + 14
            let rect = NSRect(x: right - w, y: r.midY - 9, width: w, height: 18)
            if rect.minX < r.minX + r.width * 0.3 { break }
            out.append((b, rect))
            right = rect.minX - 4
        }
        return out
    }

    private func statusButtonRect(_ title: String) -> NSRect {
        NSRect(x: 14, y: 60, width: Text.width(title, font: Fonts.mono(Metrics.fontSize - 1)) + 12, height: 18)
    }

    override func draw(_ dirty: NSRect) {
        let small = Fonts.mono(Metrics.fontSize - 2)
        switch content {
        case .message(let head, let detail, let button):
            drawMessage(head, detail, button)
        case .empty(let head, let detail, let action):
            drawMessage(head, detail, action?.title)
        case .list(let sections):
            if sections.allSatisfy({ $0.rows.isEmpty }) { return drawMessage("Nothing here.", nil, nil) }
            let l = layoutRows()
            let head = Fonts.mono(Metrics.fontSize - 2.5, .medium)
            for (title, y) in l.sections {
                Text.draw(title.uppercased(), in: NSRect(x: 14, y: y, width: bounds.width - 28, height: Self.section), color: t.fg3, font: head)
            }
            for p in l.rows {
                let row = p.row, r = p.rect
                let box = r.insetBy(dx: 6, dy: 1)
                let lit = hover?.row == row.id
                if lit { t.hover.setFill(); NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill() }
                // The pointer's row trades its badge for its buttons; other rows stay quiet.
                let buttons = lit ? buttonRects(row, in: box) : []
                var right = (buttons.map(\.1.minX).min() ?? box.maxX - 4) - 6
                let line1 = NSRect(x: 0, y: r.minY + (row.subtitle == nil ? (r.height - 18) / 2 : 3), width: 0, height: 18)
                if buttons.isEmpty, let b = row.badge {
                    let w = min(box.width * 0.4, Text.width(b.text, font: small) + 11)
                    let x = box.maxX - 8 - w
                    t.color(for: b.tone).setFill()
                    NSRect(x: x, y: line1.midY - 2.5, width: 5, height: 5).fill()
                    Text.draw(b.text, in: NSRect(x: x + 10, y: line1.minY, width: w - 10, height: 18), color: t.fg3, font: small)
                    right = x - 10
                }
                var x = box.minX + 8
                // Rows with a status lead with the session glyph that means the same, like the sessions list.
                if p.glyph {
                    if let st = row.status { Glyph.draw(st.glyph, at: NSPoint(x: x + 4, y: line1.midY), color: t.color(for: st.glyph), angle: 90) }
                    x += 16
                }
                if let k = row.key {
                    Text.draw(k, in: NSRect(x: x, y: line1.minY, width: max(0, min(p.keyW, right - x)), height: 18), color: t.fg3)
                    x += p.keyW
                }
                Text.draw(row.title, in: NSRect(x: x, y: line1.minY, width: max(0, right - x), height: 18), color: t.fg)
                if let sub = row.subtitle {
                    let sx = x
                    let subRight = (buttons.map(\.1.minX).min() ?? box.maxX - 4) - 6
                    Text.draw(sub, in: NSRect(x: sx, y: r.minY + 20, width: max(0, subRight - sx), height: 15), color: t.fg3, font: small)
                }
                for (i, (b, rect)) in buttons.enumerated() {
                    let hot = hover == .button(row.id, b.action)
                    let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
                    // The main action is filled; the rest are outlined.
                    if i == 0 { (hot ? t.fg2 : t.fg3).withAlphaComponent(0.35).setFill(); path.fill() }
                    else if hot { t.hair2.setFill(); path.fill() }
                    t.hair.setStroke(); path.lineWidth = 1; path.stroke()
                    Text.draw(b.title, in: rect, color: hot || i == 0 ? t.fg : t.fg2, font: small, align: .center)
                }
            }
        }
    }

    private func drawMessage(_ head: String, _ detail: String?, _ button: String?) {
        Text.draw(head, in: NSRect(x: 14, y: 14, width: bounds.width - 28, height: 18), color: t.fg2)
        if let detail { Text.draw(detail, in: NSRect(x: 14, y: 32, width: bounds.width - 28, height: 18), color: t.fg3, font: Fonts.mono(Metrics.fontSize - 1)) }
        if let button {
            let r = statusButtonRect(button)
            let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            if hover == .statusButton { t.hover.setFill(); path.fill() }
            t.hair.setStroke(); path.lineWidth = 1; path.stroke()
            Text.draw(button, in: r, color: t.fg, font: Fonts.mono(Metrics.fontSize - 1), align: .center)
        }
    }

    private var statusButtonTitle: String? {
        switch content {
        case .message(_, _, let b): return b
        case .empty(_, _, let a): return a?.title
        case .list: return nil
        }
    }

    private func hit(_ p: NSPoint) -> (Hit, PluginView.Row?)? {
        if let b = statusButtonTitle, statusButtonRect(b).contains(p) { return (.statusButton, nil) }
        for placed in layoutRows().rows where placed.rect.contains(p) {
            let row = placed.row, r = placed.rect
            if let (b, _) = buttonRects(row, in: r.insetBy(dx: 6, dy: 1.5)).first(where: { $0.1.insetBy(dx: -2, dy: -2).contains(p) }) { return (.button(row.id, b.action), row) }
            return (.row(row.id), row)
        }
        return nil
    }

    override func mouseMoved(with e: NSEvent) {
        let h = hit(convert(e.locationInWindow, from: nil))?.0
        if h != hover { hover = h; needsDisplay = true }
    }
    override func mouseExited(with e: NSEvent) { hover = nil; needsDisplay = true }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }

    override func mouseDown(with e: NSEvent) {
        guard let (h, row) = hit(convert(e.locationInWindow, from: nil)) else { return }
        switch h {
        case .statusButton:
            if case .empty(_, _, let a?) = content { onRun?(a.action, nil, nil) } else { onStatusButton?() }
        case .button(_, let action): onRun?(action, row?.session, row?.id)
        case .row:
            guard let row else { return }
            if let s = row.session { onSelectSession?(s) } else if let u = row.url.flatMap(URL.init(string:)) { onOpenURL?(u) }
            else if let first = row.actions.first { onRun?(first.action, nil, row.id) }
        }
    }

    func tip(at p: NSPoint) -> (tip: Tip, rect: NSRect)? {
        guard let (h, row) = hit(p), let row else { return nil }
        let r = layoutRows().rows.first { $0.row.id == row.id }!.rect
        switch h {
        case .button(_, let a):
            let rect = buttonRects(row, in: r.insetBy(dx: 6, dy: 1.5)).first { $0.0.action == a }!.1
            return (Tip(row.actions.first { $0.action == a }?.title ?? a).adding(row.title), rect)
        case .row:
            if row.session != nil { return (Tip("Open the session").adding(row.title), r) }
            if let u = row.url { return (Tip("Open \(u)"), r) }
            return nil
        case .statusButton: return nil
        }
    }
}
