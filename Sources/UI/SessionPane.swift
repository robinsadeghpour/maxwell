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
    /// The account a session is continuing on, while that runs.
    func movingTo(_ id: SessionID) -> Account?
    /// Every other account it can continue on, with its room: the banner's ▾.
    func continueAccounts(_ id: SessionID) -> NSMenu?
    func scheduledResume(_ id: SessionID) -> Date?
    func bringIn(_ id: SessionID, force: Bool)
    func bringInQueued(_ id: SessionID) -> Bool
    func showAgents(_ id: SessionID)
    func openCloud(_ id: SessionID)
    func bringToMac(_ id: SessionID)
    func closeCloud(_ id: SessionID)
    /// "listing from 14:02 · <why>" while the account's cloud listing fails; nil while it works.
    func cloudNote(_ s: Session) -> String?
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
    /// A cloud session's claude.ai/code page, signed in to its account.
    let cloudPage = ArtifactView(frame: .zero)
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
    /// The overview's buttons: next session that needs you, new session.
    func onOverview(next: @escaping () -> Void, new: @escaping () -> Void) {
        overview.onNext = next
        overview.onNew = new
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        [glyph, prompt, title, project, pills, agents, headerLine, banner, content, empty, message.scroll, cloudPage, overview].forEach(addSubview)
        cloudPage.isHidden = true
        cloudPage.noun = "cloud session"
        cloudPage.offersBrowser = false
        banner.isHidden = true
        prompt.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ s: Session?, group: PhaseGroup?, blockers: [String], project projectName: String?, account: Account?,
              terminal: TerminalView?, needsYou: (all: Int, here: Int), scope: String?) {
        session = s
        self.account = account
        shellShown = false
        prompt.isHidden = true
        select(terminal)
        overview.isHidden = s != nil
        message.scroll.isHidden = true
        if !(s?.isCloud ?? false) { cloudPage.isHidden = true; cloudPage.hide() }
        guard let s else {
            [glyph, title, project, pills, agents, banner, empty, headerLine].forEach { $0.isHidden = true }
            overview.needsYou = needsYou
            overview.scope = scope
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
        if s.isCloud { p.append("[cloud]") }
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
        if case .cloud(let url) = s.reach {
            showCloud(s, url: url, group: group ?? .idle)
        } else if case .elsewhere = s.reach, terminal == nil {
            empty.isHidden = true
            message.scroll.isHidden = false
            message.show(note: "Runs in another terminal, read-only here. Bring it into Maxwell to work with it in this pane.",
                         text: s.lastMessage ?? "No reply yet.")
            if delegate?.bringInQueued(s.id) == true {
                banner.add(MXButton("Moves in when this turn ends · Move now") { [weak self] in self?.delegate?.bringIn(s.id, force: true) })
            } else {
                banner.add(MXButton("Bring into Maxwell", primary: true) { [weak self] in self?.delegate?.bringIn(s.id, force: false) })
            }
        } else if let to = delegate?.movingTo(s.id), terminal == nil {
            empty.isHidden = true
            message.scroll.isHidden = false
            message.show(note: "Claude Code stops it on \(account?.name ?? s.accountId) and resumes it on \(to.name) with the whole conversation. It opens here once it runs there.",
                         text: s.lastMessage ?? "No reply yet.", asReply: s.lastMessage != nil, quiet: true)
        } else if s.parkedAt != nil && terminal == nil {
            empty.isHidden = true
            message.scroll.isHidden = false
            let asked: String? = { if case .needsYou(let q) = s.phase { return q }; return nil }()
            let note = "This session isn't running: Claude Code stopped it while it waited. The conversation is kept; ⌘R resumes it."
            if let reply = s.lastMessage ?? asked {
                message.show(note: note, text: reply, asReply: true, quiet: group != .needsYou)
            } else {
                message.show(note: note, text: "Resume to see where it left off.")
            }
            banner.append(" · not running")
            // Safe to close already offers Close as the one main action; elsewhere Resume is the next step.
            if group != .safeToClose {
                banner.add(MXButton("Resume", hint: "⌘R", primary: true) { [weak self] in self?.delegate?.reattach(s.id) })
            }
        } else {
            empty.isHidden = terminal != nil
            empty.lines = ["Detached. The session keeps running in the background.", "", "⌘R resumes it here."]
        }
        needsLayout = true
    }

    /// A cloud session: its page in the pane, and what Maxwell can do from here in the banner.
    private func showCloud(_ s: Session, url: String, group: PhaseGroup) {
        empty.isHidden = true
        cloudPage.isHidden = false
        if let account, let u = URL(string: url) { cloudPage.show(ArtifactLink(url: u, id: s.id), account: account) }
        let stale = delegate?.cloudNote(s).map { " · " + $0 } ?? ""
        switch group {
        case .needsYou: if case .needsYou(let q) = s.phase { banner.configure(group: group, text: q + stale, tint: { $0.on }) }
        case .working: banner.configure(group: group, text: "Working in the cloud" + stale, tint: { $0.fg3 })
        default: banner.configure(group: group, text: "Your turn · " + (s.lastMessage ?? "its turn is over") + stale, tint: { $0.chk })
        }
        banner.add(MXButton("Open in browser", hint: "⇧⌘O") { [weak self] in self?.delegate?.openCloud(s.id) })
        banner.add(MXButton("Bring to Mac", hint: "⌥⌘↓") { [weak self] in self?.delegate?.bringToMac(s.id) })
        banner.add(MXButton("Archive…", hint: "⇧⌘⌫") { [weak self] in self?.delegate?.closeCloud(s.id) })
        banner.isHidden = false
    }

    /// A plain terminal: the folder it is in, its path, and the shell.
    func showShell(title folder: String, path: String, terminal: TerminalView) {
        session = nil
        shellShown = true
        select(terminal)
        [overview, banner, empty, glyph, pills, message.scroll, cloudPage].forEach { $0.isHidden = true }
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
            // Only your mark puts a session here with checks still failing: say what they found.
            let text = !blockers.isEmpty ? "Safe to close · you marked it; Maxwell still sees: " + blockers.joined(separator: " · ")
                : note.map { "Safe to close · \($0) · every check passed" } ?? "Safe to close · every check passed; → on its row lists them"
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
            banner.configure(group: group, text: "Usage limit on \(name) · \(when)", tint: { $0.fg3 })
            if let to = delegate?.movingTo(s.id) {
                banner.configure(group: .working, text: "Continuing on \(to.name) with the whole conversation…", tint: { $0.fg3 })
                break
            }
            if let scheduled = delegate?.scheduledResume(s.id) {
                banner.add(MXButton("Resumes \(Format.clock.string(from: scheduled)) ✓", small: false))
            } else if case .background = s.reach {
                let label = reset.map { $0 > now ? "Resume at reset" : "Resume now" } ?? "Resume now"
                banner.add(MXButton(label, hint: "⇧⌘R") { [weak self] in self?.delegate?.resume(s.id) })
            }
            let other = delegate?.roomiest(for: s.id)
            if let other {
                let left = other.usedPercent.map { " · \(100 - Int($0))% left" } ?? ""
                banner.add(MXButton("Continue on \(other.name)\(left)", hint: "⇧⌘M", primary: true) { [weak self] in self?.delegate?.move(s.id) })
            }
            // A split button: the main one takes the account with the most room, ▾ picks another.
            if case .background = s.reach {
                let pick = MXButton(other == nil ? "Continue on ▾" : "▾")
                pick.tip = Tip("Continue on another account")
                pick.action = { [weak self, weak pick] in
                    guard let pick, let menu = self?.delegate?.continueAccounts(s.id) else { return }
                    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: pick.bounds.height + 2), in: pick)
                }
                banner.add(pick)
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
        // The agents button sits at the right edge so a long title can't push it out of view.
        let bs = agents.intrinsicContentSize
        agents.frame = NSRect(x: w - bs.width - 10, y: ((h - bs.height) / 2).rounded(), width: bs.width, height: bs.height)
        let end = agents.isHidden ? w : agents.frame.minX - 8
        let tw = min(title.textWidth + 2, end * 0.45)
        title.frame = NSRect(x: 28, y: 0, width: tw, height: h)
        let pw = min(project.textWidth + 2, max(0, end - title.frame.maxX - 8))
        project.frame = NSRect(x: title.frame.maxX + 8, y: 0, width: pw, height: h)
        pills.frame = NSRect(x: project.frame.maxX + 10, y: 0, width: min(pills.textWidth + 2, max(0, end - project.frame.maxX - 22)), height: h)
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
        cloudPage.frame = content.frame
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

    /// `asReply`: drawn like the end of Claude's transcript, behind ⏺ with wrapped lines indented.
    /// `quiet`: a question keeps the body colour, for a session that no longer needs you.
    func show(note: String, text body: String, asReply: Bool = false, quiet: Bool = false) {
        let t = Look.theme
        let mark = "⏺ "
        let indent = asReply ? (mark as NSString).size(withAttributes: [.font: Fonts.mono(Metrics.fontSize)]).width : 0
        let out = NSMutableAttributedString()
        let p = NSMutableParagraphStyle(); p.lineSpacing = 2; p.paragraphSpacing = 9
        let tight = NSMutableParagraphStyle(); tight.lineSpacing = 2; tight.paragraphSpacing = 2
        for s in [p, tight] { s.headIndent = indent; s.firstLineHeadIndent = indent }
        let first = NSMutableParagraphStyle(); first.setParagraphStyle(p); first.firstLineHeadIndent = 0
        let noteStyle = NSMutableParagraphStyle(); noteStyle.lineSpacing = 2; noteStyle.paragraphSpacing = 9
        out.append(NSAttributedString(string: note + "\n", attributes: [.font: Fonts.mono(Metrics.fontSize - 1), .foregroundColor: t.fg3, .paragraphStyle: noteStyle]))
        var marked = !asReply
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
            let asks = !quiet && (raw.hasSuffix("?") || raw.hasSuffix("?**"))
            let style = !marked ? first : listItem && nextIsList ? tight : p
            if !marked { line = mark + line; marked = true }
            out.append(NSAttributedString(string: line + "\n", attributes: [
                .font: Fonts.mono(Metrics.fontSize, heading ? .semibold : .regular),
                .foregroundColor: asks ? t.on : heading ? t.fg : t.fg.withAlphaComponent(0.9),
                .paragraphStyle: style]))
        }
        text.textStorage?.setAttributedString(out)
        text.scrollToBeginningOfDocument(nil)
    }
}

