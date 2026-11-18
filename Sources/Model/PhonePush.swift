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

    /// One Expo push message for one phone.
    static func message(to token: String, session s: Session, ask: PhoneAsk, counts: [String: Int], now: Date) -> [String: Any] {
        let body: String, category: String
        switch ask {
        case .permission(let tool, let detail):
            category = "permission"
            body = tool == "Bash" && !detail.isEmpty ? "Run \(detail)?" : detail.isEmpty ? "Allow \(tool.isEmpty ? "a tool" : tool)?" : "Allow \(tool): \(detail)?"
        case .question(let text, _):
            category = "question"
            body = text
        }
        return [
            "to": token, "title": "\(s.title) needs you", "body": String(body.prefix(240)),
            "categoryId": category, "mutableContent": true, "threadId": s.id, "sound": "default",
            "data": ["session": s.id, "counts": counts, "at": PhoneState.iso.string(from: now)] as [String: Any],
        ]
    }
}
