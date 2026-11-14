import AppKit

/// The current theme. Views read tokens from here and redraw on `Look.changed`.
enum Look {
    static var theme = Theme.load("graphite")
    static let changed = Notification.Name("maxwell.look.changed")

    static func set(_ t: Theme) {
        theme = t
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

/// Base for every custom view: flipped coordinates, redraw on theme change.
class MXView: NSView {
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        // Since macOS 14 views draw outside their bounds unless told otherwise.
        clipsToBounds = true
        NotificationCenter.default.addObserver(self, selector: #selector(lookChanged), name: Look.changed, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func lookChanged() { needsDisplay = true; subviews.forEach { $0.needsDisplay = true } }
    var t: Theme { Look.theme }
}

/// A view that fills itself with one token colour.
class Fill: MXView {
    var color: (Theme) -> NSColor
    init(_ color: @escaping (Theme) -> NSColor) { self.color = color; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ r: NSRect) { color(t).setFill(); bounds.fill() }
}

/// Hairline divider.
func hairline() -> Fill { Fill { $0.hair } }

// MARK: text

enum Text {
    static func attrs(_ color: NSColor, _ font: NSFont = Fonts.mono()) -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        return [.font: font, .foregroundColor: color, .paragraphStyle: p]
    }

    /// Draws one line vertically centred in `rect`, truncated with an ellipsis.
    @discardableResult
    static func draw(_ s: String, in rect: NSRect, color: NSColor, font: NSFont = Fonts.mono(), align: NSTextAlignment = .left) -> CGFloat {
        let a = NSMutableAttributedString(string: s, attributes: attrs(color, font))
        if align != .left {
            let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail; p.alignment = align
            a.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: a.length))
        }
        let h = font.ascender - font.descender
        let r = NSRect(x: rect.minX, y: rect.minY + (rect.height - h) / 2 - 0.5, width: rect.width, height: h + 2)
        a.draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        return min(rect.width, ceil(a.size().width))
    }

    static func width(_ s: String, font: NSFont = Fonts.mono()) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: font]).width)
    }
}

// MARK: state glyph

/// Colour plus shape, so state reads without colour too:
/// ● needs you, ◐ your turn, spinner working, ◇ limited, ✓ safe to close, – idle.
enum Glyph {
    static func draw(_ group: PhaseGroup, at center: NSPoint, color: NSColor, angle: CGFloat = 0) {
        color.set()
        let r: CGFloat = 4
        switch group {
        case .needsYou:
            NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)).fill()
        case .yourTurn:
            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - r + 0.5, y: center.y - r + 0.5, width: 2 * r - 1, height: 2 * r - 1))
            ring.lineWidth = 1.2
            ring.stroke()
            let half = NSBezierPath()
            half.move(to: NSPoint(x: center.x, y: center.y - r))
            half.appendArc(withCenter: center, radius: r, startAngle: -90, endAngle: 90, clockwise: true)
            half.close()
            half.fill()
        case .working:
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: r - 0.5, startAngle: angle, endAngle: angle + 270)
            arc.lineWidth = 1.5
            arc.lineCapStyle = .round
            arc.stroke()
        case .limited:
            let d = NSBezierPath()
            d.move(to: NSPoint(x: center.x, y: center.y - r - 0.5))
            d.line(to: NSPoint(x: center.x + r + 0.5, y: center.y))
            d.line(to: NSPoint(x: center.x, y: center.y + r + 0.5))
            d.line(to: NSPoint(x: center.x - r - 0.5, y: center.y))
            d.close()
            d.lineWidth = 1.2
            d.stroke()
        case .safeToClose:
            let c = NSBezierPath()
            c.move(to: NSPoint(x: center.x - r, y: center.y + 0.2))
            c.line(to: NSPoint(x: center.x - 1.2, y: center.y + r - 1))
            c.line(to: NSPoint(x: center.x + r, y: center.y - r + 0.5))
            c.lineWidth = 1.6
            c.lineCapStyle = .round
            c.lineJoinStyle = .round
            c.stroke()
        case .idle, .recentlyClosed:
            NSBezierPath(rect: NSRect(x: center.x - 3, y: center.y - 0.5, width: 6, height: 1)).fill()
        }
    }
}

/// One line of a Safe-to-close checklist: mark, check, what was found, where it came from.
enum CheckLine {
    static func mark(_ o: Check.Outcome) -> String { o == .pass ? "✓" : o == .fail ? "✗" : "?" }

