import Foundation

/// Where the messages come from. The rules only ever see a `Snapshot`.
protocol SlackSource {
    /// Messages from `since` until now, in every conversation that could hold a question for me.
    func fetch(since: Date) throws -> Snapshot
}

/// Recorded, anonymised conversations (tests, screenshots, and the plugin before Slack is connected).
struct FixtureSource: SlackSource {
    var url: URL
    /// Fixture times are moved so the newest message is this long before now.
    var newestAgo: TimeInterval = 20 * 60

    func fetch(since: Date) throws -> Snapshot {
        var s = try JSONDecoder().decode(FixtureFile.self, from: Data(contentsOf: url)).snapshot
        let newest = s.conversations.flatMap(\.messages).map(\.date).max() ?? Date()
        let shift = Date().addingTimeInterval(-newestAgo).timeIntervalSince(newest)
        s.conversations = s.conversations.map { c in
            var c = c
            c.messages = c.messages.map { m in
                var m = m
                m.ts = Ts.shift(m.ts, by: shift)
                m.threadTs = m.threadTs.map { Ts.shift($0, by: shift) }
                return m
            }
            return c
        }
        return s
    }
}

/// The fixture file: a snapshot plus what the rules should say about it (used by the tests).
struct FixtureFile: Decodable {
    var me: String
    var users: [String: Person]
    var conversations: [Conversation]
    var expected: [Expected]?

    struct Expected: Decodable {
        var conversation: String
        var ts: String
        var waiting: Bool
        var kind: String?
        var why: String?
        var state: String?
    }

    var snapshot: Snapshot { Snapshot(me: me, workspace: "https://example.slack.com/", team: "T_FIXTURE", users: users, conversations: conversations) }
}

enum Ts {
    static func shift(_ ts: String, by s: TimeInterval) -> String {
        let parts = ts.split(separator: ".", maxSplits: 1)
        guard let sec = Double(parts.first ?? "") else { return ts }
        return "\(Int(sec + s)).\(parts.count > 1 ? String(parts[1]) : "000000")"
    }
}

/// The Slack Web API with a user token, read only (see `ReadOnly`).
///
/// One poll: three searches find where anything happened (my DMs, mentions of me, my own
/// messages), then only those conversations and threads are read. Search finds the places;
/// history and replies give the full order, which the rules need to tell whether I answered.
final class WebSource: SlackSource {
    let api: SlackAPI
    private var auth: (me: String, team: String, url: String)?
    private var people: [String: Person] = [:]

    init(api: SlackAPI) { self.api = api }

    func fetch(since: Date) throws -> Snapshot {
        let a = try whoami()
        let after = Self.day.string(from: since.addingTimeInterval(-86400))
        let oldest = String(format: "%.6f", since.timeIntervalSince1970)

        var places: [String: Place] = [:]
        var threads: [String: Set<String>] = [:]
        let mentionQuery = "<@\(a.me)> after:\(after)"
        for query in ["is:dm after:\(after)", mentionQuery, "from:<@\(a.me)> after:\(after)"] {
            let matches = try api.paged("search.messages", ["query": query, "sort": "timestamp", "count": "100"], key: "matches", pages: 5, nested: "messages")
            for m in matches {
                guard let ch = m["channel"] as? [String: Any], let id = ch["id"] as? String else { continue }
                places[id] = places[id] ?? Place(channel: ch)
                if query == mentionQuery { places[id]?.mentioned = true }
                if let t = Self.threadTs(m) { threads[id, default: []].insert(t) }
            }
        }

        var conversations: [Conversation] = []
        for (id, place) in places.sorted(by: { $0.key < $1.key }) {
            var raw: [[String: Any]] = []
            // A channel's top level matters only around a mention; its threads are read below.
            if place.kind != .channel || place.mentioned {
                raw = try api.paged("conversations.history", ["channel": id, "oldest": oldest, "limit": "200"], key: "messages", pages: 3)
            }
            var ts = threads[id] ?? []
            for m in raw where (m["reply_count"] as? Int ?? 0) > 0 { if let t = m["ts"] as? String { ts.insert(t) } }
            for t in ts.sorted() {
                let replies = try api.paged("conversations.replies", ["channel": id, "ts": t, "limit": "200"], key: "messages", pages: 2)
                raw += replies.filter { ($0["ts"] as? String) != t || !raw.contains { ($0["ts"] as? String) == t } }
            }
            let messages = raw.compactMap(Self.message).sorted { $0.ts < $1.ts }
            guard !messages.isEmpty else { continue }
            conversations.append(Conversation(id: id, kind: place.kind, name: try name(place, id: id, me: a.me, messages: messages),
                                              external: place.external, messages: messages))
        }
        for u in Set(conversations.flatMap { $0.messages.map(\.user) }) where people[u] == nil {
            people[u] = try person(u, team: a.team)
        }
        return Snapshot(me: a.me, workspace: a.url, team: a.team, users: people, conversations: conversations)
    }

