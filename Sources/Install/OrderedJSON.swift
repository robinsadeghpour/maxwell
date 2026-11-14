import Foundation

/// JSON that keeps key order and the source text of every scalar, so editing one
/// branch of a settings file leaves every other byte as Claude Code wrote it.
indirect enum OJSON: Equatable {
    case object([(String, OJSON)])
    case array([OJSON])
    case scalar(String)   // raw JSON text: string with quotes, number, true, false, null

    static func == (a: OJSON, b: OJSON) -> Bool {
        switch (a, b) {
        case let (.object(x), .object(y)): return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case let (.array(x), .array(y)): return x == y
        case let (.scalar(x), .scalar(y)): return x == y
        default: return false
        }
    }

    static func string(_ s: String) -> OJSON {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where u.value < 0x20: out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return .scalar(out + "\"")
    }

    static func number(_ n: Int) -> OJSON { .scalar(String(n)) }

    subscript(key: String) -> OJSON? {
        guard case .object(let kv) = self else { return nil }
        return kv.first { $0.0 == key }?.1
    }

    /// Sets or appends `key`, keeping the position of an existing key.
    mutating func set(_ key: String, _ value: OJSON?) {
        guard case .object(var kv) = self else { return }
        if let i = kv.firstIndex(where: { $0.0 == key }) {
            if let value { kv[i].1 = value } else { kv.remove(at: i) }
        } else if let value {
            kv.append((key, value))
        }
        self = .object(kv)
    }

    /// The decoded value of a string scalar.
    var stringValue: String? {
        guard case .scalar(let raw) = self, raw.hasPrefix("\"") else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: .fragmentsAllowed)) as? String
    }

    /// Same layout as JSON.stringify(value, null, 2), which is how Claude Code writes settings.
    func serialized(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent + 1), end = String(repeating: "  ", count: indent)
        switch self {
        case .scalar(let raw): return raw
        case .array(let items):
            if items.isEmpty { return "[]" }
            return "[\n" + items.map { pad + $0.serialized(indent: indent + 1) }.joined(separator: ",\n") + "\n" + end + "]"
        case .object(let kv):
            if kv.isEmpty { return "{}" }
            return "{\n" + kv.map { pad + OJSON.string($0.0).serialized() + ": " + $0.1.serialized(indent: indent + 1) }
                .joined(separator: ",\n") + "\n" + end + "}"
        }
    }

    struct ParseError: Error, CustomStringConvertible {
        let offset: Int
        var description: String { "invalid JSON at byte \(offset)" }
    }

    static func parse(_ text: String) throws -> OJSON {
        var p = Parser(bytes: Array(text.utf8))
        let v = try p.value()
        p.skipSpace()
        guard p.i == p.bytes.count else { throw ParseError(offset: p.i) }
        return v
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        mutating func skipSpace() {
            while i < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[i]) { i += 1 }
        }

        mutating func value() throws -> OJSON {
            skipSpace()
            guard i < bytes.count else { throw ParseError(offset: i) }
            switch bytes[i] {
            case UInt8(ascii: "{"):
                i += 1
                var kv: [(String, OJSON)] = []
                skipSpace()
                if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(kv) }
                while true {
                    skipSpace()
                    guard case .scalar(let raw) = try scalarString(), let key = OJSON.scalar(raw).stringValue else { throw ParseError(offset: i) }
                    skipSpace()
                    guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw ParseError(offset: i) }
                    i += 1
                    kv.append((key, try value()))
                    skipSpace()
                    guard i < bytes.count else { throw ParseError(offset: i) }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(kv) }
                    throw ParseError(offset: i)
                }
            case UInt8(ascii: "["):
                i += 1
                var items: [OJSON] = []
                skipSpace()
                if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                while true {
                    items.append(try value())
                    skipSpace()
                    guard i < bytes.count else { throw ParseError(offset: i) }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                    throw ParseError(offset: i)
                }
            case UInt8(ascii: "\""):
                return try scalarString()
            default:
                let start = i
                while i < bytes.count, !",]} \n\r\t".utf8.contains(bytes[i]) { i += 1 }
                let raw = String(decoding: bytes[start..<i], as: UTF8.self)
                guard (try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: .fragmentsAllowed)) != nil else {
                    throw ParseError(offset: start)
                }
                return .scalar(raw)
            }
        }

        mutating func scalarString() throws -> OJSON {
            guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw ParseError(offset: i) }
            let start = i
            i += 1
            while i < bytes.count, bytes[i] != UInt8(ascii: "\"") {
                if bytes[i] == UInt8(ascii: "\\") { i += 1 }
                i += 1
            }
            guard i < bytes.count else { throw ParseError(offset: start) }
            i += 1
            return .scalar(String(decoding: bytes[start..<i], as: UTF8.self))
        }
    }
}