    /// `stacked` (narrow columns): the source goes on a second line under the finding.
    static func draw(_ c: Check, in r: NSRect, theme t: Theme, stacked: Bool = false) {
        let small = Fonts.mono(Metrics.fontSize - 2)
        let color = c.outcome == .pass ? t.safe : c.outcome == .fail ? t.on : t.chk
        let lineH = stacked ? r.height / 2 : r.height
        var x = r.minX
        x += Text.draw(mark(c.outcome), in: NSRect(x: x, y: r.minY, width: 12, height: lineH), color: color, font: small) + 6
        if stacked {
            let kw = Text.draw(c.kind.title, in: NSRect(x: x, y: r.minY, width: r.maxX - x, height: lineH), color: t.fg2, font: small)
            Text.draw(c.detail, in: NSRect(x: x + kw + 8, y: r.minY, width: max(0, r.maxX - x - kw - 8), height: lineH), color: t.fg, font: small)
            Text.draw(c.source, in: NSRect(x: x, y: r.minY + lineH - 2, width: r.maxX - x, height: lineH), color: t.fg3, font: small)
            return
        }
        let kindW: CGFloat = min(170, r.width * 0.3)
        Text.draw(c.kind.title, in: NSRect(x: x, y: r.minY, width: kindW, height: r.height), color: t.fg2, font: small)
        x += kindW + 6
        let srcW = min(Text.width(c.source, font: small), max(0, (r.maxX - x) * 0.4))
        Text.draw(c.detail, in: NSRect(x: x, y: r.minY, width: max(0, r.maxX - x - srcW - 8), height: r.height), color: t.fg, font: small)
        Text.draw(c.source, in: NSRect(x: r.maxX - srcW, y: r.minY, width: srcW, height: r.height), color: t.fg3, font: small, align: .right)
    }
}

/// A glyph that animates its spinner while working (only while visible).
final class GlyphView: MXView {
    var group: PhaseGroup = .idle { didSet { updateTimer(); needsDisplay = true } }
    private var angle: CGFloat = 0
    private var timer: Timer?

    override func draw(_ r: NSRect) {
        Glyph.draw(group, at: NSPoint(x: bounds.midX, y: bounds.midY), color: t.color(for: group), angle: angle)
    }
    override func viewDidMoveToWindow() { updateTimer() }
    override func viewDidHide() { updateTimer() }
    override func viewDidUnhide() { updateTimer() }
    private func updateTimer() {
        let spin = group == .working && window != nil && !isHiddenOrHasHiddenAncestor
        if spin, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1 / 12, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.angle -= 30
                self.needsDisplay = true
            }
        } else if !spin {
            timer?.invalidate(); timer = nil
        }
    }
}

// MARK: button

/// The one button: 22 pt, hairline border, optional key hint; `primary` inverts.
final class MXButton: MXView, TipSource {
    var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var hint: String?
    var tip: Tip?
    var primary = false
    var small = false
    var isEnabled = true { didSet { needsDisplay = true } }
    var isOn = false { didSet { needsDisplay = true } }
    var action: (() -> Void)?
    private var hover = false
    private var pressed = false

    init(_ title: String, hint: String? = nil, primary: Bool = false, small: Bool = false, action: (() -> Void)? = nil) {
        self.title = title; self.hint = hint; self.primary = primary; self.small = small; self.action = action
        super.init(frame: .zero)
        updateTrackingAreas()
    }
    required init?(coder: NSCoder) { fatalError() }

    var font: NSFont { Fonts.mono(small ? Metrics.fontSize - 1 : Metrics.fontSize) }
    var hintFont: NSFont { Fonts.mono(Metrics.fontSize - 2) }

    override var intrinsicContentSize: NSSize {
        var w = Text.width(title, font: font) + (small ? 12 : 16)
        if let hint { w += Text.width(hint, font: hintFont) + 6 }
        return NSSize(width: w, height: small ? 18 : Metrics.control)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with e: NSEvent) { hover = false; needsDisplay = true }
    override func mouseDown(with e: NSEvent) { guard isEnabled else { return }; pressed = true; needsDisplay = true }
    override func mouseUp(with e: NSEvent) {
        guard isEnabled else { return }
        pressed = false; needsDisplay = true
        if bounds.contains(convert(e.locationInWindow, from: nil)) { action?() }
    }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    func tip(at p: NSPoint) -> (tip: Tip, rect: NSRect)? { tip.map { ($0, bounds) } }

