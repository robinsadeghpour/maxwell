import AppKit

/// One thing Maxwell needs to work fully, checked live. `button` runs `action`.
struct SetupStep {
    var title: String
    var detail: String
    var done: Bool
    var button: String? = nil
    var action: (() -> Void)? = nil
    var key: String { "\(title)|\(detail)|\(done)|\(button ?? "")" }
}

/// What the middle pane shows with no session open: what is left to set up, the state of
/// everything, and the keys.
final class Overview: MXView {
    var counts: [(PhaseGroup, Int)] = [] { didSet { needsDisplay = true } }
    var setup: [SetupStep] = [] {
        didSet {
            guard setup.map(\.key) != oldValue.map(\.key) else { return }
            buttons.forEach { $0.removeFromSuperview() }
            buttons = setup.map { step in
                let b = MXButton(step.button ?? "", primary: false, small: true, action: step.action)
                b.isHidden = step.done || step.button == nil
                addSubview(b)
                return b
            }
            hide.isHidden = setup.isEmpty
            needsLayout = true
            needsDisplay = true
        }
    }
    var onHideSetup: (() -> Void)?
    private var buttons: [MXButton] = []
    private let hide = MXButton("Hide", small: true)
    private static let x: CGFloat = 32, top: CGFloat = 40, rowH: CGFloat = 40, cardPad: CGFloat = 14

    override init(frame: NSRect) {
        super.init(frame: frame)
        hide.tip = Tip("Hide this list. Everything in it is also in Settings.")
        hide.action = { [weak self] in self?.onHideSetup?() }
        hide.isHidden = true
        addSubview(hide)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var cardWidth: CGFloat { min(620, bounds.width - 2 * Self.x) }
    private var cardHeight: CGFloat { setup.isEmpty ? 0 : Self.cardPad + 30 + CGFloat(setup.count) * Self.rowH + Self.cardPad - 6 }

    override func layout() {
        super.layout()
        let right = Self.x + cardWidth - Self.cardPad
        let hs = hide.intrinsicContentSize
        hide.frame = NSRect(x: right - hs.width, y: Self.top + Self.cardPad + 2, width: hs.width, height: hs.height)
        for (i, b) in buttons.enumerated() {
            let size = b.intrinsicContentSize
            let y = Self.top + Self.cardPad + 30 + CGFloat(i) * Self.rowH
            b.frame = NSRect(x: right - size.width, y: y + (Self.rowH - size.height) / 2 - 1, width: size.width, height: size.height)
        }
    }

    private func drawSetup() -> CGFloat {
        guard !setup.isEmpty else { return Self.top }
        let x = Self.x, card = NSRect(x: x, y: Self.top, width: cardWidth, height: cardHeight)
        let path = NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        t.panel.setFill(); path.fill()
        t.hair.setStroke(); path.lineWidth = 1; path.stroke()
        let ix = x + Self.cardPad
        var y = Self.top + Self.cardPad
        let w = Text.draw("Set up Maxwell", in: NSRect(x: ix, y: y, width: 240, height: 22), color: t.fg, font: Fonts.mono(Metrics.fontSize + 1, .semibold))
        let done = setup.filter(\.done).count
        Text.draw("\(done) of \(setup.count) done", in: NSRect(x: ix + w + 12, y: y, width: 160, height: 22), color: t.fg3, font: Fonts.mono(Metrics.fontSize - 1))
        y += 30
        let textW = card.maxX - Self.cardPad - ix - 28 - 110
        for (i, step) in setup.enumerated() {
            if i > 0 { t.hair2.setFill(); NSRect(x: ix, y: y, width: card.width - 2 * Self.cardPad, height: 1).fill() }
            let mark = NSRect(x: ix, y: y + 11, width: 16, height: 16)
            if step.done {
                t.safe.setFill(); NSBezierPath(ovalIn: mark).fill()
                Text.draw("✓", in: mark, color: t.background, font: Fonts.mono(Metrics.fontSize - 2, .bold), align: .center)
            } else {
                t.fg3.setStroke(); let o = NSBezierPath(ovalIn: mark.insetBy(dx: 1, dy: 1)); o.lineWidth = 1.2; o.stroke()
            }
            Text.draw(step.title, in: NSRect(x: ix + 28, y: y + 3, width: textW, height: 18), color: step.done ? t.fg2 : t.fg, font: Fonts.mono(Metrics.fontSize, step.done ? .regular : .semibold))
            Text.draw(step.detail, in: NSRect(x: ix + 28, y: y + 20, width: textW, height: 16), color: t.fg3, font: Fonts.mono(Metrics.fontSize - 1.5))
            y += Self.rowH
        }
        return Self.top + cardHeight + 28
    }

    override func draw(_ r: NSRect) {
        let x = Self.x
        var y = drawSetup()
        Text.draw("No session open", in: NSRect(x: x, y: y, width: bounds.width - 2 * x, height: 22), color: t.fg, font: Fonts.mono(Metrics.fontSize + 2, .semibold))
        y += 30
        let hints: [PhaseGroup: String] = [.needsYou: "⌘J jumps to the next one", .safeToClose: "⇧⌘X closes them all"]
        for (g, n) in counts where !g.folds {
            Glyph.draw(g, at: NSPoint(x: x + 5, y: y + 11), color: t.color(for: g))
            let w = Text.draw("\(n)", in: NSRect(x: x + 20, y: y, width: 40, height: 22), color: n > 0 && g != .working ? t.color(for: g) : t.fg2, font: Fonts.mono(Metrics.fontSize, .semibold))
            Text.draw(g.title.lowercased(), in: NSRect(x: x + 28 + w, y: y, width: 160, height: 22), color: t.fg2)
            if n > 0, let h = hints[g] { Text.draw(h, in: NSRect(x: x + 200, y: y, width: 260, height: 22), color: t.fg3) }
            y += 24
        }
        y += 18
        t.hair2.setFill(); NSRect(x: x, y: y, width: min(460, bounds.width - 2 * x), height: 1).fill()
        y += 14
        let keys = [("J K", "move in the list"), ("⏎", "open the session"), ("⌘0–9", "switch project"), ("⌘N", "new session"), ("⌘K", "every action")]
        for (k, what) in keys {
            let kw = Text.width(k, font: Fonts.mono(Metrics.fontSize - 1)) + 12
            let kr = NSRect(x: x, y: y + 2, width: kw, height: 18)
            t.hover.setFill(); NSBezierPath(roundedRect: kr, xRadius: 4, yRadius: 4).fill()
            t.hair.setStroke(); let b = NSBezierPath(roundedRect: kr.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4); b.lineWidth = 1; b.stroke()
            Text.draw(k, in: kr, color: t.fg2, font: Fonts.mono(Metrics.fontSize - 1), align: .center)
            Text.draw(what, in: NSRect(x: x + 76, y: y, width: 300, height: 22), color: t.fg3)
            y += 26
        }
    }
}
