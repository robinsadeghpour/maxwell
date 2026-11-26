import AppKit

/// The one way usage is drawn: a 2 pt bar on a hairline track, the percent, then when it
/// resets. Grey until 80%, brighter to 95%, amber at the limit.
enum UsageBar {
    static func draw(_ w: UsageWindow?, in r: NSRect, now: Date, theme t: Theme, resetWidth: CGFloat) {
        let font = Fonts.mono(Metrics.fontSize - 2)
        // Past the reset time a sample no longer says anything about the new window.
        let live = w.flatMap { $0.resetsAt > now ? $0 : nil }
        let pct = live?.usedPercent ?? (w == nil ? nil : 0)
        let pctW: CGFloat = 34
        // Narrow: the reset time moves to the tooltip, the bar keeps its room.
        let resetWidth = r.width < 170 ? 0 : resetWidth
        let barW = max(12, r.width - pctW - resetWidth - 12)
        let bar = NSRect(x: r.minX, y: r.midY - 1, width: barW, height: 2)
        Meter.draw(pct, in: bar, theme: t)
        let full = (pct ?? 0) >= 100
        Text.draw(pct.map { "\(Int($0))%" } ?? "–", in: NSRect(x: bar.maxX + 6, y: r.minY, width: pctW, height: r.height),
                  color: full ? t.on : pct.map { $0 >= 80 } == true ? t.fg : t.fg2, font: font, align: .right)
        guard resetWidth > 0 else { return }
        let reset = live.map { "↻" + Format.reset($0.resetsAt, now: now) } ?? (w == nil ? "" : "ready")
        Text.draw(reset, in: NSRect(x: r.maxX - resetWidth, y: r.minY, width: resetWidth, height: r.height),
                  color: full ? t.on : t.fg3, font: font, align: .right)
    }
}

extension UsageBar {
    /// "62% used in the last 5 hours", then when it resets in plain words.
    static func tip(_ w: UsageWindow?, week: Bool, now: Date = Date()) -> Tip {
        let span = week ? "this week" : "in the last 5 hours"
        guard let w else { return Tip("No usage reported yet for \(span)") }
        if w.resetsAt <= now { return Tip("The \(week ? "weekly" : "5 hour") limit has reset").adding("All of it is free again") }
        return Tip("\(Int(w.usedPercent))% used \(span)").adding("Resets \(Format.when(w.resetsAt, now: now))")
    }
}

/// The small header every widget panel uses: a caps label, room for a note on the right.
private func drawWidgetHeader(_ title: String, note: String = "", in v: MXView, theme t: Theme) {
    let head = Fonts.mono(Metrics.fontSize - 2.5, .medium)
    Text.draw(title, in: NSRect(x: 12, y: 0, width: 120, height: Widget.header), color: t.fg3, font: head)
    if !note.isEmpty {
        Text.draw(note, in: NSRect(x: 12, y: 0, width: v.bounds.width - 24, height: Widget.header), color: t.fg3, font: head, align: .right)
    }
}

enum Widget {
    static let header: CGFloat = 24
    static let line: CGFloat = 19
}

/// Usage per account: 5-hour and weekly bars with percent and reset time.
final class UsagePanel: MXView, PanelContent, TipSource {
    var accounts: [Account] = [] { didSet { if accounts != oldValue { needsDisplay = true } } }
    var counts: [AccountID: Int] = [:] { didSet { if counts != oldValue { needsDisplay = true } } }

    var gripRect: NSRect { NSRect(x: 0, y: 0, width: bounds.width, height: Widget.header) }
    func preferredExtent(along d: Dock) -> CGFloat? {
        d == .bottom ? Widget.header + CGFloat(max(3, accounts.count)) * Widget.line + 8 : Widget.header + CGFloat(accounts.count) * Widget.line + 10
    }

    private var columns: (name: CGFloat, c1: NSRect, c2: NSRect) {
        let x0: CGFloat = 12 + 76
        let w = (bounds.width - x0 - 12 - 16) / 2
        return (76, NSRect(x: x0, y: 0, width: w, height: 0), NSRect(x: x0 + w + 16, y: 0, width: w, height: 0))
    }

    /// The account (and its running sessions), or one bar: how much is used and when it resets.
    func tip(at p: NSPoint) -> (tip: Tip, rect: NSRect)? {
        let c = columns
        if p.y < Widget.header {
            if p.x >= c.c2.minX { return (Tip("Share of each account's weekly limit used"), NSRect(x: c.c2.minX, y: 0, width: c.c2.width, height: Widget.header)) }
            if p.x >= c.c1.minX { return (Tip("Share of each account's 5 hour limit used"), NSRect(x: c.c1.minX, y: 0, width: c.c1.width, height: Widget.header)) }
            return nil
        }
        let i = Int((p.y - Widget.header) / Widget.line)
        guard accounts.indices.contains(i) else { return nil }
        let a = accounts[i], y = Widget.header + CGFloat(i) * Widget.line
        if p.x < c.c1.minX {
            let n = counts[a.id] ?? 0
            return (Tip(a.name).adding(n == 0 ? "No sessions running" : n == 1 ? "1 session running" : "\(n) sessions running"), NSRect(x: 0, y: y, width: c.c1.minX - 4, height: Widget.line))
        }
        let week = p.x >= c.c2.minX
        let col = week ? c.c2 : c.c1
        return (UsageBar.tip(week ? a.week : a.fiveHour, week: week), NSRect(x: col.minX, y: y, width: col.width, height: Widget.line))
    }

