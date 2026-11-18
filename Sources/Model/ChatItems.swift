import Foundation

/// One entry in the phone's conversation view (docs/phone.md, "Transcript item"), read from a
/// session's transcript. A tool shows when Claude calls it and again, with the same `id`, once its
/// result is in; the phone replaces the first with the second.
enum ChatItem: Equatable {
    case you(String, at: String?)
    case claude(String, at: String?)
    case tool(id: String, tool: String, summary: String, added: Int?, removed: Int?, status: ToolStatus?)
    case artifact(url: String, title: String?)
    case note(String, at: String?)

    enum ToolStatus: String { case running, ok, failed }

    /// The tool call this item stands for: a later item with the same id replaces it.
    var id: String? { if case .tool(let id, _, _, _, _, _) = self { return id }; return nil }

    var json: [String: Any] {
        func timed(_ k: String, _ text: String, _ at: String?) -> [String: Any] {
            var d: [String: Any] = ["k": k, "text": text]
            if let at { d["at"] = at }
            return d
        }
        switch self {
        case .you(let t, let at): return timed("you", t, at)
        case .claude(let t, let at): return timed("claude", t, at)
        case .note(let t, let at): return timed("note", t, at)
        case .artifact(let url, let title): return ["k": "artifact", "url": url, "title": title ?? NSNull()]
        case .tool(let id, let tool, let summary, let added, let removed, let status):
            var d: [String: Any] = ["k": "tool", "id": id, "tool": tool, "summary": summary]
            if let added { d["added"] = added }
            if let removed { d["removed"] = removed }
            if let status { d["status"] = status.rawValue }
            return d
        }
    }
}

/// Reads transcript lines in order and says what each adds to the conversation. It remembers
/// tool calls until their results come, so it is fed every line, once, in order.
struct ChatParser {
    let cwd: String
    private var calls: [String: ChatItem] = [:]
    private var lastArtifact: String?
    static let maxText = 20_000

    init(cwd: String) { self.cwd = cwd }

    /// The newest `limit` items of a run of lines, a tool's result folded into its call.
    static func recent(_ lines: [Substring], cwd: String, limit: Int = 300) -> [ChatItem] {
        var p = ChatParser(cwd: cwd)
        return p.recent(lines, limit: limit)
    }

    /// Reads a run of lines and keeps the calls still waiting for results, so later lines fold into them.
    mutating func recent(_ lines: [Substring], limit: Int = 300) -> [ChatItem] {
        var items: [ChatItem] = []
        for line in lines { Self.merge(read(line), into: &items, limit: .max) }
        return Array(items.suffix(limit))
    }

    /// Appends items, a tool's newer version replacing the one with its id, keeping the newest `limit`.
    static func merge(_ new: [ChatItem], into items: inout [ChatItem], limit: Int) {
        for item in new {
            if let id = item.id, let i = items.lastIndex(where: { $0.id == id }) { items[i] = item } else { items.append(item) }
        }
        if items.count > limit { items.removeFirst(items.count - limit) }
    }

    mutating func read(_ line: Substring) -> [ChatItem] {
        guard line.count < 8_000_000, let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              obj["isSidechain"] as? Bool != true else { return [] }
        let at = obj["timestamp"] as? String
        var out: [ChatItem] = []
        switch obj["type"] as? String {
        case "user": out = user(obj, at: at)
        case "assistant": out = assistant(obj, at: at)
        case "system" where obj["subtype"] as? String == "compact_boundary": out = [.note("Conversation compacted", at: at)]
        default: return []
        }
        // Reuse the viewer's reading of artifacts: publishes, opens, and links Claude names.
        if let a = ArtifactTranscript.sighting(inLine: String(line)), a.link.url.absoluteString != lastArtifact || a.republished {
            lastArtifact = a.link.url.absoluteString
            out.append(.artifact(url: a.link.url.absoluteString, title: a.title))
        }
        return out
    }

    // MARK: lines

    private mutating func user(_ obj: [String: Any], at: String?) -> [ChatItem] {
        guard obj["isMeta"] as? Bool != true, let msg = obj["message"] as? [String: Any] else { return [] }
        if let text = msg["content"] as? String { return typed(text, at: at) }
        guard let blocks = msg["content"] as? [[String: Any]] else { return [] }
        var out: [ChatItem] = []
        var typedText: [String] = []
        for b in blocks {
            switch b["type"] as? String {
            case "tool_result":
                if let id = b["tool_use_id"] as? String, let done = result(id, block: b, record: obj["toolUseResult"]) { out.append(done) }
            case "text":
                if let t = b["text"] as? String { typedText.append(t) }
            default: break
            }
        }
        if !typedText.isEmpty { out += typed(typedText.joined(separator: "\n"), at: at) }
        return out
    }

