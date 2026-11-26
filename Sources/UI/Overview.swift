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

/// What the middle pane shows with no session open, in one centred column: what is left to set
/// up (finished steps fold into the progress bar), what is waiting in this project, and the next step.
final class Overview: MXView {
    /// Sessions that need you in every project (what ⌘J walks through) and in the one on screen.
    var needsYou: (all: Int, here: Int) = (0, 0) {
        didSet {
            guard needsYou != oldValue else { return }
            needsLayout = true; needsDisplay = true
            setAccessibilityLabel("No session open. \(summary)")
        }
    }
    /// The project on screen; nil for all projects.
    var scope: String? { didSet { if scope != oldValue { needsDisplay = true; setAccessibilityLabel("No session open. \(summary)") } } }
    var setup: [SetupStep] = [] {
        didSet {
            guard setup.map(\.key) != oldValue.map(\.key) else { return }
            buttons.forEach { $0.removeFromSuperview() }
            buttons = todo.map { step in
                let b = MXButton(step.button ?? "", small: true, action: step.action)
                b.isHidden = step.button == nil
                addSubview(b)
                return b
            }
            hide.isHidden = setup.isEmpty
            needsLayout = true
            needsDisplay = true
        }
    }
    var onHideSetup: (() -> Void)?
    var onNext: (() -> Void)? { get { next.action } set { next.action = newValue } }
    var onNew: (() -> Void)? { get { new.action } set { new.action = newValue } }
    /// The next step in place: the session that needs you, else a new one.
    private let next = MXButton("Next that needs you", hint: "⌘J", primary: true)
    private let new = MXButton("New session", hint: "⌘N")
    private var buttons: [MXButton] = []
    private let hide = MXButton("Hide", small: true)
    private var todo: [SetupStep] { setup.filter { !$0.done } }

    // The column's vertical rhythm, top to bottom.
    private static let pad: CGFloat = 16, headH: CGFloat = 20, barGap: CGFloat = 10, barH: CGFloat = 2
    private static let rowH: CGFloat = 46, cardGap: CGFloat = 32, titleH: CGFloat = 24, summaryH: CGFloat = 22, actionGap: CGFloat = 22

    override init(frame: NSRect) {
        super.init(frame: frame)
        hide.tip = Tip("Hide this list. Everything in it is also in Settings.")
        hide.action = { [weak self] in self?.onHideSetup?() }
        hide.isHidden = true
        addSubview(hide)
        next.tip = Tip("Open the next session that needs you, in any project", action: "next-needs-you")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        new.tip = Tip("Start a session", action: "new-session")
        addSubview(next); addSubview(new)
    }
    required init?(coder: NSCoder) { fatalError() }

    private struct Plan {
        var column: NSRect; var card: NSRect?; var rows: Int; var title: CGFloat; var actions: CGFloat; var stacked: Bool
        /// Too narrow to say anything useful: the session list holds it all.
        var blank: Bool { column.width < 220 }
    }
    private static let cardBase = pad + headH + barGap + barH + 8 + 6, moreH: CGFloat = 22

    /// One place that places everything, so drawing and the buttons can't drift apart.
    private var plan: Plan {
        let w = min(520, bounds.width - 48), x = ((bounds.width - w) / 2).rounded()
        let actions = [next, new].filter { !$0.isHidden }
        let stacked = actions.map { $0.intrinsicContentSize.width }.reduce(0, +) + 8 > w
        let rest = Self.titleH + 6 + Self.summaryH + Self.actionGap + Metrics.control + (stacked && actions.count > 1 ? Metrics.control + 8 : 0)
        // The next step always fits; setup rows take what is left, and the rest wait in Settings.
        let room = bounds.height - 48 - rest - Self.cardGap - Self.cardBase
        var rows = todo.count
        if CGFloat(rows) * Self.rowH > room { rows = max(1, Int((room - Self.moreH) / Self.rowH)) }
        rows = min(rows, todo.count)
        let cardH: CGFloat = setup.isEmpty ? 0 : Self.cardBase + CGFloat(rows) * Self.rowH + (rows < todo.count ? Self.moreH : 0)
        let total = (setup.isEmpty ? 0 : cardH + Self.cardGap) + rest
        // Optically centred: a little above the middle, never under the top edge.
        var y = max(24, ((bounds.height - total) * 0.42).rounded())
        var card: NSRect?
        if !setup.isEmpty { card = NSRect(x: x, y: y, width: w, height: cardH); y += cardH + Self.cardGap }
        let title = y
        return Plan(column: NSRect(x: x, y: 0, width: w, height: bounds.height), card: card, rows: rows, title: title,
                    actions: title + Self.titleH + 6 + Self.summaryH + Self.actionGap, stacked: stacked)
    }

