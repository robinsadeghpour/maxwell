import AppKit
import UniformTypeIdentifiers

/// Everything Settings shows. The window edits ~/.config/maxwell/config line by line and the
/// app reloads from the file, so the mouse and the config file always agree.
struct SettingsModel {
    var config = Config()
    var hookStatus = ""
    /// Per account: its settings.json (nil: none yet), whether Maxwell's hooks are in it, and
    /// whether another account points at the same file.
    var hooks: [(account: String, file: String?, installed: Bool, shared: Bool)] = []
    var accounts: [Account] = []
    var projects: [String] = []
    /// The folders each project's sessions run in, where its logo is searched.
    var projectRoots: [String: [String]] = [:]
    var actions: [(id: String, title: String, menu: String, shortcut: String)] = []
    /// The theme the window shows now, and whether macOS is in dark mode.
    var themeName = ""
    var systemDark = true
    /// The version a download is ready for, and what the last manual check said.
    var updateReady: String?
    var updateStatus: String?
    /// Whether macOS lets Maxwell post notifications; nil until asked.
    var notificationsAllowed: Bool?
    var plugins: [PluginInfo] = []
    var brokenPlugins: [(folder: String, why: String)] = []
    var pluginsFolder = ""
}

/// One plugin as Settings shows it.
struct PluginInfo {
    var manifest: PluginManifest
    var status: PluginStatus
    /// Secret keys that have a value in the Keychain.
    var secretsSet: Set<String>
}

enum SettingsSection: String, CaseIterable {
    case general = "General", appearance = "Appearance", accounts = "Accounts", projects = "Projects", plugins = "Plugins", keys = "Keys", advanced = "Advanced"
}

// MARK: controls

/// On/off, drawn like the rest: a 26 × 14 track with a square knob, no circles.
final class Switch: MXView {
    var isOn = false { didSet { needsDisplay = true } }
    var isEnabled = true
    var onChange: ((Bool) -> Void)?
    private var hover = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseEntered(with e: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with e: NSEvent) { hover = false; needsDisplay = true }
    override func mouseDown(with e: NSEvent) { guard isEnabled else { return }; isOn.toggle(); onChange?(isOn) }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    static let size = NSSize(width: 30, height: 18)
    /// On is filled with the knob right; off is an empty outline with a dim knob left, so the
    /// state reads without a second switch to compare against.
    override func draw(_ r: NSRect) {
        let track = NSRect(x: 0.5, y: (bounds.height - 16) / 2 + 0.5, width: Self.size.width - 1, height: 15)
        let p = NSBezierPath(roundedRect: track, xRadius: 3.5, yRadius: 3.5)
        if isOn { (hover ? t.fg : t.sel).setFill(); p.fill() } else if hover { t.hover.setFill(); p.fill() }
        (isOn ? (hover ? t.fg : t.sel) : hover ? t.fg3 : t.hair).setStroke(); p.lineWidth = 1; p.stroke()
        let knob = NSRect(x: isOn ? track.maxX - 13 : track.minX + 2, y: track.minY + 2, width: 11, height: 11)
        (isOn ? t.selFg : t.fg3).setFill()
        NSBezierPath(roundedRect: knob, xRadius: 2, yRadius: 2).fill()
    }
}

/// A hairline track with a square knob and the value on the right. Live while dragging,
/// committed on release.
final class Slider: MXView {
    var value: Double { didSet { needsDisplay = true } }
    let range: ClosedRange<Double>
    var format: (Double) -> String
    var onLive: ((Double) -> Void)?
    var onCommit: ((Double) -> Void)?
    private var hover = false, dragging = false
    static let labelWidth: CGFloat = 54

    init(_ value: Double, _ range: ClosedRange<Double>, format: @escaping (Double) -> String) {
        self.value = value; self.range = range; self.format = format
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    private var track: NSRect { NSRect(x: 6, y: bounds.midY - 1, width: bounds.width - 12 - Self.labelWidth, height: 2) }
    private func pos(_ v: Double) -> CGFloat { track.minX + track.width * CGFloat((v - range.lowerBound) / (range.upperBound - range.lowerBound)) }

    override func draw(_ r: NSRect) {
        let tr = track
        t.hair.setFill(); tr.fill()
        let x = pos(value)
        t.fg3.setFill(); NSRect(x: tr.minX, y: tr.minY, width: x - tr.minX, height: tr.height).fill()
        let knob = NSRect(x: x - 5, y: bounds.midY - 7, width: 10, height: 14)
        (dragging ? t.fg : hover ? t.fg2 : t.panel).setFill()
        let k = NSBezierPath(roundedRect: knob.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2); k.fill()
        t.fg3.setStroke(); k.lineWidth = 1; k.stroke()
        Text.draw(format(value), in: NSRect(x: bounds.width - Self.labelWidth, y: 0, width: Self.labelWidth, height: bounds.height), color: t.fg, font: Fonts.mono(Metrics.fontSize - 1), align: .right)
    }

    override func mouseEntered(with e: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with e: NSEvent) { hover = false; needsDisplay = true }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) {
        dragging = true
        func set(_ ev: NSEvent) {
            let x = convert(ev.locationInWindow, from: nil).x
            let f = Double(max(0, min(1, (x - track.minX) / track.width)))
            value = range.lowerBound + f * (range.upperBound - range.lowerBound)
            onLive?(value)
        }
        set(e)
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged { set(next) }
        dragging = false; needsDisplay = true
        onCommit?(value)
    }
}

/// A shortcut you click and then press: records the next key chord, Esc cancels, ⌫ clears.
final class KeyRecorder: MXView {
    var shortcut: String { didSet { needsDisplay = true } }
    var onSet: ((String?) -> Void)?
    private var recording = false { didSet { needsDisplay = true } }
    private var hover = false
    init(_ shortcut: String) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    override func mouseEntered(with e: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with e: NSEvent) { hover = false; needsDisplay = true }
    override func mouseDown(with e: NSEvent) { recording = true; window?.makeFirstResponder(self) }
    override func resignFirstResponder() -> Bool { recording = false; return true }
    override func keyDown(with e: NSEvent) {
        guard recording else { return super.keyDown(with: e) }
        if e.keyCode == 53 { recording = false; return }
        if e.keyCode == 51, e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty { recording = false; onSet?(nil); return }
        var parts: [String] = []
        let m = e.modifierFlags
        if m.contains(.control) { parts.append("ctrl") }
        if m.contains(.option) { parts.append("alt") }
        if m.contains(.shift) { parts.append("shift") }
        if m.contains(.command) { parts.append("cmd") }
        guard !parts.isEmpty || e.keyCode >= 96, let ch = e.charactersIgnoringModifiers?.lowercased(), !ch.isEmpty else { return }
        parts.append(e.keyCode == 51 ? "backspace" : ch)
        recording = false
        onSet?(parts.joined(separator: "+"))
    }
    override func draw(_ r: NSRect) {
        let box = bounds.insetBy(dx: 0.5, dy: 2.5)
        let p = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
        if recording { t.rowSel.setFill(); p.fill() } else if hover { t.hover.setFill(); p.fill() }
        (recording ? t.fg2 : t.hair).setStroke(); p.lineWidth = 1; p.stroke()
        let s = recording ? "press keys…" : shortcut.isEmpty ? "—" : shortcut
        Text.draw(s, in: bounds, color: recording ? t.fg : shortcut.isEmpty ? t.fg3 : t.fg, font: Fonts.mono(Metrics.fontSize - 1), align: .center)
    }
}

/// Exclusive choice as one control: segments joined in a single outline, the current one raised.
final class Segmented: MXView {
    let options: [(value: String, title: String)]
    var current: String { didSet { needsDisplay = true } }
    var onPick: ((String) -> Void)?
    var isEnabled = true
    private var hover: Int?
    private let font = Fonts.mono(Metrics.fontSize - 1)

