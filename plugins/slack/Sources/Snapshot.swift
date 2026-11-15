import Foundation

/// What a data source hands the rules: the people, and the recent messages of every
/// conversation that could hold a question for me. Source-independent, so fixtures and the
/// Slack API look the same to everything after this point.
struct Snapshot: Codable, Equatable {
    var me: String
    /// Workspace URL ("https://acme.slack.com/") for links to a message; nil gives slack:// links.
    var workspace: String?
    var team: String?
    var users: [String: Person]
    var conversations: [Conversation]
}

struct Person: Codable, Equatable {
    enum Kind: String, Codable { case member, external, bot }
    var name: String
    var kind: Kind
}

struct Conversation: Codable, Equatable {
    enum Kind: String, Codable {
        case dm         // one to one
        case group      // group DM
        case channel    // public or private channel
    }
    var id: String
    var kind: Kind
    var name: String
    /// Shared with another company (Slack Connect): everyone from outside counts as a customer.
    var external: Bool = false
    /// Top-level messages and thread replies together; a reply carries its parent's `threadTs`.
    var messages: [Message]

    enum CodingKeys: String, CodingKey { case id, kind, name, external, messages }
    init(id: String, kind: Kind, name: String, external: Bool = false, messages: [Message]) {
        self.id = id; self.kind = kind; self.name = name; self.external = external; self.messages = messages
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        name = try c.decode(String.self, forKey: .name)
        external = try c.decodeIfPresent(Bool.self, forKey: .external) ?? false
        messages = try c.decode([Message].self, forKey: .messages)
    }
}

struct Message: Codable, Equatable {
    /// Slack's message id and time in one: "1767603600.000100".
    var ts: String
    var user: String
    var text: String
    /// The parent's ts for a reply, and for a parent that has replies; nil for a plain message.
    var threadTs: String?
    var reactions: [Reaction]
    var mentions: [String]
    var files: Int

    var date: Date { Date(timeIntervalSince1970: Double(ts) ?? 0) }
    /// A message in a thread that isn't its first.
    var isReply: Bool { threadTs != nil && threadTs != ts }

    enum CodingKeys: String, CodingKey { case ts, user, text, threadTs = "thread_ts", reactions, mentions, files }
    init(ts: String, user: String, text: String, threadTs: String? = nil, reactions: [Reaction] = [], mentions: [String] = [], files: Int = 0) {
        self.ts = ts; self.user = user; self.text = text; self.threadTs = threadTs
        self.reactions = reactions; self.mentions = mentions; self.files = files
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        ts = try c.decode(String.self, forKey: .ts)
        user = try c.decode(String.self, forKey: .user)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        threadTs = try c.decodeIfPresent(String.self, forKey: .threadTs)
        reactions = try c.decodeIfPresent([Reaction].self, forKey: .reactions) ?? []
        mentions = try c.decodeIfPresent([String].self, forKey: .mentions) ?? []
        files = try c.decodeIfPresent(Int.self, forKey: .files) ?? 0
    }
}

struct Reaction: Codable, Equatable {
    var name: String
    var users: [String]
}
