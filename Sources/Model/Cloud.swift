import Foundation

/// Claude Code sessions that run on Anthropic's cloud machines (`claude --cloud`, claude.ai/code),
/// as one account's Sessions API lists them. Read, never guessed: a status Maxwell doesn't know
/// stays `unknown` and shows as such.
struct CloudSnapshot: Equatable {
    var at: Date
    var accountId: AccountID
    var sessions: [CloudSession]
}

struct CloudSession: Equatable {
    let id: SessionID                 // session_…
    var title: String
    var url: String                   // its claude.ai/code page
    var status: Status
    var summary: Summary?             // Claude's own note on the last turn
    var branch: String?
    var repo: String?                 // owner/name, when it works on a GitHub repository
    var createdAt: Date
    var updatedAt: Date
    /// The local checkout of `repo`, found on this Mac; not from the API.
    var folder: String? = nil

    enum Status: Equatable {
        case pending, running, idle, needsAnswer, requiresAction, paused, failed, archived
        case unknown(String)
    }

    /// `post_turn_summary`: what the turn ended on, in Claude's words.
    struct Summary: Equatable {
        var category: String          // working, completed, review_ready, needs_action, blocked, failed
        var detail: String            // "replied 'done' as requested"
        var needs: String             // what it needs from you, empty when nothing
    }

    /// The phase Maxwell's groups use. A turn that ended asking something needs you; one that
    /// ended with a result is your turn; a running or queued one is working.
    var phase: Phase {
        switch status {
        case .pending, .running: return .working
        case .needsAnswer, .requiresAction: return .needsYou(nonEmpty(summary?.needs) ?? "Waiting for your answer")
        case .failed: return .needsYou("Stopped on an error" + (nonEmpty(summary?.detail).map { " · " + $0 } ?? ""))
        case .archived: return .ended
        case .paused, .unknown: return .yourTurn
        case .idle:
            switch summary?.category {
            case "needs_action"?, "blocked"?: return .needsYou(nonEmpty(summary?.needs) ?? nonEmpty(summary?.detail) ?? "Waiting for you")
            case "failed"?: return .needsYou("Stopped on an error" + (nonEmpty(summary?.detail).map { " · " + $0 } ?? ""))
            default: return .yourTurn
            }
        }
    }

    /// Where the phase came from, for the banner's tip and `Maxwell state`.
    var phaseSource: String {
        let s: String
        switch status {
        case .pending: s = "pending"
        case .running: s = "running"
        case .idle: s = "idle"
        case .needsAnswer: s = "needs an answer"
        case .requiresAction: s = "requires action"
        case .paused: s = "paused"
        case .failed: s = "failed"
        case .archived: s = "archived"
        case .unknown(let raw): s = "unknown status \(raw)"
        }
        return "Claude Code cloud: " + s + (summary.map { " · " + $0.category } ?? "")
    }
}

extension Session {
    var isCloud: Bool { if case .cloud = reach { return true }; return false }
}

private func nonEmpty(_ s: String?) -> String? {
    guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
    return t
}

enum CloudParser {
    /// `GET /v1/sessions`: the account's sessions, cloud ones only. Remote Control sessions (kind
    /// `bridge`) run on a computer and are listed by `claude agents` there.
    static func parse(_ data: Data, accountId: AccountID, at: Date) -> CloudSnapshot? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = o["data"] as? [[String: Any]] else { return nil }
        return CloudSnapshot(at: at, accountId: accountId, sessions: list.compactMap(session))
    }

    static func session(_ d: [String: Any]) -> CloudSession? {
        guard d["environment_kind"] as? String == "anthropic_cloud", let id = d["id"] as? String else { return nil }
        let meta = d["external_metadata"] as? [String: Any]
        let pts = (d["post_turn_summary"] ?? meta?["post_turn_summary"]) as? [String: Any]
        let summary = pts.flatMap { p -> CloudSession.Summary? in
            guard let c = p["status_category"] as? String else { return nil }
            return .init(category: c, detail: p["status_detail"] as? String ?? "", needs: p["needs_action"] as? String ?? "")
        }
        let branches = meta?["current_branches"] as? [String: String]
        let sources = (d["session_context"] as? [String: Any])?["sources"] as? [[String: Any]]
        let repo = sources?.compactMap { ($0["url"] as? String).flatMap(repoName) }.first
        return CloudSession(id: id, title: d["title"] as? String ?? id, // The list leaves session_url empty; the page is claude.ai/code/<id>, as `claude --cloud` prints it.
                            url: nonEmpty(d["session_url"] as? String) ?? "https://claude.ai/code/\(id)",
                            status: status(d["session_status"] as? String), summary: summary,
                            branch: branches?.values.first(where: { !$0.isEmpty }), repo: repo,
                            createdAt: date(d["created_at"]) ?? .distantPast, updatedAt: date(d["updated_at"]) ?? .distantPast)
    }

    static func status(_ s: String?) -> CloudSession.Status {
        switch s {
        case "pending"?: return .pending
        case "running"?: return .running
        case "idle"?: return .idle
        case "needs_answer"?: return .needsAnswer
        case "requires_action"?: return .requiresAction
        case "paused"?: return .paused
        case "failed"?: return .failed
        case "archived"?: return .archived
        default: return .unknown(s ?? "none")
        }
    }

    /// "https://github.com/acme/web.git" or "git@github.com:acme/web.git" → "acme/web".
    static func repoName(_ url: String) -> String? {
        var u = url.trimmingCharacters(in: .whitespaces)
        if u.hasSuffix(".git") { u.removeLast(4) }
        guard let r = u.range(of: "github.com[/:]", options: .regularExpression) else { return nil }
        let rest = u[r.upperBound...].split(separator: "/")
        return rest.count >= 2 ? "\(rest[0])/\(rest[1])" : nil
    }

    /// What `claude --cloud "<task>"` prints: "Created cloud session: <title>", "View: <url>",
    /// "Resume with: claude --teleport <id>".
    static func created(_ output: String) -> (id: SessionID, title: String, url: String)? {
        let plain = output.replacingOccurrences(of: #"\u{1B}\[[0-9;?<>]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
        func after(_ label: String) -> String? {
            plain.components(separatedBy: .newlines).first { $0.contains(label) }
                .map { ($0.components(separatedBy: label).last ?? "").trimmingCharacters(in: .whitespaces) }
        }
        guard let id = after("claude --teleport ")?.split(separator: " ").first.map(String.init), id.hasPrefix("session_") || id.hasPrefix("cse_") else { return nil }
        let url = after("View: ")?.split(separator: " ").first.map(String.init) ?? "https://claude.ai/code/\(id)"
        return (id, after("Created cloud session: ") ?? id, url)
    }

    private static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    /// "2026-11-15T22:38:52.629070Z": microseconds, which the formatter doesn't read, so cut to milliseconds.
    private static func date(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        let ms = s.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        return iso.date(from: ms) ?? ISO8601DateFormatter().date(from: s)
    }
}
