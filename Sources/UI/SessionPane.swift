import AppKit

/// What the middle pane can ask the app to do.
protocol SessionPaneDelegate: AnyObject {
    func reattach(_ id: SessionID)
    func resume(_ id: SessionID)
    func move(_ id: SessionID)
    func close(_ id: SessionID)
    func notSafe(_ id: SessionID)
    func reopen(_ id: SessionID)
    func roomiest(for id: SessionID) -> Account?
    func scheduledResume(_ id: SessionID) -> Date?
    func bringIn(_ id: SessionID, force: Bool)
    func bringInQueued(_ id: SessionID) -> Bool
    func showAgents(_ id: SessionID)
}

/// The middle pane: header with pills, a state banner, and the session's terminal.
final class SessionPane: MXView {
    weak var delegate: SessionPaneDelegate?
    private(set) var session: Session?
    private var account: Account?
    private let glyph = GlyphView(frame: .zero)
    private let title = Label(font: Fonts.mono(Metrics.fontSize, .semibold))
    private let project = Label(color: { $0.fg3 })
    private let pills = Label(color: { $0.fg3 })
    private let agents = MXButton("", small: true)
    private let headerLine = Fill { $0.hair2 }
    private let banner = Banner(frame: .zero)
    let content = TerminalWell(frame: .zero)
    private let empty = EmptyState(frame: .zero)
    private let message = MessageView()
    private let overview = Overview(frame: .zero)
    private var terminal: TerminalView?
    private let prompt = Label("❯", font: Fonts.mono(Metrics.fontSize, .semibold), color: { $0.fg2 })
    /// A plain terminal is on screen: no state, banner or pills, just its folder.
    private var shellShown = false