    /// What you typed, or a slash command; Claude Code's own wrappers and notices are left out.
    private func typed(_ raw: String, at: String?) -> [ChatItem] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("[Request interrupted by user") { return [.note("Interrupted", at: at)] }
        if let name = Self.tag("command-name", in: text) {
            let args = Self.tag("command-args", in: text) ?? ""
            return [.you(args.isEmpty ? name : "\(name) \(args)", at: at)]
        }
        guard !text.isEmpty, !text.hasPrefix("<"), !text.hasPrefix("Caveat:") else { return [] }
        return [.you(String(text.prefix(Self.maxText)), at: at)]
    }

    private mutating func assistant(_ obj: [String: Any], at: String?) -> [ChatItem] {
        guard let msg = obj["message"] as? [String: Any], let blocks = msg["content"] as? [[String: Any]] else { return [] }
        var out: [ChatItem] = []
        for b in blocks {
            switch b["type"] as? String {
            case "text":
                let t = (b["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out.append(.claude(String(t.prefix(Self.maxText)), at: at)) }
            case "tool_use":
                guard let id = b["id"] as? String, let name = b["name"] as? String else { continue }
                let input = b["input"] as? [String: Any] ?? [:]
                let call = ChatItem.tool(id: id, tool: name, summary: summary(name, input), added: nil, removed: nil,
                                         status: name == "Bash" ? .running : nil)
                calls[id] = call
                out.append(call)
            default: break
            }
        }
        return out
    }

    /// The call again, with what its result says: lines added and removed, or how a command ended.
    private mutating func result(_ id: String, block: [String: Any], record: Any?) -> ChatItem? {
        guard case .tool(_, let tool, let summary, _, _, _)? = calls.removeValue(forKey: id) else { return nil }
        let failed = block["is_error"] as? Bool == true || (record as? [String: Any])?["interrupted"] as? Bool == true
        let counts = Self.lineCounts(record as? [String: Any])
        let status: ChatItem.ToolStatus? = failed ? .failed : tool == "Bash" ? .ok : nil
        return .tool(id: id, tool: tool, summary: summary, added: counts?.added, removed: counts?.removed, status: status)
    }

    // MARK: details

    /// Lines added and removed by an Edit or Write, from the patch Claude Code records with its result.
    static func lineCounts(_ r: [String: Any]?) -> (added: Int, removed: Int)? {
        guard let r else { return nil }
        if let hunks = r["structuredPatch"] as? [[String: Any]], !hunks.isEmpty {
            var added = 0, removed = 0
            for h in hunks {
                for l in h["lines"] as? [String] ?? [] {
                    if l.hasPrefix("+") { added += 1 } else if l.hasPrefix("-") { removed += 1 }
                }
            }
            return (added, removed)
        }
        if r["type"] as? String == "create", let content = r["content"] as? String {
            return (content.split(separator: "\n", omittingEmptySubsequences: false).count - (content.hasSuffix("\n") ? 1 : 0), 0)
        }
        return nil
    }

    /// A few words on what a tool call is about: the file, the command, the pattern or the link.
    func summary(_ tool: String, _ input: [String: Any]) -> String {
        func str(_ k: String) -> String? { (input[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        if let path = str("file_path") ?? str("notebook_path") { return relative(path) }
        if tool == "Bash", let cmd = str("command") { return Self.oneLine(cmd) }
        for k in ["pattern", "url", "query", "description", "path", "title", "prompt", "command", "name"] {
            if let v = str(k) { return Self.oneLine(k == "path" ? relative(v) : v) }
        }
        return ""
    }

    private func relative(_ path: String) -> String {
        guard !cwd.isEmpty, path.hasPrefix(cwd + "/") else { return path }
        return String(path.dropFirst(cwd.count + 1))
    }

    static func oneLine(_ s: String, max: Int = 160) -> String {
        let first = s.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let t = first.trimmingCharacters(in: .whitespaces)
        return t.count > max ? String(t.prefix(max - 1)) + "…" : t
    }

    private static func tag(_ name: String, in text: String) -> String? {
        guard let a = text.range(of: "<\(name)>"), let b = text.range(of: "</\(name)>", range: a.upperBound..<text.endIndex) else { return nil }
        return String(text[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
