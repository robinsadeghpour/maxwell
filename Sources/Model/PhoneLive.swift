import Foundation

/// What the iPhone's Live Activity shows, sent to the relay for each phone that turned it on
/// (docs/phone.md, "Live Activity"). Plain, not boxed: the relay pushes it to Apple, so it reads the
/// counts, and for a phone that asked for full details the newest Needs you session's title and ask.
enum PhoneLive {
    /// A paired phone as the Live Activity sees it: whether it wants one, and how much it may show.
    struct Phone {
        var id: String
        var live: Bool
        var detail: PushPlanner.Detail
    }

    /// One `{"to": "<phone id>", "live": {…} | null}` frame, and what it says without its time.
    struct Frame {
        var phone: String
        var key: String
        var frame: [String: Any]
    }

    static let offKey = "off"

    /// The `live` object for one phone.
    static func payload(_ state: AppState, rules: GroupRules, now: Date, macName: String, detail: PushPlanner.Detail) -> [String: Any] {
        let c = PhoneState.counts(state, rules: rules, now: now)
        var limited: [(Date, Session)] = []
        var needing: [Session] = []
        for s in state.sessions.values {
            switch state.group(s, now: now, rules: rules) {
            case .limited?: if case .limited(let reset?) = s.phase { limited.append((reset, s)) }
            case .needsYou?: needing.append(s)
            default: break
            }
        }
        let reset = limited.min { $0.0 < $1.0 }
        let top = detail == .full ? needing.max { $0.lastEventAt < $1.lastEventAt } : nil
        return [
            "counts": ["needsYou": c["needsYou"] ?? 0, "yourTurn": c["yourTurn"] ?? 0, "working": c["working"] ?? 0, "limited": c["limited"] ?? 0],
            "nextReset": reset.map { ["at": ms($0.0), "account": state.account($0.1.accountId)?.name ?? ""] as [String: Any] } ?? NSNull(),
            "top": top.map { s in
                ["session": s.id, "title": String(s.title.prefix(80)), "ask": PhoneAsk.of(s).map { String(PushPlanner.line($0).body.prefix(160)) } ?? NSNull()] as [String: Any]
            } ?? NSNull(),
            "mac": macName,
            "at": ms(now),
        ]
    }

    /// The frames to send now: a phone whose picture changed since `sent`, and `null` once for a
    /// phone that turned it off. `sent` holds each phone's last key; the caller records what went out.
    static func frames(_ phones: [Phone], state: AppState, rules: GroupRules, now: Date, macName: String, sent: [String: String]) -> [Frame] {
        phones.compactMap { p in
            guard p.live else {
                guard let last = sent[p.id], last != offKey else { return nil }
                return Frame(phone: p.id, key: offKey, frame: ["to": p.id, "live": NSNull()])
            }
            let live = payload(state, rules: rules, now: now, macName: macName, detail: p.detail)
            let k = key(live)
            return k == sent[p.id] ? nil : Frame(phone: p.id, key: k, frame: ["to": p.id, "live": live])
        }
    }

    /// What a `live` object says, without when: the same key is nothing new.
    static func key(_ live: [String: Any]) -> String {
        var l = live
        l["at"] = nil
        let data = try? JSONSerialization.data(withJSONObject: l, options: [.sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    private static func ms(_ d: Date) -> Int { Int(d.timeIntervalSince1970 * 1000) }
}
