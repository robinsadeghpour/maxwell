import Foundation

/// The only thing that changes session and account state. Pure: time comes from events.
func reduce(_ state: AppState, _ event: Event) -> AppState {
    var s = state
    reduce(into: &s, event)
    return s
}

/// `reduce` in place. Folds use this: the by-value form copies every dictionary per event.
func reduce(into s: inout AppState, _ event: Event) {
    switch event {
    case .hook(let h):
        guard let acct = s.accountId(forConfigDir: h.configDir) else { return }
        // Helper runs inside a config dir (e.g. a hook's own `claude -p`) are not work sessions.
        if let cwd = h.cwd, s.accounts.contains(where: { cwd.hasPrefix(Paths.normalize($0.configDir.path) + "/") || cwd == Paths.normalize($0.configDir.path) }) {
            return
        }
        var session = s.sessions[h.sessionId] ?? Session(
            id: h.sessionId, name: String(h.sessionId.prefix(8)), accountId: acct, cwd: h.cwd ?? "", at: h.at,
            origin: s.startedByMaxwell.contains(h.sessionId) ? .maxwell : .external, reach: .elsewhere(pid: nil))
        if session.phase == .ended { guard case .sessionStart = h.kind else { return } }
        session.lastEventAt = max(session.lastEventAt, h.at)
        session.hookSeenAt = max(session.hookSeenAt ?? h.at, h.at)
        if let cwd = h.cwd, !cwd.isEmpty { session.cwd = cwd }
        if let t = h.transcriptPath { session.transcriptPath = t }
        switch h.kind {
        case .sessionStart:
            if session.phase == .ended { session.phase = .yourTurn }
        case .promptSubmitted(let prompt, let title):
            session.prompted = true
            session.phase = .working
            session.doneCheck = nil
            if let title, !title.isEmpty { session.hookTitle = title }
            if session.promptTitle == nil, !prompt.isEmpty { session.promptTitle = Titles.fromPrompt(prompt) }
        case .stopped(let message):
            session.prompted = true
            session.lastMessage = message ?? session.lastMessage
            if case .limited = session.phase { break }
            session.phase = Reply.phase(after: session.lastMessage)
        case .stopFailed(let error):
            if error.contains("rate_limit") || error.contains("usage_limit") {
                session.phase = .limited(s.account(acct)?.limitResetsAt(now: h.at))
            } else {
                session.phase = .needsYou("Stopped on an error: \(error)")
            }
        case .notification(let type, let message):
            // idle_prompt repeats "waiting for your input" after a Stop we already handled.
            if type == "permission_prompt" || type == "elicitation_dialog" || (type.isEmpty && !message.isEmpty) {
                session.phase = .needsYou(message)
            }
        case .sessionEnd:
            session.phase = .ended
        }
        s.sessions[h.sessionId] = session

    case .usage(let u):
        guard let acct = s.accountId(forConfigDir: u.configDir), let i = s.accounts.firstIndex(where: { $0.id == acct }) else { return }
        if let prev = s.accounts[i].sampledAt, prev > u.at { return }
        if let w = u.fiveHour { s.accounts[i].fiveHour = w }
        if let w = u.week { s.accounts[i].week = w }
        s.accounts[i].sampledAt = u.at
        if let sid = u.sessionId, let tokens = u.contextTokens, tokens > 0 { s.sessions[sid]?.contextTokens = tokens }
        // A limit hit often lands before the sample that says when it resets.
        if let reset = s.accounts[i].limitResetsAt(now: u.at) {
            for (id, sess) in s.sessions where sess.accountId == acct && sess.phase == .limited(nil) {
                s.sessions[id]?.phase = .limited(reset)
            }
        }

    case .agents(let snap):
        let listed = Set(snap.entries.map(\.sessionId))
        s.listedAt[snap.accountId] = snap.at
        for e in snap.entries {
            var session = s.sessions[e.sessionId] ?? Session(
                id: e.sessionId, name: e.name, accountId: snap.accountId, cwd: e.cwd, at: e.startedAt,
                origin: s.startedByMaxwell.contains(e.sessionId) ? .maxwell : .external, reach: e.reach)
            session.name = e.name
            session.cwd = e.cwd
            session.reach = e.reach
            session.accountId = snap.accountId
            session.listedAt = snap.at
            session.listedStatus = e.status
            session.runningTasks = e.runningTasks
            s.closed[e.sessionId] = nil
            if let t = e.title { session.tabTitle = t }
            if e.used { session.prompted = true }
            if let m = e.lastMessage { session.lastMessage = m }
            if session.promptTitle == nil, let p = e.firstPrompt { session.promptTitle = Titles.fromPrompt(p) }
            // The transcript is written on every prompt and reply, including ones typed in another terminal.
            if let active = e.lastActiveAt { session.lastEventAt = max(session.lastEventAt, active) }
            switch e.status {
            case .busy:
                session.prompted = true
                if case .limited = session.phase {} else if session.phase != .working {
                    session.phase = .working
                    session.doneCheck = nil
                }
            case .waiting(let why):
                if case .needsYou = session.phase {} else { session.phase = .needsYou(why) }
            case .idle:
                switch session.phase {
                case .working, .ended, .yourTurn: session.phase = Reply.phase(after: session.lastMessage)
                case .needsYou, .limited: break
                }
            }
            s.sessions[e.sessionId] = session
        }
        // A session of this account that is no longer listed has exited.
        for (id, sess) in s.sessions where sess.accountId == snap.accountId && !listed.contains(id) && sess.phase != .ended {
            s.sessions[id]?.phase = .ended
        }

    case .doneCheck(let id, let check):
        guard var session = s.sessions[id] else { return }
        session.doneCheck = check
        if let b = check.branch { session.branch = b }
        s.sessions[id] = session

    case .judged(let hash, let j):
        s.judgments[hash] = j

    case .closed(let c):
        s.closed[c.session.id] = c
        s.sessions[c.session.id]?.phase = .ended
        // Hooks alone never say a session is a background one; the record does, so it can attach again.
        if case .background = c.session.reach { s.sessions[c.session.id]?.reach = c.session.reach }

    case .reopened(let id, _):
        // A session closed in an earlier run is known only from its record; keep it so it can attach.
        if let c = s.closed[id] {
            if s.sessions[id] == nil { s.sessions[id] = c.session }
            if case .background = c.session.reach { s.sessions[id]?.reach = c.session.reach }
        }
        s.closed[id] = nil

    case .markedNotSafe(let id, let at):
        s.sessions[id]?.markedNotSafeAt = at

    // Kept by id, not on the session: a move or dismissal can fold before the session's first hook.
    case .movedToProject(let id, let project):
        s.moved[id] = project

    case .projectSuggested(let id, let project):
        s.suggested[id] = project

    case .suggestionDismissed(let id, let project):
        s.dismissed[id, default: []].insert(project)

    case .started(let id, let acct, let name, let cwd, let shortId, let at):
        s.startedByMaxwell.insert(id)
        var session = s.sessions[id] ?? Session(id: id, name: name, accountId: acct, cwd: cwd, at: at, origin: .maxwell,
                                                reach: .background(shortId: shortId))
        session.origin = .maxwell
        s.sessions[id] = session
    }
}

