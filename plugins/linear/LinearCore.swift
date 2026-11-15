import Foundation

/// The Linear plugin's rules, with no I/O: which ticket a session works on, what to suggest,
/// and what to tell Maxwell. main.swift does the wire and the network around it.

/// A session as the plugin reads it from `sessions/changed`.
struct LinearSession: Equatable {
    var id: String
    var title: String
    var cwd: String
    var branch: String?
    var group: String?
    var phase: String
    var prState: String?
    var prNumber: Int?
    var transcriptPath: String?
    var lastEventAt: String

    init?(_ d: [String: Any]) {
        guard let id = d["id"] as? String else { return nil }
        self.id = id
        title = (d["title"] as? String) ?? (d["name"] as? String) ?? id
        cwd = (d["cwd"] as? String) ?? ""
        branch = d["branch"] as? String
        group = d["group"] as? String
        phase = (d["phase"] as? String) ?? ""
        let pr = d["pr"] as? [String: Any]
        prState = pr?["state"] as? String
        prNumber = (pr?["number"] as? NSNumber)?.intValue
        transcriptPath = d["transcriptPath"] as? String
        lastEventAt = (d["lastEventAt"] as? String) ?? ""
    }
}

struct LinearIssue: Equatable {
    struct State: Equatable { var id: String; var name: String; var type: String; var position: Double }
    var identifier: String
    /// Linear's own id; writes use it.
    var uuid: String
    var title: String
    var url: String
    var state: State
    /// The team's workflow, to find "In Progress" and "Done" by type rather than by name.
    var teamStates: [State]

    var isDone: Bool { ["completed", "canceled", "duplicate"].contains(state.type) }
    var notStarted: Bool { ["backlog", "unstarted", "triage"].contains(state.type) }

    /// The first state of a type in the team's order: "started" is In Progress, "completed" is Done.
    func target(_ type: String) -> State? { teamStates.filter { $0.type == type }.min { $0.position < $1.position } }

    static func parse(_ d: [String: Any]) -> LinearIssue? {
        guard let id = d["identifier"] as? String, let title = d["title"] as? String, let url = d["url"] as? String,
              let st = d["state"] as? [String: Any], let state = parseState(st) else { return nil }
        let states = (((d["team"] as? [String: Any])?["states"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []).compactMap(parseState)
        return LinearIssue(identifier: id, uuid: (d["id"] as? String) ?? id, title: title, url: url, state: state, teamStates: states)
    }
    private static func parseState(_ d: [String: Any]) -> State? {
        guard let id = d["id"] as? String, let name = d["name"] as? String, let type = d["type"] as? String else { return nil }
        return State(id: id, name: name, type: type, position: (d["position"] as? NSNumber)?.doubleValue ?? 0)
    }
}

enum LinearLink {
    /// "robin/acme-56-billing-totals" → "ACME-56". Linear's own branch format is `<user>/<key>-<n>-<slug>`;
    /// with known team keys, any segment that starts with one counts.
    static func fromBranch(_ branch: String?, teams: Set<String>) -> String? {
        guard let branch, !branch.isEmpty else { return nil }
        for seg in branch.split(separator: "/").reversed() {
            let parts = seg.split(separator: "-", maxSplits: 2)
            guard parts.count >= 2, let n = Int(parts[1]), n > 0 else { continue }
            let key = parts[0].uppercased()
            guard key.count >= 2, key.count <= 7, key.allSatisfy({ $0.isLetter || $0.isNumber }), key.first!.isLetter else { continue }
            if teams.isEmpty || teams.contains(key) { return "\(key)-\(n)" }
        }
        return nil
    }

    static let idPattern = try! NSRegularExpression(pattern: "\\b([A-Z][A-Z0-9]{1,6})-([0-9]{1,6})\\b")

    static func ids(in text: String, teams: Set<String>) -> [String] {
        let ns = text as NSString
        return idPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let key = ns.substring(with: m.range(at: 1))
            return teams.isEmpty || teams.contains(key) ? ns.substring(with: m.range) : nil
        }
    }
}

/// What a session's transcript says about tickets, read line by line as the file grows.
/// Votes: a Linear call that changes a ticket (status, comment, attachment) 3; Robin naming a
/// ticket in a prompt 2; reading one 1; creating one 1 (filing tickets isn't working on them).
/// Text Claude Code injects (CLAUDE.md, system reminders) never counts: it names example tickets.
struct TranscriptVotes: Equatable {
    var scores: [String: Int] = [:]
    var offset: UInt64 = 0
    /// Linear tool calls waiting for their result (the id of a created ticket is in the result).
    var creating: Set<String> = []