    init(_ options: [(value: String, title: String)], current: String) {
        self.options = options; self.current = current
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    private var widths: [CGFloat] { options.map { Text.width($0.title, font: font) + 20 } }
    override var intrinsicContentSize: NSSize { NSSize(width: widths.reduce(0, +), height: Metrics.control) }
    private func rects() -> [NSRect] {
        var x: CGFloat = 0
        return widths.map { w in defer { x += w }; return NSRect(x: x, y: 0, width: w, height: bounds.height) }
    }

    override func draw(_ r: NSRect) {
        let outer = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        t.hair2.setFill(); outer.fill()
        for (i, (o, rect)) in zip(options, rects()).enumerated() {
            let on = o.value == current
            if on {
                let k = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 3, yRadius: 3)
                t.rowSel.setFill(); k.fill()
                t.hair.setStroke(); k.lineWidth = 1; k.stroke()
            } else if hover == i {
                t.hover.setFill(); NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 3, yRadius: 3).fill()
            }
            Text.draw(o.title, in: rect, color: on ? t.fg : t.fg2, font: on ? Fonts.mono(Metrics.fontSize - 1, .medium) : font, align: .center)
        }
        t.hair.setStroke(); outer.lineWidth = 1; outer.stroke()
    }

    private func index(_ e: NSEvent) -> Int? { let p = convert(e.locationInWindow, from: nil); return rects().firstIndex { $0.contains(p) } }
    override func mouseMoved(with e: NSEvent) { let i = isEnabled ? index(e) : nil; if i != hover { hover = i; needsDisplay = true } }
    override func mouseExited(with e: NSEvent) { hover = nil; needsDisplay = true }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) {
        guard isEnabled, let i = index(e), options[i].value != current else { return }
        current = options[i].value
        onPick?(current)
    }
}

// MARK: form

/// One section laid out the way Linear and macOS lay out preferences: groups with a heading
/// and a line about them, each group a card of rows. A row says what the setting is and what
/// it does for you on the left; its control sits on the right, so every switch lines up.
final class FormView: MXView {
    private enum Item {
        case header(y: CGFloat, title: String, note: String?)
        case row(y: CGFloat, h: CGFloat, textY: CGFloat, title: String, note: String?, textW: CGFloat, first: Bool, indent: CGFloat, strong: Bool, warn: Bool, enabled: Bool)
        case footnote(y: CGFloat, text: String)
    }
    private var items: [Item] = []
    private var cards: [NSRect] = []
    private var cardTop: CGFloat?
    private(set) var cursor: CGFloat = 0
    static let x0: CGFloat = 24
    /// Rows stop at a reading width, however wide the window is.
    static let maxW: CGFloat = 660
    static let pad: CGFloat = 14
    static let rowH: CGFloat = 30
    static var titleFont: NSFont { Fonts.mono(Metrics.fontSize - 1) }
    static var noteFont: NSFont { Fonts.mono(Metrics.fontSize - 2) }

    /// Measured from the scroll view, not the clip view: the cards keep their right edge
    /// whether or not a scroller shows.
    var contentW: CGFloat { max(380, min(Self.maxW, (enclosingScrollView?.frame.width ?? bounds.width) - Self.x0 * 2 - 14)) }
    /// The width inside a card: what a control spanning a whole row gets.
    var innerW: CGFloat { contentW - Self.pad * 2 }

    private static func attrs(_ font: NSFont, _ color: NSColor) -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle(); p.lineSpacing = 2
        return [.font: font, .foregroundColor: color, .paragraphStyle: p]
    }
    private func height(_ s: String, _ font: NSFont, width: CGFloat) -> CGFloat {
        ceil((s as NSString).boundingRect(with: NSSize(width: width, height: 2000), options: [.usesLineFragmentOrigin], attributes: Self.attrs(font, .black)).height)
    }

    func reset() { subviews.forEach { $0.removeFromSuperview() }; items = []; cards = []; cardTop = nil; cursor = 12; needsDisplay = true }

    private func openCard() { if cardTop == nil { cardTop = cursor } }
    private func closeCard() {
        guard let top = cardTop else { return }
        cards.append(NSRect(x: Self.x0, y: top, width: contentW, height: cursor - top))
        cardTop = nil
    }

    /// A group: its name, and when it needs one, a line on what the group is for.
    func header(_ s: String, note: String? = nil) {
        closeCard()
        if cursor > 12 { cursor += 26 }
        items.append(.header(y: cursor, title: s, note: note))
        cursor += 20
        if let note { cursor += 2 + height(note, Self.noteFont, width: contentW) }
        cursor += 10
    }

    /// A line under a card: what holds for every row above it.
    func paragraph(_ s: String) {
        closeCard()
        cursor += 8
        items.append(.footnote(y: cursor, text: s))
        cursor += height(s, Self.noteFont, width: contentW)
    }

    /// Ends the card here; the next row starts a new one.
    func gap(_ h: CGFloat) { closeCard(); cursor += h }

    private func controlHeight(_ v: NSView) -> CGFloat {
        switch v {
        case is MXButton, is Segmented: return Metrics.control
        case is KeyRecorder: return 22
        case is Switch: return 18
        case is InputField: return 30
        case is ProjectMark: return 26
        case is Label: return 18
        default: return 20
        }
    }

    /// A row: what it is and what it does on the left, the controls on the right, left to right.
    /// `icon` sits before the title (a project's logo); `warn` marks a row that needs you with a
    /// rule down its left edge; `enabled: false` greys the row and stops its controls.
    func row(_ title: String, _ controls: [(NSView, CGFloat)], note: String? = nil, height minH: CGFloat = 0, padding pv: CGFloat = 11,
             icon: NSView? = nil, warn: Bool = false, enabled: Bool = true) {
        openCard()
        let gap: CGFloat = 6
        let cw = controls.reduce(0) { $0 + $1.1 } + CGFloat(max(0, controls.count - 1)) * gap
        let indent: CGFloat = icon == nil ? 0 : 32
        let textW = max(150, innerW - indent - cw - (controls.isEmpty ? 0 : 24))
        let titleH: CGFloat = title.isEmpty ? 0 : 18
        let noteH = note.map { height($0, Self.noteFont, width: textW) } ?? 0
        let textH = titleH + (note == nil ? 0 : noteH + (title.isEmpty ? 0 : 2))
        let ctlH = controls.map { controlHeight($0.0) }.max() ?? 0
        let h = max(minH, max(textH, ctlH) + pv * 2)
        var x = Self.x0 + contentW - Self.pad - cw
        for (v, w) in controls {
            let ch = controlHeight(v)
            v.frame = NSRect(x: x, y: cursor + (h - ch) / 2, width: w, height: ch)
            addSubview(v)
            if !enabled { v.alphaValue = 0.4; (v as? Segmented)?.isEnabled = false; (v as? MXButton)?.isEnabled = false; (v as? Switch)?.isEnabled = false }
            x += w + gap
        }
        if let icon {
            icon.frame = NSRect(x: Self.x0 + Self.pad, y: cursor + (h - 24) / 2, width: 24, height: 24)
            addSubview(icon)
        }
        items.append(.row(y: cursor, h: h, textY: cursor + (h - textH) / 2, title: title, note: note, textW: textW, first: cursor == cardTop,
                          indent: indent, strong: false, warn: warn, enabled: enabled))
        cursor += h
    }

    /// A row whose control needs the full width: the title and note on top, the view under them.
    func wide(_ title: String, note: String? = nil, _ v: NSView, height vh: CGFloat, strong: Bool = false) {
        openCard()
        let pv: CGFloat = 12
        let noteH = strong ? 0 : note.map { height($0, Self.noteFont, width: innerW) } ?? 0
        let textH = 18 + (note == nil || strong ? 0 : noteH + 2)
        let h = pv + textH + 10 + vh + pv
        v.frame = NSRect(x: Self.x0 + Self.pad, y: cursor + pv + textH + 10, width: innerW, height: vh)
        addSubview(v)
        items.append(.row(y: cursor, h: h, textY: cursor + pv, title: title, note: note, textW: innerW, first: cursor == cardTop,
                          indent: 0, strong: strong, warn: false, enabled: true))
        cursor += h
    }

    /// Exclusive choice: one segmented control, the current option raised.
    func choice(_ label: String, _ options: [(value: String, title: String)], current: String, note: String? = nil, onPick: @escaping (String) -> Void) {
        let s = Segmented(options, current: current)
        s.onPick = onPick
        row(label, [(s, s.intrinsicContentSize.width)], note: note)
    }

    /// Equal tiles, left to right, wrapping when the row is full.
    func grid(_ label: String, _ tiles: [NSView], size: NSSize, note: String? = nil) {
        let gap: CGFloat = 6
        let perRow = max(1, Int((innerW + gap) / (size.width + gap)))
        let rows = (tiles.count + perRow - 1) / perRow
        let box = FlippedBox(frame: .zero)
        for (i, v) in tiles.enumerated() {
            v.frame = NSRect(x: CGFloat(i % perRow) * (size.width + gap), y: CGFloat(i / perRow) * (size.height + gap), width: size.width, height: size.height)
            box.addSubview(v)
        }
        wide(label, note: note, box, height: CGFloat(rows) * (size.height + gap) - gap)
    }

    func toggle(_ label: String, _ on: Bool, note: String? = nil, extra: [(NSView, CGFloat)] = [], onChange: @escaping (Bool) -> Void) {
        let s = Switch(frame: .zero)
        s.isOn = on
        s.onChange = onChange
        row(label, extra + [(s, Switch.size.width)], note: note)
    }

    /// A fact rather than a setting: its value on the right, in the secondary ink.
    func text(_ label: String, _ value: String, note: String? = nil) {
        let font = Fonts.mono(Metrics.fontSize - 1)
        let l = Label(value, font: font, color: { $0.fg2 })
        l.align = .right
        row(label, [(l, min(Text.width(value, font: font) + 4, innerW * 0.6))], note: note)
    }

    func finish() {
        closeCard()
        setFrameSize(NSSize(width: frame.width, height: max(cursor + 28, superview?.bounds.height ?? 0)))
        needsDisplay = true
    }

    /// Descriptions: the light themes' third ink is too faint for small text on a card.
    private var noteColor: NSColor { t.dark ? t.fg3 : t.fg2.blended(withFraction: 0.35, of: t.fg3) ?? t.fg2 }

    override func draw(_ r: NSRect) {
        for c in cards {
            let p = NSBezierPath(roundedRect: c.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            // A shade lighter than the page in both themes, so a card never reads as greyed out.
            (t.dark ? t.fg.withAlphaComponent(0.03) : NSColor.white.withAlphaComponent(0.6)).setFill(); p.fill()
            t.hair.setStroke(); p.lineWidth = 1; p.stroke()
        }
        for item in items {
            switch item {
            case let .header(y, title, note):
                Text.draw(title, in: NSRect(x: Self.x0, y: y, width: contentW, height: 20), color: t.fg, font: Fonts.mono(Metrics.fontSize, .semibold))
                if let note {
                    (note as NSString).draw(with: NSRect(x: Self.x0, y: y + 22, width: contentW, height: 400), options: [.usesLineFragmentOrigin], attributes: Self.attrs(Self.noteFont, noteColor))
                }
            case let .row(y, h, textY, title, note, textW, first, indent, strong, warn, enabled):
                if !first { t.hair2.setFill(); NSRect(x: Self.x0 + Self.pad, y: y, width: contentW - Self.pad * 2, height: 1).fill() }
                if warn { t.on.setFill(); NSRect(x: Self.x0 + 1, y: y + 8, width: 2, height: h - 16).fill() }
                let x = Self.x0 + Self.pad + indent
                if strong {
                    // A card's own header: its name one step up, the note beside it.
                    let f = Fonts.mono(Metrics.fontSize, .semibold)
                    let w = Text.width(title, font: f)
                    Text.draw(title, in: NSRect(x: x, y: textY - 1, width: w + 2, height: 20), color: t.fg, font: f)
                    if let note { Text.draw(note, in: NSRect(x: x + w + 12, y: textY, width: textW - w - 12, height: 18), color: noteColor, font: Self.noteFont) }
                    continue
                }
                if !title.isEmpty {
                    Text.draw(title, in: NSRect(x: x, y: textY, width: textW, height: 18), color: enabled ? t.fg : t.fg3, font: Self.titleFont)
                }
                if let note {
                    (note as NSString).draw(with: NSRect(x: x, y: textY + (title.isEmpty ? 0 : 20), width: textW, height: 400), options: [.usesLineFragmentOrigin], attributes: Self.attrs(Self.noteFont, enabled ? noteColor : t.fg3.withAlphaComponent(0.6)))
                }
            case let .footnote(y, text):
                (text as NSString).draw(with: NSRect(x: Self.x0, y: y, width: contentW, height: 400), options: [.usesLineFragmentOrigin], attributes: Self.attrs(Self.noteFont, noteColor))
            }
        }
    }
}