    override func draw(_ r: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        let fg: NSColor
        if primary || isOn {
            t.sel.withAlphaComponent(pressed ? 0.85 : 1).setFill(); path.fill()
            fg = t.selFg
        } else {
            if hover || pressed { t.hover.setFill(); path.fill() }
            t.hair.setStroke(); path.lineWidth = 1; path.stroke()
            fg = t.fg
        }
        let color = isEnabled ? fg : fg.withAlphaComponent(0.4)
        let x: CGFloat = small ? 6 : 8
        let w = Text.draw(title, in: NSRect(x: x, y: 0, width: bounds.width - x, height: bounds.height), color: color, font: font)
        if let hint {
            Text.draw(hint, in: NSRect(x: x + w + 6, y: 0, width: bounds.width - x - w - 6, height: bounds.height),
                      color: color.withAlphaComponent(0.55), font: hintFont)
        }
    }
}

/// Square icon button for the title bar (plus, palette, gear), drawn as line art.
final class IconButton: MXView, TipSource {
    enum Icon { case plus, gear, palette, pin, tree, close, search, more, minimize, maximize, restore }
    let icon: Icon
    var tip: Tip
    var action: (() -> Void)?
    var isOn = false { didSet { needsDisplay = true } }
    private var hover = false
    private var pressed = false

    init(_ icon: Icon, tip: Tip, action: (() -> Void)? = nil) {
        self.icon = icon; self.tip = tip; self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: 26, height: Metrics.control))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: 26, height: Metrics.control) }
    override func mouseEntered(with e: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with e: NSEvent) { hover = false; needsDisplay = true }
    override func mouseUp(with e: NSEvent) {
        pressed = false; needsDisplay = true
        if bounds.contains(convert(e.locationInWindow, from: nil)) { action?() }
    }
    override func mouseDown(with e: NSEvent) { pressed = true; needsDisplay = true }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    func tip(at p: NSPoint) -> (tip: Tip, rect: NSRect)? { (tip, bounds) }

    override func draw(_ r: NSRect) {
        if hover || isOn || pressed {
            (pressed ? t.rowSel : t.hover).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
        (hover || isOn ? t.fg : t.fg2).setStroke()
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let p = NSBezierPath()
        p.lineWidth = 1.3
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        switch icon {
        case .plus:
            p.move(to: NSPoint(x: c.x - 5, y: c.y)); p.line(to: NSPoint(x: c.x + 5, y: c.y))
            p.move(to: NSPoint(x: c.x, y: c.y - 5)); p.line(to: NSPoint(x: c.x, y: c.y + 5))
        case .gear:
            // One closed outline with flat-topped teeth, so it reads as a cog, not a sun's rays.
            func pt(_ deg: CGFloat, _ r: CGFloat) -> NSPoint { NSPoint(x: c.x + cos(deg * .pi / 180) * r, y: c.y + sin(deg * .pi / 180) * r) }
            for i in 0..<6 {
                let a = CGFloat(i) * 60
                let pts = [pt(a - 19, 4.7), pt(a - 11, 6.6), pt(a + 11, 6.6), pt(a + 19, 4.7)]
                if i == 0 { p.move(to: pts[0]) } else { p.line(to: pts[0]) }
                pts.dropFirst().forEach { p.line(to: $0) }
            }
            p.close()
            p.appendRoundedRect(NSRect(x: c.x - 1.9, y: c.y - 1.9, width: 3.8, height: 3.8), xRadius: 1.2, yRadius: 1.2)
        case .palette:
            p.appendRoundedRect(NSRect(x: c.x - 6, y: c.y - 5, width: 12, height: 10), xRadius: 2, yRadius: 2)
            p.move(to: NSPoint(x: c.x - 3.5, y: c.y - 1.5)); p.line(to: NSPoint(x: c.x - 1.5, y: c.y)); p.line(to: NSPoint(x: c.x - 3.5, y: c.y + 1.5))
            p.move(to: NSPoint(x: c.x, y: c.y + 2)); p.line(to: NSPoint(x: c.x + 3, y: c.y + 2))
        case .pin:
            p.move(to: NSPoint(x: c.x, y: c.y + 6)); p.line(to: NSPoint(x: c.x, y: c.y + 1))
            p.appendRoundedRect(NSRect(x: c.x - 3, y: c.y - 6, width: 6, height: 5), xRadius: 1, yRadius: 1)
            p.move(to: NSPoint(x: c.x - 5, y: c.y + 1)); p.line(to: NSPoint(x: c.x + 5, y: c.y + 1))
        case .tree:
            p.move(to: NSPoint(x: c.x - 5, y: c.y - 5)); p.line(to: NSPoint(x: c.x - 5, y: c.y + 4)); p.line(to: NSPoint(x: c.x - 1, y: c.y + 4))
            p.move(to: NSPoint(x: c.x - 5, y: c.y - 1)); p.line(to: NSPoint(x: c.x - 1, y: c.y - 1))
            p.move(to: NSPoint(x: c.x + 1, y: c.y - 5)); p.line(to: NSPoint(x: c.x + 6, y: c.y - 5))
            p.move(to: NSPoint(x: c.x + 1, y: c.y - 1)); p.line(to: NSPoint(x: c.x + 6, y: c.y - 1))
            p.move(to: NSPoint(x: c.x + 1, y: c.y + 4)); p.line(to: NSPoint(x: c.x + 6, y: c.y + 4))
        case .search:
            p.appendRoundedRect(NSRect(x: c.x - 5.5, y: c.y - 5.5, width: 8.5, height: 8.5), xRadius: 2.5, yRadius: 2.5)
            p.move(to: NSPoint(x: c.x + 3, y: c.y + 3)); p.line(to: NSPoint(x: c.x + 5.5, y: c.y + 5.5))
        case .more:
            p.stroke()
            (hover || isOn ? t.fg : t.fg2).setFill()
            for dx in [-4.5, 0, 4.5] { NSRect(x: c.x + CGFloat(dx) - 1, y: c.y - 1, width: 2, height: 2).fill() }
            return
        case .minimize:
            p.move(to: NSPoint(x: c.x - 4.5, y: c.y)); p.line(to: NSPoint(x: c.x + 4.5, y: c.y))
        case .maximize:
            p.move(to: NSPoint(x: c.x - 4.5, y: c.y + 2.5)); p.line(to: NSPoint(x: c.x, y: c.y - 2)); p.line(to: NSPoint(x: c.x + 4.5, y: c.y + 2.5))
        case .restore:
            p.move(to: NSPoint(x: c.x - 4.5, y: c.y - 2)); p.line(to: NSPoint(x: c.x, y: c.y + 2.5)); p.line(to: NSPoint(x: c.x + 4.5, y: c.y - 2))
        case .close:
            p.move(to: NSPoint(x: c.x - 4, y: c.y - 4)); p.line(to: NSPoint(x: c.x + 4, y: c.y + 4))
            p.move(to: NSPoint(x: c.x + 4, y: c.y - 4)); p.line(to: NSPoint(x: c.x - 4, y: c.y + 4))
        }
        p.stroke()
    }
}

