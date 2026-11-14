import AppKit

/// One thing search can find: a session, an action or a project.
struct SearchItem {
    enum Kind { case session, action, project }
    var kind: Kind
    var title: String
    /// Text to match with its weight: title 3, project and branch 2, the rest 1.
    var fields: [(text: String, weight: Int, label: String)]
    var detail: String
    var group: PhaseGroup?
    /// Higher for what needs him and what he touched last; breaks ties between equal matches.
    var boost: Int = 0
    var enabled = true
    var run: () -> Void
}

/// Subsequence matching with bonuses for word starts and runs, after VS Code's fuzzy scorer.
enum Fuzzy {
    /// Score of `q` (lowercase) in `text`, and the matched character offsets; nil if it does not match.
    /// Long text (a message, a file list) only matches as a whole word piece, never scattered letters.
    static func match(_ q: String, in text: String) -> (score: Int, hits: [Int])? {
        if text.count > 80 {
            guard let r = text.lowercased().range(of: q) else { return nil }
            let lower = text.lowercased()
            let atWord = r.lowerBound == lower.startIndex || " /-_.:(".contains(lower[lower.index(before: r.lowerBound)])
            return (q.count * 4 + (atWord ? 8 : 0), [])
        }
        let t = Array(text.lowercased()), p = Array(q)
        guard !p.isEmpty, p.count <= t.count else { return p.isEmpty ? (0, []) : nil }
        var best: (Int, [Int])?
        for start in t.indices where t[start] == p[0] {
            var hits: [Int] = [], score = 0, ti = start, prev = -2
            for c in p {
                while ti < t.count, t[ti] != c { ti += 1 }
                guard ti < t.count else { hits = []; break }
                score += 1
                if ti == prev + 1 { score += 5 } else if prev >= 0 { score -= min(ti - prev - 1, 6) }
                if ti == 0 { score += 8 } else if " /-_.:".contains(t[ti - 1]) { score += 5 }
                hits.append(ti); prev = ti; ti += 1
            }
            guard hits.count == p.count else { continue }
            // Scattered letters count for half: "shop" in "Show or Hide … Panels" is a weak match.
            if text.lowercased().contains(q) { score += 10 } else { score /= 2 }
            if best == nil || score > best!.0 { best = (score, hits) }
            if best!.1.first == 0 { break }
        }
        return best
    }
}

/// Search everywhere (⌘P, or Shift twice): sessions by title, project, branch, account, last
/// message and files touched; projects; and every action. "> " limits it to actions (⌘K).
final class SearchPanel: MXView, NSTextFieldDelegate {
    private struct Hit { var item: SearchItem; var score: Int; var hits: [Int]; var why: String? }
    private let field = NSTextField()
    private var all: [SearchItem] = []
    private var shown: [Hit] = []
    private var index = 0
    private var hover: Int?
    var onClose: (() -> Void)?
    static let width: CGFloat = 640
    private let maxRows = 12
    private static let top: CGFloat = 40
    private static let foot: CGFloat = 24

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Fonts.mono(Metrics.fontSize + 1)
        field.delegate = self
        addSubview(field)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        lookChanged()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func lookChanged() {
        super.lookChanged()
        field.textColor = t.fg
        field.font = Fonts.mono(Metrics.fontSize + 1)
        field.placeholderAttributedString = NSAttributedString(string: "Search sessions, projects, files, actions…   > actions only",
                                                               attributes: [.foregroundColor: t.fg3, .font: Fonts.mono(Metrics.fontSize + 1)])
    }

    /// New items (files touched arrived), keeping what is typed.
    func replace(_ items: [SearchItem]) { all = items; filter() }

