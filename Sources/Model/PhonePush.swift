import Foundation

/// Which sessions are news for a push: a Needs you that wasn't asked before (docs/phone.md, "Pushes").
/// The first look after launch only learns what already waits, so a restart doesn't push them all again.
struct PushPlanner {
    private var asked: [SessionID: String] = [:]
    private var primed = false

    /// Sessions that started asking something new since the last look, with what they ask.
    mutating func news(_ state: AppState, rules: GroupRules, now: Date) -> [(Session, PhoneAsk)] {
        var out: [(Session, PhoneAsk)] = []
        var still: [SessionID: String] = [:]
        for s in state.sessions.values where state.group(s, now: now, rules: rules) == .needsYou {
            guard case .needsYou(let q) = s.phase, let ask = PhoneAsk.of(s) else { continue }
            still[s.id] = q
            if primed, asked[s.id] != q { out.append((s, ask)) }
        }
        // A session that stopped asking and asks the same thing again later is news again.
        asked = still
        primed = true
        return out.sorted { $0.0.lastEventAt < $1.0.lastEventAt }
    }

    /// What a push says on the lock screen (`hello`'s `pushDetail`). Hidden until the phone asks for full:
    /// titles and bodies pass through Expo and Apple readable.
    enum Detail: String, Codable { case full, hidden }

    /// One Expo push message for one phone.
    /// What a session asks, in a push's words, and the push's category.
    static func line(_ ask: PhoneAsk) -> (category: String, body: String) {
        switch ask {
        case .permission(let tool, let command):
            return ("permission", tool == "Bash" && !command.isEmpty ? "Run \(command)?" : command.isEmpty ? "Allow \(tool.isEmpty ? "a tool" : tool)?" : "Allow \(tool): \(command)?")
        case .question(let text, _):
            return ("question", text)
        }
    }

    static func message(to token: String, session s: Session, ask: PhoneAsk, counts: [String: Int], now: Date, detail: Detail = .hidden) -> [String: Any] {
        var (category, body) = line(ask)
        var title = "\(s.title) needs you"
        if detail == .hidden { title = "Maxwell"; body = "A session needs you" }
        return [
            "to": token, "title": title, "body": String(body.prefix(240)),
            "categoryId": category, "mutableContent": true, "threadId": s.id, "sound": "default",
            "data": ["session": s.id, "counts": counts, "at": PhoneState.iso.string(from: now)] as [String: Any],
        ]
    }
}