/// Thin usage bar. Grey by default; louder as it fills; `on` colour at the limit.
enum Meter {
    static func draw(_ pct: Double?, in r: NSRect, theme t: Theme) {
        t.hair.setFill()
        r.fill()
        guard let pct else { return }
        let fill = pct >= 100 ? t.on : pct >= 80 ? t.fg2 : t.fg3
        fill.setFill()
        NSRect(x: r.minX, y: r.minY, width: r.width * CGFloat(min(pct, 100) / 100), height: r.height).fill()
    }
}

/// A one-line label drawn from tokens (keeps text views out of the hierarchy).
final class Label: MXView, TipSource {
    var text: String { didSet { needsDisplay = true } }
    var tip: Tip?
    var color: (Theme) -> NSColor
    var font: NSFont
    var align: NSTextAlignment = .left
    init(_ text: String = "", font: NSFont = Fonts.mono(), color: @escaping (Theme) -> NSColor = { $0.fg }) {
        self.text = text; self.color = color; self.font = font
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ r: NSRect) { Text.draw(text, in: bounds, color: color(t), font: font, align: align) }
    var textWidth: CGFloat { Text.width(text, font: font) }
    func tip(at p: NSPoint) -> (tip: Tip, rect: NSRect)? { tip.map { ($0, bounds) } }
}

enum Format {
    static let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    static let dayClock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE HH:mm"; return f }()

    /// "20:50" today, "Thu 16:00" later.
    static func reset(_ d: Date, now: Date = Date()) -> String {
        Calendar.current.isDate(d, inSameDayAs: now) ? clock.string(from: d) : dayClock.string(from: d)
    }

    /// Compact age: 42s, 7m, 3h, 2d.
    static func age(_ d: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(d)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}