/// A plain flipped container, so tiles lay out top-down like the form around them.
final class FlippedBox: MXView {}

/// One app icon choice: the icon itself with its name under it, the current one outlined.
final class IconTile: MXView, TipSource {
    let value: String, title: String
    var tip: Tip?
    var isOn = false { didSet { needsDisplay = true } }
    var onPick: ((String) -> Void)?
    private var hover = false
    private lazy var image = IconArt.preview(value, size: 128)
    static let size = NSSize(width: 92, height: 82)

    init(value: String, title: String) {
        self.value = value; self.title = title
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with e: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with e: NSEvent) { hover = false; needsDisplay = true }
    override func mouseUp(with e: NSEvent) { if bounds.contains(convert(e.locationInWindow, from: nil)) { onPick?(value) } }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    func tip(at p: NSPoint) -> (tip: Tip, rect: NSRect)? { tip.map { ($0, bounds) } }

    override func draw(_ r: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
        if isOn {
            t.hover.setFill(); box.fill()
            t.sel.setStroke(); box.lineWidth = 1.5; box.stroke()
        } else if hover {
            t.hover.setFill(); box.fill()
        }
        let side: CGFloat = 56
        image.draw(in: NSRect(x: (bounds.width - side) / 2, y: 4, width: side, height: side))
        let font = Fonts.mono(Metrics.fontSize - 2, isOn ? .medium : .regular)
        let w = min(Text.width(title, font: font), bounds.width - 8)
        Text.draw(title, in: NSRect(x: (bounds.width - w) / 2, y: 60, width: w + 1, height: 18), color: isOn ? t.fg : t.fg2, font: font)
    }
}

/// The section list on the left, like macOS System Settings or Xcode: one key per section.
final class SectionList: MXView {
    var selected = SettingsSection.general { didSet { needsDisplay = true } }
    var onSelect: ((SettingsSection) -> Void)?
    private var hover: Int?
    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    /// Below the traffic lights: the window's content runs under its transparent title bar.
    private func rect(_ i: Int) -> NSRect { NSRect(x: 8, y: 44 + CGFloat(i) * 28, width: bounds.width - 16, height: 26) }
    override func draw(_ r: NSRect) {
        t.plane.setFill(); bounds.fill()
        t.hair.setFill(); NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
        for (i, s) in SettingsSection.allCases.enumerated() {
            let rr = rect(i)
            let sel = s == selected
            if sel { t.rowSel.setFill(); NSBezierPath(roundedRect: rr, xRadius: 4, yRadius: 4).fill() }
            else if hover == i { t.hover.setFill(); NSBezierPath(roundedRect: rr, xRadius: 4, yRadius: 4).fill() }
            Text.draw(s.rawValue, in: NSRect(x: rr.minX + 12, y: rr.minY, width: rr.width - 40, height: rr.height), color: sel ? t.fg : t.fg2)
            Text.draw("⌘\(i + 1)", in: NSRect(x: rr.maxX - 32, y: rr.minY, width: 26, height: rr.height), color: t.fg3, font: Fonts.mono(Metrics.fontSize - 2.5), align: .right)
        }
    }
    private func index(_ e: NSEvent) -> Int? {
        let p = convert(e.locationInWindow, from: nil)
        return SettingsSection.allCases.indices.first { rect($0).contains(p) }
    }
    override func mouseMoved(with e: NSEvent) { let i = index(e); if i != hover { hover = i; needsDisplay = true } }
    override func mouseExited(with e: NSEvent) { hover = nil; needsDisplay = true }
    override func mouseDown(with e: NSEvent) { if let i = index(e) { onSelect?(SettingsSection.allCases[i]) } }
}