    override func layout() {
        super.layout()
        next.isHidden = needsYou.all == 0
        new.isHidden = false
        let p = plan
        if p.blank { ([next, new, hide] + buttons).forEach { $0.isHidden = true }; return }
        hide.isHidden = setup.isEmpty
        let shown = [next, new].filter { !$0.isHidden }
        if p.stacked {
            for (i, b) in shown.enumerated() {
                let size = b.intrinsicContentSize
                b.frame = NSRect(x: (p.column.midX - size.width / 2).rounded(), y: p.actions + CGFloat(i) * (Metrics.control + 8), width: size.width, height: size.height)
            }
        } else {
            let total = shown.map { $0.intrinsicContentSize.width }.reduce(0, +) + 8 * CGFloat(shown.count - 1)
            var bx = (p.column.midX - total / 2).rounded()
            for b in shown {
                let size = b.intrinsicContentSize
                b.frame = NSRect(x: bx, y: p.actions, width: size.width, height: size.height)
                bx += size.width + 8
            }
        }
        guard let card = p.card else { return }
        let right = card.maxX - Self.pad
        let hs = hide.intrinsicContentSize
        hide.frame = NSRect(x: right - hs.width, y: card.minY + Self.pad + (Self.headH - hs.height) / 2, width: hs.width, height: hs.height)
        let rowsTop = card.minY + Self.pad + Self.headH + Self.barGap + Self.barH + 8
        for (i, b) in buttons.enumerated() {
            b.isHidden = i >= p.rows || todo[i].button == nil
            let size = b.intrinsicContentSize
            let y = rowsTop + CGFloat(i) * Self.rowH
            b.frame = NSRect(x: right - size.width, y: y + (Self.rowH - size.height) / 2, width: size.width, height: size.height)
        }
    }

    private func drawSetup(in card: NSRect, rows: Int) {
        let path = NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        t.panel.setFill(); path.fill()
        t.hair.setStroke(); path.lineWidth = 1; path.stroke()
        let ix = card.minX + Self.pad, inner = card.width - 2 * Self.pad
        var y = card.minY + Self.pad
        let done = setup.filter(\.done).count
        let w = Text.draw("Set up Maxwell", in: NSRect(x: ix, y: y, width: 240, height: Self.headH), color: t.fg, font: Fonts.mono(Metrics.fontSize, .semibold))
        let doneW = hide.frame.minX - 10 - (ix + w + 10)
        if doneW > 40 { Text.draw("\(done) of \(setup.count) done", in: NSRect(x: ix + w + 10, y: y, width: doneW, height: Self.headH), color: t.fg3, font: Fonts.mono(Metrics.fontSize - 1)) }
        y += Self.headH + Self.barGap
        // Progress: the finished steps live here instead of as rows.
        let track = NSRect(x: ix, y: y, width: inner, height: Self.barH)
        t.hair2.setFill(); NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1).fill()
        t.fg3.setFill()
        NSBezierPath(roundedRect: NSRect(x: ix, y: y, width: max(Self.barH, inner * CGFloat(done) / CGFloat(max(1, setup.count))), height: Self.barH), xRadius: 1, yRadius: 1).fill()
        y += Self.barH + 8
        for (i, step) in todo.prefix(rows).enumerated() {
            let b = buttons[i], textW = inner - 26 - (b.isHidden ? 0 : b.intrinsicContentSize.width + 16)
            if i > 0 { t.hair2.setFill(); NSRect(x: ix + 26, y: y, width: inner - 26, height: 1).fill() }
            let mark = NSRect(x: ix + 1, y: y + 9, width: 14, height: 14)
            t.fg3.setStroke(); let o = NSBezierPath(ovalIn: mark.insetBy(dx: 0.75, dy: 0.75)); o.lineWidth = 1.2; o.stroke()
            Text.draw(step.title, in: NSRect(x: ix + 26, y: y + 6, width: textW, height: 18), color: t.fg, font: Fonts.mono(Metrics.fontSize))
            Text.draw(step.detail, in: NSRect(x: ix + 26, y: y + 24, width: textW, height: 16), color: t.fg3, font: Fonts.mono(Metrics.fontSize - 1.5))
            y += Self.rowH
        }
        if rows < todo.count {
            Text.draw("\(todo.count - rows) more in Settings", in: NSRect(x: ix + 26, y: y, width: inner - 26, height: Self.moreH - 4), color: t.fg3, font: Fonts.mono(Metrics.fontSize - 1.5))
        }
    }

    /// One line on what is waiting: every project, since ⌘J reaches them all, and this project's share.
    private var summary: String {
        let (all, here) = needsYou
        guard all > 0 else { return "Nothing needs you." }
        let head = all == 1 ? "1 session needs you" : "\(all) sessions need you"
        guard let scope, here != all else { return head }
        return "\(head) · \(here == 0 ? "none" : "\(here)") in \(scope)"
    }

    private func drawSummary(centeredIn c: NSRect, y: CGFloat) {
        let font = Fonts.mono(Metrics.fontSize - 0.5)
        guard needsYou.all > 0 else {
            Text.draw(summary, in: NSRect(x: c.minX, y: y, width: c.width, height: Self.summaryH), color: t.fg3, font: font, align: .center)
            return
        }
        // The needs-you glyph leads, so the line reads like the sidebar's group of the same name.
        // Short of room, the project's share goes first; the total is what ⌘J acts on.
        var text = summary
        if Text.width(text, font: font) > c.width - 16, let cut = text.range(of: " · ") { text = String(text[..<cut.lowerBound]) }
        let w = min(c.width - 16, Text.width(text, font: font))
        let x = (c.midX - (w + 14) / 2).rounded()
        Glyph.draw(.needsYou, at: NSPoint(x: x + 4, y: y + Self.summaryH / 2), color: t.on)
        Text.draw(text, in: NSRect(x: x + 14, y: y, width: w, height: Self.summaryH), color: t.fg2, font: font)
    }

    override func draw(_ r: NSRect) {
        let p = plan
        guard !p.blank else { return }
        if let card = p.card { drawSetup(in: card, rows: p.rows) }
        Text.draw("No session open", in: NSRect(x: p.column.minX, y: p.title, width: p.column.width, height: Self.titleH), color: t.fg, font: Fonts.mono(Metrics.fontSize + 2, .semibold), align: .center)
        drawSummary(centeredIn: p.column, y: p.title + Self.titleH + 6)
    }
}