    override func draw(_ r: NSRect) {
        let c = columns
        drawWidgetHeader("USAGE", in: self, theme: t)
        let head = Fonts.mono(Metrics.fontSize - 2.5, .medium)
        Text.draw("5 HOURS", in: NSRect(x: c.c1.minX, y: 0, width: c.c1.width, height: Widget.header), color: t.fg3, font: head)
        Text.draw("WEEK", in: NSRect(x: c.c2.minX, y: 0, width: c.c2.width, height: Widget.header), color: t.fg3, font: head)
        let now = Date()
        let small = Fonts.mono(Metrics.fontSize - 2)
        for (i, a) in accounts.enumerated() {
            let y = Widget.header + CGFloat(i) * Widget.line
            let nameW = Text.draw(a.name, in: NSRect(x: 12, y: y, width: c.name - 20, height: Widget.line), color: t.fg2, font: Fonts.mono(Metrics.fontSize - 1))
            if let n = counts[a.id], n > 0 {
                Text.draw("\(n)", in: NSRect(x: 12 + nameW + 5, y: y, width: 24, height: Widget.line), color: t.fg3, font: small)
            }
            let rw = Text.width("↻Sat 00:00", font: small)
            UsageBar.draw(a.fiveHour, in: NSRect(x: c.c1.minX, y: y, width: c.c1.width, height: Widget.line), now: now, theme: t, resetWidth: rw)
            UsageBar.draw(a.week, in: NSRect(x: c.c2.minX, y: y, width: c.c2.width, height: Widget.line), now: now, theme: t, resetWidth: rw)
        }
        if accounts.isEmpty {
            Text.draw("No account has reported usage yet.", in: NSRect(x: 12, y: Widget.header, width: bounds.width - 24, height: Widget.line), color: t.fg3, font: small)
        }
    }
}

/// What Claude Code and the machine use right now: CPU and memory, sampled every 2 s while shown.
/// A click on a row opens the details card (`SystemDetail`).
final class SystemPanel: MXView, PanelContent, TipSource {
    private(set) var sample: SystemSample?
    private(set) var history = SystemHistory()
    private var timer: Timer?
    /// Takes one reading off the main thread and hands it back on it. Set by the window controller.
    var measure: ((@escaping (SystemSample) -> Void) -> Void)?
    var onSample: (() -> Void)?
    var onOpen: (() -> Void)?

    var gripRect: NSRect { NSRect(x: 0, y: 0, width: bounds.width, height: Widget.header) }
    func preferredExtent(along d: Dock) -> CGFloat? { Widget.header + 3 * Widget.line + 8 }

    override func viewDidMoveToWindow() { updateTimer() }
    override func viewDidHide() { updateTimer() }
    override func viewDidUnhide() { updateTimer() }

    private func updateTimer() {
        let live = window != nil && !isHiddenOrHasHiddenAncestor
        if live, timer == nil {
            tick()
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        } else if !live {
            timer?.invalidate(); timer = nil
        }
    }