// MARK: the window

final class SettingsView: MXView {
    var model = SettingsModel()
    var section = SettingsSection.general { didSet { sections.selected = section; rebuild() } }
    var onSet: ((String, String) -> Void)?
    /// Live preview while a slider moves; the config is written on release.
    var onPreview: ((String, Double?) -> Void)?
    var onInstallHooks: (() -> Void)?
    var onUninstallHooks: (() -> Void)?
    var onAppearance: ((String) -> Void)?
    var onAddAccount: (() -> Void)?
    var onRunAction: ((String) -> Void)?
    /// Sets (nil: removes) an account's `browser` line.
    var onBrowser: ((String, BrowserChoice?) -> Void)?
    private var installedBrowsers: [Browsers.Installed]?
    var onPluginSecret: ((PluginID, String, String?) -> Void)?
    var onPluginRestart: ((PluginID) -> Void)?
    private let sections = SectionList(frame: .zero)
    private let scroll = NSScrollView()
    private let form = FormView(frame: .zero)
    private let title = Label("", font: Fonts.mono(Metrics.fontSize + 1, .semibold))
    /// Keys only: narrows the list as you type. ⌘F focuses it.
    private let filter = InputField(value: "", placeholder: "Filter commands   ⌘F", secure: false)
    private var keyFilter = ""
    static let sidebarW: CGFloat = 168

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.useThinScroller()
        scroll.documentView = form
        [sections, title, scroll, filter].forEach(addSubview)
        filter.onChange = { [weak self] in self?.keyFilter = $0.trimmingCharacters(in: .whitespaces); self?.rebuild() }
        sections.onSelect = { [weak self] in self?.section = $0 }
        NotificationCenter.default.addObserver(forName: ClaudeWeb.changed, object: nil, queue: .main) { [weak self] _ in
            if self?.section == .accounts { self?.rebuild() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        sections.frame = NSRect(x: 0, y: 0, width: Self.sidebarW, height: bounds.height)
        title.frame = NSRect(x: Self.sidebarW + FormView.x0, y: 10, width: 300, height: 30)
        // Its right edge lines up with the cards'.
        filter.frame = NSRect(x: Self.sidebarW + FormView.x0 + form.contentW - 220, y: 8, width: 220, height: 30)
        scroll.frame = NSRect(x: Self.sidebarW, y: 44, width: bounds.width - Self.sidebarW, height: bounds.height - 44)
        if form.frame.width != scroll.contentSize.width { form.frame.size.width = scroll.contentSize.width; rebuild() }
    }

    override func draw(_ r: NSRect) {
        t.background.setFill(); bounds.fill()
        t.hair2.setFill(); NSRect(x: Self.sidebarW, y: 43, width: bounds.width - Self.sidebarW, height: 1).fill()
    }

    func update(_ m: SettingsModel) { model = m; rebuild() }

    func rebuild() {
        title.text = section.rawValue
        filter.isHidden = section != .keys
        form.reset()
        switch section {
        case .general: general()
        case .appearance: appearance()
        case .accounts: accounts()
        case .projects: projects()
        case .plugins: plugins()
        case .keys: keys()
        case .advanced: advanced()
        }
        form.finish()
    }

    private var c: Config { model.config }
    private func set(_ k: String, _ v: String) { onSet?(k, v) }
    private func hours(_ d: TimeInterval) -> String { d.truncatingRemainder(dividingBy: 86400) == 0 && d >= 86400 ? "\(Int(d / 86400))d" : "\(Int(d / 3600))h" }

    private func general() {
        form.header("Updates")
        if !Updater.isRelease {
            form.text("Development build", Updater.current, note: "Development builds don't update themselves. The released Maxwell checks every 4 hours.")
        } else if let v = model.updateReady {
            let go = MXButton("Restart to update", primary: true, small: true) { [weak self] in self?.onRunAction?("install-update") }
            form.row("Maxwell \(v) is ready", [(go, go.intrinsicContentSize.width)],
                     note: "You have \(Updater.current). Restarting installs it, and your sessions keep running.")
        } else {
            let check = MXButton("Check now", small: true) { [weak self] in self?.onRunAction?("check-updates") }
            form.row("Maxwell \(Updater.current)", [(check, check.intrinsicContentSize.width)],
                     note: model.updateStatus ?? "Checks every 4 hours and downloads in the background. Nothing installs until you restart.")
        }
        form.toggle("Send crash reports", c.crashReports,
                    note: Updater.isRelease ? "Crashes and hangs, without paths, prompts or names. runmaxwell.com/docs/privacy#crash-reports" : "Development builds never send them. The released Maxwell does, unless this is off.") { [weak self] in self?.set("crash-reports", $0 ? "on" : "off") }
        notifications()
        form.header("Files", note: "Markdown files open in the viewer, the pane beside the session.")
        form.toggle("Open files as sessions write them", c.autoOpen, note: "Also files a session mentions. ⌘-click any path in the terminal to open it yourself.") { [weak self] in self?.set("auto-open", $0 ? "true" : "false") }
        form.toggle("Show the folder tree", c.showTree, note: "The session's folder, above the open file. ⇧⌘T") { [weak self] in self?.set("file-tree", $0 ? "true" : "false") }
        form.header("Sessions")
        form.toggle("Name sessions automatically", c.autoTitles, note: "Titles each session after what it's working on, with Haiku when Claude's own title says little. Off: a session keeps the name you give it (/rename or Rename…).") { [weak self] in self?.set("auto-titles", $0 ? "on" : "off") }
        form.toggle("Skip permission prompts", c.skipPermissions, note: "Sessions Maxwell starts or brings in run with --dangerously-skip-permissions, so Claude edits files and runs commands without asking. Off: Claude asks as usual.") { [weak self] in self?.set("skip-permissions", $0 ? "on" : "off") }
        form.choice("Move quiet sessions to Idle after", [("12h", "12h"), ("24h", "24h"), ("2d", "2d"), ("7d", "7d")], current: hours(c.idleAfter),
                    note: "Idle is folded away at the bottom of the list. Nothing is stopped.") { [weak self] in self?.set("idle-after", $0) }
        form.toggle("Check finished work with Haiku", c.judge, note: "When a session's reply doesn't end in Safe to close, Haiku reads it once before it counts as safe, for about $0.0002 on the account with the most usage left. Off: no session is ever marked Safe to close.") { [weak self] in self?.set("judge", $0 ? "on" : "off") }
        form.choice("Session list", [("compact", "One line"), ("detail", "Two lines")], current: c.rowStyle,
                    note: "Two lines adds the account, branch and anything running under each title.") { [weak self] in self?.set("row-style", $0) }
    }

    private func notifications() {
        form.header("Notifications", note: "No alert for the session you're already looking at.")
        if model.notificationsAllowed == false {
            let open = MXButton("Open System Settings…", primary: true, small: true) {
                let id = Bundle.main.bundleIdentifier ?? "dev.maxwell.app"
                if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") { NSWorkspace.shared.open(url) }
            }
            form.row("Notifications are off for Maxwell in macOS", [(open, open.intrinsicContentSize.width)],
                     note: "Until you turn them on, alerts show Script Editor's icon and clicking one doesn't open the session.", warn: true)
        }
        form.toggle("When a session needs you", c.notify, note: "It asked you something or wants permission to go on.",
                    extra: c.notify ? [soundMenu(key: "notify-sound", current: c.notifySound)] : []) { [weak self] in self?.set("notify", $0 ? "true" : "false") }
        form.toggle("When a session finishes", c.notifyDone, note: "It stopped, and the next move is yours.",
                    extra: c.notifyDone ? [soundMenu(key: "notify-done-sound", current: c.notifyDoneSound)] : []) { [weak self] in self?.set("notify-done", $0 ? "true" : "false") }
    }

    /// A button that opens a menu: the title on the left, ▾ at the right edge, as wide as `width`.
    /// The font is monospaced, so padding with spaces puts the ▾ in the same column on every row.
    static func popupTitle(_ title: String, width: CGFloat) -> String {
        let cw = Text.width("x", font: Fonts.mono(Metrics.fontSize - 1))
        let room = Int((width - 20) / max(1, cw)) - title.count - 1
        return title + String(repeating: " ", count: max(2, room)) + "▾"
    }

    /// A menu of `Config.sounds`; picking one plays it.
    private func soundMenu(key: String, current: String) -> (NSView, CGFloat) {
        let pick = MXButton(Self.popupTitle(current == "none" ? "No sound" : current, width: 120), small: true)
        pick.tip = Tip("The sound it plays. Picking one plays it")
        pick.action = { [weak self, weak pick] in
            guard let self, let pick else { return }
            let m = NSMenu()
            for s in Config.sounds {
                let i = MenuAction(s == "none" ? "No sound" : s) { [weak self] in Store.play(s); self?.set(key, s) }
                i.state = s == current ? .on : .off
                m.addItem(i)
            }
            m.popUp(positioning: nil, at: NSPoint(x: 0, y: pick.bounds.height + 2), in: pick)
        }
        return (pick, max(120, pick.intrinsicContentSize.width))
    }

    private func appearance() {
        form.header("Theme")
        let free = c.themeOverride == nil
        if let o = c.themeOverride {
            let clear = MXButton("Use Settings instead", small: true) { [weak self] in self?.onAppearance?(self?.c.appearance ?? "system") }
            form.row("Your config file sets the theme", [(clear, clear.intrinsicContentSize.width)],
                     note: "theme = \(o) in ~/.config/maxwell/config. The choices below are ignored until you remove that line.", warn: true)
        }
        func pick(_ label: String, _ options: [(value: String, title: String)], _ current: String, note: String? = nil, _ onPick: @escaping (String) -> Void) {
            let seg = Segmented(options, current: current)
            seg.onPick = onPick
            form.row(label, [(seg, seg.intrinsicContentSize.width)], note: note, enabled: free)
        }
        pick("Mode", [("system", "System"), ("light", "Light"), ("dark", "Dark")], c.appearance,
             note: free ? "System follows macOS. ⇧⌘L switches between light and dark." : "System follows macOS.") { [weak self] in self?.onAppearance?($0) }
        pick("Light theme", Config.lightThemes.map { ($0, Self.themeTitle($0)) }, c.themeLight) { [weak self] in self?.set("theme-light", $0) }
        pick("Dark theme", Config.darkThemes.map { ($0, Self.themeTitle($0)) }, c.themeDark) { [weak self] in self?.set("theme-dark", $0) }
        form.header("App icon")
        let current = IconArt.choices.contains { $0.value == c.appIcon } ? c.appIcon : "auto"
        let tiles = IconArt.choices.map { o -> NSView in
            let tile = IconTile(value: o.value, title: o.title)
            tile.isOn = o.value == current
            tile.tip = Tip(o.tip)
            tile.onPick = { [weak self] in self?.set("app-icon", $0) }
            return tile
        }
        form.grid("Icon in the Dock and Finder", tiles, size: IconTile.size, note: "Auto is Silver in light mode and Gunmetal in dark.")
        form.header("Window glass", note: "How much of your desktop shows through Maxwell.")
        let theme = Theme.load(model.themeName)
        let opacity = c.backgroundOpacity ?? Double(theme.backgroundOpacity)
        let glass = Slider(opacity, 0.3...1) { "\(Int(($0 * 100).rounded()))%" }
        glass.onLive = { [weak self] in self?.onPreview?("background-opacity", $0) }
        glass.onCommit = { [weak self] in self?.set("background-opacity", String(format: "%.2f", $0)) }
        var glassControls: [(NSView, CGFloat)] = [(glass, 220)]
        if c.backgroundOpacity != nil {
            let reset = MXButton("Reset", small: true) { [weak self] in self?.set("background-opacity", "") }
            reset.tip = Tip("Back to the theme's \(Int((theme.backgroundOpacity * 100).rounded()))%")
            glassControls.append((reset, reset.intrinsicContentSize.width))
        }
        form.row("Opacity", glassControls, note: c.backgroundOpacity == nil
                 ? "The theme's own. Lower shows more desktop; panes with text stay at least 72% so they stay readable."
                 : "Lower shows more desktop. Panes with text stay at least 72% so they stay readable.")
        let blurValue = c.backgroundBlur ?? theme.backgroundBlur.map(Double.init)
        let blur = Slider(blurValue ?? 20, 0...64) { "\(Int($0))" }
        blur.onLive = { [weak self] in self?.onPreview?("background-blur", $0) }
        blur.onCommit = { [weak self] in self?.set("background-blur", "\(Int($0))") }
        var blurControls: [(NSView, CGFloat)] = [(blur, 220)]
        if c.backgroundBlur != nil {
            let reset = MXButton("Reset", small: true) { [weak self] in self?.set("background-blur", "") }
            reset.tip = Tip(theme.backgroundBlur == nil ? "Back to the macOS frost" : "Back to the theme's blur")
            blurControls.append((reset, reset.intrinsicContentSize.width))
        }
        form.row("Blur", blurControls, note: blurValue == nil
                 ? "Using the macOS frost. Drag to set your own: 0 is clear glass, 64 is heavy frost."
                 : "0 is clear glass, 64 is heavy frost.")
        form.header("Text and motion")
        stepper("Terminal text size", key: "terminal-font-size", value: c.terminalFontSize, range: 8...28, actions: ("font-smaller", "font-bigger"), note: "The Claude session in the middle.")
        stepper("Interface text size", key: "font-size", value: c.fontSize, range: 10...20, note: "The session list, panels and the viewer.")
        form.choice("Viewer font", [("mono", "Mono"), ("sans", "Sans")], current: c.viewerFont, note: "For Markdown files in the viewer.") { [weak self] in self?.set("viewer-font", $0) }
        form.choice("Animations", [("on", "On"), ("off", "Off")], current: c.motion, note: "Always off while Reduce Motion is on in macOS.") { [weak self] in self?.set("motion", $0) }
    }

    /// − and +, with the actions' live shortcuts as hints when the setting has them.
    private func stepper(_ label: String, key: String, value: Double, range: ClosedRange<Double>, actions: (String, String)? = nil, note: String? = nil) {
        let smaller = MXButton("−", hint: actions.flatMap { Tooltips.shortcut($0.0) }) { [weak self] in self?.set(key, "\(Int(max(range.lowerBound, value - 1)))") }
        let bigger = MXButton("+", hint: actions.flatMap { Tooltips.shortcut($0.1) }) { [weak self] in self?.set(key, "\(Int(min(range.upperBound, value + 1)))") }
        smaller.tip = Tip("Smaller text", action: actions?.0)
        bigger.tip = Tip("Bigger text", action: actions?.1)
        smaller.isEnabled = value > range.lowerBound
        bigger.isEnabled = value < range.upperBound
        let size = Label("\(Int(value)) pt", font: Fonts.mono(Metrics.fontSize - 1), color: { $0.fg })
        size.align = .center
        form.row(label, [(smaller, smaller.intrinsicContentSize.width), (size, 44), (bigger, bigger.intrinsicContentSize.width)], note: note)
    }

    static func title(_ theme: String) -> String { theme.split(separator: "-").map { $0.capitalized }.joined(separator: " ") }
    /// Under "Light theme" the "-light" in a name says nothing: silver-light shows as Silver.
    static func themeTitle(_ theme: String) -> String { title(theme.hasSuffix("-light") ? String(theme.dropLast(6)) : theme) }

    private func accounts() {
        form.header("Claude accounts", note: "Each account is a Claude Code config folder with its own login. ⌘N starts new sessions on the account with the most usage left.")
        let now = Date()
        let browsers = installedBrowsers ?? Browsers.installed()
        installedBrowsers = browsers
        for (i, a) in model.accounts.enumerated() {
            if i > 0 { form.gap(10) }
            form.wide(a.name, note: (a.configDir.path as NSString).abbreviatingWithTildeInPath, UsageRow(account: a, now: now), height: 18, strong: true)
            claudeRow(a)
            let choice = c.browser(for: a.name)
            let pick = MXButton(Self.popupTitle(choice.title(profileName: { _ in Browsers.profileName(choice, in: browsers) }), width: 180), small: true)
            pick.tip = Tip("Where this account's links open outside Maxwell")
            pick.action = { [weak self, weak pick] in if let pick { self?.browserMenu(for: a, browsers: browsers, under: pick) } }
            form.row("Open links in", [(pick, max(180, pick.intrinsicContentSize.width))],
                     note: choice.kind == .container ? "Needs the “Open external links in a container” add-on in \(choice.title())." : "The browser or profile for links from \(a.name) sessions.")
        }
        form.gap(10)
        let add = MXButton("Add account…", small: true) { [weak self] in self?.onAddAccount?() }
        form.row("Add another account", [(add, add.intrinsicContentSize.width)],
                 note: "Choose its config folder, like ~/.claude-work. To make one, run CLAUDE_CONFIG_DIR=~/.claude-work claude and log in.")
        form.header("Artifacts")
        form.choice("Open claude.ai artifacts", [("viewer", "Beside the session"), ("browser", "In the browser")], current: c.artifacts,
                    note: "Artifact links a session makes, or that you ⌘-click. In the browser uses each account's choice above.") { [weak self] in self?.set("artifacts", $0) }
    }

    /// Whether the account is signed in to claude.ai inside Maxwell, with Sign in or Sign out.
    private func claudeRow(_ a: Account) {
        let status = ClaudeWeb.shared.status[a.name] ?? .unknown
        if status == .unknown { ClaudeWeb.shared.refresh(a) }
        let email = ClaudeWeb.expectedEmail(a)
        let text: String, button: MXButton
        switch status {
        case .signedIn:
            text = "Signed in"
            button = MXButton("Sign out", small: true) { [weak self] in ClaudeWeb.shared.signOut(a) { self?.rebuild() } }
            button.tip = Tip("Removes this account's claude.ai login and data from Maxwell")
        case .signedOut:
            text = "Not signed in"
            button = MXButton("Sign in…", small: true) { [weak self] in SignInWindow.show(a, near: self?.window) }
            button.tip = Tip("Opens claude.ai's own sign-in page for \(a.name)\(email.map { " (\($0))" } ?? "")")
        case .unknown:
            text = "Checking…"
            button = MXButton("Sign in…", small: true) { [weak self] in SignInWindow.show(a, near: self?.window) }
        }
        let font = Fonts.mono(Metrics.fontSize - 1)
        let label = Label(text, font: font, color: { status == .signedIn ? $0.fg : $0.fg2 })
        label.align = .right
        form.row("claude.ai", [(label, Text.width(text, font: font) + 4), (button, button.intrinsicContentSize.width)],
                 note: status == .signedIn ? "Artifacts from \(a.name) sessions open signed in." : "Sign in\(email.map { " as \($0)" } ?? "") so this account's artifact links open inside Maxwell.")
    }

    private func browserMenu(for a: Account, browsers: [Browsers.Installed], under v: NSView) {
        let current = c.browser(for: a.name)
        let m = NSMenu()
        m.autoenablesItems = false
        func item(_ title: String, _ choice: BrowserChoice, indent: Int = 0, enabled: Bool = true) -> NSMenuItem {
            let i = MenuAction(title) { [weak self] in self?.onBrowser?(a.name, choice == .systemDefault ? nil : choice) }
            i.state = choice == current ? .on : .off
            i.indentationLevel = indent
            i.isEnabled = enabled
            return i
        }
        m.addItem(item("Default browser", .systemDefault))
        for b in browsers {
            m.addItem(.separator())
            m.addItem(item(b.browser.title, BrowserChoice(browser: b.browser.id)))
            if b.profiles.count > 1 {
                let h = NSMenuItem(title: "Profiles", action: nil, keyEquivalent: ""); h.isEnabled = false; h.indentationLevel = 1
                m.addItem(h)
                for p in b.profiles { m.addItem(item(p.name, BrowserChoice(browser: b.browser.id, kind: .profile, name: p.id), indent: 2)) }
            }
            if !b.containers.isEmpty {
                let h = NSMenuItem(title: b.containerAddon ? "Containers" : "Containers (need the “Open external links in a container” add-on)", action: nil, keyEquivalent: "")
                h.isEnabled = false; h.indentationLevel = 1
                m.addItem(h)
                for n in b.containers { m.addItem(item(n, BrowserChoice(browser: b.browser.id, kind: .container, name: n), indent: 2, enabled: b.containerAddon || current.name == n)) }
                if !b.containerAddon {
                    let get = MenuAction("Get the add-on…") { Browsers.open(Browsers.containerAddonPage, with: BrowserChoice(browser: b.browser.id)) }
                    get.indentationLevel = 2
                    m.addItem(get)
                }
            }
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: v.bounds.height + 2), in: v)
    }