/// What a stopped session's last reply leaves for you.
enum Reply: Equatable {
    case question(String)   // asks him something directly: needs you
    case offer(String)      // proposes a next step without a question mark: your turn, never safe
    case limitHit           // the reply is Claude Code's own "You've hit your limit" line
    case statement          // reports; nothing asked, offered or left for him to do

    static func phase(after message: String?) -> Phase {
        switch message.map(classify) {
        case .question(let q)?: return .needsYou(q)
        case .limitHit?: return .limited(nil)
        default: return .yourTurn
        }
    }

    /// Looks at the last few paragraphs, skipping trailers sessions often end with
    /// ("Linear: …", "Sources: …"), so a question above them still counts.
    static func classify(_ message: String) -> Reply {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("You've hit your") && trimmed.contains("limit") && trimmed.count < 200 { return .limitHit }
        let paragraphs = message.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !isTrailer($0) }
        let tail = Array(paragraphs.suffix(4))
        for p in tail.reversed() {
            for line in p.components(separatedBy: "\n").reversed() where !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                if let q = lastQuestion(in: line) { return .question(q) }
            }
        }
        for p in tail.reversed() {
            // Most paragraphs hold no phrase at all; only those get split into sentences.
            let lowerP = p.lowercased()
            guard offerPhrases.contains(where: lowerP.contains) else { continue }
            for sentence in sentences(p).reversed() {
                let lower = sentence.lowercased()
                if offerPhrases.contains(where: lower.contains) { return .offer(String(sentence.prefix(200))) }
            }
        }
        return .statement
    }

    /// Anything that hands work back to you or promises more. Broad on purpose: a false
    /// "your turn" costs a glance, a false "safe to close" loses work.
    static let offerPhrases = [
        "want me to", "should i ", "shall i ", "let me know", "if you ", "would you like", "do you want",
        "i can ", "i could ", "i'll ", "i will ", "next step", "next:", "happy to ", "say the word", "your call",
        "up to you", "when you", "once you", "ready when", "say go", "your go", "tell me", "give me", "send me",
        "paste ", "your pick", "waiting on you", "waiting for you", "still waiting", "still open", "todo", "to do:",
        "not yet", "follow-up", "follow up", "bescheid", "sag mir", "gib mir", "soll ich", "willst du", "möchtest du",
    ]

    private static func isTrailer(_ p: String) -> Bool {
        let l = p.lowercased().replacingOccurrences(of: "**", with: "")
        return ["linear:", "sources:", "source:", "linear —", "linear -"].contains { l.hasPrefix($0) }
    }

    /// The last sentence in a line that ends with "?" (allowing trailing **, ), quotes).
    private static func lastQuestion(in line: String) -> String? {
        guard line.contains("?") else { return nil }
        let clean = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        let ns = clean as NSString
        guard let m = questionPattern.matches(in: clean, range: NSRange(location: 0, length: ns.length)).last else { return nil }
        var q = ns.substring(with: m.range).trimmingCharacters(in: .whitespaces)
        while let f = q.first, "-*•>0123456789)".contains(f) { q = String(q.dropFirst()).trimmingCharacters(in: .whitespaces) }
        return q.count >= 4 ? String(q.prefix(200)) : nil
    }

    private static let questionPattern = try! NSRegularExpression(pattern: #"[^.!?\n]*\?(?=[)"'”]*(\s|$))"#)

    private static func sentences(_ p: String) -> [String] {
        p.replacingOccurrences(of: "**", with: "").components(separatedBy: CharacterSet(charactersIn: ".!\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// 90s -> "1m", 7200 -> "2h", 3 days -> "3d".
    static func span(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return s % 3600 == 0 || s >= 10 * 3600 ? "\(s / 3600)h" : "\(s / 3600)h\((s % 3600) / 60)m" }
        return "\(s / 86400)d"
    }
}

enum Titles {
    /// First words of a prompt, for sessions with no name yet.
    static func fromPrompt(_ prompt: String) -> String {
        let words = prompt.split(whereSeparator: { $0.isWhitespace }).prefix(6).joined(separator: " ")
        return words.count > 48 ? String(words.prefix(47)) + "…" : words
    }
}
