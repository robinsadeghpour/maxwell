import Foundation
import Security

/// Where the bridge keeps its secrets between launches. Keychain in the app, memory in quiet test runs
/// (a rebuilt app is a new app to macOS and would ask for Keychain access).
protocol PhoneVault: AnyObject {
    func read(_ item: String) -> Data?
    func write(_ item: String, _ value: Data?)
}

/// Keychain generic passwords, service "Maxwell phone <bundle id>": Maxwell Dev and Maxwell each get
/// their own room on the relay, so the two never take each other's connection.
final class KeychainVault: PhoneVault {
    private let service = "Maxwell phone \(Bundle.main.bundleIdentifier ?? "dev.maxwell.app")"
    private func query(_ item: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: item]
    }
    func read(_ item: String) -> Data? {
        var q = query(item)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status != errSecSuccess && status != errSecItemNotFound { mark("phone: keychain read \(item) failed (\(status))") }
        return out as? Data
    }
    /// Updates in place, else adds: never delete-then-add, which would lose the item if the add failed.
    func write(_ item: String, _ value: Data?) {
        guard let value else {
            let status = SecItemDelete(query(item) as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound { mark("phone: keychain delete \(item) failed (\(status))") }
            return
        }
        var status = SecItemUpdate(query(item) as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(item)
            q[kSecValueData as String] = value
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        }
        if status != errSecSuccess { mark("phone: keychain write \(item) failed (\(status))") }
    }
}

final class MemoryVault: PhoneVault {
    private var items: [String: Data] = [:]
    func read(_ item: String) -> Data? { items[item] }
    func write(_ item: String, _ value: Data?) { items[item] = value }
}

/// A phone that paired with this Mac.
struct PairedPhone: Codable, Equatable {
    var id: String
    var name: String
    /// The pairing key `k`; both directions' keys come from it.
    var key: Data
    var push: String?
    var app: String?
    var pairedAt: Date
    var lastSeen: Date?
    /// The highest `n` seen from this phone; a box at or below it is a replay. Reset by pairing.
    var seenN: Int?
    /// The last `n` this Mac sent it, and how far ahead that is written down: after a restart the Mac
    /// goes on from `sentReserved`, so its counter never repeats without a Keychain write per message.
    var sentN: Int?
    var sentReserved: Int?
    /// What its pushes may say on the lock screen; hidden until the phone asks for full.
    var pushDetail: PushPlanner.Detail?
    /// When this Mac handed it each account's claude.ai sign-in (`artifactLogin`), by account name.
    var artifactShares: [String: Date]?

    var keys: PhoneKeys { PhoneKeys(pairingKey: key) }
}

/// This Mac's room id and token on the relay, and the paired phones (docs/phone.md, "Pairing").
final class PhoneRegistry {
    private let vault: PhoneVault
    let macId: String
    let macToken: String
    private(set) var phones: [String: PairedPhone]

    init(vault: PhoneVault) {
        self.vault = vault
        macId = Self.secret(vault, "mac-id", bytes: 16)
        macToken = Self.secret(vault, "mac-token", bytes: 32)
        let list = vault.read("phones").flatMap { try? JSONDecoder().decode([PairedPhone].self, from: $0) } ?? []
        phones = Dictionary(list.map { p in
            var p = p
            p.sentN = p.sentReserved ?? p.sentN
            return (p.id, p)
        }, uniquingKeysWith: { a, _ in a })
    }

    /// Made once and kept: the room is claimed by the first token that connects to it.
    private static func secret(_ vault: PhoneVault, _ item: String, bytes: Int) -> String {
        if let d = vault.read(item), let s = String(data: d, encoding: .utf8), !s.isEmpty { return s }
        let s = Base64URL.encode(PhoneBox.random(bytes))
        vault.write(item, Data(s.utf8))
        return s
    }

    func save(_ p: PairedPhone) {
        phones[p.id] = p
        persist()
    }

    func remove(_ id: String) {
        phones[id] = nil
        persist()
    }

    private var dirty = false

    /// Last seen changes often; it's written with the next save, not each time.
    func touch(_ id: String, at: Date) { phones[id]?.lastSeen = at; dirty = true }

    /// The `n` for the next message to this phone, written ahead in blocks of 1000.
    func nextSent(_ id: String) -> Int {
        guard var p = phones[id] else { return 0 }
        let n = (p.sentN ?? 0) + 1
        p.sentN = n
        let reserve = n > (p.sentReserved ?? 0)
        if reserve { p.sentReserved = n + 999 }
        phones[id] = p
        if reserve { persist() }
        return n
    }

    /// A message from the phone passed the replay check. `now`: write it down at once (commands).
    func seen(_ id: String, n: Int, now: Bool) {
        phones[id]?.seenN = n
        dirty = true
        if now { persist() }
    }

    func persistIfChanged() { if dirty { persist() } }

    func persist() {
        dirty = false
        let list = phones.values.sorted { $0.pairedAt < $1.pairedAt }
        vault.write("phones", try? JSONEncoder().encode(list))
    }
}
