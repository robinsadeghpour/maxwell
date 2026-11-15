import AppKit

/// One session row as the list draws it.
struct Row: Equatable {
    var session: Session
    var group: PhaseGroup
    var detail: String     // second line (or right tag): project · branch · account
    var checks: [Check] = []   // Safe to close rows: the evidence, shown when expanded
    var closedAt: Date?        // Recently closed rows
    var suggestion: String?    // "→ Acme?": the project its transcript points at
    var badges: [RowBadge] = []   // from plugins, e.g. "ACME-56 · In Review"
}

/// A plain terminal Maxwell runs, listed above the sessions.
struct ShellRow: Equatable {
    var id: String
    var title: String      // the folder it is in now
    var detail: String     // that folder's path
}

/// A plugin's badge on a session row; a click runs its action for that session.
struct RowBadge: Equatable {
    var plugin: PluginID
    var badge: PluginNote.Badge
    var actionTitle: String?
}

extension NSPasteboard.PasteboardType {
    /// A session row dragged onto a rail key; the payload is the session id.
    static let maxwellSession = NSPasteboard.PasteboardType("dev.maxwell.session")
}

/// Sessions grouped by state. Click to open; when focused, J/K or arrows move the cursor and
/// Return opens. A row that changes group flashes its state colour for a moment. A Safe to
/// close row expands (click, or →) to its checklist and a "Not safe" action; a Recently
/// closed row reopens on click.
final class SessionList: MXView, NSDraggingSource, TipSource {
    enum Item { case shells(Int), shell(ShellRow), group(PhaseGroup, Int), session(Row), check(Check), notSafe(SessionID) }
    private(set) var items: [Item] = []
    var current: SessionID? { didSet { if current != oldValue, current != nil { cursor = current }; needsDisplay = true } }
    var compact = false { didSet { relayout(); needsDisplay = true } }
    var emptyText = ["Nothing here."]
    private var cursor: SessionID?
    private var hoverIndex: Int?
    var onOpen: ((SessionID) -> Void)?
    /// Plain terminals, drawn first under their own header; × on a row ends it.
    var shells: [ShellRow] = [] { didSet { if shells != oldValue { rebuildItems() } } }
    var onCloseShell: ((String) -> Void)?
    var onNewShell: (() -> Void)?
    var onCloseAllSafe: (() -> Void)?
    /// Stops the idle sessions Maxwell can stop (background ones); Undo reopens them.
    var onStopIdle: (([SessionID]) -> Void)?
    var onReopen: ((SessionID) -> Void)?
    var onNotSafe: ((SessionID) -> Void)?
    /// Right-click on a session row.
    var menuFor: ((Session) -> NSMenu?)?
    /// The suggestion chip: true moves the session there, false dismisses it.
    var onSuggestion: ((SessionID, String, Bool) -> Void)?
    /// A plugin badge was clicked.
    var onBadge: ((SessionID, RowBadge) -> Void)?
    /// A row drag started (true) or ended (false), so the rail can show itself as a target.
    var onDragSession: ((Bool) -> Void)?
    private var downAt: (point: NSPoint, row: Row)?
    private(set) var expanded = Set<SessionID>()
    private let closeAll = MXButton("close all", hint: "⇧⌘X", small: true)
    private let stopIdle = MXButton("stop all", small: true)
    private let newShell = MXButton("new", hint: "⌥⌘T", small: true)
    private var spinAngle: CGFloat = 0
    private var timer: Timer?
    private var lastGroup: [SessionID: PhaseGroup] = [:]
    private var pulses: [SessionID: Date] = [:]
    private static let pulseLength: TimeInterval = 1.6