    /// The setup checklist on the no-session overview; empty once everything is done or hidden.
    var setup: [SetupStep] {
        get { overview.setup }
        set { overview.setup = newValue }
    }
    var onHideSetup: (() -> Void)? {
        get { overview.onHideSetup }
        set { overview.onHideSetup = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        [glyph, prompt, title, project, pills, agents, headerLine, banner, content, empty, message.scroll, overview].forEach(addSubview)
        banner.isHidden = true
        prompt.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ s: Session?, group: PhaseGroup?, blockers: [String], project projectName: String?, account: Account?,
              terminal: TerminalView?, summary: [(PhaseGroup, Int)]) {
        session = s
        self.account = account
        shellShown = false
        prompt.isHidden = true
        select(terminal)
        overview.isHidden = s != nil
        message.scroll.isHidden = true
        guard let s else {
            [glyph, title, project, pills, agents, banner, empty, headerLine].forEach { $0.isHidden = true }
            overview.counts = summary
            needsLayout = true
            return
        }
        [glyph, title, project, pills, headerLine].forEach { $0.isHidden = false }
        glyph.group = group ?? .idle
        title.text = s.title
        let folder = (s.cwd as NSString).lastPathComponent
        let branch = s.branch ?? s.doneCheck?.branch
        project.text = ([projectName ?? folder] + (folder != projectName && !folder.isEmpty && folder.lowercased() != projectName?.lowercased() ? [folder] : []) + (branch.map { [$0] } ?? [])).joined(separator: " › ")
        var p: [String] = []
        p.append("[\(account?.name ?? s.accountId)]")
        if case .open(let n) = s.doneCheck?.pr { p.append("[PR #\(n)]") }
        if case .merged = s.doneCheck?.pr { p.append("[PR merged]") }
        if let ctx = s.contextTokens { p.append("[ctx \(ctx / 1000)k]") }
        let tasks = s.runningTasks ?? []
        let names = tasks.agents.map { $0.label ?? "agent \($0.id.prefix(8))" }
        let attachable: Bool = { if case .background = s.reach { return true }; return false }()
        agents.isHidden = names.isEmpty || !attachable
        pills.tip = nil
        if !agents.isHidden {
            agents.title = tasks.summary
            agents.tip = Tip("Open Claude's agent list", action: "show-agents").adding(names.joined(separator: "\n"))
            agents.action = { [weak self] in self?.delegate?.showAgents(s.id) }
        } else if !tasks.isEmpty {
            p.append("[\(tasks.summary)]")
            if !names.isEmpty { pills.tip = Tip("Agents running").adding(names.joined(separator: "\n")) }
        }
        pills.text = p.joined(separator: " ")
        updateBanner(s, group: group ?? .idle, blockers: blockers)
        if case .elsewhere = s.reach, terminal == nil {
            empty.isHidden = true
            message.scroll.isHidden = false
            message.show(note: "Runs in another terminal, read-only here. Bring it into Maxwell to work with it in this pane.",
                         text: s.lastMessage ?? "No reply yet.")
            if delegate?.bringInQueued(s.id) == true {
                banner.add(MXButton("Moves in when this turn ends · Move now") { [weak self] in self?.delegate?.bringIn(s.id, force: true) })
            } else {
                banner.add(MXButton("Bring into Maxwell", primary: true) { [weak self] in self?.delegate?.bringIn(s.id, force: false) })
            }
        } else if s.parkedAt != nil && terminal == nil {
            empty.isHidden = true
            message.scroll.isHidden = false
            message.show(note: "This session isn't running: Claude Code stopped it while it waited. The conversation is kept; ⌘R resumes it.",
                         text: s.lastMessage ?? "Resume to see where it left off.")
            // Safe to close already offers Close as the one main action; elsewhere Resume is the next step.
            if group != .safeToClose {
                banner.add(MXButton("Resume", hint: "⌘R", primary: true) { [weak self] in self?.delegate?.reattach(s.id) })
            }
        } else {
            empty.isHidden = terminal != nil
            empty.lines = ["Detached. The session keeps running in the background.", "", "⌘R reattaches."]
        }
        needsLayout = true
    }

    /// A plain terminal: the folder it is in, its path, and the shell.
    func showShell(title folder: String, path: String, terminal: TerminalView) {
        session = nil
        shellShown = true
        select(terminal)
        [overview, banner, empty, glyph, pills, message.scroll].forEach { $0.isHidden = true }
        [prompt, title, project, headerLine].forEach { $0.isHidden = false }
        title.text = folder
        project.text = path
        pills.text = ""
        needsLayout = true
    }

    /// Every visited terminal stays a subview; only the selected one is visible and rendering.
    private func select(_ terminal: TerminalView?) {
        if let terminal, terminal.superview !== content { content.addSubview(terminal) }
        for case let v as TerminalView in content.subviews {
            let visible = v === terminal
            v.isHidden = !visible
            v.setVisible(visible)
        }
        self.terminal = terminal
    }

    private func updateBanner(_ s: Session, group: PhaseGroup, blockers: [String]) {
        let now = Date()
        banner.buttons.forEach { $0.removeFromSuperview() }
        banner.buttons = []
        banner.source = s.phaseSource + (s.unverified.map { " · unverified: \($0)" } ?? "")
        switch group {
        case .needsYou:
            if case .needsYou(let q) = s.phase { banner.configure(group: group, text: q, tint: { $0.on }) }
        case .yourTurn where !s.prompted && s.origin == .maxwell:
            banner.configure(group: group, text: "New session · type the first prompt below", tint: { $0.fg3 })
        case .idle:
            // A question nobody answered for days: still say what it asked, quietly.
            if case .needsYou(let q) = s.phase {
                banner.configure(group: group, text: "Asked \(Format.ago(s.lastEventAt, now: now)) · \(q)", tint: { $0.fg3 })
                break
            }
            fallthrough
        case .yourTurn:
            let offer: String? = { if case .offer(let o)? = s.lastMessage.map(Reply.classify) { return o }; return nil }()
            let wrap = s.lastMessage.flatMap(Wrap.parse)
            let open = wrap.flatMap { $0.state == .open ? "Not done" + ($0.note.isEmpty ? "" : " · " + $0.note) : nil }
            let text = offer.map { "Your turn · \($0)" } ?? open ?? "Your turn · not safe to close: " + blockers.joined(separator: " · ")
            banner.configure(group: group, text: text, tint: { $0.chk })
        case .safeToClose:
            let note = s.lastMessage.flatMap(Wrap.parse).flatMap { $0.state == .safe && !$0.note.isEmpty ? $0.note : nil }
            let text = note.map { "Safe to close · \($0) · every check passed" } ?? "Safe to close · every check passed; → on its row lists them"
            banner.configure(group: group, text: text, tint: { $0.safe })
            banner.add(MXButton("Not safe") { [weak self] in self?.delegate?.notSafe(s.id) })
            if case .background = s.reach {
                banner.add(MXButton("Close session", hint: "⇧⌘⌫", primary: true) { [weak self] in self?.delegate?.close(s.id) })
            }
        case .recentlyClosed:
            banner.configure(group: group, text: "Closed by Maxwell · stopped with claude stop, conversation kept", tint: { $0.fg3 })
            banner.add(MXButton("Reopen", primary: true) { [weak self] in self?.delegate?.reopen(s.id) })
        case .limited:
            guard case .limited(let reset) = s.phase else { break }
            let name = account?.name ?? s.accountId
            let when = reset.map { $0 > now ? "resets \(Format.reset($0, now: now))" : "limit has reset" } ?? "waiting for the reset time"
            banner.configure(group: group, text: "Hit the usage limit on \(name) · \(when)", tint: { $0.fg3 })
            if let scheduled = delegate?.scheduledResume(s.id) {
                banner.add(MXButton("Resumes \(Format.clock.string(from: scheduled)) ✓", small: false))
            } else if case .background = s.reach {
                let label = reset.map { $0 > now ? "Resume at \(Format.clock.string(from: $0))" : "Resume now" } ?? "Resume now"
                banner.add(MXButton(label, hint: "⇧⌘R") { [weak self] in self?.delegate?.resume(s.id) })
            }
            if let other = delegate?.roomiest(for: s.id) {
                let left = other.usedPercent.map { " · \(100 - Int($0))% left" } ?? ""
                banner.add(MXButton("Move to \(other.name)\(left)", hint: "⇧⌘M", primary: true) { [weak self] in self?.delegate?.move(s.id) })
            }
        case .working:
            // A running turn needs no strip; a finished one still waiting on its background work does.
            guard let w = s.waitingOn else { banner.isHidden = true; return }
            banner.configure(group: group, text: "Working · the reply is in, \(w)", tint: { $0.fg3 })
        }
        banner.isHidden = false
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = Metrics.header
        glyph.frame = NSRect(x: 8, y: 0, width: 16, height: h)
        prompt.frame = NSRect(x: 10, y: 0, width: 14, height: h)
        let tw = min(title.textWidth + 2, w * 0.45)
        title.frame = NSRect(x: 28, y: 0, width: tw, height: h)
        let pw = project.textWidth + 2
        project.frame = NSRect(x: title.frame.maxX + 8, y: 0, width: pw, height: h)
        pills.frame = NSRect(x: project.frame.maxX + 10, y: 0, width: min(pills.textWidth + 2, max(0, w - project.frame.maxX - 22)), height: h)
        let bs = agents.intrinsicContentSize
        agents.frame = NSRect(x: pills.frame.maxX + 8, y: ((h - bs.height) / 2).rounded(), width: bs.width, height: bs.height)
        headerLine.frame = NSRect(x: 0, y: h - 1, width: w, height: 1)
        var y = h
        if !banner.isHidden && session != nil && !shellShown {
            banner.frame = NSRect(x: 0, y: y, width: w, height: Metrics.header)
            y += Metrics.header
        }
        if session == nil && !shellShown { y = 0 }
        content.frame = NSRect(x: 0, y: y, width: w, height: bounds.height - y)
        content.subviews.forEach { $0.frame = content.bounds }
        empty.frame = content.frame
        message.scroll.frame = content.frame
        overview.frame = bounds
    }
}

/// Holds the terminals. Transparent in dark themes; a dark well in light ones.
final class TerminalWell: MXView {
    override func draw(_ r: NSRect) {
        guard let bg = t.terminalBackground, subviews.contains(where: { !$0.isHidden }) else { return }
        bg.setFill()
        bounds.fill()
    }
}

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

/// Quiet multi-line text for empty and read-only states.
final class EmptyState: MXView {
    var lines: [String] = [] { didSet { needsDisplay = true } }
    override func draw(_ r: NSRect) {
        var y: CGFloat = 16
        for (i, l) in lines.enumerated() {
            Text.draw(l, in: NSRect(x: 16, y: y, width: bounds.width - 32, height: 18), color: i == 0 ? t.fg2 : t.fg3)
            y += 18
        }
    }
}

/// A session's last reply, wrapped and scrollable, for sessions Maxwell cannot attach to.
final class MessageView: NSObject {
    let scroll = NSScrollView()
    private let text = NSTextView()

