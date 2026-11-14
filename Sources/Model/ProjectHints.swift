import Foundation

/// Where a session's work actually goes, read from its transcript: the files it edits, the
/// folders it `cd`s or `git -C`s into, and the Linear ids it names. A session started in
/// ~/projects/notes that edits Acme all day points at Acme.
struct ProjectVotes: Equatable {
    var paths: [String: Int] = [:]     // file or folder → times touched
    var linear: [String: Int] = [:]    // "TIN" → times an id like TIN-123 was named

    /// Adds what one transcript line points at: paths from assistant tool calls, Linear ids from
    /// prompts, replies and tool output. Not from attachments or meta lines: those carry
    /// CLAUDE.md, whose example ids would point every session at the same project.
    mutating func read(_ line: Substring) {
        let ids = Self.linearId.matches(in: String(line), range: NSRange(line.startIndex..., in: line))
        guard !ids.isEmpty || line.contains("\"tool_use\""), let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = obj["type"] as? String, type == "user" || type == "assistant", obj["isMeta"] as? Bool != true else { return }
        for m in ids {
            if let r = Range(m.range(at: 1), in: line) { linear[String(line[r]), default: 0] += 1 }
        }
        guard type == "assistant", let msg = obj["message"] as? [String: Any], let content = msg["content"] as? [[String: Any]] else { return }
        for c in content where c["type"] as? String == "tool_use" {
            guard let input = c["input"] as? [String: Any] else { continue }
            switch c["name"] as? String {
            case "Edit", "Write", "MultiEdit", "NotebookEdit":
                if let p = (input["file_path"] ?? input["notebook_path"]) as? String { paths[p, default: 0] += 1 }
            case "Bash":
                for p in Self.folders(inCommand: input["command"] as? String ?? "") { paths[p, default: 0] += 1 }
            default: break
            }
        }
    }

    /// Absolute or ~ folders after `cd` and `git -C`.
    static func folders(inCommand cmd: String) -> [String] {
        folderArg.matches(in: cmd, range: NSRange(cmd.startIndex..., in: cmd)).compactMap { m in
            Range(m.range(at: 1), in: cmd).map { Paths.normalize(String(cmd[$0]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))) }
        }
    }

    /// The project most of the votes point at, when that is not `current`. `project(path)` names
    /// a path's project (nil: no project, the vote is dropped); `keys` maps Linear team keys to projects.
    func suggestion(current: String, project: (String) -> String?, keys: [String: String]) -> String? {
        var tally: [String: Int] = [:]
        for (p, n) in paths { if let name = project(p) { tally[name, default: 0] += n } }
        for (k, n) in linear { if let name = keys[k] { tally[name, default: 0] += n } }
        let total = tally.values.reduce(0, +)
        guard let (top, n) = tally.max(by: { $0.value < $1.value }), top != current, n >= 3, n * 2 > total else { return nil }
        return top
    }

    private static let linearId = try! NSRegularExpression(pattern: #"\b([A-Z]{2,6})-[0-9]{1,6}\b"#)
    private static let folderArg = try! NSRegularExpression(pattern: #"(?:^|[\s;&|(])(?:cd|git\s+-C)\s+("?[~/][^\s;&|)"]*"?)"#)
}

enum LinearKeys {
    /// A repo's Linear team key from its branch names (me/acm-56-fix → "ACM"): the most common
    /// prefix, when it names at least 5 branches and twice as many as the runner-up.
    static func key(branches: [String]) -> String? {
        var count: [String: Int] = [:]
        for b in branches {
            let last = b.split(separator: "/").last.map(String.init) ?? b
            guard let m = prefix.firstMatch(in: last, range: NSRange(last.startIndex..., in: last)), let r = Range(m.range(at: 1), in: last) else { continue }
            count[last[r].uppercased(), default: 0] += 1
        }
        let ranked = count.sorted { $0.value > $1.value }
        guard let top = ranked.first, top.value >= 5, ranked.count < 2 || top.value >= ranked[1].value * 2 else { return nil }
        return top.key
    }
    private static let prefix = try! NSRegularExpression(pattern: #"^([A-Za-z]{2,6})-[0-9]+"#)
}
