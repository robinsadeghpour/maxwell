import Foundation

/// An artifact a session made or showed, as the phone lists it.
struct PhoneArtifact: Equatable {
    var url: String
    var title: String?
    var session: SessionID
    var account: AccountID
    var at: Date
}

/// What a waiting session asks, in the shape the phone answers it: a permission prompt (Allow,
/// Allow always, Deny) or a question (a reply).
enum PhoneAsk: Equatable {
    case permission(tool: String, detail: String)
    case question(String, options: [String])

    var json: [String: Any] {
        switch self {
        case .permission(let tool, let detail): return ["kind": "permission", "tool": tool, "detail": detail]
        case .question(let text, let options): return ["kind": "question", "text": text, "options": options]
        }
    }

    /// Claude Code's waits that a permission answer (1, 2, Esc) settles.
    static let permissionWaits: Set<String> = ["permission prompt", "permission", "worker request", "sandbox request"]

    /// The ask behind a Needs you session, best words first: Claude Code's own ("approve Bash: curl …"),
    /// then a permission hook's ("Claude needs your permission to use Bash"), then the question.
    static func of(_ s: Session) -> PhoneAsk? {
        guard case .needsYou(let q) = s.phase else { return nil }
        var waitingFor: String?
        if case .waiting(let w)? = s.listedStatus { waitingFor = w }
        let permission = waitingFor.map(permissionWaits.contains) ?? (q.hasPrefix("approve ") || q.contains("needs your permission"))
        guard permission else { return .question(q, options: []) }
        if q.hasPrefix("approve "), let colon = q.firstIndex(of: ":") {
            let tool = q[q.index(q.startIndex, offsetBy: 8)..<colon].trimmingCharacters(in: .whitespaces)
            return .permission(tool: tool, detail: q[q.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        if let r = q.range(of: "permission to use ") {
            return .permission(tool: q[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)), detail: "")
        }
        return .permission(tool: "", detail: q)
    }
}

/// How the phone can reach a session's terminal (docs/phone.md, `reach`).
extension Reach {
    var phoneName: String {
        switch self {
        case .background: return "background"
        case .elsewhere: return "terminal"
        case .cloud: return "cloud"
        }
    }
}

/// The whole picture sent to the phone as `state` (docs/phone.md). Pure: everything it needs is passed in.
enum PhoneState {
    struct Input {
        var state: AppState
        var rules: GroupRules
        var projects: Projects
        var pinned: [String]
        var folders: [ProjectFolder]
        var webSignedIn: Set<String>
        /// Each account's Claude login email, where Maxwell could read it.
        var emails: [AccountID: String] = [:]
        var artifacts: [PhoneArtifact]
        var macName: String
        var rev: Int
        var now: Date
    }

    static let iso: ISO8601DateFormatter = ISO8601DateFormatter()

    static func payload(_ i: Input) -> [String: Any] {
        [
            "t": "state", "rev": i.rev, "mac": ["name": i.macName], "at": iso.string(from: i.now),
            "accounts": accounts(i), "sessions": sessions(i), "projects": projects(i),
            "artifacts": i.artifacts.sorted { $0.at > $1.at }.prefix(200).map { a in
                ["url": a.url, "title": a.title ?? NSNull(), "session": a.session, "account": a.account, "at": iso.string(from: a.at)] as [String: Any]
            },
        ]
    }

    static func sessions(_ i: Input) -> [[String: Any]] {
        i.state.grouped(now: i.now, rules: i.rules).flatMap { group, list in
            list.map { session($0, group: group, i) }
        }
    }

    static func session(_ s: Session, group: PhaseGroup, _ i: Input) -> [String: Any] {
        var d = PluginHost.json(s, state: i.state, group: group, project: i.state.project(s, in: i.projects))
        // The phone shows the start of the reply; the conversation tab has all of it.
        d["lastMessage"] = s.lastMessage.map { String($0.prefix(1500)) } ?? NSNull()
        d["ask"] = group == .needsYou ? PhoneAsk.of(s)?.json ?? NSNull() : NSNull()
        d["checks"] = group == .yourTurn || group == .safeToClose
            ? i.state.checks(s, now: i.now, rules: i.rules).map { ["name": $0.title, "ok": $0.outcome == .pass, "detail": $0.detail] as [String: Any] }
            : [[String: Any]]()
        if case .limited(let reset) = s.phase, let reset { d["limitResetsAt"] = iso.string(from: reset) } else { d["limitResetsAt"] = NSNull() }
        d["contextPercent"] = s.contextPercent.map { min(100, max(0, $0)) } ?? NSNull()
        d["reach"] = s.reach.phoneName
        d["pinned"] = i.state.pins.contains(s.id)
        return d
    }

    static func accounts(_ i: Input) -> [[String: Any]] {
        let most = i.state.roomiest(now: i.now)?.id ?? i.state.accounts.first?.id
        func window(_ w: UsageWindow?) -> Any {
            w.map { ["percent": Int($0.usedPercent.rounded()), "resetsAt": iso.string(from: $0.resetsAt)] as [String: Any] } ?? NSNull()
        }
        return i.state.accounts.map { a in
            ["id": a.id, "name": a.name, "email": i.emails[a.id] ?? NSNull(), "fiveHour": window(a.fiveHour), "week": window(a.week),
             "sampledAt": a.sampledAt.map(iso.string) ?? NSNull(), "limited": a.limitResetsAt(now: i.now) != nil,
             "mostRoom": a.id == most, "webSignedIn": i.webSignedIn.contains(a.name)]
        }
    }

    /// Each folder a session can start in once, pinned projects first in rail order.
    static func projects(_ i: Input) -> [[String: Any]] {
        var seen = Set<String>()
        let rank = { (name: String) in i.pinned.firstIndex(of: name) ?? Int.max }
        let list = i.folders.filter { seen.insert($0.path).inserted }.enumerated().sorted { a, b in
            rank(a.element.project) != rank(b.element.project) ? rank(a.element.project) < rank(b.element.project) : a.offset < b.offset
        }
        return list.prefix(200).map { ["name": $0.element.project, "folder": $0.element.path, "pinned": i.pinned.contains($0.element.project)] }
    }

    /// How many sessions sit in each group, for the phone's widgets.
    static func counts(_ state: AppState, rules: GroupRules, now: Date) -> [String: Int] {
        var c = ["needsYou": 0, "yourTurn": 0, "working": 0, "limited": 0, "safeToClose": 0]
        for s in state.sessions.values {
            guard let g = state.group(s, now: now, rules: rules), c["\(g)"] != nil else { continue }
            c["\(g)", default: 0] += 1
        }
        return c
    }
}