    private func projects() {
        form.header("Project bar", note: "The column of project logos on the left edge of the main window. Click one to see only its sessions.")
        form.choice("Show the bar", [("shown", "Always"), ("auto", "When I point at the edge")], current: c.rail) { [weak self] in self?.set("rail", $0) }
        if c.rail == "auto" {
            let delay = Slider(c.railDelay, 0...1) { String(format: "%.2f s", $0) }
            delay.onCommit = { [weak self] in self?.set("rail-delay", String(format: "%.2f", $0)) }
            form.row("Wait before showing it", [(delay, 220)], note: "How long the pointer rests at the edge before the bar slides out.")
        }
        let pinned = c.pinned
        if pinned.isEmpty {
            form.header("Pinned projects", note: "Nothing is pinned, so every project shows on the bar. Pin the ones you work on to keep only those, plus any project where a session needs you.")
            for p in model.projects {
                let pin = MXButton("Pin", small: true) { [weak self] in self?.set("project-pin", p + "\n") }
                form.row(p, [(pin, pin.intrinsicContentSize.width)], padding: 7, icon: mark(p))
            }
        } else {
            form.header("Pinned projects", note: "Always on the bar, in this order. ⌘1 to ⌘9 jump to them.")
            for (i, p) in pinned.enumerated() {
                let key = Label(i < 9 ? "⌘\(i + 1)" : "", font: Fonts.mono(Metrics.fontSize - 2), color: { $0.fg3 })
                key.align = .right
                let up = MXButton("↑", small: true) { [weak self] in self?.movePin(p, by: -1, in: pinned) }
                up.isEnabled = i > 0
                up.tip = Tip("Move up the bar")
                let down = MXButton("↓", small: true) { [weak self] in self?.movePin(p, by: 1, in: pinned) }
                down.isEnabled = i < pinned.count - 1
                down.tip = Tip("Move down the bar")
                let unpin = MXButton("Unpin", small: true) { [weak self] in self?.set("project-pin", pinned.filter { $0 != p }.joined(separator: "\n") + "\n") }
                unpin.tip = Tip("Show \(p) only when a session there needs you")
                form.row(p, [(key, 28), (up, 24), (down, 24), (unpin, unpin.intrinsicContentSize.width)], padding: 7, icon: mark(p))
            }
            let others = model.projects.filter { !pinned.contains($0) }
            form.paragraph("On the bar, right-click a logo and choose Keep in Rail to pin it, or drag it off to unpin.")
            if !others.isEmpty {
                form.header("Other projects", note: "On the bar only while a session there needs you.")
                for p in others {
                    let pin = MXButton("Pin", small: true) { [weak self] in self?.set("project-pin", (pinned + [p]).joined(separator: "\n") + "\n") }
                    form.row(p, [(pin, pin.intrinsicContentSize.width)], padding: 7, icon: mark(p))
                }
            }
        }
        form.header("Logos", note: "Maxwell looks for a logo in each project's folder and redraws it in the theme's ink.")
        form.choice("Style", [("engraved", "Engraved"), ("pixel", "Pixel"), ("monogram", "Initials")], current: c.logoStyle) { [weak self] in self?.set("project-logo-style", $0) }
        var names = (pinned.isEmpty ? model.projects : pinned + model.projects.filter { !pinned.contains($0) })
        for n in c.logos.keys.sorted() where !names.contains(n) { names.append(n) }
        for name in names { logoRow(name) }
    }