    private func tick() {
        measure? { [weak self] s in
            guard let self else { return }
            self.sample = s
            self.history.add(s)
            self.needsDisplay = true
            self.onSample?()
        }
    }

    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if p.y >= Widget.header, sample != nil { onOpen?() } else { super.mouseDown(with: e) }
    }
    override func resetCursorRects() { addCursorRect(NSRect(x: 0, y: Widget.header, width: bounds.width, height: bounds.height - Widget.header), cursor: .pointingHand) }

    /// What each row measures. CPU is always a share of the whole Mac, so the rows add up.
    func tip(at p: NSPoint) -> (tip: Tip, rect: NSRect)? {
        guard let s = sample else { return nil }
        let x0: CGFloat = 12 + 76, w = (bounds.width - x0 - 12 - 16) / 2
        if p.y < Widget.header {
            if p.x >= x0 + w + 16 { return (Tip("Memory in use"), NSRect(x: x0 + w + 16, y: 0, width: w, height: Widget.header)) }
            if p.x >= x0 { return (Tip("Share of the whole Mac's processing power").adding("\(s.cores) cores together are 100%"), NSRect(x: x0, y: 0, width: w, height: Widget.header)) }
            return nil
        }
        let i = Int((p.y - Widget.header) / Widget.line)
        let n = s.sessions.count
        let tips = [
            Tip("Claude Code, every account").adding("\(n == 1 ? "1 session" : "\(n) sessions") and the commands they run").adding("Click for each session"),
            Tip("Maxwell itself").adding("Click for details"),
            Tip("The whole Mac").adding("\(s.cores) cores, \(Self.gb(s.memTotal)) GB memory").adding("Click for details"),
        ]
        guard tips.indices.contains(i) else { return nil }
        return (tips[i], NSRect(x: 0, y: Widget.header + CGFloat(i) * Widget.line, width: bounds.width, height: Widget.line))
    }

    override func draw(_ r: NSRect) {
        drawWidgetHeader("SYSTEM", in: self, theme: t)
        guard let s = sample else {
            Text.draw("Measuring…", in: NSRect(x: 12, y: Widget.header, width: 200, height: Widget.line), color: t.fg3, font: Fonts.mono(Metrics.fontSize - 2))
            return
        }
        let claude = s.claude
        let rows: [(String, String, Double, UInt64)] = [
            ("claude", s.sessions.isEmpty ? "" : "\(s.sessions.count)", claude.cpu, claude.memory),
            ("maxwell", "", s.maxwell.cpu, s.maxwell.memory),
            ("machine", "", s.machineCPU, s.memUsed),
        ]
        let x0: CGFloat = 12 + 76
        let w = (bounds.width - x0 - 12 - 16) / 2
        let small = Fonts.mono(Metrics.fontSize - 2)
        let head = Fonts.mono(Metrics.fontSize - 2.5, .medium)
        Text.draw("CPU", in: NSRect(x: x0, y: 0, width: w, height: Widget.header), color: t.fg3, font: head)
        // The header's right end holds the panel buttons (… — ^ ×); the label never runs under them.
        let memX = x0 + w + 16, memRoom = bounds.width - 100 - memX
        let memLabel = memRoom >= Text.width("MEMORY", font: head) ? "MEMORY" : "MEM"
        if memRoom >= Text.width(memLabel, font: head) {
            Text.draw(memLabel, in: NSRect(x: memX, y: 0, width: memRoom, height: Widget.header), color: t.fg3, font: head)
        }
        for (i, (name, count, cpu, mem)) in rows.enumerated() {
            let y = Widget.header + CGFloat(i) * Widget.line
            let nw = Text.draw(name, in: NSRect(x: 12, y: y, width: 70, height: Widget.line), color: t.fg2, font: Fonts.mono(Metrics.fontSize - 1))
            if !count.isEmpty { Text.draw(count, in: NSRect(x: 12 + nw + 5, y: y, width: 30, height: Widget.line), color: t.fg3, font: small) }
            bar(cpu, label: Self.percent(cpu), labelWidth: Text.width("100.0%", font: small), in: NSRect(x: x0, y: y, width: w, height: Widget.line))
            let memPct = Double(mem) / Double(max(1, s.memTotal)) * 100
            let label = i == 2 ? "\(Self.gb(mem))/\(Self.gb(s.memTotal)) GB" : Self.memory(mem)
            bar(memPct, label: label, labelWidth: Text.width("88.8/88.8 GB", font: small), in: NSRect(x: x0 + w + 16, y: y, width: w, height: Widget.line))
        }
    }

    private func bar(_ pct: Double, label: String, labelWidth lw: CGFloat, in r: NSRect) {
        let b = NSRect(x: r.minX, y: r.midY - 1, width: max(12, r.width - lw - 6), height: 2)
        Meter.draw(pct, in: b, theme: t)
        Text.draw(label, in: NSRect(x: r.maxX - lw, y: r.minY, width: lw, height: r.height), color: pct >= 80 ? t.fg : t.fg2, font: Fonts.mono(Metrics.fontSize - 2), align: .right)
    }

    static func gb(_ b: UInt64) -> String { String(format: "%.1f", Double(b) / Double(1 << 30)) }
    static func memory(_ b: UInt64) -> String { b > 1 << 30 ? "\(gb(b)) GB" : "\(b >> 20) MB" }
    static func percent(_ cpu: Double) -> String { String(format: cpu < 10 ? "%.1f%%" : "%.0f%%", cpu) }
}

extension ViewerPane: PanelContent {
    /// The tabs take clicks and drags of their own; the empty header after them moves the panel.
    var gripRect: NSRect {
        NSRect(x: tabsEnd, y: 0, width: max(0, stripEnd - tabsEnd), height: Metrics.header)
    }
    func preferredExtent(along d: Dock) -> CGFloat? { nil }
}

extension Sidebar: PanelContent {
    var gripRect: NSRect { NSRect(x: 0, y: headerTop, width: max(0, bounds.width - 64), height: Metrics.header) }
    func preferredExtent(along d: Dock) -> CGFloat? { nil }
}
