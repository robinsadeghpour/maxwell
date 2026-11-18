import Foundation

/// Pairing codes shown in Settings › Phone: each holds a fresh key, lasts 10 minutes and is spent
/// by the first phone that pairs with it (docs/phone.md, "Pairing").
struct PairingCodes {
    struct Code: Equatable {
        var key: Data
        var expires: Date
    }
    static let lifetime: TimeInterval = 600
    private(set) var codes: [Code] = []

    /// A new code. Older unexpired ones stay valid until they expire or are used.
    mutating func make(now: Date, key: Data = PhoneBox.random(32)) -> Code {
        prune(now: now)
        let c = Code(key: key, expires: now.addingTimeInterval(Self.lifetime))
        codes.append(c)
        return c
    }

    mutating func prune(now: Date) { codes.removeAll { $0.expires <= now } }

    /// Settings › Phone › Done: no code works any more.
    mutating func cancelAll() { codes = [] }

    /// The code whose key opens a `pair` box from this phone, spent on the spot.
    mutating func spend(box: String, from phone: String, now: Date) -> (key: Data, message: [String: Any])? {
        prune(now: now)
        for (i, c) in codes.enumerated() {
            guard let m = PhoneBox.open(box, key: PhoneKeys(pairingKey: c.key).phoneToMac),
                  m["t"] as? String == "pair", m["phone"] as? String == phone else { continue }
            codes.remove(at: i)
            return (c.key, m)
        }
        return nil
    }

    /// The newest code still valid, for Settings to keep showing.
    func current(now: Date) -> Code? { codes.filter { $0.expires > now }.max { $0.expires < $1.expires } }
}

/// The last 500 command ids and their answers: a resent command gets the first answer again and
/// does nothing twice (docs/phone.md, `cmd`).
struct CommandLog {
    static let size = 500
    private var order: [String] = []
    private var answers: [String: [String: Any]] = [:]
    /// Commands started and not yet answered: a resend while one runs must not start it again.
    private(set) var running: Set<String> = []

    enum Seen { case new, running, answered([String: Any]) }

    func seen(_ id: String) -> Seen {
        if let a = answers[id] { return .answered(a) }
        return running.contains(id) ? .running : .new
    }

    mutating func start(_ id: String) { running.insert(id) }

    mutating func finish(_ id: String, ack: [String: Any]) {
        running.remove(id)
        if answers[id] == nil { order.append(id) }
        answers[id] = ack
        while order.count > Self.size { answers[order.removeFirst()] = nil }
    }
}