    /// The project's logo as the bar draws it.
    private func mark(_ name: String) -> ProjectMark {
        let m = ProjectMark(frame: .zero)
        m.project = name; m.roots = model.projectRoots[name] ?? []; m.monogram = String(name.prefix(2))
        return m
    }

    /// A project's mark, where it comes from, and Choose… / Reset for `project-logo`.
    private func logoRow(_ name: String) {
        let roots = model.projectRoots[name] ?? []
        let key = ProjectMark(frame: .zero)
        key.project = name; key.roots = roots; key.monogram = String(name.prefix(2))
        // Inside the project's own folder the path from there says enough.
        func shown(_ path: String) -> String {
            roots.first { path.hasPrefix($0 + "/") }.map { String(path.dropFirst($0.count + 1)) } ?? (path as NSString).abbreviatingWithTildeInPath
        }
        let note: String
        if let o = c.logos[name] { note = "Your image, " + shown(o) }
        else if name == "Maxwell" { note = "The app icon" }
        else if let m = ProjectLogos.shared.mark(name, roots: roots) { note = "Found " + shown(m.source) }
        else { note = roots.isEmpty ? "Initials until a session runs in it" : "No logo file found, so initials" }
        let choose = MXButton("Choose…", small: true) { [weak self] in self?.chooseLogo(name) }
        choose.tip = Tip("Pick an image to use as this project's logo")
        var controls: [(NSView, CGFloat)] = []
        if c.logos[name] != nil {
            let reset = MXButton("Reset", small: true) { [weak self] in self?.setLogo(name, nil) }
            reset.tip = Tip("Go back to the logo Maxwell found")
            controls.append((reset, reset.intrinsicContentSize.width))
        }
        controls += [(choose, choose.intrinsicContentSize.width), (key, 26)]
        form.row(name, controls, note: note, padding: 8)
    }

