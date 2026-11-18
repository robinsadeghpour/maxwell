import CryptoKit
import Foundation

/// The phone's end-to-end encryption (docs/phone.md, "Encryption"): two ChaCha20-Poly1305 keys
/// derived from the key a phone paired with, one per direction. The relay only sees boxes.
struct PhoneKeys: Equatable {
    let macToPhone: SymmetricKey
    let phoneToMac: SymmetricKey

    static func == (a: PhoneKeys, b: PhoneKeys) -> Bool {
        a.macToPhone.withUnsafeBytes { Data($0) } == b.macToPhone.withUnsafeBytes { Data($0) }
    }

    /// `k` is the 32 random bytes from the pairing code, kept per phone after pairing.
    init(pairingKey k: Data) {
        let salt = Data("maxwell-phone-1".utf8)
        let ikm = SymmetricKey(data: k)
        macToPhone = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("mac→phone".utf8), outputByteCount: 32)
        phoneToMac = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("phone→mac".utf8), outputByteCount: 32)
    }
}

enum PhoneBox {
    /// `base64url(nonce ‖ ciphertext ‖ tag)` of one JSON object, with a fresh random nonce.
    static func seal(_ message: [String: Any], key: SymmetricKey) -> String? {
        guard let json = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]),
              let box = try? ChaChaPoly.seal(json, using: key) else { return nil }
        return Base64URL.encode(box.combined)
    }

    /// The message in a box, or nil when this key doesn't open it (another phone's, or tampered with).
    static func open(_ box: String, key: SymmetricKey) -> [String: Any]? {
        guard let raw = Base64URL.decode(box), raw.count > 28,
              let sealed = try? ChaChaPoly.SealedBox(combined: raw),
              let plain = try? ChaChaPoly.open(sealed, using: key) else { return nil }
        return (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any]
    }

    static func random(_ count: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &g) })
    }
}

enum Base64URL {
    static func encode(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    static func decode(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }
}

/// `maxwell://pair?v=1&relay=…&mac=…&k=…&name=…`, the link the Settings QR code holds.
struct PairLink: Equatable {
    var relay: String
    var mac: String
    var key: Data
    var name: String

    var url: String {
        var c = URLComponents()
        c.scheme = "maxwell"
        c.host = "pair"
        c.queryItems = [.init(name: "v", value: "1"), .init(name: "relay", value: relay), .init(name: "mac", value: mac),
                        .init(name: "k", value: Base64URL.encode(key)), .init(name: "name", value: name)]
        // URLComponents leaves ":" and "/" in query values; the phone decodes either way, but encode them
        // so the link survives being pasted into anything.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: ":", with: "%3A").replacingOccurrences(of: "/", with: "%2F")
        return c.string ?? ""
    }

    static func parse(_ s: String) -> PairLink? {
        guard let c = URLComponents(string: s), c.scheme == "maxwell", c.host == "pair" else { return nil }
        let q = Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard q["v"] == "1", let relay = q["relay"], let mac = q["mac"], let k = q["k"].flatMap(Base64URL.decode), k.count == 32 else { return nil }
        return PairLink(relay: relay, mac: mac, key: k, name: q["name"] ?? "")
    }
}
