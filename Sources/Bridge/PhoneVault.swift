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
    func write(_ item: String, _ value: Data?) {
        SecItemDelete(query(item) as CFDictionary)
        guard let value else { return }
        var q = query(item)
        q[kSecValueData as String] = value
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
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
        phones = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
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

    /// Last seen and push tokens change often; they're written with the next save, not each time.
    func touch(_ id: String, at: Date) { phones[id]?.lastSeen = at }

    func persist() {
        let list = phones.values.sorted { $0.pairedAt < $1.pairedAt }
        vault.write("phones", try? JSONEncoder().encode(list))
    }
}