    static let writes: Set<String> = ["save_issue", "update_issue", "save_comment", "create_comment", "create_attachment", "save_attachment"]

    /// The ticket the session works on: at least 3 votes and twice the runner-up, else none.
    func winner() -> String? {
        let sorted = scores.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        guard let top = sorted.first, top.value >= 3 else { return nil }
        if sorted.count > 1, sorted[1].value * 2 > top.value { return nil }
        return top.key
    }

    private static let linear = Data("inear__".utf8), toolResult = Data("\"tool_result\"".utf8), userType = Data("\"type\":\"user\"".utf8)
    private static let idLike = try! NSRegularExpression(pattern: "[A-Z][A-Z0-9]{1,6}-[0-9]")

    /// A cheap look at raw bytes before parsing: a Linear tool call, a tool result while a created
    /// ticket's id is awaited, or a prompt with something shaped like a ticket id.
    static func worthParsing(_ line: Data, pending: Bool) -> Bool {
        if line.range(of: linear) != nil { return true }
        let isResult = line.range(of: toolResult) != nil
        if isResult { return pending }
        guard line.range(of: userType) != nil, line.count < 200_000 else { return false }
        let s = String(decoding: line, as: UTF8.self)
        return idLike.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    mutating func feed(_ line: Substring, teams: Set<String>) {
        guard line.contains("\"type\""), let d = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return }
        // Injected text: meta lines, and compaction summaries that repeat every ticket id seen so far.
        if d["isMeta"] as? Bool == true || d["isCompactSummary"] as? Bool == true { return }
        let message = d["message"] as? [String: Any]
        switch d["type"] as? String {
        case "user":
            if let s = message?["content"] as? String { prompt(s, teams) }
            for item in (message?["content"] as? [[String: Any]]) ?? [] {
                switch item["type"] as? String {
                case "text": prompt((item["text"] as? String) ?? "", teams)
                case "tool_result":
                    guard let id = item["tool_use_id"] as? String, creating.remove(id) != nil else { continue }
                    let text = Self.text(item["content"])
                    if let created = LinearLink.ids(in: text, teams: teams).first { scores[created, default: 0] += 1 }
                default: break
                }
            }
        case "assistant":
            for item in (message?["content"] as? [[String: Any]]) ?? [] where item["type"] as? String == "tool_use" {
                guard let name = item["name"] as? String, let tool = Self.linearTool(name) else { continue }
                let input = (item["input"] as? [String: Any]) ?? [:]
                let target = ["id", "issueId", "issue", "identifier"].lazy.compactMap { input[$0] as? String }.first { !LinearLink.ids(in: $0, teams: teams).isEmpty }
                if let t = target.flatMap({ LinearLink.ids(in: $0, teams: teams).first }) {
                    scores[t, default: 0] += Self.writes.contains(tool) ? 3 : tool.hasPrefix("get_") ? 1 : 0
                } else if tool == "save_issue" || tool == "create_issue", let id = item["id"] as? String {
                    creating.insert(id)
                }
            }
        default: break
        }
    }

    private mutating func prompt(_ s: String, _ teams: Set<String>) {
        guard !s.contains("<system-reminder>"), !s.hasPrefix("<command-"), !s.hasPrefix("Caveat:"),
              !s.hasPrefix("This session is being continued from a previous conversation") else { return }
        for id in Set(LinearLink.ids(in: s, teams: teams)) { scores[id, default: 0] += 2 }
    }

    /// "mcp__linear__save_issue", "mcp__claude_ai_Linear__save_comment" → the tool's own name.
    static func linearTool(_ name: String) -> String? {
        guard name.hasPrefix("mcp__"), let r = name.range(of: "inear__") else { return nil }
        let server = name[name.index(name.startIndex, offsetBy: 5)..<r.lowerBound]
        guard server.lowercased().hasSuffix("l") else { return nil }
        return String(name[r.upperBound...])
    }