    func whoami() throws -> (me: String, team: String, url: String) {
        if let auth { return auth }
        let r = try api.call("auth.test")
        let a = (me: r["user_id"] as? String ?? "", team: r["team_id"] as? String ?? "", url: r["url"] as? String ?? "")
        auth = a
        return a
    }

    struct Place {
        var kind: Conversation.Kind
        var name: String
        var external: Bool
        var mentioned = false
        init(channel c: [String: Any]) {
            kind = c["is_im"] as? Bool == true ? .dm : c["is_mpim"] as? Bool == true ? .group : .channel
            name = c["name"] as? String ?? ""
            external = c["is_ext_shared"] as? Bool == true
        }
    }

    private func name(_ p: Place, id: String, me: String, messages: [Message]) throws -> String {
        switch p.kind {
        case .channel: return "#" + p.name
        case .dm, .group:
            let others = Array(Set(messages.map(\.user)).subtracting([me])).sorted()
            for u in others where people[u] == nil { people[u] = try person(u, team: auth?.team ?? "") }
            return others.compactMap { people[$0]?.name }.joined(separator: ", ")
        }
    }

    private func person(_ id: String, team: String) throws -> Person {
        if id.hasPrefix("B") { return Person(name: "bot", kind: .bot) }
        guard let u = try? api.call("users.info", ["user": id])["user"] as? [String: Any] else { return Person(name: id, kind: .member) }
        let profile = u["profile"] as? [String: Any] ?? [:]
        let display = (profile["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let name = display ?? u["real_name"] as? String ?? u["name"] as? String ?? id
        let kind: Person.Kind = u["is_bot"] as? Bool == true ? .bot : (u["team_id"] as? String).map { $0 != team && !team.isEmpty } == true ? .external : .member
        return Person(name: name, kind: kind)
    }

    static let day: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    /// A search match's thread: its permalink carries `thread_ts` when it is a reply.
    static func threadTs(_ m: [String: Any]) -> String? {
        guard let link = m["permalink"] as? String, let c = URLComponents(string: link) else { return nil }
        return c.queryItems?.first { $0.name == "thread_ts" }?.value
    }

    /// One API message in the shape the rules read. Joins and other system lines are dropped.
    static func message(_ m: [String: Any]) -> Message? {
        guard let ts = m["ts"] as? String else { return nil }
        let subtype = m["subtype"] as? String
        if let subtype, !["bot_message", "thread_broadcast", "file_share", "me_message"].contains(subtype) { return nil }
        let user = m["user"] as? String ?? m["bot_id"] as? String ?? ""
        guard !user.isEmpty else { return nil }
        let text = m["text"] as? String ?? ""
        let reactions = (m["reactions"] as? [[String: Any]] ?? []).map { Reaction(name: $0["name"] as? String ?? "", users: $0["users"] as? [String] ?? []) }
        return Message(ts: ts, user: user, text: text, threadTs: m["thread_ts"] as? String,
                       reactions: reactions, mentions: mentions(in: text), files: (m["files"] as? [Any])?.count ?? 0)
    }

    static func mentions(in text: String) -> [String] {
        var out: [String] = []
        var rest = Substring(text)
        while let r = rest.range(of: "<@") {
            rest = rest[r.upperBound...]
            let id = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if !id.isEmpty { out.append(String(id)) }
        }
        return out
    }
}

extension SlackAPI {
    /// `search.messages` nests its list one level down (`messages.matches`) and pages by number.
    func paged(_ method: String, _ params: [String: String], key: String, pages: Int, nested: String) throws -> [[String: Any]] {
        var out: [[String: Any]] = []
        for page in 1...pages {
            var p = params
            p["page"] = String(page)
            let r = try call(method, p)
            let box = r[nested] as? [String: Any] ?? [:]
            out += box[key] as? [[String: Any]] ?? []
            let paging = box["paging"] as? [String: Any] ?? [:]
            if page >= (paging["pages"] as? Int ?? 1) { break }
        }
        return out
    }
}
