import AppKit

/// "Close all safe" (and ⇧⌘⌫ on one session): every session with its checklist, and nothing
/// closes until you confirm. ⏎ closes, esc cancels.
final class CloseSheet: MXView {
    struct Item { var id: SessionID; var title: String; var detail: String; var checks: [Check]; var hash: String? }
    private(set) var items: [Item] = []
    private let scroll = NSScrollView()
    private let list = ListView(frame: .zero)
    private let confirm = MXButton("Close", hint: "⏎", primary: true)
    private let cancel = MXButton("Cancel", hint: "esc")
    var onConfirm: (([Item]) -> Void)?
    var onClose: (() -> Void)?
    static let width: CGFloat = 760
    private static let header: CGFloat = 58, footer: CGFloat = 50

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = list
        scroll.contentView.drawsBackground = false
        confirm.action = { [weak self] in self?.submit() }
        cancel.action = { [weak self] in self?.dismiss() }
        [scroll, confirm, cancel].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    func present(_ items: [Item], in host: NSView) {
        self.items = items
        list.items = items
        confirm.title = items.count == 1 ? "Close it" : "Close \(items.count)"
        let h = min(host.bounds.height - 100, Self.header + list.contentHeight + Self.footer)
        frame = NSRect(x: (host.bounds.width - Self.width) / 2, y: 52, width: min(Self.width, host.bounds.width - 40), height: h)
        host.addSubview(self)
        needsLayout = true
        window?.makeFirstResponder(self)
    }

    func submit() {
        let chosen = items
        dismiss()
        onConfirm?(chosen)
    }

    func dismiss() {
        removeFromSuperview()
        onClose?()
    }

    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 36, 76: submit()
        case 53: dismiss()
        default: super.keyDown(with: e)
        }
    }

    override func layout() {
        super.layout()
        scroll.frame = NSRect(x: 0, y: Self.header, width: bounds.width, height: bounds.height - Self.header - Self.footer)
        list.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: max(list.contentHeight, scroll.contentSize.height))
        let ss = confirm.intrinsicContentSize, cs = cancel.intrinsicContentSize
        confirm.frame = NSRect(x: bounds.width - 14 - ss.width, y: bounds.height - 12 - ss.height, width: ss.width, height: ss.height)
        cancel.frame = NSRect(x: confirm.frame.minX - 8 - cs.width, y: confirm.frame.minY, width: cs.width, height: cs.height)
    }

    override func draw(_ r: NSRect) {
        t.panel.setFill(); bounds.fill()
        t.hair.setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8); border.lineWidth = 1; border.stroke()
        let n = items.count
        Text.draw("Close \(n) session\(n == 1 ? "" : "s")?", in: NSRect(x: 14, y: 6, width: 300, height: 24), color: t.fg, font: Fonts.mono(Metrics.fontSize, .semibold))
        Text.draw("Each one is checked again right before it closes and skipped if anything changed.",
                  in: NSRect(x: 14, y: 28, width: bounds.width - 28, height: 22), color: t.fg3, font: Fonts.mono(Metrics.fontSize - 1))
        t.hair2.setFill(); NSRect(x: 0, y: Self.header - 1, width: bounds.width, height: 1).fill()
        NSRect(x: 0, y: bounds.height - Self.footer, width: bounds.width, height: 1).fill()
        Text.draw("claude stop only, conversation kept · Undo 10 s · Recently closed reopens",
                  in: NSRect(x: 14, y: bounds.height - Self.footer + 1, width: bounds.width - 260, height: Self.footer - 2), color: t.fg3, font: Fonts.mono(Metrics.fontSize - 1))
    }

    /// The sessions and their checks, one line each.
    final class ListView: MXView {
        var items: [Item] = [] { didSet { needsDisplay = true } }
        static let titleH: CGFloat = 26, checkH: CGFloat = 18, gap: CGFloat = 10
        var contentHeight: CGFloat { items.reduce(8) { $0 + Self.titleH + CGFloat($1.checks.count) * Self.checkH + Self.gap } }

        override func draw(_ r: NSRect) {
            var y: CGFloat = 8
            for it in items {
                Glyph.draw(.safeToClose, at: NSPoint(x: 22, y: y + Self.titleH / 2), color: t.safe)
                let w = Text.draw(it.title, in: NSRect(x: 36, y: y, width: bounds.width * 0.55, height: Self.titleH), color: t.fg, font: Fonts.mono(Metrics.fontSize, .semibold))
                Text.draw(it.detail, in: NSRect(x: 36 + w + 10, y: y, width: max(0, bounds.width - 60 - w), height: Self.titleH), color: t.fg3, font: Fonts.mono(Metrics.fontSize - 1))
                y += Self.titleH
                for c in it.checks {
                    CheckLine.draw(c, in: NSRect(x: 36, y: y, width: bounds.width - 50, height: Self.checkH), theme: t)
                    y += Self.checkH
                }
                y += Self.gap
            }
        }
    }
}