    private static func text(_ any: Any?) -> String {
        if let s = any as? String { return s }
        return ((any as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
}

/// A status move or comment the plugin offers for one session's ticket.
struct LinearSuggestion: Equatable {
    enum Kind: Equatable { case start, prOpened(Int), done(Int?) }
    var kind: Kind
    var session: String
    var issue: String

    /// Stable id, for "Not now" and for not suggesting the same thing twice.
    var key: String {
        switch kind {
        case .start: return "\(issue)/start"
        case .prOpened(let n): return "\(issue)/pr-\(n)"
        case .done: return "\(issue)/done"
        }
    }
    var action: String {
        switch kind {
        case .start: return "move-started"
        case .prOpened: return "comment-pr"
        case .done: return "move-done"
        }
    }
    func title(_ i: LinearIssue) -> String {
        switch kind {
        case .start: return "Move to \(i.target("started")?.name ?? "In Progress")"
        case .prOpened(let n): return "Comment PR #\(n)"
        case .done: return "Move to \(i.target("completed")?.name ?? "Done")"
        }
    }
    func why(_ s: LinearSession) -> String {
        switch kind {
        case .start: return "work started in \(s.title)"
        case .prOpened(let n): return "PR #\(n) is open"
        case .done(let n?): return "PR #\(n) merged"
        case .done(nil): return "merged"
        }
    }
}

enum LinearRules {
    /// Robin's three moments: work starts (In Progress), a PR opens (a comment), the PR merges (Done).
    static func suggestions(_ s: LinearSession, _ i: LinearIssue, settled: Set<String>) -> [LinearSuggestion] {
        var out: [LinearSuggestion] = []
        if i.notStarted, s.phase != "ended", i.target("started") != nil { out.append(.init(kind: .start, session: s.id, issue: i.identifier)) }
        if s.prState == "open", let n = s.prNumber, !i.isDone { out.append(.init(kind: .prOpened(n), session: s.id, issue: i.identifier)) }
        if s.prState == "merged", !i.isDone, i.target("completed") != nil { out.append(.init(kind: .done(s.prNumber), session: s.id, issue: i.identifier)) }
        return out.filter { !settled.contains($0.key) }
    }

    static func tone(_ i: LinearIssue) -> String {
        switch i.state.type {
        case "completed": return "good"
        case "started": return "info"
        default: return "neutral"
        }
    }

    /// The "Linear ticket done" check. With a key there is always a check, and anything short of a
    /// fresh read of a done ticket is fail or unknown. Without a key the plugin has no say: nil.
    static func check(issueId: String, issue: LinearIssue?, error: String?, fetchedAt: Date?, now: Date, hasKey: Bool, connected: Bool) -> [String: Any]? {
        guard hasKey else { return nil }
        let at = fetchedAt.map { Self.clock($0) } ?? "never"
        var c: [String: Any] = ["id": "ticket-done", "title": "Linear ticket done", "source": "Linear API \(at)", "outcome": "unknown"]
        if !connected {
            c["detail"] = "not connected to Linear"
        } else if let error {
            c["detail"] = "couldn't read \(issueId): \(error)"
        } else if let issue, let f = fetchedAt, now.timeIntervalSince(f) < 600 {
            c["outcome"] = issue.isDone ? "pass" : "fail"
            c["detail"] = "\(issue.identifier) is \(issue.state.name)"
        } else {
            c["detail"] = issue == nil ? "\(issueId) not read yet" : "last read over 10 minutes ago"
        }
        return c
    }

    /// Everything the plugin says about one session (`session/annotate`).
    static func annotation(_ s: LinearSession, issueId: String?, issue: LinearIssue?, error: String?, fetchedAt: Date?,
                           now: Date, hasKey: Bool, connected: Bool, pending: [LinearSuggestion]) -> [String: Any] {
        guard let issueId else { return ["session": s.id] }
        var badgeText = issueId
        var tooltip = hasKey ? "\(issueId): reading from Linear…" : "\(issueId), from the branch. Connect Linear to see its status."
        var badgeTone = "neutral"
        var fields: [[String: Any]] = []
        if let issue {
            badgeText = "\(issueId) · \(issue.state.name)"
            badgeTone = pending.isEmpty ? tone(issue) : "warn"
            tooltip = issue.title + (pending.isEmpty ? "" : "\nSuggested: " + pending.map { $0.title(issue) }.joined(separator: ", "))
            fields.append(["label": "Ticket", "value": "\(issueId) \(issue.title)", "url": issue.url])
            fields.append(["label": "Status", "value": issue.state.name])
        }
        var actions = issue == nil ? [String]() : ["open-ticket"]
        actions += pending.map(\.action)
        var a: [String: Any] = ["session": s.id, "badges": [["text": badgeText, "tone": badgeTone, "tooltip": tooltip, "action": issue == nil ? NSNull() : "open-ticket"] as [String: Any]],
                                "fields": fields, "actions": actions]
        if let c = check(issueId: issueId, issue: issue, error: error, fetchedAt: fetchedAt, now: now, hasKey: hasKey, connected: connected) { a["checks"] = [c] }
        return a
    }

    static func clock(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

/// The Linear panel: every ticket that matters to you (yours, or one a session is on), grouped by
/// status, each with the state of its sessions. Suggested moves come first.
enum LinearBoard {
    /// Most urgent first: what a ticket's badge shows when it has several sessions.
    static let urgency = ["needsYou", "yourTurn", "limited", "working", "safeToClose", "idle"]
    static let groupNames = ["needsYou": "needs you", "yourTurn": "your turn", "working": "working", "limited": "limited", "safeToClose": "safe to close", "idle": "idle"]
    static let groupTone = ["needsYou": "bad", "yourTurn": "warn", "safeToClose": "good"]

    static func view(mine: [LinearIssue], issues: [String: LinearIssue], links: [String: String], sessions: [String: LinearSession],
                     suggested: [[String: Any]], connected: Bool) -> [String: Any] {
        var tickets: [String: LinearIssue] = [:]
        var order: [String] = []
        for i in mine + links.values.compactMap({ issues[$0] }) where tickets[i.identifier] == nil {
            tickets[i.identifier] = i
            order.append(i.identifier)
        }
        var byTicket: [String: [LinearSession]] = [:]
        for (sid, t) in links { if let s = sessions[sid] { byTicket[t, default: []].append(s) } }
        // Linked tickets not read yet still show, by id.
        let unread = Set(byTicket.keys).subtracting(tickets.keys).sorted()

        func rank(_ s: LinearSession) -> Int { urgency.firstIndex(of: s.group ?? "") ?? urgency.count }
        func row(_ id: String, _ issue: LinearIssue?) -> [String: Any] {
            let ss = (byTicket[id] ?? []).sorted { rank($0) < rank($1) }
            var r: [String: Any] = ["id": "issue:\(id)", "title": "\(id) \(issue?.title ?? "")", "actions": issue == nil ? [] : [["action": "open-ticket", "title": "Open"]]]
            if let top = ss.first {
                r["session"] = top.id
                let g = top.group ?? "idle"
                r["badge"] = ["text": groupNames[g] ?? g, "tone": groupTone[g] ?? "neutral"]
                r["subtitle"] = ss.count == 1 ? top.title : "\(ss.count) sessions · " + summary(ss)
            } else {
                r["subtitle"] = "no session"
                if let u = issue?.url { r["url"] = u }
            }
            return r
        }
        func summary(_ ss: [LinearSession]) -> String {
            var n: [String: Int] = [:]
            for s in ss { n[s.group ?? "idle", default: 0] += 1 }
            return urgency.compactMap { g in n[g].map { "\($0) \(groupNames[g] ?? g)" } }.joined(separator: ", ")
        }
        func withSessionsFirst(_ ids: [String]) -> [String] {
            ids.enumerated().sorted { a, b in
                let ra = byTicket[a.element].map { $0.map(rank).min() ?? 99 } ?? 99, rb = byTicket[b.element].map { $0.map(rank).min() ?? 99 } ?? 99
                return ra != rb ? ra < rb : a.offset < b.offset
            }.map(\.element)
        }

        var sections: [[String: Any]] = []
        if !suggested.isEmpty { sections.append(["title": "Suggested", "rows": suggested]) }
        let groups: [(String, Set<String>)] = [("In progress", ["started"]), ("Todo", ["unstarted"]), ("Backlog", ["backlog", "triage"]),
                                               ("Done this week", ["completed"])]
        for (title, types) in groups {
            let ids = withSessionsFirst(order.filter { types.contains(tickets[$0]!.state.type) })
            if !ids.isEmpty { sections.append(["title": "\(title)  \(ids.count)", "rows": ids.map { row($0, tickets[$0]) }]) }
        }
        if !unread.isEmpty { sections.append(["title": "Reading from Linear…", "rows": unread.map { row($0, nil) }]) }
        if sections.isEmpty {
            return connected
                ? ["type": "empty", "title": "No open tickets.", "body": "Tickets assigned to you, and any a session works on, show here."]
                : ["type": "empty", "title": "No session is on a ticket.", "body": "Connect Linear to see all your tickets here."]
        }
        return ["type": "list", "sections": sections]
    }
}