    override init() {
        super.init()
        text.isEditable = false
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 18, height: 14)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        scroll.useThinScroller()
        scroll.isHidden = true
    }

    func show(note: String, text body: String) {
        let t = Look.theme
        let out = NSMutableAttributedString()
        let p = NSMutableParagraphStyle(); p.lineSpacing = 2; p.paragraphSpacing = 9
        let tight = NSMutableParagraphStyle(); tight.lineSpacing = 2; tight.paragraphSpacing = 2
        out.append(NSAttributedString(string: note + "\n", attributes: [.font: Fonts.mono(Metrics.fontSize - 1), .foregroundColor: t.fg3, .paragraphStyle: p]))
        // The hook keeps the last 2000 characters; say so when the start is cut.
        if body.count >= 2000 { out.append(NSAttributedString(string: "…\n", attributes: [.font: Fonts.mono(Metrics.fontSize), .foregroundColor: t.fg3, .paragraphStyle: tight])) }
        let link = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\([^)]+\)"#)
        let lines = body.components(separatedBy: "\n")
        for (i, raw) in lines.enumerated() where !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            var line = raw
            let heading = line.hasPrefix("#") || (line.hasPrefix("**") && line.hasSuffix("**"))
            while line.hasPrefix("#") { line.removeFirst() }
            if heading { line = line.trimmingCharacters(in: .whitespaces) }
            line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            if let link { line = link.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "$1") }
            let lead = line.trimmingCharacters(in: .whitespaces)
            let listItem = lead.hasPrefix("- ") || lead.first?.isNumber == true
            let nextIsList = lines.indices.contains(i + 1) && { let n = lines[i + 1].trimmingCharacters(in: .whitespaces); return n.hasPrefix("- ") || n.first?.isNumber == true }()
            out.append(NSAttributedString(string: line + "\n", attributes: [
                .font: Fonts.mono(Metrics.fontSize, heading ? .semibold : .regular),
                .foregroundColor: raw.hasSuffix("?") || raw.hasSuffix("?**") ? t.on : heading ? t.fg : t.fg.withAlphaComponent(0.9),
                .paragraphStyle: listItem && nextIsList ? tight : p]))
        }
        text.textStorage?.setAttributedString(out)
        text.scrollToBeginningOfDocument(nil)
    }
}

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
