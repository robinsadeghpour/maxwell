import Foundation

/// What I said about an item in Maxwell. Kept on this Mac only; nothing goes back to Slack.
/// Each mark covers the conversation's messages up to `upTo`, so a new message brings the item back.
struct Marks: Codable, Equatable {
    enum Kind: String, Codable { case handled, snoozed, notForMe }
    struct Mark: Codable, Equatable {
        var kind: Kind
        var upTo: String
        var until: Date?
        var at: Date
    }
    var byKey: [String: Mark] = [:]

    func hides(_ w: Waiting, now: Date) -> Bool {
        guard let m = byKey[w.key] else { return false }
        switch m.kind {
        case .handled: return w.lastTs <= m.upTo
        case .snoozed: return w.lastTs <= m.upTo && (m.until ?? .distantFuture) > now
        // Not for me: only a later message that mentions me or asks again in a DM brings it back.
        case .notForMe: return w.lastTs <= m.upTo || !w.direct
        }
    }

    mutating func mark(_ w: Waiting, _ kind: Kind, until: Date? = nil, now: Date = Date()) {
        byKey[w.key] = Mark(kind: kind, upTo: w.lastTs, until: until, at: now)
    }

    mutating func clear(_ key: String) { byKey[key] = nil }

    /// Marks older than the window can't match anything any more.
    mutating func prune(before: Date) {
        byKey = byKey.filter { ($0.value.until ?? $0.value.at) > before }
    }

    static func load(_ url: URL) -> Marks {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder.iso.decode(Marks.self, from: $0) } ?? Marks()
    }
    func save(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.iso.encode(self).write(to: url, options: .atomic)
    }
}

extension JSONDecoder {
    static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
extension JSONEncoder {
    static let iso: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }()
}