    func present(_ items: [SearchItem], query: String = "", in host: NSView) {
        all = items
        field.stringValue = query
        filter()
        frame = NSRect(x: (host.bounds.width - Self.width) / 2, y: 64, width: Self.width, height: preferredHeight)
        host.addSubview(self)
        Motion.appear(self)
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: query.count, length: 0)
    }

    private var preferredHeight: CGFloat { Self.top + CGFloat(min(maxRows, max(1, shown.count))) * Metrics.row + 6 + Self.foot }

    private func filter() {
        var q = field.stringValue
        let actionsOnly = q.hasPrefix(">")
        if actionsOnly { q.removeFirst() }
        let tokens = q.lowercased().split(separator: " ").map(String.init)
        let pool = actionsOnly ? all.filter { $0.kind == .action } : all
        if tokens.isEmpty {
            // Before typing: what needs him and what he opened last, then (for "> ") every action.
            shown = (actionsOnly ? pool : pool.filter { $0.kind == .session && $0.boost > 0 }.sorted { $0.boost > $1.boost }.prefix(10).map { $0 })
                .map { Hit(item: $0, score: 0, hits: [], why: nil) }
        } else {
            shown = pool.compactMap { item in
                var total = 0, titleHits: [Int] = [], why: String?
                for tok in tokens {
                    var bestTok: (Int, [Int], Int)?
                    for (fi, f) in item.fields.enumerated() {
                        guard let m = Fuzzy.match(tok, in: f.text) else { continue }
                        let s = m.score * f.weight
                        if bestTok == nil || s > bestTok!.0 { bestTok = (s, m.hits, fi) }
                    }
                    guard let b = bestTok else { return nil }
                    total += b.0
                    if b.2 == 0 { titleHits += b.1 } else if why == nil, !item.fields[b.2].label.isEmpty {
                        why = "\(item.fields[b.2].label) \(Self.snippet(item.fields[b.2].text, around: tok))"
                    }
                }
                return Hit(item: item, score: total * 4 + item.boost, hits: titleHits, why: why)
            }.sorted { $0.score != $1.score ? $0.score > $1.score : $0.item.title.count < $1.item.title.count }
        }
        index = shown.firstIndex { $0.item.enabled } ?? 0
        if superview != nil { frame.size = NSSize(width: Self.width, height: preferredHeight) }
        needsDisplay = true
        needsLayout = true
    }

    /// A short piece of a long field around the match, e.g. the file name or the words in a message.
    private static func snippet(_ text: String, around tok: String) -> String {
        if text.contains("/") {
            let parts = text.split(separator: " ")
            return String(parts.first { $0.lowercased().contains(tok) } ?? parts.first ?? "").split(separator: "/").suffix(2).joined(separator: "/")
        }
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard let r = flat.lowercased().range(of: tok) else { return String(flat.prefix(40)) }
        let start = flat.index(r.lowerBound, offsetBy: -16, limitedBy: flat.startIndex) ?? flat.startIndex
        return (start > flat.startIndex ? "…" : "") + String(flat[start...].prefix(48))
    }

    func controlTextDidChange(_ n: Notification) { filter() }

    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): step(1); return true
        case #selector(NSResponder.moveUp(_:)): step(-1); return true
        case #selector(NSResponder.insertNewline(_:)): runSelected(); return true
        case #selector(NSResponder.cancelOperation(_:)): dismiss(); return true
        default: return false
        }
    }

    private func step(_ d: Int) {
        guard !shown.isEmpty else { return }
        index = (index + d + shown.count) % shown.count
        needsDisplay = true
    }

    private func runSelected() {
        guard shown.indices.contains(index), shown[index].item.enabled else { return }
        let e = shown[index].item
        dismiss()
        e.run()
    }

    func dismiss() {
        removeFromSuperview()
        onClose?()
    }

    override func layout() {
        super.layout()
        field.frame = NSRect(x: 14, y: 10, width: bounds.width - 28, height: 22)
    }

    private var first: Int { max(0, min(index - maxRows + 1, shown.count - maxRows)) }

    override func draw(_ r: NSRect) {
        t.panel.setFill(); bounds.fill()
        t.hair.setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7); border.lineWidth = 1; border.stroke()
        t.hair2.setFill(); NSRect(x: 0, y: Self.top - 1, width: bounds.width, height: 1).fill()
        let small = Fonts.mono(Metrics.fontSize - 2)
        for (row, i) in (first..<min(shown.count, first + maxRows)).enumerated() {
            let h = shown[i], e = h.item
            let rr = NSRect(x: 4, y: Self.top + 3 + CGFloat(row) * Metrics.row, width: bounds.width - 8, height: Metrics.row)
            let sel = i == index
            if sel { t.rowSel.setFill(); NSBezierPath(roundedRect: rr, xRadius: 4, yRadius: 4).fill() }
            else if hover == i { t.hover.setFill(); NSBezierPath(roundedRect: rr, xRadius: 4, yRadius: 4).fill() }
            if sel { t.fg.setFill(); NSRect(x: rr.minX, y: rr.minY + 6, width: 2, height: rr.height - 12).fill() }
            var x = rr.minX + 10
            switch e.kind {
            case .session: Glyph.draw(e.group ?? .idle, at: NSPoint(x: x + 4, y: rr.midY), color: t.color(for: e.group ?? .idle))
            case .action: Text.draw("›", in: NSRect(x: x, y: rr.minY, width: 10, height: rr.height), color: t.fg3, align: .center)
            case .project:
                t.fg3.setFill()
                for (dx, dy) in [(0, 0), (5, 0), (0, 5), (5, 5)] { NSRect(x: x + CGFloat(dx), y: rr.midY - 4 + CGFloat(dy), width: 3.5, height: 3.5).fill() }
            }
            x += 20
            let detailW = min(260, Text.width(e.detail, font: small))
            Text.draw(e.detail, in: NSRect(x: rr.maxX - detailW - 10, y: rr.minY, width: detailW, height: rr.height), color: t.fg3, font: small)
            let titleW = rr.maxX - detailW - 24 - x
            let used = drawTitle(e.title, hits: h.hits, in: NSRect(x: x, y: rr.minY, width: titleW, height: rr.height), color: e.enabled ? t.fg : t.fg3)
            if let why = h.why, titleW - used > 60 {
                Text.draw(why, in: NSRect(x: x + used + 10, y: rr.minY, width: titleW - used - 10, height: rr.height), color: t.fg3, font: small)
            }
        }
        if shown.isEmpty { Text.draw("Nothing matches.", in: NSRect(x: 14, y: Self.top + 3, width: 300, height: Metrics.row), color: t.fg3) }
        let fy = bounds.height - Self.foot
        t.hair2.setFill(); NSRect(x: 0, y: fy, width: bounds.width, height: 1).fill()
        Text.draw("↑↓ move  ⏎ open  esc close  > actions only  ⇧⇧ or ⌘P search  ⌘K actions", in: NSRect(x: 14, y: fy + 1, width: bounds.width - 28, height: Self.foot - 1), color: t.fg3, font: small)
    }

    /// The title with the matched characters in the brighter ink.
    private func drawTitle(_ s: String, hits: [Int], in r: NSRect, color: NSColor) -> CGFloat {
        let a = NSMutableAttributedString(string: s, attributes: Text.attrs(hits.isEmpty ? color : color.withAlphaComponent(0.72)))
        let chars = Array(s)
        var utf16 = 0
        var offsets: [Int] = []
        for c in chars { offsets.append(utf16); utf16 += String(c).utf16.count }
        for h in hits where h < chars.count {
            a.addAttributes([.foregroundColor: color, .font: Fonts.mono(Metrics.fontSize, .semibold)], range: NSRange(location: offsets[h], length: String(chars[h]).utf16.count))
        }
        let f = Fonts.mono()
        let lineH = f.ascender - f.descender
        a.draw(with: NSRect(x: r.minX, y: r.minY + (r.height - lineH) / 2 - 0.5, width: r.width, height: lineH + 2), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        return min(r.width, ceil(a.size().width))
    }

    private func row(at p: NSPoint) -> Int? {
        guard p.y > Self.top, p.y < bounds.height - Self.foot else { return nil }
        let i = first + Int((p.y - Self.top - 3) / Metrics.row)
        return shown.indices.contains(i) ? i : nil
    }
    override func mouseMoved(with e: NSEvent) {
        let i = row(at: convert(e.locationInWindow, from: nil))
        if i != hover { hover = i; needsDisplay = true }
    }
    override func mouseExited(with e: NSEvent) { hover = nil; needsDisplay = true }
    override func mouseDown(with e: NSEvent) {
        guard let i = row(at: convert(e.locationInWindow, from: nil)) else { return }
        index = i
        runSelected()
    }
}

