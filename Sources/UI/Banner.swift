import AppKit

/// The state strip under the header: glyph, one line, actions on the right. Hovering the line
/// says what the state rests on ("Claude Code: blocked on you").
final class Banner: MXView, TipSource {
    private let glyph = GlyphView(frame: .zero)
    private let label = Label()
    var buttons: [MXButton] = []
    private var tint: (Theme) -> NSColor = { $0.fg3 }
    /// Where the session's phase came from (`Session.phaseSource`); nil shows no tip.
    var source: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        [glyph, label].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Adds to the line, after what the group says.
    func append(_ more: String) {
        label.text += more
        needsLayout = true
    }

    func configure(group: PhaseGroup, text: String, tint: @escaping (Theme) -> NSColor) {
        glyph.group = group
        label.text = text.replacingOccurrences(of: "\n", with: " ")
        self.tint = tint
        label.color = { t in group == .working || group == .limited ? t.fg2 : t.fg }
        needsDisplay = true
        needsLayout = true
    }

    func add(_ b: MXButton) { buttons.append(b); addSubview(b); needsLayout = true }

    func tip(at p: NSPoint) -> (tip: Tip, rect: NSRect)? {
        let area = label.frame.union(glyph.frame)
        guard let source, !source.isEmpty, area.contains(p) else { return nil }
        return (Tip("Why: " + source), area)
    }

    override func draw(_ r: NSRect) {
        tint(t).withAlphaComponent(0.08).setFill()
        bounds.fill()
        tint(t).withAlphaComponent(0.3).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override func layout() {
        super.layout()
        var x = bounds.width - 8
        for b in buttons.reversed() {
            let s = b.intrinsicContentSize
            x -= s.width
            b.frame = NSRect(x: x, y: (bounds.height - s.height) / 2, width: s.width, height: s.height)
            x -= 6
        }
        glyph.frame = NSRect(x: 8, y: 0, width: 16, height: bounds.height)
        label.frame = NSRect(x: 28, y: 0, width: max(0, x - 34), height: bounds.height)
    }
}