    override init(frame: NSRect) {
        super.init(frame: frame)
        closeAll.action = { [weak self] in self?.onCloseAllSafe?() }
        closeAll.isHidden = true
        closeAll.tip = Tip("Close every session that is safe to close")
        addSubview(closeAll)
        stopIdle.action = { [weak self] in guard let self else { return }; self.onStopIdle?(self.stoppableIdle) }
        stopIdle.isHidden = true
        addSubview(stopIdle)
        newShell.action = { [weak self] in self?.onNewShell?() }
        newShell.isHidden = true
        newShell.tip = Tip("Open another terminal")
        addSubview(newShell)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Idle and Recently closed start folded; clicking the header (or ⇧⌘I for Idle) toggles them.
    private var unfolded = Set<PhaseGroup>()
    var idleExpanded: Bool { unfolded.contains(.idle) }
    var idleNote = "quiet 24h+"
    private var groups: [(PhaseGroup, [Row])] = []

    func update(_ groups: [(PhaseGroup, [Row])]) {
        let now = Date()
        for (g, rows) in groups {
            for r in rows {
                if let old = lastGroup[r.session.id], old != g { pulses[r.session.id] = now }
                lastGroup[r.session.id] = g
            }
        }
        self.groups = groups
        rebuildItems()
    }

    private func rebuildItems() {
        let before = Dictionary(zip(items.map(Self.key), rowRects().map(\.minY)), uniquingKeysWith: { a, _ in a })
        let oldKeys = items.map(Self.key)
        let safeIds = Set(groups.first { $0.0 == .safeToClose }?.1.map(\.session.id) ?? [])
        expanded.formIntersection(safeIds)
        let shellItems: [Item] = shells.isEmpty ? [] : [.shells(shells.count)] + shells.map(Item.shell)
        items = shellItems + groups.flatMap { g, rows -> [Item] in
            guard !g.folds || unfolded.contains(g) else { return [.group(g, rows.count)] }
            return [.group(g, rows.count)] + rows.flatMap { r -> [Item] in
                guard expanded.contains(r.session.id) else { return [.session(r)] }
                return [.session(r)] + r.checks.map(Item.check) + [.notSafe(r.session.id)]
            }
        }
        // Rows that move slide to their new place; new rows fade in. Nothing jumps.
        if items.map(Self.key) != oldKeys, !oldKeys.isEmpty, window != nil, !Motion.reduced {
            slide.set(0, animated: false)
            slideFrom = before
            slide.set(1)
        }
        if let c = cursor, !rowIds.contains(c) { cursor = nil }
        relayout()
        updateTimer()
        needsDisplay = true
    }

    func relayout() {
        let h = height
        if frame.height != h { setFrameSize(NSSize(width: frame.width, height: h)) }
        layoutCloseAll()
    }

    var sessionIds: [SessionID] { items.compactMap { if case .session(let r) = $0 { return r.session.id }; return nil } }
    /// Every row J/K and ⌘[ ⌘] step through: terminals, then sessions.
    var rowIds: [String] {
        items.compactMap {
            switch $0 {
            case .shell(let r): return r.id
            case .session(let r): return r.session.id
            default: return nil
            }
        }
    }

    private var rowHeight: CGFloat { compact ? Metrics.row : Metrics.row2 }
    private static let groupHeight: CGFloat = 26
    private static let checkHeight: CGFloat = 30
    private static let notSafeHeight: CGFloat = 28

    private static func key(_ it: Item) -> String {
        switch it {
        case .shells: return "gshells"
        case .shell(let r): return r.id
        case .group(let g, _): return "g\(g.rawValue)"
        case .session(let r): return r.session.id
        case .check(let c): return "c\(c.kind.rawValue)\(c.title)\(c.detail)"
        case .notSafe(let id): return "n" + id
        }
    }
    private var slideFrom: [String: CGFloat] = [:]
    private lazy var slide: Tween = {
        let t = Tween(1)
        // The group buttons ride along with their header, or a launch-time slide leaves them mid-way.
        t.step = { [weak self] _ in self?.needsDisplay = true; self?.layoutCloseAll() }
        t.done = { [weak self] in self?.slideFrom = [:]; self?.needsDisplay = true; self?.layoutCloseAll() }
        return t
    }()

    /// Row frames where they settle, or part-way there while rows slide.
    private func rowRects(settled: Bool = false) -> [NSRect] {
        var y: CGFloat = 4, out: [NSRect] = []
        let p = slide.value
        for (i, it) in items.enumerated() {
            let h: CGFloat
            switch it {
            case .group, .shells: y += i == 0 ? 0 : 8; h = Self.groupHeight
            case .session, .shell: h = rowHeight
            case .check: h = Self.checkHeight
            case .notSafe: h = Self.notSafeHeight
            }
            var shown = y
            if !settled, p < 1, let from = slideFrom[Self.key(it)] { shown = from + (y - from) * p }
            out.append(NSRect(x: 0, y: shown, width: bounds.width, height: h))
            y += h
        }
        return out
    }

    /// 0 … 1 for a row that just appeared, 1 for every other.
    private func fade(_ it: Item) -> CGFloat {
        slide.value < 1 && !slideFrom.isEmpty && slideFrom[Self.key(it)] == nil ? slide.value * slide.value : 1
    }

    private var height: CGFloat { max((rowRects(settled: true).last?.maxY ?? 0) + 10, superview?.bounds.height ?? 0) }

    /// Idle sessions running in the background. One in a terminal is that terminal's to end.
    private var stoppableIdle: [SessionID] {
        (groups.first { $0.0 == .idle }?.1 ?? []).compactMap { r in
            if case .background = r.session.reach { return r.session.id }
            return nil
        }
    }

    private func layoutCloseAll() {
        let rects = rowRects()
        func place(_ b: MXButton, on g: PhaseGroup, when ok: Bool = true) {
            guard ok, let i = items.firstIndex(where: { if case .group(g, _) = $0 { return true }; return false }) else { b.isHidden = true; return }
            let size = b.intrinsicContentSize
            b.frame = NSRect(x: bounds.width - size.width - 10, y: rects[i].midY - size.height / 2, width: size.width, height: size.height)
            b.isHidden = false
        }
        place(closeAll, on: .safeToClose)
        if let i = items.firstIndex(where: { if case .shells = $0 { return true }; return false }) {
            let size = newShell.intrinsicContentSize
            newShell.frame = NSRect(x: bounds.width - size.width - 10, y: rects[i].midY - size.height / 2, width: size.width, height: size.height)
            newShell.isHidden = false
        } else {
            newShell.isHidden = true
        }
        let n = stoppableIdle.count
        let idleCount = groups.first { $0.0 == .idle }?.1.count ?? 0
        stopIdle.title = n == idleCount ? "stop all" : "stop \(n)"
        stopIdle.tip = Tip(n == idleCount
            ? "Stop every idle session. Conversations are kept; Undo or Recently closed reopens them."
            : "Stop the \(n) idle sessions running in the background. The other \(idleCount - n) run in a terminal; end those there.")
        place(stopIdle, on: .idle, when: n > 0)
    }

    override func resizeSubviews(withOldSize s: NSSize) { super.resizeSubviews(withOldSize: s); layoutCloseAll() }

    /// Spinners and pulses animate; nothing ticks when neither is on screen.
    private func updateTimer() {
        let now = Date()
        pulses = pulses.filter { now.timeIntervalSince($0.value) < Self.pulseLength }
        let working = items.contains { if case .session(let r) = $0 { return r.group == .working }; return false }
        if (working || !pulses.isEmpty), timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in self?.tick() }
        } else if !working && pulses.isEmpty {
            timer?.invalidate(); timer = nil
        }
    }

    private var frameCount = 0
    private func tick() {
        guard window?.isVisible == true else { return }
        frameCount += 1
        let spin = frameCount % 3 == 0
        if spin { spinAngle -= 36 }
        for (i, r) in rowRects().enumerated() {
            guard case .session(let row) = items[i] else { continue }
            if pulses[row.session.id] != nil { setNeedsDisplay(r) } else if spin && row.group == .working { setNeedsDisplay(NSRect(x: 0, y: r.minY, width: 30, height: r.height)) }
        }
        if pulses.contains(where: { Date().timeIntervalSince($0.value) >= Self.pulseLength }) { updateTimer() }
    }

    override func draw(_ dirty: NSRect) {
        let rects = rowRects()
        let focused = window?.firstResponder === self
        let now = Date()
        for (i, it) in items.enumerated() {
            let r = rects[i]
            guard r.intersects(dirty) else { continue }
            let a = fade(it)
            if a < 1 { NSGraphicsContext.current?.cgContext.saveGState(); NSGraphicsContext.current?.cgContext.setAlpha(a) }
            switch it {
            case .shells(let n):
                drawHeader("Terminals", n, color: t.fg2, in: r)
            case .shell(let row):
                drawShell(row, in: r, hovered: hoverIndex == i, cursor: focused && row.id == cursor)
            case .group(let g, let n):
                drawGroup(g, n, in: r, hovered: hoverIndex == i)
            case .session(let row):
                drawRow(row, in: r, hovered: hoverIndex == i, cursor: focused && row.session.id == cursor, now: now)
            case .check(let c):
                CheckLine.draw(c, in: NSRect(x: r.minX + 34, y: r.minY + 1, width: r.width - 44, height: r.height - 2), theme: t, stacked: true)
            case .notSafe:
                let label = "Not safe · keep it open"
                let w = Text.width(label, font: Fonts.mono(Metrics.fontSize - 1)) + 16
                let b = NSRect(x: r.minX + 34, y: r.minY + 4, width: w, height: r.height - 8)
                (hoverIndex == i ? t.hover : t.hair2).setFill()
                NSBezierPath(roundedRect: b, xRadius: 4, yRadius: 4).fill()
                Text.draw(label, in: b, color: t.on, font: Fonts.mono(Metrics.fontSize - 1), align: .center)
            }
            if a < 1 { NSGraphicsContext.current?.cgContext.restoreGState() }
        }
        if items.isEmpty {
            var y: CGFloat = 14
            for (i, l) in emptyText.enumerated() {
                Text.draw(l, in: NSRect(x: 14, y: y, width: bounds.width - 28, height: 18), color: i == 0 ? t.fg2 : t.fg3)
                y += 18
            }
        }
    }

    private func drawGroup(_ g: PhaseGroup, _ n: Int, in r: NSRect, hovered: Bool) {
        let color: NSColor
        switch g {
        case .needsYou: color = t.on
        case .yourTurn: color = t.chk
        case .safeToClose: color = t.safe
        default: color = t.fg3
        }
        var x: CGFloat = 14
        if g.folds {
            if hovered { t.hover.setFill(); NSBezierPath(roundedRect: r.insetBy(dx: 6, dy: 2), xRadius: 4, yRadius: 4).fill() }
            x += Text.draw(unfolded.contains(g) ? "▾" : "▸", in: NSRect(x: x, y: r.minY, width: 12, height: r.height), color: t.fg3) + 5
        }
        let font = Fonts.mono(Metrics.fontSize - 1, .semibold)
        let w = Text.draw(g.title, in: NSRect(x: x, y: r.minY, width: 160, height: r.height), color: color, font: font)
        Text.draw("\(n)", in: NSRect(x: x + w + 7, y: r.minY, width: 40, height: r.height), color: t.fg3, font: Fonts.mono(Metrics.fontSize - 1))
        if g == .recentlyClosed {
            Text.draw("click reopens", in: NSRect(x: bounds.width - 120, y: r.minY, width: 106, height: r.height), color: t.fg3.withAlphaComponent(0.8), font: Fonts.mono(Metrics.fontSize - 2.5), align: .right)
        }
        if g == .idle {
            let right = stopIdle.isHidden ? bounds.width - 14 : stopIdle.frame.minX - 8
            Text.draw(idleNote, in: NSRect(x: right - 106, y: r.minY, width: 106, height: r.height), color: t.fg3.withAlphaComponent(0.8), font: Fonts.mono(Metrics.fontSize - 2.5), align: .right)
        }
    }

    private func drawHeader(_ title: String, _ n: Int, color: NSColor, in r: NSRect) {
        let font = Fonts.mono(Metrics.fontSize - 1, .semibold)
        let w = Text.draw(title, in: NSRect(x: 14, y: r.minY, width: 160, height: r.height), color: color, font: font)
        Text.draw("\(n)", in: NSRect(x: 14 + w + 7, y: r.minY, width: 40, height: r.height), color: t.fg3, font: Fonts.mono(Metrics.fontSize - 1))
    }

    /// A terminal row: a prompt mark where sessions have their state glyph, the folder, its path,
    /// and × to end it while the pointer is on the row.
    private func drawShell(_ row: ShellRow, in r: NSRect, hovered: Bool, cursor: Bool) {
        let box = r.insetBy(dx: 6, dy: compact ? 1 : 1.5)
        let path = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
        let isCurrent = row.id == current
        if isCurrent {
            t.rowSel.setFill(); path.fill()
            t.fg3.setFill()
            NSBezierPath(roundedRect: NSRect(x: box.minX, y: box.minY + 5, width: 2.5, height: box.height - 10), xRadius: 1.25, yRadius: 1.25).fill()
        } else if hovered || cursor {
            t.hover.setFill(); path.fill()
        }
        if cursor {
            t.hair.setStroke(); let p = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5); p.lineWidth = 1; p.stroke()
        }
        let small = Fonts.mono(Metrics.fontSize - 2)
        let line1 = compact ? r : NSRect(x: r.minX, y: r.minY + 3, width: r.width, height: 18)
        Text.draw("❯", in: NSRect(x: box.minX + 8, y: line1.minY, width: 12, height: line1.height), color: isCurrent ? t.fg : t.fg2,
                  font: Fonts.mono(Metrics.fontSize - 1, .semibold), align: .center)
        let titleX = box.minX + 28
        let close = shellCloseRect(in: r)
        let right = (hovered || isCurrent ? close.minX : box.maxX - 10) - 6
        if hovered || isCurrent {
            Text.draw("×", in: close, color: closeHover == row.id ? t.fg : t.fg3, font: Fonts.mono(Metrics.fontSize), align: .center)
        }
        if compact {
            Text.draw(row.title, in: NSRect(x: titleX, y: r.minY, width: right - titleX, height: r.height), color: t.fg)
        } else {
            Text.draw(row.title, in: NSRect(x: titleX, y: line1.minY, width: right - titleX, height: line1.height), color: t.fg)
            Text.draw(row.detail, in: NSRect(x: titleX, y: line1.maxY - 1, width: right - titleX, height: 15), color: t.fg3, font: small)
        }
    }

    private func shellCloseRect(in r: NSRect) -> NSRect {
        let box = r.insetBy(dx: 6, dy: 0)
        return NSRect(x: box.maxX - 26, y: r.midY - 10, width: 20, height: 20)
    }
    private var closeHover: String?

    private func drawRow(_ row: Row, in r: NSRect, hovered: Bool, cursor: Bool, now: Date) {
        let s = row.session, g = row.group
        let box = r.insetBy(dx: 6, dy: compact ? 1 : 1.5)
        let path = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
        let isCurrent = s.id == current
        if let start = pulses[s.id] {
            let p = CGFloat(max(0, 1 - now.timeIntervalSince(start) / Self.pulseLength))
            t.color(for: g).withAlphaComponent(0.22 * p * p).setFill(); path.fill()
        }
        if isCurrent {
            t.rowSel.setFill(); path.fill()
            ([.needsYou, .yourTurn, .safeToClose].contains(g) ? t.color(for: g) : t.fg3).setFill()
            NSBezierPath(roundedRect: NSRect(x: box.minX, y: box.minY + 5, width: 2.5, height: box.height - 10), xRadius: 1.25, yRadius: 1.25).fill()
        } else if hovered || cursor {
            t.hover.setFill(); path.fill()
        }
        if cursor {
            t.hair.setStroke(); let p = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5); p.lineWidth = 1; p.stroke()
        }
        let quiet = g == .working || g == .limited || g.folds
        let fg = quiet && !isCurrent ? t.fg2 : t.fg
        let small = Fonts.mono(Metrics.fontSize - 2)
        let line1 = compact ? r : NSRect(x: r.minX, y: r.minY + 3, width: r.width, height: 18)
        Glyph.draw(g, at: NSPoint(x: box.minX + 14, y: line1.midY), color: t.color(for: g), angle: spinAngle)
        let right = box.maxX - 10
        let age = rowDetail(s, now: now, closedAt: row.closedAt)
        let ageW = max(24, Text.width(age, font: small))
        Text.draw(age, in: NSRect(x: right - ageW, y: line1.minY, width: ageW, height: line1.height), color: t.fg3, font: small, align: .right)
        let titleX = box.minX + 28
        let chip = chipRects(row, in: r)
        if let c = chip {
            let path = NSBezierPath(roundedRect: c.chip, xRadius: 3, yRadius: 3)
            (chipHover == .chip(s.id) ? t.hover : t.hair2).setFill(); path.fill()
            t.hair.setStroke(); path.lineWidth = 1; path.stroke()
            Text.draw(Self.chipText(row.suggestion!), in: c.chip, color: chipHover == .chip(s.id) ? t.fg : t.fg2, font: small, align: .center)
            Text.draw("×", in: c.close, color: chipHover == .close(s.id) ? t.fg : t.fg3, font: small, align: .center)
        }
        let badges = badgeRects(row, in: r)
        for (rect, b) in badges { drawBadge(b, in: rect, hot: badgeHover == BadgeHover(session: s.id, badge: b)) }
        let badgeLeft = badges.map(\.0.minX).min()
        let right1 = compact ? (badgeLeft ?? chip?.chip.minX ?? right - ageW) - 8 : right - ageW - 8
        if compact {
            let tagW = min(110, Text.width(row.detail, font: small))
            Text.draw(row.detail, in: NSRect(x: right1 - tagW, y: r.minY, width: tagW, height: r.height), color: t.fg3, font: small)
            Text.draw(s.title, in: NSRect(x: titleX, y: r.minY, width: right1 - 8 - tagW - titleX, height: r.height), color: fg)
        } else {
            Text.draw(s.title, in: NSRect(x: titleX, y: line1.minY, width: right1 - titleX, height: line1.height), color: fg)
            Text.draw(row.detail, in: NSRect(x: titleX, y: line1.maxY - 1, width: (badgeLeft ?? chip?.chip.minX ?? right) - 6 - titleX, height: 15), color: t.fg3, font: small)
        }
    }

    private struct BadgeHover: Equatable { var session: SessionID; var badge: RowBadge }
    private var badgeHover: BadgeHover?

    /// Plugin badges, right-aligned on the detail line, left of the suggestion chip (compact: left of
    /// the age, one badge). A badge never takes more than half the row.
    private func badgeRects(_ row: Row, in r: NSRect) -> [(NSRect, RowBadge)] {
        guard !row.badges.isEmpty, row.group != .recentlyClosed else { return [] }
        let small = Fonts.mono(Metrics.fontSize - 2)
        let box = r.insetBy(dx: 6, dy: compact ? 1 : 1.5)
        var right: CGFloat, midY: CGFloat
        if let c = chipRects(row, in: r) { right = c.chip.minX - 4 } else { right = box.maxX - 10 }
        if compact {
            if chipRects(row, in: r) == nil { right -= max(24, Text.width(rowDetail(row.session, now: Date(), closedAt: row.closedAt), font: small)) + 6 }
            midY = r.midY
        } else { midY = r.minY + 27.5 }
        var out: [(NSRect, RowBadge)] = []
        let maxW = (box.width - 28) * 0.62
        for b in row.badges.prefix(compact ? 1 : 2) {
            let w = min(maxW, Text.width(b.badge.text, font: small) + 19)
            let rect = NSRect(x: right - w, y: midY - 7.5, width: w, height: 15)
            if rect.minX < box.minX + 28 { break }
            out.append((rect, b))
            right = rect.minX - 4
        }
        return out
    }

    private func drawBadge(_ b: RowBadge, in rect: NSRect, hot: Bool) {
        let small = Fonts.mono(Metrics.fontSize - 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        (hot ? t.hover : t.hair2).setFill(); path.fill()
        t.hair.setStroke(); path.lineWidth = 1; path.stroke()
        t.color(for: b.badge.tone).setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.minX + 6, y: rect.midY - 2.5, width: 5, height: 5), xRadius: 1, yRadius: 1).fill()
        Text.draw(b.badge.text, in: NSRect(x: rect.minX + 15, y: rect.minY, width: rect.width - 19, height: rect.height), color: hot ? t.fg : t.fg2, font: small)
    }

    private func badge(at p: NSPoint) -> (RowBadge, Row, NSRect)? {
        guard let i = index(at: p), case .session(let row) = items[i] else { return nil }
        return badgeRects(row, in: rowRects()[i]).first { $0.0.insetBy(dx: -1, dy: -2).contains(p) }.map { ($0.1, row, $0.0) }
    }

    private static func chipText(_ project: String) -> String { "→ \(project)?" }

    /// The suggestion chip at the right end of the second line (of the only line when compact,
    /// left of the age), and its × to dismiss.
    private func chipRects(_ row: Row, in r: NSRect) -> (chip: NSRect, close: NSRect)? {
        guard let p = row.suggestion else { return nil }
        let small = Fonts.mono(Metrics.fontSize - 2)
        let box = r.insetBy(dx: 6, dy: compact ? 1 : 1.5)
        let w = Text.width(Self.chipText(p), font: small) + 12
        var right = box.maxX - 10, midY = r.minY + 27.5   // the detail line drawRow draws
        if compact {
            right -= max(24, Text.width(rowDetail(row.session, now: Date(), closedAt: row.closedAt), font: small)) + 6
            midY = r.midY
        }
        let close = NSRect(x: right - 12, y: midY - 7.5, width: 12, height: 15)
        return (NSRect(x: close.minX - 2 - w, y: midY - 7.5, width: w, height: 15), close)
    }

    private enum ChipPart: Equatable { case chip(SessionID), close(SessionID) }
    private var chipHover: ChipPart?

    private func chipPart(at p: NSPoint) -> (ChipPart, Row)? {
        guard let i = index(at: p), case .session(let row) = items[i], let c = chipRects(row, in: rowRects()[i]) else { return nil }
        if c.chip.insetBy(dx: -2, dy: -2).contains(p) { return (.chip(row.session.id), row) }
        if c.close.insetBy(dx: -2, dy: -2).contains(p) { return (.close(row.session.id), row) }
        return nil
    }

    /// A row's state glyph, its suggestion chip, and its age column.
    func tip(at p: NSPoint) -> (tip: Tip, rect: NSRect)? {
        guard let i = index(at: p), case .session(let row) = items[i] else { return nil }
        if let (b, _, rect) = badge(at: p) {
            var tip = Tip(b.badge.tooltip ?? b.badge.text)
            if let a = b.actionTitle { tip = tip.adding("Click: \(a)") }
            return (tip, rect)
        }
        if let (part, _) = chipPart(at: p), let c = chipRects(row, in: rowRects()[i]) {
            if case .chip = part { return (Tip("Move this session to \(row.suggestion ?? "")").adding("Its folder suggests it belongs there"), c.chip) }
            return (Tip("Keep it where it is"), c.close)
        }
        let r = rowRects()[i], box = r.insetBy(dx: 6, dy: 0)
        let line1 = compact ? r : NSRect(x: r.minX, y: r.minY + 3, width: r.width, height: 18)
        if p.x < box.minX + 26 { return (row.group.tip, NSRect(x: box.minX + 4, y: line1.minY, width: 20, height: line1.height)) }
        let now = Date(), small = Fonts.mono(Metrics.fontSize - 2)
        let ageW = max(24, Text.width(rowDetail(row.session, now: now, closedAt: row.closedAt), font: small))
        let age = NSRect(x: box.maxX - 10 - ageW, y: line1.minY, width: ageW, height: line1.height)
        guard age.insetBy(dx: -2, dy: 0).contains(p) else { return nil }
        let text: String
        if let closedAt = row.closedAt { text = "Closed \(Format.ago(closedAt, now: now))" }
        else if case .limited(let d?) = row.session.phase { text = d > now ? "The limit resets \(Format.when(d, now: now))" : "The limit has reset" }
        else { text = "Last activity \(Format.ago(row.session.lastEventAt, now: now))" }
        return (Tip(text), age)
    }

    /// Right column: age, or when a limit resets, or when Maxwell closed it.
    private func rowDetail(_ s: Session, now: Date, closedAt: Date? = nil) -> String {
        if let closedAt { return "closed " + Format.age(closedAt, now: now) }
        if case .limited(let d?) = s.phase { return d > now ? "↻" + Format.clock.string(from: d) : "ready" }
        return Format.age(s.lastEventAt, now: now)
    }

    // MARK: mouse

    private func index(at p: NSPoint) -> Int? { rowRects().firstIndex { $0.contains(p) } }

    override func mouseMoved(with e: NSEvent) {
        let part = chipPart(at: convert(e.locationInWindow, from: nil))?.0
        if part != chipHover { chipHover = part; needsDisplay = true }
        let bh = badge(at: convert(e.locationInWindow, from: nil)).flatMap { b, row, _ in b.badge.action == nil ? nil : BadgeHover(session: row.session.id, badge: b) }
        if bh != badgeHover { badgeHover = bh; needsDisplay = true }
        let i = index(at: convert(e.locationInWindow, from: nil))
        let p = convert(e.locationInWindow, from: nil)
        let ch: String? = i.flatMap { i in
            if case .shell(let r) = items[i], shellCloseRect(in: rowRects()[i]).contains(p) { return r.id }
            return nil
        }
        if ch != closeHover { closeHover = ch; needsDisplay = true }
        let h = i.flatMap { i -> Int? in
            switch items[i] {
            case .session, .notSafe, .shell: return i
            case .group(let g, _) where g.folds: return i
            default: return nil
            }
        }
        if h != hoverIndex { hoverIndex = h; needsDisplay = true }
    }
    override func mouseExited(with e: NSEvent) { hoverIndex = nil; chipHover = nil; badgeHover = nil; closeHover = nil; needsDisplay = true }
    func toggleIdle() { toggle(.idle) }

    func toggle(_ g: PhaseGroup) {
        if !unfolded.insert(g).inserted { unfolded.remove(g) }
        rebuildItems()
    }

    /// Shows or hides a Safe to close row's checklist.
    func setExpanded(_ id: SessionID, _ on: Bool) {
        guard on != expanded.contains(id) else { return }
        if on { expanded.insert(id) } else { expanded.remove(id) }
        rebuildItems()
    }

    private func row(_ id: SessionID?) -> Row? {
        items.lazy.compactMap { if case .session(let r) = $0, r.session.id == id { return r }; return nil }.first
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        downAt = nil
        if let (b, row, _) = badge(at: p), b.badge.action != nil { onBadge?(row.session.id, b); return }
        if let (part, row) = chipPart(at: p), let project = row.suggestion {
            if case .chip = part { onSuggestion?(row.session.id, project, true) } else { onSuggestion?(row.session.id, project, false) }
            return
        }
        guard let i = index(at: p) else { return }
        if case .session(let r) = items[i], r.group != .recentlyClosed { downAt = (p, r) }
        switch items[i] {
        case .shell(let r):
            if shellCloseRect(in: rowRects()[i]).contains(p) { onCloseShell?(r.id); return }
            cursor = r.id
            onOpen?(r.id)
        case .group(let g, _) where g.folds: toggle(g)
        case .notSafe(let id): onNotSafe?(id)
        case .session(let r) where r.group == .recentlyClosed: onReopen?(r.session.id)
        case .session(let r):
            cursor = r.session.id
            if r.group == .safeToClose { setExpanded(r.session.id, !expanded.contains(r.session.id)) }
            onOpen?(r.session.id)
        default: break
        }
    }

    override func rightMouseDown(with e: NSEvent) {
        guard let i = index(at: convert(e.locationInWindow, from: nil)), case .session(let r) = items[i],
              let m = menuFor?(r.session) else { return super.rightMouseDown(with: e) }
        NSMenu.popUpContextMenu(m, with: e, for: self)
    }

    private(set) var openMenu: NSMenu?
    /// The row's menu under the row, as a right-click would show it (test hook for captures).
    func showMenu(_ id: SessionID, submenu: Bool = false) {
        guard let i = items.firstIndex(where: { if case .session(let r) = $0 { return r.session.id == id }; return false }),
              case .session(let r) = items[i], let row = menuFor?(r.session), let m = submenu ? row.items.first(where: { $0.hasSubmenu })?.submenu : row else { return }
        let rect = rowRects()[i]
        openMenu = m
        m.popUp(positioning: m.items.first, at: NSPoint(x: rect.minX + 60, y: rect.midY), in: self)
        openMenu = nil
    }

    // MARK: dragging a row onto a rail key

    override func mouseDragged(with e: NSEvent) {
        guard let (start, row) = downAt else { return }
        let p = convert(e.locationInWindow, from: nil)
        guard hypot(p.x - start.x, p.y - start.y) > 4, let i = items.firstIndex(where: { if case .session(let r) = $0 { return r.session.id == row.session.id }; return false }) else { return }
        downAt = nil
        let rect = rowRects()[i]
        let item = NSDraggingItem(pasteboardWriter: { let pb = NSPasteboardItem(); pb.setString(row.session.id, forType: .maxwellSession); return pb }())
        let image = NSImage(size: rect.size, flipped: true) { [weak self] _ in
            guard let self else { return false }
            self.t.panel.withAlphaComponent(0.92).setFill(); NSBezierPath(roundedRect: NSRect(origin: .zero, size: rect.size).insetBy(dx: 6, dy: 1.5), xRadius: 5, yRadius: 5).fill()
            Text.draw(row.session.title, in: NSRect(x: 34, y: 0, width: rect.width - 50, height: rect.height), color: self.t.fg)
            return true
        }
        item.setDraggingFrame(rect, contents: image)
        onDragSession?(true)
        beginDraggingSession(with: [item], event: e, source: self)
    }

    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
    func draggingSession(_ s: NSDraggingSession, endedAt p: NSPoint, operation: NSDragOperation) { onDragSession?(false) }

    // MARK: keyboard

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        if cursor == nil { cursor = current ?? rowIds.first }
        needsDisplay = true
        return true
    }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    override func keyDown(with e: NSEvent) {
        switch e.charactersIgnoringModifiers {
        case "j", String(UnicodeScalar(NSDownArrowFunctionKey)!): move(1)
        case "k", String(UnicodeScalar(NSUpArrowFunctionKey)!): move(-1)
        case "\r", "o", " ":
            if let c = cursor, shells.contains(where: { $0.id == c }) { onOpen?(c); break }
            guard let r = row(cursor) else { break }
            if r.group == .recentlyClosed { onReopen?(r.session.id) } else { onOpen?(r.session.id) }
        case String(UnicodeScalar(NSRightArrowFunctionKey)!), "l":
            if let r = row(cursor), r.group == .safeToClose { setExpanded(r.session.id, true) }
        case String(UnicodeScalar(NSLeftArrowFunctionKey)!), "h":
            if let c = cursor { setExpanded(c, false) }
        default: super.keyDown(with: e)
        }
    }

    func move(_ d: Int) {
        let ids = rowIds
        guard !ids.isEmpty else { return }
        let from = ids.firstIndex(of: cursor ?? current ?? "") ?? (d > 0 ? -1 : ids.count)
        cursor = ids[max(0, min(ids.count - 1, from + d))]
        if let i = items.firstIndex(where: { Self.key($0) == cursor }) {
            scrollToVisible(rowRects()[i].insetBy(dx: 0, dy: -rowHeight))
        }
        needsDisplay = true
    }
}

