import AppKit
import UniformTypeIdentifiers

/// Everything Settings shows. The window edits ~/.config/maxwell/config line by line and the
/// app reloads from the file, so the mouse and the config file always agree.
struct SettingsModel {
    var config = Config()
    var hookStatus = ""
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
    var onChange: ((Bool) -> Void)?
    private var hover = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseEntered(with e: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with e: NSEvent) { hover = false; needsDisplay = true }
    override func mouseDown(with e: NSEvent) { isOn.toggle(); onChange?(isOn) }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func draw(_ r: NSRect) {
        let track = NSRect(x: 0.5, y: (bounds.height - 14) / 2 + 0.5, width: 26, height: 13)
        let p = NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3)
        (isOn ? t.sel : hover ? t.hover : t.hair2).setFill(); p.fill()
        t.hair.setStroke(); p.lineWidth = 1; p.stroke()
        let knob = NSRect(x: isOn ? track.maxX - 11.5 : track.minX + 1.5, y: track.minY + 1.5, width: 10, height: 10)
        (isOn ? t.selFg : t.fg2).setFill()
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
    override func mouseMoved(with e: NSEvent) { let i = index(e); if i != hover { hover = i; needsDisplay = true } }
    override func mouseExited(with e: NSEvent) { hover = nil; needsDisplay = true }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) {
        guard let i = index(e), options[i].value != current else { return }
        current = options[i].value
        onPick?(current)
    }
}

// MARK: form

/// One section's rows on one grid: labels in a 200 pt column, controls from there, 30 pt rows.
/// Notes wrap under their controls instead of being cut off.
final class FormView: MXView {
    private struct Line { var y: CGFloat; var label: String; var note: String?; var noteH: CGFloat = 0; var header: Bool }
    private var lines: [Line] = []
    private(set) var cursor: CGFloat = 0
    static let labelW: CGFloat = 200
    static let rowH: CGFloat = 30
    static let x0: CGFloat = 24
    /// Notes stop at a reading width, however wide the window is.
    static let noteMax: CGFloat = 480
    private static let noteFont = Fonts.mono(Metrics.fontSize - 2)

