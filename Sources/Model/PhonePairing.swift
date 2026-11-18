import CryptoKit
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

/// Replay protection (docs/phone.md, "Order and freshness"): every boxed message carries `n`, a counter
/// that only rises per sender, and `ts`, the sender's clock in ms. A box seen before, or from too long ago,
/// is dropped even though it opens.
enum ReplayGuard {
    enum Verdict: Equatable { case fresh, replayed(n: Int, last: Int), stale(seconds: Int), missing }
    static let window: TimeInterval = 300
    static let pairWindow: TimeInterval = 600

    /// A message after pairing: `n` above the last one seen from this phone, `ts` within 5 minutes.
    static func check(_ m: [String: Any], lastSeen: Int, now: Date) -> Verdict {
        guard let n = (m["n"] as? NSNumber)?.intValue, let ts = (m["ts"] as? NSNumber)?.doubleValue else { return .missing }
        if let late = late(ts, now: now, window: window) { return .stale(seconds: late) }
        return n > lastSeen ? .fresh : .replayed(n: n, last: lastSeen)
    }

    /// `pair` has no counter yet; only its time counts, within the code's 10 minutes.
    static func checkPair(_ m: [String: Any], now: Date) -> Verdict {
        guard let ts = (m["ts"] as? NSNumber)?.doubleValue else { return .missing }
        return late(ts, now: now, window: pairWindow).map { .stale(seconds: $0) } ?? .fresh
    }

    private static func late(_ ts: Double, now: Date, window: TimeInterval) -> Int? {
        let off = abs(now.timeIntervalSince1970 - ts / 1000)
        return off > window ? Int(off) : nil
    }
}

/// Whether the bridge keeps a connection to the relay. Maxwell is public and the relay is shared, so
/// only while it has a reason: a paired phone, or a pairing code on screen. Never with the phone off.
enum PhoneConnection {
    /// How the relay knows a phone without learning its id: lowercase hex SHA-256 of the id (`allow`).
    static func allowHash(_ phone: String) -> String {
        SHA256.hash(data: Data(phone.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The Mac's control frame for the relay: which phones may join the room, and whether any may
    /// (a pairing code is showing). Sent in the clear; it holds no ids, only their hashes.
    static func control(phones: [String], pairing: Bool) -> [String: Any] {
        ["allow": phones.sorted().map(allowHash), "pairing": pairing]
    }

    static func wanted(relay: String?, pairedPhones: Int, codeShowing: Bool) -> Bool {
        relay != nil && (pairedPhones > 0 || codeShowing)
    }
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