    private func chooseLogo(_ name: String) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.png, .svg, .icns, .ico, .jpeg]
        p.message = "An image for \(name). Maxwell draws its shape in the theme's ink."
        if let first = (model.projectRoots[name] ?? []).first { p.directoryURL = URL(fileURLWithPath: first) }
        guard let w = window else { return }
        p.beginSheetModal(for: w) { [weak self] r in
            if r == .OK, let u = p.url { self?.setLogo(name, u.path) }
        }
    }

    /// Rewrites every `project-logo` line, with this project's set to `path` or removed.
    private func setLogo(_ name: String, _ path: String?) {
        var logos = c.logos
        logos[name] = path
        set("project-logo", logos.sorted { $0.key < $1.key }.map { "\($0.key) \(($0.value as NSString).abbreviatingWithTildeInPath)" }.joined(separator: "\n") + "\n")
    }

    private func movePin(_ p: String, by d: Int, in pins: [String]) {
        var list = pins
        guard let i = list.firstIndex(of: p), list.indices.contains(i + d) else { return }
        list.swapAt(i, i + d)
        set("project-pin", list.joined(separator: "\n") + "\n")
    }

    private func keys() {
        form.paragraph("Click a shortcut, then press the new keys. Delete removes it, Esc cancels. Names match the menus.")
        var menu = ""
        defer { if menu.isEmpty { form.paragraph("No command matches “\(keyFilter)”.") } }
        for a in model.actions {
            let rec = KeyRecorder(a.shortcut)
            let id = a.id
            rec.onSet = { [weak self] spec in self?.setKey(id, spec) }
            if !keyFilter.isEmpty, !a.title.localizedCaseInsensitiveContains(keyFilter), !a.menu.localizedCaseInsensitiveContains(keyFilter) { continue }
            if a.menu != menu { form.header(a.menu); menu = a.menu }
            // Running these from a list is one click from undoing setup or restarting the app.
            let risky = ["uninstall-hooks", "install-hooks", "install-update"].contains(id)
            let run = MXButton("Run", small: true) { [weak self] in self?.onRunAction?(id) }
            run.tip = Tip("Do it now")
            run.alphaValue = risky ? 0 : 1
            run.isEnabled = !risky
            form.row(a.title, [(rec, 110), (run, run.intrinsicContentSize.width)], padding: 5)
        }
    }

    private func setKey(_ id: String, _ spec: String?) {
        var binds = c.keybinds
        binds[id] = spec ?? "none"
        set("keybind", binds.sorted { $0.key < $1.key }.map { "\($0.value)=\($0.key)" }.joined(separator: "\n") + "\n")
    }

    static let docs = "https://github.com/robinsadeghpour/maxwell/blob/v1/docs/"

    private func plugins() {
        let w = form.innerW
        if model.plugins.isEmpty { form.paragraph("No plugins yet. Add one below.") }
        for p in model.plugins {
            let m = p.manifest
            form.header(m.name, note: m.description)
            let on = c.pluginEnabled(m)
            form.toggle(m.name, on, note: "Version \(m.version)\(m.bundled ? ", comes with Maxwell" : "")") { [weak self] in self?.set("\(m.id).enabled", $0 ? "true" : "false") }
            guard on else { continue }
            for f in m.settings {
                let value = c.plugins[m.id]?[f.key] ?? f.default ?? ""
                let key = "\(m.id).\(f.key)"
                switch f.type {
                case .bool:
                    form.toggle(f.title, value == "true", note: f.help) { [weak self] in self?.set(key, $0 ? "true" : "false") }
                case .choice:
                    form.choice(f.title, (f.choices ?? []).map { ($0, $0.prefix(1).uppercased() + $0.dropFirst().replacingOccurrences(of: "-", with: " ")) }, current: value, note: f.help) { [weak self] in self?.set(key, $0) }
                case .string:
                    let field = InputField(value: value, placeholder: f.placeholder ?? "", secure: false)
                    field.onCommit = { [weak self] in self?.set(key, $0) }
                    // A number needs room for a few digits, not a sentence.
                    form.row(f.title, [(field, Int(value) != nil ? 72 : min(w * 0.5, 260))], note: f.help)
                case .secret:
                    let saved = p.secretsSet.contains(f.key)
                    let field = InputField(value: "", placeholder: saved ? "Saved in Keychain" : (f.placeholder ?? "Paste it here"), secure: true)
                    field.onCommit = { [weak self] v in if !v.isEmpty { self?.onPluginSecret?(m.id, f.key, v) } }
                    var controls: [(NSView, CGFloat)] = [(field, min(w * 0.45, 240))]
                    if saved {
                        let clear = MXButton("Remove", small: true) { [weak self] in self?.onPluginSecret?(m.id, f.key, nil) }
                        clear.tip = Tip("Delete it from the Keychain")
                        controls.append((clear, clear.intrinsicContentSize.width))
                    }
                    form.row(f.title, controls, note: f.help ?? "Kept in the macOS Keychain. Only \(m.name) can read it.")
                }
            }
            // A plugin waiting for a key isn't broken: say what it needs, not how to restart it.
            if let need = m.settings.first(where: { $0.type == .secret && !p.secretsSet.contains($0.key) }), p.status.reported == .setup || p.status.reported == nil {
                form.text("Status", "Not connected", note: "Paste the \(need.title) above.")
                continue
            }
            let restart = MXButton("Restart", small: true) { [weak self] in self?.onPluginRestart?(m.id) }
            restart.tip = Tip("Stop and start \(m.name) again")
            let log = MXButton("Open log", small: true) {
                NSWorkspace.shared.open(Paths.stateDir.appendingPathComponent("plugins/\(m.id).log"))
            }
            log.tip = Tip("What \(m.name) wrote to stderr, and when it started and stopped")
            form.row("Status", [(restart, restart.intrinsicContentSize.width), (log, log.intrinsicContentSize.width)], note: p.status.line)
        }
        if !model.brokenPlugins.isEmpty {
            form.header("Couldn't load", note: "Fix the plugin's folder and Maxwell tries again.")
            for b in model.brokenPlugins { form.row(b.folder, [], note: b.why) }
        }
        form.header("Add a plugin")
        let reveal = MXButton("Show folder", small: true) { [weak self] in
            guard let self else { return }
            let url = URL(fileURLWithPath: (self.model.pluginsFolder as NSString).expandingTildeInPath)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        let guide = MXButton("How to write one", small: true) { if let u = URL(string: Self.docs + "plugins.md") { NSWorkspace.shared.open(u) } }
        form.row("Plugins folder", [(guide, guide.intrinsicContentSize.width), (reveal, reveal.intrinsicContentSize.width)],
                 note: "\(model.pluginsFolder). Copy a plugin's folder in and Maxwell loads it.")
    }

    private func confirmUninstall() {
        guard let w = window else { return }
        let a = NSAlert()
        let n = model.hooks.filter(\.installed).count
        a.messageText = "Uninstall hooks from \(n == 1 ? "1 account" : "\(n) accounts")?"
        a.informativeText = "Maxwell won't see when sessions start, stop or need you until you install them again."
        a.addButton(withTitle: "Uninstall")
        a.addButton(withTitle: "Cancel")
        a.buttons.first?.hasDestructiveAction = true
        a.beginSheetModal(for: w) { [weak self] r in if r == .alertFirstButtonReturn { self?.onUninstallHooks?() } }
    }

    private func advanced() {
        let missing = model.hooks.contains { !$0.installed }
        form.header("Hooks", note: "Hooks tell Maxwell when a session starts, stops or needs you. Without them it can't tell. Maxwell also adds one line to your status-line script to read usage; your status line won't change.")
        for h in model.hooks {
            let state = h.file == nil ? "No settings.json" : h.installed ? "Installed" : "Not installed"
            let font = Fonts.mono(Metrics.fontSize - 1)
            let l = Label(state, font: font, color: { h.installed ? $0.fg2 : $0.on })
            l.align = .right
            form.row(h.account, [(l, Text.width(state, font: font) + 4)],
                     note: h.file.map { f in
                         let others = model.hooks.filter { $0.file == f && $0.account != h.account }.map(\.account)
                         return (f as NSString).abbreviatingWithTildeInPath + (others.isEmpty ? "" : " (\(others.joined(separator: ", ")) uses it too)")
                     } ?? "Run Claude Code once with this account to create it.", padding: 8, warn: h.file != nil && !h.installed)
        }
        let uninstall = MXButton("Uninstall", small: true) { [weak self] in self?.confirmUninstall() }
        uninstall.tip = Tip("Takes out everything Maxwell added. Sessions stop reporting to Maxwell")
        var buttons: [(NSView, CGFloat)] = [(uninstall, uninstall.intrinsicContentSize.width)]
        if missing {
            let install = MXButton("Install hooks", primary: true, small: true) { [weak self] in self?.onInstallHooks?() }
            buttons.append((install, install.intrinsicContentSize.width))
        }
        form.row("", buttons, note: "Each settings.json is backed up beside itself first. Uninstall takes out everything Maxwell added.")
        form.header("Config file", note: "Everything in Settings is saved here as plain text. Edit it by hand and Maxwell reloads when you save.")
        let path = (Paths.configFile.path as NSString).abbreviatingWithTildeInPath
        let reveal = MXButton("Show in Finder", small: true) { NSWorkspace.shared.activateFileViewerSelecting([Paths.configFile]) }
        let open = MXButton("Open", small: true) { NSWorkspace.shared.open(Paths.configFile) }
        form.row(path, [(reveal, reveal.intrinsicContentSize.width), (open, open.intrinsicContentSize.width)], note: "⇧⌘, opens it from anywhere.")
        let guide = MXButton("Open guide", small: true) { if let u = URL(string: Self.docs + "config.md") { NSWorkspace.shared.open(u) } }
        form.row("Every setting, explained", [(guide, guide.intrinsicContentSize.width)], note: "Including the few only the file has, like grouping folders into one project.")
    }

    override func keyDown(with e: NSEvent) {
        if section == .keys, e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "f" { filter.focus(); return }
        if e.modifierFlags.contains(.command), let n = Int(e.charactersIgnoringModifiers ?? ""), (1...SettingsSection.allCases.count).contains(n) {
            section = SettingsSection.allCases[n - 1]
        } else { super.keyDown(with: e) }
    }
    override var acceptsFirstResponder: Bool { true }
}

