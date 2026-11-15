import Foundation

/// Which session works on which Slack message. Made by Start Session; kept on this Mac.
struct Links: Codable, Equatable {
    struct Link: Codable, Equatable {
        var session: String
        var at: Date
        var who: String
        var place: String
        var url: String
    }
    var byKey: [String: Link] = [:]

    func key(forSession sid: String) -> String? { byKey.first { $0.value.session == sid }?.key }

    /// Links whose session is gone, or that are older than the look-back, can't be checked any more.
    mutating func prune(sessions: Set<String>?, before: Date) {
        byKey = byKey.filter { $0.value.at > before && (sessions?.contains($0.value.session) ?? true) }
    }

    static func load(_ url: URL) -> Links {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder.iso.decode(Links.self, from: $0) } ?? Links()
    }
    func save(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.iso.encode(self).write(to: url, options: .atomic)
    }
}

/// Where a Slack item stands, in the words both plugins use (issue #1).
enum ItemStatus: String {
    case needsYou, inSession, owed, readyToClose, done
}

enum Loop {
    /// Did I write in the item's conversation (its thread, or the DM's top level) after `after`?
    /// Nil when the snapshot doesn't hold that conversation, so the answer is unknown.
    static func replied(_ s: Snapshot, key: String, after: Date) -> Bool? {
        guard let c = s.conversations.first(where: { key.hasPrefix($0.id + ":") }) else { return nil }
        let root = String(key.dropFirst(c.id.count + 1))
        return c.messages.contains { m in
            m.user == s.me && m.date > after && (root == "top" ? !m.isReply : m.threadTs == root)
        }
    }

    /// A linked item's status from its session's sidebar group.
    static func status(_ w: Waiting?, link: Links.Link?, group: String?, replied: Bool?) -> ItemStatus {
        guard link != nil else { return w?.state == .owed ? .owed : .needsYou }
        if replied == true { return .done }
        switch group {
        case "working", "needsYou", "limited": return .inSession
        case nil: return w?.state == .owed ? .owed : .needsYou     // the session is gone
        default: return .readyToClose                               // your turn, safe to close, idle
        }
    }

    /// What the linked session shows: a badge, and a Safe-to-close check that holds it until I've replied.
    static func annotation(session: String, link: Links.Link, replied: Bool?, checkedAt: Date?) -> [String: Any] {
        let outcome = replied.map { $0 ? "pass" : "fail" } ?? "unknown"
        let detail = replied == true ? "you answered \(link.who)" : replied == false ? "\(link.who) is still waiting (\(link.place))" : "Slack hasn't been read yet"
        let source = checkedAt.map { "Slack " + Panel.clock($0) } ?? "Slack"
        return [
            "session": session,
            "badges": [["text": "Slack · \(link.who)", "tone": replied == true ? "good" : "warn",
                        "tooltip": "Started from \(link.who)'s message in \(link.place)"]],
            "fields": [["label": "Slack", "value": "\(link.who) in \(link.place)", "url": link.url]],
            "checks": [["id": "replied-slack", "title": "Replied on Slack", "outcome": outcome, "detail": detail, "source": source]],
        ]
    }
}