/// Files each session edited, from its transcript; read off the main thread and cached by size.
final class TouchedFiles {
    static let shared = TouchedFiles()
    private var cache: [String: (size: UInt64, files: [String])] = [:]
    private let queue = DispatchQueue(label: "maxwell.touched", qos: .utility)
    private let lock = NSLock()

    func files(_ transcript: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return cache[transcript]?.files ?? []
    }

    /// Refreshes the transcripts that grew since the last read, then calls `done` on the main thread.
    func refresh(_ transcripts: [String], done: @escaping () -> Void) {
        queue.async {
            for path in transcripts {
                let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
                self.lock.lock(); let old = self.cache[path]; self.lock.unlock()
                guard size > 0, old?.size != size else { continue }
                let files = Self.read(path)
                self.lock.lock(); self.cache[path] = (size, files); self.lock.unlock()
            }
            DispatchQueue.main.async(execute: done)
        }
    }

    /// `"file_path":"…"` in the last 4 MB of tool calls, newest first, distinct.
    private static func read(_ path: String) -> [String] {
        guard let h = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 4 << 20 ? size - (4 << 20) : 0)
        let text = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
        var seen = Set<String>(), out: [String] = []
        let re = try! NSRegularExpression(pattern: #""(?:file_path|notebook_path)":"([^"]+)""#)
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let r = Range(m.range(at: 1), in: text) else { continue }
            let f = String(text[r])
            if seen.insert(f).inserted { out.append(f) }
            if out.count >= 60 { break }
        }
        return out
    }
}

/// Shift pressed and released twice, with nothing else in between, within the double-click time.
final class DoubleShift {
    private var lastTap: Date?
    private var downAt: Date?
    private var monitor: Any?

    init(_ fire: @escaping () -> Void) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] e in
            guard let self else { return e }
            if e.type == .keyDown { self.lastTap = nil; self.downAt = nil; return e }
            let mods = e.modifierFlags.intersection([.shift, .command, .option, .control])
            if mods == .shift { self.downAt = Date() }
            else if mods.isEmpty, let d = self.downAt {
                self.downAt = nil
                guard Date().timeIntervalSince(d) < 0.3 else { self.lastTap = nil; return e }
                if let l = self.lastTap, Date().timeIntervalSince(l) < NSEvent.doubleClickInterval {
                    self.lastTap = nil
                    fire()
                } else {
                    self.lastTap = Date()
                }
            } else {
                self.downAt = nil; self.lastTap = nil
            }
            return e
        }
    }
}