/// A one-line text box with a hairline border. Commits on Return or when focus leaves.
final class InputField: MXView, NSTextFieldDelegate {
    private let field: NSTextField
    var onCommit: ((String) -> Void)?
    /// Every keystroke, for fields that filter as you type.
    var onChange: ((String) -> Void)?
    private var committed: String

    init(value: String, placeholder: String, secure: Bool) {
        field = secure ? NSSecureTextField() : NSTextField()
        committed = value
        super.init(frame: .zero)
        field.stringValue = value
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Fonts.mono(Metrics.fontSize - 1)
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        addSubview(field)
        lookChanged()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func lookChanged() {
        super.lookChanged()
        field.textColor = t.fg
        field.placeholderAttributedString = NSAttributedString(string: field.placeholderString ?? "", attributes: Text.attrs(t.fg3, Fonts.mono(Metrics.fontSize - 1)))
    }
    override func layout() { super.layout(); field.frame = NSRect(x: 7, y: (bounds.height - 18) / 2, width: bounds.width - 14, height: 18) }
    override func draw(_ r: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 4.5), xRadius: 3, yRadius: 3)
        t.hair2.setFill(); path.fill()
        (window?.firstResponder === field.currentEditor() ? t.fg3 : t.hair).setStroke(); path.lineWidth = 1; path.stroke()
    }
    override func mouseDown(with e: NSEvent) { window?.makeFirstResponder(field) }
    func controlTextDidBeginEditing(_ n: Notification) { needsDisplay = true }
    func controlTextDidChange(_ n: Notification) { onChange?(field.stringValue) }
    func focus() { window?.makeFirstResponder(field) }
    func controlTextDidEndEditing(_ n: Notification) {
        needsDisplay = true
        let v = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard v != committed else { return }
        committed = v
        onCommit?(v)
    }
}

/// One account's 5-hour and weekly bars, the same component as the usage panel.
final class UsageRow: MXView, TipSource {
    let account: Account
    let now: Date
    init(account: Account, now: Date) { self.account = account; self.now = now; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ r: NSRect) {
        let w = (bounds.width - 16) / 2
        let small = Fonts.mono(Metrics.fontSize - 2)
        let rw = Text.width("↻Sat 00:00", font: Fonts.mono(Metrics.fontSize - 2))
        let lw = Text.width("Weekly", font: small) + 8
        Text.draw("5-hour", in: NSRect(x: 0, y: 0, width: lw, height: bounds.height), color: t.fg3, font: small)
        UsageBar.draw(account.fiveHour, in: NSRect(x: lw, y: 0, width: w - lw, height: bounds.height), now: now, theme: t, resetWidth: rw)
        Text.draw("Weekly", in: NSRect(x: w + 16, y: 0, width: lw, height: bounds.height), color: t.fg3, font: small)
        UsageBar.draw(account.week, in: NSRect(x: w + 16 + lw, y: 0, width: w - lw, height: bounds.height), now: now, theme: t, resetWidth: rw)
    }
    func tip(at p: NSPoint) -> (tip: Tip, rect: NSRect)? {
        let w = (bounds.width - 16) / 2, week = p.x >= w + 16
        return (UsageBar.tip(week ? account.week : account.fiveHour, week: week), NSRect(x: week ? w + 16 : 0, y: 0, width: w, height: bounds.height))
    }
}

final class SettingsWindowController: NSWindowController {
    let view = SettingsView(frame: NSRect(x: 0, y: 0, width: 820, height: 600))
    private(set) var tooltips: Tooltips!

    init() {
        let w = MXWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        w.title = "Maxwell Settings"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.minSize = NSSize(width: 720, height: 420)
        view.autoresizingMask = [.width, .height]
        w.contentView = view
        w.isReleasedWhenClosed = false
        super.init(window: w)
        tooltips = Tooltips(window: w)
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: Look.changed, object: nil)
        themeChanged()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func themeChanged() { window?.appearance = Look.theme.appearance; view.rebuild() }

    func show(_ m: SettingsModel, section: SettingsSection? = nil) {
        if let section { view.section = section }
        view.update(m)
        if window?.isVisible != true { window?.center() }
        (window as? MXWindow)?.present()
        window?.makeFirstResponder(view)
    }
}
