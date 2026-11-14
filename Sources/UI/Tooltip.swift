import AppKit

/// What a hovered control says: one or two short lines, and the action whose shortcut follows them.
/// The shortcut is looked up when the tip shows, so a remapped key reads right.
struct Tip: Equatable {
    var text: String
    var action: String?
    init(_ text: String, action: String? = nil) { self.text = text; self.action = action }
    /// The same tip with a second, quieter line.
    func adding(_ line: String) -> Tip { Tip(text + "\n" + line, action: action) }
}

/// A view that explains itself on hover. The point and the returned rect are in the view's own coordinates.
protocol TipSource: NSView {
    func tip(at p: NSPoint) -> (tip: Tip, rect: NSRect)?
    /// Tips go under the control; a vertical strip at the window's edge (the rail) puts them beside it.
    var tipsBeside: Bool { get }
}

extension TipSource {
    var tipsBeside: Bool { false }
}

/// One per window. A single tracking area on the content view reports the pointer; the TipSource
/// under it names the tip. Cold, a tip waits 0.5 s; while warm (one is showing, or one just hid)
/// the next shows at once. A click, scroll or key hides it, and the clicked control stays quiet
/// until the pointer moves to another one. No timer runs unless the pointer rests on a control.
final class Tooltips: NSResponder {
    /// The live shortcut for an action id, set by the main window from its action registry.
    static var shortcut: (String) -> String? = { _ in nil }
    static let delay: TimeInterval = 0.5
    static let warmFor: TimeInterval = 0.5

    private struct Target: Equatable { var tip: Tip; var rect: NSRect; var beside = false }   // rect in window coordinates
    private enum State { case idle, waiting(Target, Timer), shown(Target) }

    private weak var window: NSWindow?
    private let view = TipView()
    private var state = State.idle { didSet { updateMonitor() } }
    private var warmUntil = Date.distantPast
    private var quiet: NSRect?
    private var pointer = NSPoint.zero
    private var monitor: Any?

    /// Watches the window's current content view.
    init(window: NSWindow) {
        self.window = window
        super.init()
        window.contentView?.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Set by the `--tooltip` test hook, so the real pointer cannot move the tip it placed.
    var frozen = false

    override func mouseMoved(with e: NSEvent) { if !frozen { hover(at: e.locationInWindow) } }
    override func mouseEntered(with e: NSEvent) { if !frozen { hover(at: e.locationInWindow) } }
    override func mouseExited(with e: NSEvent) { if !frozen { leave() } }

    /// The pointer is at `p` (window coordinates). Also what `--tooltip x,y` calls.
    @discardableResult
    func hover(at p: NSPoint, immediately: Bool = false) -> Bool {
        pointer = p
        guard let target = target(at: p) else { leave(); return false }
        if let q = quiet { if q == target.rect { return true } else { quiet = nil } }
        switch state {
        case .shown(let t) where t == target: return true
        case .waiting(let t, _) where t == target: return true
        case .waiting(_, let timer): timer.invalidate()
        default: break
        }
        if case .shown = state { show(target, fade: false) }
        else if immediately || Date() < warmUntil { show(target, fade: false) }
        else {
            let timer = Timer(timeInterval: Self.delay, repeats: false) { [weak self] _ in self?.show(target, fade: true) }
            RunLoop.main.add(timer, forMode: .common)
            state = .waiting(target, timer)
        }
        return true
    }

    func hide() {
        if case .waiting(_, let timer) = state { timer.invalidate() }
        view.removeFromSuperview()
        state = .idle
    }

    private func leave() {
        if case .shown = state { warmUntil = Date().addingTimeInterval(Self.warmFor) }
        quiet = nil
        hide()
    }

    private func target(at p: NSPoint) -> Target? {
        guard let content = window?.contentView, let frame = content.superview,
              var v = content.hitTest(frame.convert(p, from: nil)) else { return nil }
        while true {
            if let s = v as? TipSource, let r = s.tip(at: v.convert(p, from: nil)) {
                return Target(tip: r.tip, rect: v.convert(r.rect, to: nil), beside: s.tipsBeside)
            }
            guard let up = v.superview, v !== content else { return nil }
            v = up
        }
    }

    private func show(_ target: Target, fade: Bool) {
        guard let content = window?.contentView else { return }
        state = .shown(target)
        view.tip = target.tip
        let size = view.fittingSize
        let anchor = content.convert(target.rect, from: nil)
        let margin: CGFloat = 6, gap: CGFloat = 4
        if target.beside {
            let y = anchor.midY - size.height / 2
            let x = anchor.maxX + gap + 2 + size.width <= content.bounds.width - margin ? anchor.maxX + gap + 2 : anchor.minX - gap - 2 - size.width
            return place(NSRect(x: x, y: min(max(margin, y), content.bounds.height - size.height - margin), width: size.width, height: size.height), in: content, fade: fade)
        }
        // Under the control, centred on it; on a wide control (a usage row) under the pointer instead.
        let cx = anchor.width > 120 ? min(max(content.convert(pointer, from: nil).x, anchor.minX), anchor.maxX) : anchor.midX
        let x = min(max(margin, cx - size.width / 2), content.bounds.width - size.width - margin)
        var y = content.isFlipped ? anchor.maxY + gap : anchor.minY - gap - size.height
        let fits = content.isFlipped ? y + size.height <= content.bounds.height - margin : y >= margin
        if !fits { y = content.isFlipped ? anchor.minY - gap - size.height : anchor.maxY + gap }
        place(NSRect(x: x, y: y, width: size.width, height: size.height), in: content, fade: fade)
    }

    private func place(_ f: NSRect, in content: NSView, fade: Bool) {
        view.frame = NSRect(x: round(f.minX), y: round(f.minY), width: f.width, height: f.height)
        content.addSubview(view, positioned: .above, relativeTo: nil)
        view.layer?.removeAllAnimations()
        if fade, !Motion.reduced {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 0; a.toValue = 1; a.duration = 0.1
            view.layer?.add(a, forKey: "fade")
        }
    }

    /// Listens for clicks, scrolls and keys only while a tip is pending or showing.
    private func updateMonitor() {
        let active: Bool
        if case .idle = state { active = false } else { active = true }
        if active, monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]) { [weak self] e in
                self?.interrupted(by: e)
                return e
            }
        } else if !active, let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }

    private func interrupted(by e: NSEvent) {
        let current: Target?
        switch state {
        case .idle: current = nil
        case .waiting(let t, _), .shown(let t): current = t
        }
        warmUntil = .distantPast
        hide()
        if e.type != .scrollWheel { quiet = current?.rect }
    }
}

