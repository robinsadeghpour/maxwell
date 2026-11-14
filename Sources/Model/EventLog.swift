import Foundation

/// ~/.local/state/maxwell/events.jsonl: folded once at launch, then tailed.
final class EventLog {
    static func fold(url: URL, accounts: [Account]) -> AppState {
        let reader = EventLog(url: url)
        return reader.readNew().reduce(into: AppState(accounts: accounts)) { reduce(into: &$0, $1) }
    }

    let url: URL
    private var offset: UInt64 = 0
    private var partial = Data()
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1

    init(url: URL) { self.url = url }

    /// Events appended since the last call (all of them on the first call).
    func readNew() -> [Event] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        if size < offset { offset = 0; partial = Data() }   // rotated or truncated
        try? h.seek(toOffset: offset)
        guard let data = try? h.readToEnd(), !data.isEmpty else { return [] }
        offset += UInt64(data.count)
        var buf = partial + data
        var events: [Event] = []
        while let nl = buf.firstIndex(of: 0x0A) {
            let line = buf[buf.startIndex..<nl]
            if let s = String(data: line, encoding: .utf8), let e = EventParser.parse(line: Substring(s)) { events.append(e) }
            buf = buf[(nl + 1)...]
        }
        partial = Data(buf)
        return events
    }

    /// Calls `onEvents` on the main queue whenever lines are appended.
    func tail(_ onEvents: @escaping ([Event]) -> Void) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.extend, .write, .delete, .rename], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            if src.data.contains(.delete) || src.data.contains(.rename) {
                src.cancel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.tail(onEvents) }
            }
            let events = self.readNew()
            if !events.isEmpty { onEvents(events) }
        }
        let fdCopy = fd
        src.setCancelHandler { close(fdCopy) }
        source = src
        src.resume()
    }
}

/// Maxwell's own lines in the event log: `{"ts": ms, "maxwell": {"type": …}}`.
enum MaxwellRecord {
    /// Appends one line with a single write on O_APPEND, like the hook, so lines never interleave.
    static func append(_ fields: [String: Any], at: Date = Date(), to url: URL = Paths.eventLog) {
        let obj: [String: Any] = ["ts": (at.timeIntervalSince1970 * 1000).rounded(), "maxwell": fields]
        guard var data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
    }

    static func judged(hash: String, session: SessionID, verdict: String, account: AccountID, costUSD: Double?, ms: Int, raw: String) -> [String: Any] {
        var f: [String: Any] = ["type": "judged", "hash": hash, "session": session, "verdict": verdict, "account": account, "ms": ms, "model": "haiku"]
        if let costUSD { f["costUsd"] = costUSD }
        if verdict != "finished" && verdict != "pending" && verdict != "unsure" { f["raw"] = String(raw.prefix(300)) }
        return f
    }

    static func closed(_ s: Session, checks: [Check]) -> [String: Any] {
        var f: [String: Any] = ["type": "closed", "session": s.id, "account": s.accountId, "name": s.name, "title": s.title, "cwd": s.cwd,
                                "checks": checks.map(encode)]
        if case .background(let short) = s.reach { f["shortId"] = short }
        return f
    }

    static func reopened(_ id: SessionID) -> [String: Any] { ["type": "reopened", "session": id] }

    static func notSafe(_ s: Session, checks: [Check]) -> [String: Any] {
        ["type": "not-safe", "session": s.id, "hash": s.lastMessage.map(Reply.hash) ?? "", "checks": checks.map(encode)]
    }

    /// nil `project`: back to the folder's project.
    static func moved(_ id: SessionID, to project: String?) -> [String: Any] {
        var f: [String: Any] = ["type": "moved", "session": id]
        if let project { f["project"] = project }
        return f
    }

    static func dismissed(_ id: SessionID, suggestion project: String) -> [String: Any] {
        ["type": "suggestion-dismissed", "session": id, "project": project]
    }

    static func encode(_ c: Check) -> [String: String] {
        ["kind": c.kind.rawValue, "outcome": c.outcome.rawValue, "detail": c.detail, "source": c.source]
    }

    static func decode(_ any: Any?) -> [Check] {
        ((any as? [[String: String]]) ?? []).compactMap { d in
            guard let k = d["kind"].flatMap(Check.Kind.init), let o = d["outcome"].flatMap(Check.Outcome.init) else { return nil }
            return Check(kind: k, outcome: o, detail: d["detail"] ?? "", source: d["source"] ?? "")
        }
    }

    static func parse(_ m: [String: Any], at: Date) -> Event? {
        guard let type = m["type"] as? String, let sid = m["session"] as? String else { return nil }
        switch type {
        case "judged":
            // A failed call is logged for the cost trail but not cached: the next pass asks again.
            guard let hash = m["hash"] as? String, let v = (m["verdict"] as? String).flatMap(Judgment.Verdict.init),
                  let acct = m["account"] as? String else { return nil }
            return .judged(hash: hash, Judgment(verdict: v, at: at, account: acct, costUSD: (m["costUsd"] as? NSNumber)?.doubleValue))
        case "closed":
            guard let acct = m["account"] as? String else { return nil }
            let reach: Reach = (m["shortId"] as? String).map { .background(shortId: $0) } ?? .elsewhere(pid: nil)
            var s = Session(id: sid, name: m["name"] as? String ?? String(sid.prefix(8)), accountId: acct, cwd: m["cwd"] as? String ?? "",
                            at: at, origin: .maxwell, reach: reach)
            s.hookTitle = m["title"] as? String
            s.phase = .ended
            return .closed(ClosedSession(at: at, session: s, checks: decode(m["checks"])))
        case "reopened": return .reopened(sid, at: at)
        case "not-safe": return .markedNotSafe(sid, at: at)
        case "moved": return .movedToProject(sid, m["project"] as? String)
        case "suggestion-dismissed": return (m["project"] as? String).map { .suggestionDismissed(sid, project: $0) }
        default: return nil
        }
    }
}