    private var noteWidth: CGFloat { max(160, min(Self.noteMax, bounds.width - Self.x0 * 2 - Self.labelW)) }
    private static func noteAttrs(_ color: NSColor) -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle(); p.lineSpacing = 2
        return [.font: noteFont, .foregroundColor: color, .paragraphStyle: p]
    }
    private func noteHeight(_ s: String) -> CGFloat {
        ceil((s as NSString).boundingRect(with: NSSize(width: noteWidth, height: 1000), options: [.usesLineFragmentOrigin], attributes: Self.noteAttrs(.black)).height)
    }

    func reset() { subviews.forEach { $0.removeFromSuperview() }; lines = []; cursor = 16; needsDisplay = true }

    func header(_ s: String) {
        if cursor > 16 { cursor += 14 }
        lines.append(Line(y: cursor, label: s, note: nil, header: true))
        cursor += 30
    }

    /// A row: label on the left, the controls left to right with their own widths, an optional note under them.
    /// A leading value label is only as wide as its text, so its buttons sit right after it;
    /// later labels keep their width so columns of buttons line up.
    func row(_ label: String, _ controls: [(NSView, CGFloat)], note: String? = nil, height: CGFloat = FormView.rowH) {
        var x = Self.x0 + Self.labelW
        for (i, (v, w)) in controls.enumerated() {
            let h = v is MXButton || v is Segmented ? Metrics.control : v is KeyRecorder ? 22 : height
            let w = i == 0 && controls.count > 1 ? (v as? Label).map { min(w, $0.textWidth + 2) } ?? w : w
            v.frame = NSRect(x: x, y: cursor + (height - h) / 2, width: w, height: h)
            addSubview(v)
            x += w + (i == 0 && v is Label ? 12 : 6)
        }
        let nh = note.map(noteHeight) ?? 0
        lines.append(Line(y: cursor, label: label, note: note, noteH: nh, header: false))
        cursor += height + (note == nil ? 2 : nh + 6)
    }

    /// Exclusive choice: one segmented control, the current option raised.
    func choice(_ label: String, _ options: [(value: String, title: String)], current: String, note: String? = nil, onPick: @escaping (String) -> Void) {
        let s = Segmented(options, current: current)
        s.onPick = onPick
        row(label, [(s, s.intrinsicContentSize.width)], note: note)
    }

    /// A paragraph across the control column, with no label: what a group of rows is about.
    func paragraph(_ s: String) {
        let nh = noteHeight(s)
        lines.append(Line(y: cursor - FormView.rowH + 2, label: "", note: s, noteH: nh, header: false))
        cursor += nh + 10
    }

    /// Equal tiles, left to right, wrapping to the next line when the column is full.
    func grid(_ label: String, _ tiles: [NSView], size: NSSize, note: String? = nil) {
        let gap: CGFloat = 6, avail = max(size.width, bounds.width - Self.x0 * 2 - Self.labelW)
        let perRow = max(1, Int((avail + gap) / (size.width + gap)))
        let rows = (tiles.count + perRow - 1) / perRow
        for (i, v) in tiles.enumerated() {
            v.frame = NSRect(x: Self.x0 + Self.labelW + CGFloat(i % perRow) * (size.width + gap),
                             y: cursor + 4 + CGFloat(i / perRow) * (size.height + gap), width: size.width, height: size.height)
            addSubview(v)
        }
        let height = CGFloat(rows) * (size.height + gap) - gap + 8
        lines.append(Line(y: cursor, label: label, note: nil, header: false))
        cursor += height
        if let note { paragraph(note) }
    }

    func toggle(_ label: String, _ on: Bool, note: String? = nil, onChange: @escaping (Bool) -> Void) {
        let s = Switch(frame: .zero)
        s.isOn = on
        s.onChange = onChange
        row(label, [(s, 30)], note: note)
    }

    func text(_ label: String, _ value: String, note: String? = nil) {
        let l = Label(value, font: Fonts.mono(Metrics.fontSize - 1), color: { $0.fg })
        row(label, [(l, bounds.width - Self.x0 * 2 - Self.labelW)], note: note)
    }

    /// Extra space between groups of rows.
    func gap(_ h: CGFloat) { cursor += h }

    func finish() {
        setFrameSize(NSSize(width: frame.width, height: max(cursor + 20, superview?.bounds.height ?? 0)))
        needsDisplay = true
    }

    override func draw(_ r: NSRect) {
        for l in lines {
            if l.header {
                Text.draw(l.label.uppercased(), in: NSRect(x: Self.x0, y: l.y, width: 300, height: 20), color: t.fg3, font: Fonts.mono(Metrics.fontSize - 2.5, .medium))
                t.hair2.setFill(); NSRect(x: Self.x0, y: l.y + 21, width: bounds.width - Self.x0 * 2, height: 1).fill()
            } else {
                Text.draw(l.label, in: NSRect(x: Self.x0, y: l.y, width: Self.labelW - 12, height: FormView.rowH), color: t.fg2, font: Fonts.mono(Metrics.fontSize - 1))
                if let n = l.note {
                    (n as NSString).draw(with: NSRect(x: Self.x0 + Self.labelW, y: l.y + FormView.rowH - 2, width: noteWidth, height: l.noteH + 4),
                                         options: [.usesLineFragmentOrigin], attributes: Self.noteAttrs(t.fg3))
                }
            }
        }
    }
}

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
            if sel { t.rowSel.setFill(); NSBezierPath(roundedRect: rr, xRadius: 4, yRadius: 4).fill(); t.fg.setFill(); NSRect(x: rr.minX, y: rr.minY + 6, width: 2, height: rr.height - 12).fill() }
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
    static let sidebarW: CGFloat = 168

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.useThinScroller()
        scroll.documentView = form
        [sections, title, scroll].forEach(addSubview)
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
            form.text("Version", "Maxwell Dev \(Updater.current)", note: "Dev builds don't update. The released Maxwell does.")
        } else if let v = model.updateReady {
            let go = MXButton("Restart to update", primary: true) { [weak self] in self?.onRunAction?("install-update") }
            form.row("Version", [(Label("\(Updater.current)", font: Fonts.mono(Metrics.fontSize - 1), color: { $0.fg }), 70), (go, go.intrinsicContentSize.width)],
                     note: "v\(v) is downloaded. Sessions keep running through the restart.")
        } else {
            let check = MXButton("Check now") { [weak self] in self?.onRunAction?("check-updates") }
            form.row("Version", [(Label("\(Updater.current)", font: Fonts.mono(Metrics.fontSize - 1), color: { $0.fg }), 70), (check, check.intrinsicContentSize.width)],
                     note: model.updateStatus ?? "Checked every 4 hours. A new version waits for your click.")
        }
        form.header("Attention")
        form.toggle("Notifications", c.notify, note: "A macOS notification when a session needs you.") { [weak self] in self?.set("notify", $0 ? "true" : "false") }
        form.toggle("Open files automatically", c.autoOpen, note: "Markdown files a session writes or mentions open in the viewer.") { [weak self] in self?.set("auto-open", $0 ? "true" : "false") }
        form.toggle("File tree", c.showTree, note: "Shows the session's folder above the viewer. ⇧⌘T toggles it.") { [weak self] in self?.set("file-tree", $0 ? "true" : "false") }
        form.header("Sessions")
        form.toggle("Skip permission prompts", c.skipPermissions, note: "New and brought-in sessions run with --dangerously-skip-permissions. Off: Claude's own mode.") { [weak self] in self?.set("skip-permissions", $0 ? "on" : "off") }
        form.choice("Fold into Idle after", [("12h", "12h"), ("24h", "24h"), ("2d", "2d"), ("7d", "7d")], current: hours(c.idleAfter)) { [weak self] in self?.set("idle-after", $0) }
        form.toggle("Final model check", c.judge, note: "Haiku reads the last reply once. If off, nothing is ever safe.") { [weak self] in self?.set("judge", $0 ? "on" : "off") }
        form.choice("Rows", [("detail", "Two lines"), ("compact", "One line")], current: c.rowStyle) { [weak self] in self?.set("row-style", $0) }
    }

    private func appearance() {
        form.header("Theme")
        if let o = c.themeOverride {
            let clear = MXButton("Unlock") { [weak self] in self?.onAppearance?(self?.c.appearance ?? "system") }
            form.row("Locked to", [(Label(Self.title(o), font: Fonts.mono(Metrics.fontSize - 1), color: { $0.fg }), 90), (clear, clear.intrinsicContentSize.width)],
                     note: "Set in your config file, so the choices below are ignored.")
        }
        form.choice("Appearance", [("system", "System"), ("light", "Light"), ("dark", "Dark")], current: c.appearance,
                    note: "⇧⌘L switches between light and dark. Also in View › Appearance.") { [weak self] in self?.onAppearance?($0) }
        form.choice("Light theme", Config.lightThemes.map { ($0, Self.title($0)) }, current: c.themeLight) { [weak self] in self?.set("theme-light", $0) }
        form.choice("Dark theme", Config.darkThemes.map { ($0, Self.title($0)) }, current: c.themeDark) { [weak self] in self?.set("theme-dark", $0) }
        form.header("App icon")
        let current = IconArt.choices.contains { $0.value == c.appIcon } ? c.appIcon : "auto"
        let tiles = IconArt.choices.map { o -> NSView in
            let tile = IconTile(value: o.value, title: o.title)
            tile.isOn = o.value == current
            tile.tip = Tip(o.tip)
            tile.onPick = { [weak self] in self?.set("app-icon", $0) }
            return tile
        }
        form.grid("Dock and Finder", tiles, size: IconTile.size, note: "Also shown while Maxwell is closed.")
        form.header("Glass")
        let theme = Theme.load(model.themeName)
        let glass = Slider(c.backgroundOpacity ?? Double(theme.backgroundOpacity), 0.3...1) { "\(Int(($0 * 100).rounded()))%" }
        glass.onLive = { [weak self] in self?.onPreview?("background-opacity", $0) }
        glass.onCommit = { [weak self] in self?.set("background-opacity", String(format: "%.2f", $0)) }
        let glassReset = MXButton("Theme", small: true) { [weak self] in self?.set("background-opacity", "") }
        glassReset.isOn = c.backgroundOpacity == nil
        glassReset.tip = Tip("Use the theme's own tint")
        form.row("Tint", [(glass, 260), (glassReset, glassReset.intrinsicContentSize.width)], note: "Lower shows more of the desktop. Panes with text never go below 72%.")
        let blurValue = c.backgroundBlur ?? theme.backgroundBlur.map(Double.init)
        let blur = Slider(blurValue ?? 20, 0...64) { "\(Int($0)) pt" }
        blur.onLive = { [weak self] in self?.onPreview?("background-blur", $0) }
        blur.onCommit = { [weak self] in self?.set("background-blur", "\(Int($0))") }
        let system = MXButton("System", small: true) { [weak self] in self?.set("background-blur", "") }
        system.isOn = blurValue == nil
        system.tip = Tip("Use the macOS frost")
        form.row("Blur", [(blur, 260), (system, system.intrinsicContentSize.width)], note: system.isOn ? "Using the macOS frost. Drag to set your own. 0 is clear." : "0 is clear glass, 64 is heavy frost. System uses the macOS frost.")
        form.header("Type and motion")
        stepper("Terminal text", key: "terminal-font-size", value: c.terminalFontSize, range: 8...28, actions: ("font-smaller", "font-bigger"))
        stepper("Interface text", key: "font-size", value: c.fontSize, range: 10...20, note: "Lists, panels and the viewer.")
        form.choice("Viewer text", [("mono", "Mono"), ("sans", "Sans")], current: c.viewerFont) { [weak self] in self?.set("viewer-font", $0) }
        form.choice("Motion", [("on", "On"), ("off", "Off")], current: c.motion, note: "Always off while macOS Reduce Motion is on.") { [weak self] in self?.set("motion", $0) }
    }

    /// − and +, with the actions' live shortcuts as hints when the setting has them.
    private func stepper(_ label: String, key: String, value: Double, range: ClosedRange<Double>, actions: (String, String)? = nil, note: String? = nil) {
        let smaller = MXButton("−", hint: actions.flatMap { Tooltips.shortcut($0.0) }) { [weak self] in self?.set(key, "\(Int(max(range.lowerBound, value - 1)))") }
        let bigger = MXButton("+", hint: actions.flatMap { Tooltips.shortcut($0.1) }) { [weak self] in self?.set(key, "\(Int(min(range.upperBound, value + 1)))") }
        smaller.tip = Tip("Smaller text", action: actions?.0)
        bigger.tip = Tip("Bigger text", action: actions?.1)
        form.row(label, [(smaller, smaller.intrinsicContentSize.width), (Label("\(Int(value)) pt", font: Fonts.mono(Metrics.fontSize - 1), color: { $0.fg }), 48), (bigger, bigger.intrinsicContentSize.width)], note: note)
    }

    static func title(_ theme: String) -> String { theme.split(separator: "-").map { $0.capitalized }.joined(separator: " ") }

    private func accounts() {
        form.header("Claude accounts")
        let now = Date()
        let browsers = installedBrowsers ?? Browsers.installed()
        installedBrowsers = browsers
        for (i, a) in model.accounts.enumerated() {
            if i > 0 { form.gap(10) }
            let usage = UsageRow(account: a, now: now)
            form.row(a.name, [(usage, max(200, form.bounds.width - FormView.x0 * 2 - FormView.labelW))], note: (a.configDir.path as NSString).abbreviatingWithTildeInPath)
            claudeRow(a)
            let choice = c.browser(for: a.name)
            let pick = MXButton(choice.title(profileName: { _ in Browsers.profileName(choice, in: browsers) }) + "  ▾")
            pick.tip = Tip("Where this account's links open outside Maxwell")
            pick.action = { [weak self, weak pick] in if let pick { self?.browserMenu(for: a, browsers: browsers, under: pick) } }
            form.row("  browser", [(pick, max(160, pick.intrinsicContentSize.width))],
                     note: choice.kind == .container ? "Needs the “Open external links in a container” add-on in \(choice.title())." : nil)
        }
        let add = MXButton("Add account…") { [weak self] in self?.onAddAccount?() }
        form.row("", [(add, add.intrinsicContentSize.width)], note: "Choose its config folder. New sessions go where usage is left.")
        form.header("Artifacts")
        form.choice("Open artifacts", [("viewer", "Beside the session"), ("browser", "In the account's browser")], current: c.artifacts,
                    note: "claude.ai artifact links a session makes or you ⌘-click.") { [weak self] in self?.set("artifacts", $0) }
        form.header("Usage source")
        form.text("Status line", "Claude Code's status line, every 30 s per account", note: "Set up together with the hooks in Advanced.")
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
        let label = Label(text, font: Fonts.mono(Metrics.fontSize - 1), color: { status == .signedIn ? $0.fg : $0.fg2 })
        form.row("  claude.ai", [(label, Text.width(text, font: Fonts.mono(Metrics.fontSize - 1)) + 12), (button, button.intrinsicContentSize.width)],
                 note: status == .signedIn ? "Artifacts from \(a.name) sessions open signed in." : email.map { "Sign in as \($0) to see this account's artifacts." })
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
        form.header("Rail")
        form.choice("Rail", [("auto", "Hide at the edge"), ("shown", "Always show")], current: c.rail) { [weak self] in self?.set("rail", $0) }
        let delay = Slider(c.railDelay, 0...1) { String(format: "%.2f s", $0) }
        delay.onCommit = { [weak self] in self?.set("rail-delay", String(format: "%.2f", $0)) }
        form.row("Reveal delay", [(delay, 260)], note: "Hover time at the left edge before the rail appears.")
        let pins = c.pinned.isEmpty ? model.projects : c.pinned
        form.header("Logos")
        form.choice("Style", [("engraved", "Engraved"), ("pixel", "Pixel"), ("monogram", "Initials")], current: c.logoStyle) { [weak self] in self?.set("project-logo-style", $0) }
        var names = pins + model.projects.filter { !pins.contains($0) }
        for n in c.logos.keys.sorted() where !names.contains(n) { names.append(n) }
        for name in names { logoRow(name) }
        form.header("Pinned, in rail order")
        if c.pinned.isEmpty { form.text("", "Nothing pinned yet, so every project shows on the rail.") }
        for (i, p) in pins.enumerated() {
            let up = MXButton("↑", small: true) { [weak self] in self?.movePin(p, by: -1, in: pins) }
            up.isEnabled = i > 0
            up.tip = Tip("Move up the rail")
            let down = MXButton("↓", small: true) { [weak self] in self?.movePin(p, by: 1, in: pins) }
            down.isEnabled = i < pins.count - 1
            down.tip = Tip("Move down the rail")
            let remove = MXButton("Remove", small: true) { [weak self] in self?.set("project-pin", pins.filter { $0 != p }.joined(separator: "\n") + "\n") }
            form.row("⌘\(i + 1)  \(p)", [(up, 24), (down, 24), (remove, remove.intrinsicContentSize.width)])
        }
        let unpinned = model.projects.filter { !pins.contains($0) }
        if !unpinned.isEmpty {
            form.header("Not pinned, shown only when they need you")
            for p in unpinned {
                let pin = MXButton("Keep in Rail", small: true) { [weak self] in self?.set("project-pin", (pins + [p]).joined(separator: "\n") + "\n") }
                form.row(p, [(pin, pin.intrinsicContentSize.width)])
            }
        }
    }

    /// A project's key, where its logo comes from, and Choose… / Reset for `project-logo`.
    private func logoRow(_ name: String) {
        let roots = model.projectRoots[name] ?? []
        let key = ProjectMark(frame: .zero)
        key.project = name; key.roots = roots; key.monogram = String(name.prefix(2))
        let source: String
        if let o = c.logos[name] { source = o }
        else if name == "Maxwell" { source = "The app icon" }
        else if let m = ProjectLogos.shared.mark(name, roots: roots) { source = m.source }
        else { source = roots.isEmpty ? "Initials until a session runs in it" : "Initials, no logo file found" }
        // Inside the project's own folder the relative path says enough; the tooltip has all of it.
        let root = roots.first { source.hasPrefix($0 + "/") }
        let shown = root.map { ($0 as NSString).lastPathComponent + "/" + source.dropFirst($0.count + 1) } ?? (source as NSString).abbreviatingWithTildeInPath
        let path = Label(shown, font: Fonts.mono(Metrics.fontSize - 2), color: { $0.fg2 })
        path.tip = Tip((source as NSString).abbreviatingWithTildeInPath)
        let choose = MXButton("Choose…", small: true) { [weak self] in self?.chooseLogo(name) }
        let reset = MXButton("Reset", small: true) { [weak self] in self?.setLogo(name, nil) }
        reset.isEnabled = c.logos[name] != nil
        choose.tip = Tip("Pick an image to use as this project's logo")
        reset.tip = Tip(reset.isEnabled ? "Go back to the logo Maxwell found" : "Already using the logo Maxwell found")
        let chooseW = choose.intrinsicContentSize.width + 16, resetW = reset.intrinsicContentSize.width + 16
        let pathW = max(120, form.bounds.width - FormView.x0 * 2 - FormView.labelW - 26 - chooseW - resetW - 18)
        form.row(name, [(key, 26), (path, pathW), (choose, chooseW), (reset, resetW)])
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
        var menu = ""
        for a in model.actions {
            if a.menu != menu { form.header(a.menu); menu = a.menu }
            let rec = KeyRecorder(a.shortcut)
            let id = a.id
            rec.onSet = { [weak self] spec in self?.setKey(id, spec) }
            let run = MXButton("Run", small: true) { [weak self] in self?.onRunAction?(id) }
            form.row(a.title, [(rec, 110), (run, run.intrinsicContentSize.width)], height: 26)
        }
        form.text("", "Click a shortcut and press the new keys. ⌫ removes it, Esc cancels.")
    }

    private func setKey(_ id: String, _ spec: String?) {
        var binds = c.keybinds
        binds[id] = spec ?? "none"
        set("keybind", binds.sorted { $0.key < $1.key }.map { "\($0.value)=\($0.key)" }.joined(separator: "\n") + "\n")
    }

    private func plugins() {
        let w = max(200, form.bounds.width - FormView.x0 * 2 - FormView.labelW)
        if model.plugins.isEmpty { form.text("", "No plugins installed.") }
        for p in model.plugins {
            let m = p.manifest
            form.header("\(m.name)  ·  \(m.version)\(m.bundled ? "  ·  built in" : "")")
            let on = c.pluginEnabled(m.id)
            form.toggle("Enabled", on, note: m.description) { [weak self] in self?.set("\(m.id).enabled", $0 ? "true" : "false") }
            guard on else { continue }
            var buttons: [(NSView, CGFloat)] = [(Label(p.status.line, font: Fonts.mono(Metrics.fontSize - 1), color: { $0.fg }), w - 190)]
            let restart = MXButton("Restart", small: true) { [weak self] in self?.onPluginRestart?(m.id) }
            restart.tip = Tip("Stop and start \(m.name) again")
            let log = MXButton("Open Log", small: true) {
                NSWorkspace.shared.open(Paths.stateDir.appendingPathComponent("plugins/\(m.id).log"))
            }
            log.tip = Tip("What \(m.name) wrote to stderr, and when it started and stopped")
            buttons += [(restart, restart.intrinsicContentSize.width), (log, log.intrinsicContentSize.width)]
            form.row("Status", buttons)
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
                    form.row(f.title, [(field, Int(value) != nil ? 72 : min(w, 280))], note: f.help)
                case .secret:
                    let saved = p.secretsSet.contains(f.key)
                    let field = InputField(value: "", placeholder: saved ? "Saved in Keychain" : (f.placeholder ?? "Paste it here"), secure: true)
                    field.onCommit = { [weak self] v in if !v.isEmpty { self?.onPluginSecret?(m.id, f.key, v) } }
                    var controls: [(NSView, CGFloat)] = [(field, min(w - 70, 280))]
                    if saved {
                        let clear = MXButton("Remove", small: true) { [weak self] in self?.onPluginSecret?(m.id, f.key, nil) }
                        clear.tip = Tip("Delete it from the Keychain")
                        controls.append((clear, clear.intrinsicContentSize.width))
                    }
                    form.row(f.title, controls, note: f.help ?? "Kept in the macOS Keychain, only \(m.name) can read it.")
                }
            }
        }
        if !model.brokenPlugins.isEmpty {
            form.header("Couldn't load")
            for b in model.brokenPlugins { form.text(b.folder, b.why) }
        }
        form.header("Install")
        let reveal = MXButton("Reveal in Finder") { [weak self] in
            guard let self else { return }
            let url = URL(fileURLWithPath: (self.model.pluginsFolder as NSString).expandingTildeInPath)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        form.row("Plugins folder", [(Label(model.pluginsFolder, font: Fonts.mono(Metrics.fontSize - 1), color: { $0.fg }), min(w, 320))])
        form.row("", [(reveal, reveal.intrinsicContentSize.width)], note: "Copy a plugin's folder in; Maxwell picks it up. docs/plugins.md shows how to write one.")
    }

    private func advanced() {
        form.header("Hooks")
        let install = MXButton("Install hooks", hint: "⇧⌘H") { [weak self] in self?.onInstallHooks?() }
        let uninstall = MXButton("Uninstall", hint: "⇧⌘U") { [weak self] in self?.onUninstallHooks?() }
        form.row("Status", [(Label(model.hookStatus, font: Fonts.mono(Metrics.fontSize - 1), color: { $0.fg }), 240)])
        form.row("", [(install, install.intrinsicContentSize.width), (uninstall, uninstall.intrinsicContentSize.width)],
                 note: "Backs up each account's settings.json first. Uninstall restores it.")
        form.header("Config file")
        let path = (Paths.configFile.path as NSString).abbreviatingWithTildeInPath
        let reveal = MXButton("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Paths.configFile]) }
        let open = MXButton("Open", hint: "⇧⌘,") { NSWorkspace.shared.open(Paths.configFile) }
        form.row("Path", [(Label(path, font: Fonts.mono(Metrics.fontSize - 1), color: { $0.fg }), 260)])
        form.row("", [(reveal, reveal.intrinsicContentSize.width), (open, open.intrinsicContentSize.width)], note: "Maxwell reloads it when you save. docs/config.md lists every setting.")
        form.header("Current settings")
        let text = (try? String(contentsOf: Paths.configFile, encoding: .utf8)) ?? Config.starter
        for l in text.components(separatedBy: "\n") where !l.hasPrefix("#") && !l.trimmingCharacters(in: .whitespaces).isEmpty {
            form.row("", [(Label(l, font: Fonts.mono(Metrics.fontSize - 1), color: { $0.fg2 }), 420)], height: 18)
        }
    }

    override func keyDown(with e: NSEvent) {
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
        let small = Fonts.mono(Metrics.fontSize - 2.5, .medium)
        let rw = Text.width("↻Sat 00:00", font: Fonts.mono(Metrics.fontSize - 2))
        Text.draw("5H", in: NSRect(x: 0, y: 0, width: 24, height: bounds.height), color: t.fg3, font: small)
        UsageBar.draw(account.fiveHour, in: NSRect(x: 24, y: 0, width: w - 24, height: bounds.height), now: now, theme: t, resetWidth: rw)
        Text.draw("WK", in: NSRect(x: w + 16, y: 0, width: 24, height: bounds.height), color: t.fg3, font: small)
        UsageBar.draw(account.week, in: NSRect(x: w + 40, y: 0, width: w - 24, height: bounds.height), now: now, theme: t, resetWidth: rw)
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
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
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
        if quietTest { window?.orderBack(nil) } else {
            showWindow(nil)
            window?.makeKeyAndOrderFront(nil)
        }
        window?.makeFirstResponder(view)
    }
}