/// The session column: scope header (or project chips), then the list.
final class Sidebar: MXView, TipSource {
    let list = SessionList(frame: .zero)
    let tabs = ProjectTabs(frame: .zero)
    private let scroll = NSScrollView()
    private let title = Label(font: Fonts.mono(Metrics.fontSize, .semibold))
    /// The scope's logo key, so the project reads even while the rail is hidden.
    let mark = ProjectMark(frame: .zero)
    private let count = Label(color: { $0.fg3 })
    private let hintLabel = Label("⌘K", font: Fonts.mono(Metrics.fontSize - 2), color: { $0.fg3 })
    /// "3 elsewhere ⌘0" in amber when other projects have sessions that need him.
    var elsewhere = 0 {
        didSet {
            guard elsewhere != oldValue else { return }
            hintLabel.text = elsewhere > 0 ? "\(elsewhere) elsewhere ⌘0" : "⌘K"
            hintLabel.color = elsewhere > 0 ? { $0.on } : { $0.fg3 }
            needsLayout = true; hintLabel.needsDisplay = true
        }
    }
    private let headerLine = Fill { $0.hair2 }

    func tip(at p: NSPoint) -> (tip: Tip, rect: NSRect)? {
        if hintLabel.frame.contains(p) {
            let tip = elsewhere > 0
                ? Tip(elsewhere == 1 ? "1 session in another project needs you" : "\(elsewhere) sessions in other projects need you", action: "project-all").adding("Show every project")
                : Tip("All actions", action: "palette")
            return (tip, hintLabel.frame)
        }
        if count.frame.contains(p), let n = Int(count.text) { return (Tip(n == 1 ? "1 session in this list" : "\(n) sessions in this list"), count.frame) }
        return nil
    }
    var showTabs = false { didSet { tabs.isHidden = !showTabs; needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.useThinScroller()
        scroll.documentView = list
        hintLabel.align = .right
        tabs.isHidden = true
        [mark, title, count, hintLabel, tabs, headerLine, scroll].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(scope: String, groups: [(PhaseGroup, [Row])]) {
        list.update(groups)
        title.text = scope
        count.text = "\(groups.reduce(0) { $0 + $1.1.count })"
        needsLayout = true
    }

    /// Room the panel's header buttons take on the right.
    var headerReserve: CGFloat = 0 { didSet { if headerReserve != oldValue { needsLayout = true } } }

    /// Where the scope header starts (below the project chips when they show).
    var headerTop: CGFloat { showTabs ? tabs.preferredHeight(width: bounds.width) : 0 }

    override func layout() {
        super.layout()
        let w = bounds.width
        var top: CGFloat = 0
        if showTabs {
            let th = tabs.preferredHeight(width: w)
            tabs.frame = NSRect(x: 0, y: 0, width: w, height: th)
            top = th
        }
        mark.frame = NSRect(x: 10, y: top + (Metrics.header - 18) / 2, width: 18, height: 18)
        title.frame = NSRect(x: 34, y: top, width: min(title.textWidth + 2, w - 100), height: Metrics.header)
        count.frame = NSRect(x: title.frame.maxX + 7, y: top, width: 40, height: Metrics.header)
        // Narrow: "3 elsewhere ⌘0" shortens to "3 ⌘0" rather than run into the count.
        if elsewhere > 0 {
            let long = "\(elsewhere) elsewhere ⌘0"
            let room = w - 10 - headerReserve - (count.frame.minX + Text.width(count.text, font: count.font) + 10)
            hintLabel.text = Text.width(long, font: hintLabel.font) + 2 <= room ? long : "\(elsewhere) ⌘0"
        }
        let hw = hintLabel.textWidth + 2
        hintLabel.frame = NSRect(x: w - 10 - headerReserve - hw, y: top, width: hw, height: Metrics.header)
        top += Metrics.header
        headerLine.frame = NSRect(x: 0, y: top - 1, width: w, height: 1)
        scroll.frame = NSRect(x: 0, y: top, width: w, height: bounds.height - top)
        list.frame = NSRect(x: 0, y: 0, width: w, height: max(list.frame.height, scroll.contentSize.height))
        list.relayout()
    }
}