/// The tip itself: a small panel in theme tokens, the text, then the shortcut in a dim key.
final class TipView: MXView {
    var tip = Tip("") { didSet { needsDisplay = true } }
    private let pad: CGFloat = 8
    private var font: NSFont { Fonts.mono(Metrics.fontSize - 1) }
    private var keyFont: NSFont { Fonts.mono(Metrics.fontSize - 2) }
    private var lines: [String] { tip.text.components(separatedBy: "\n") }
    private var shortcut: String? { tip.action.flatMap(Tooltips.shortcut) }
    private var lineH: CGFloat { ceil(font.ascender - font.descender) + 3 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize {
        let textW = lines.map { Text.width($0, font: font) }.max() ?? 0
        let keyW = shortcut.map { Text.width($0, font: keyFont) + 8 + 10 } ?? 0
        let w = min(520, textW + keyW + pad * 2)
        return NSSize(width: ceil(w), height: CGFloat(lines.count) * lineH + 8)
    }

    override func hitTest(_ p: NSPoint) -> NSView? { nil }

    override func draw(_ r: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        t.panel.setFill(); box.fill()
        t.hair.setStroke(); box.lineWidth = 1; box.stroke()
        let keyW = shortcut.map { Text.width($0, font: keyFont) + 8 } ?? 0
        for (i, line) in lines.enumerated() {
            let y = 4 + CGFloat(i) * lineH
            let room = bounds.width - pad * 2 - (keyW > 0 && i == 0 ? keyW + 10 : 0)
            Text.draw(line, in: NSRect(x: pad, y: y, width: room, height: lineH), color: i == 0 ? t.fg : t.fg2, font: font)
        }
        guard let s = shortcut else { return }
        let key = NSRect(x: bounds.width - pad - keyW, y: 4 + (lineH - 15) / 2, width: keyW, height: 15)
        let cap = NSBezierPath(roundedRect: key.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        t.hair2.setFill(); cap.fill()
        t.hair.setStroke(); cap.lineWidth = 1; cap.stroke()
        Text.draw(s, in: key, color: t.fg2, font: keyFont, align: .center)
    }
}

extension PhaseGroup {
    /// What the state means, in one plain line.
    var meaning: String {
        switch self {
        case .needsYou: return "Claude is waiting for your answer or permission"
        case .yourTurn: return "Claude says it is done. Not checked yet"
        case .working: return "Claude is busy"
        case .limited: return "This account reached its usage limit"
        case .safeToClose: return "Every check passed. Nothing is left to do"
        case .idle: return "No activity for a long while"
        case .recentlyClosed: return "Stopped by Maxwell. You can reopen it"
        }
    }
    /// The state glyph's tooltip: the state's name, then what it means.
    var tip: Tip { Tip(title).adding(meaning) }
}

extension PhaseGroup {
    /// "1 session needs you", "3 sessions working".
    func count(_ n: Int) -> String {
        let s = n == 1 ? "1 session" : "\(n) sessions"
        switch self {
        case .needsYou: return n == 1 ? "1 session needs you" : "\(n) sessions need you"
        case .yourTurn: return "Your turn in \(s)"
        case .working: return "\(s) working"
        case .limited: return "\(s) at a usage limit"
        case .safeToClose: return "\(s) safe to close"
        case .idle: return "\(s) idle"
        case .recentlyClosed: return "\(s) closed recently"
        }
    }
}

extension Format {
    /// "today at 14:30", "tomorrow at 09:00", "on Thursday at 16:00".
    static func when(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDate(d, inSameDayAs: now) { return "today at \(clock.string(from: d))" }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(d, inSameDayAs: tomorrow) { return "tomorrow at \(clock.string(from: d))" }
        return "on \(weekday.string(from: d)) at \(clock.string(from: d))"
    }
    /// "just now", "7 minutes ago", "3 hours ago", "2 days ago".
    static func ago(_ d: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(d)))
        func n(_ v: Int, _ unit: String) -> String { "\(v) \(unit)\(v == 1 ? "" : "s") ago" }
        if s < 60 { return "just now" }
        if s < 3600 { return n(s / 60, "minute") }
        if s < 86400 { return n(s / 3600, "hour") }
        return n(s / 86400, "day")
    }
    static let weekday: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEEE"; return f }()
}
