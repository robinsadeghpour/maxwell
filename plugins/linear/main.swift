import Foundation

/// The Linear plugin for Maxwell: which ticket each session works on, its status on the row,
/// "ticket done" in Safe to close, and one-click status moves. See plugins/linear/README.md.
final class LinearPlugin {
    let io = PluginIO()
    var settings: [String: String] = [:]
    var dataDir = URL(fileURLWithPath: NSTemporaryDirectory())
    var client: LinearClient?
    var connectedAs: String?
    var teams: Set<String> = []
    var sessions: [String: LinearSession] = [:]
    var votes: [String: TranscriptVotes] = [:]
    /// Branches read with git for sessions Maxwell hasn't checked yet (it only checks stopped ones).
    var gitBranch: [String: String] = [:]
    var links: [String: String] = [:]
    var issues: [String: LinearIssue] = [:]
    /// Tickets assigned to you, open or done this week, for the panel.
    var mine: [LinearIssue] = []
    var fetchedAt: [String: Date] = [:]
    var errors: [String: String] = [:]
    /// Suggestions done or waved away, so they aren't offered again. Kept in the data folder.
    var settled: Set<String> = []
    var inFlight: Set<String> = []
    var lastSent: [String: Data] = [:]
    let scanQueue = DispatchQueue(label: "linear.scan")
    /// Where each transcript was read up to. Only touched on `scanQueue`, so scans never overlap.
    var scanState: [String: TranscriptVotes] = [:]
    var timer: DispatchSourceTimer?

    var fixtures: URL? { ProcessInfo.processInfo.environment["MAXWELL_LINEAR_FIXTURES"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } }
    var dryRun: Bool { settings["writes"] == "dry-run" || ProcessInfo.processInfo.environment["MAXWELL_LINEAR_DRY_RUN"] == "1" || fixtures != nil }
    var sync: String { settings["sync"] ?? "suggest" }
    var connected: Bool { connectedAs != nil }
    /// A key (or fixtures) is set: from then on every linked session carries a check.
    var hasKey: Bool { client != nil }

    func start() {
        io.onRequest = { [unowned self] method, params, reply in
            switch method {
            case "initialize":
                settings = (params["settings"] as? [String: String]) ?? [:]
                if let d = (params["plugin"] as? [String: Any])?["dataDir"] as? String { dataDir = URL(fileURLWithPath: d) }
                loadSettled()
                reply(.success([String: Any]()))
                connect()
            case "action/run": run(params, reply)
            case "shutdown": reply(.success(NSNull())); DispatchQueue.main.async { exit(0) }
            default: reply(.failure(.init(code: -32601, message: "unknown method \(method)")))
            }
        }
        io.onNotification = { [unowned self] method, params in
            switch method {
            case "sessions/changed": sessionsChanged(params)
            case "settings/changed":
                settings = (params["settings"] as? [String: String]) ?? settings
                connect()
            case "secrets/changed": connect()
            default: break
            }
        }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 60, repeating: 60)
        t.setEventHandler { [unowned self] in if connected { refresh() } else if client != nil { connect() } }
        t.resume()
        timer = t
        io.run()
    }

    // MARK: connecting

    func status(_ state: String, _ message: String) { io.notify("status", ["state": state, "message": message]) }

    func connect() {
        let log = dryRun ? dataDir.appendingPathComponent("dry-run.jsonl") : nil
        if let f = fixtures {
            client = LinearClient(transport: FixtureTransport(dir: f), dryRunLog: log)
            return verify()
        }
        io.secret("api-key") { [unowned self] key in
            guard let key, !key.isEmpty else {
                client = nil; connectedAs = nil
                status("setup", "Connect Linear to see ticket status.")
                return publish(force: true)
            }
            client = LinearClient(transport: HTTPTransport(key: key.trimmingCharacters(in: .whitespacesAndNewlines)), dryRunLog: log)
            verify()
        }
    }

    func verify() {
        status("loading", "Connecting to Linear…")
        client?.viewer { [unowned self] r in
            switch r {
            case .success(let v):
                connectedAs = v.name
                if teams != v.teams {
                    teams = v.teams
                    // Votes counted before the team keys were known can't be trusted: read again.
                    scanQueue.async { self.scanState = [:] }
                    scan(Array(sessions.values)) { [unowned self] in relinkAll() }
                }
                refresh()
                status("ok", "Connected as \(v.name)\(dryRun ? ", dry run" : "")")
                relinkAll()
            case .failure(.unauthorized):
                connectedAs = nil
                status("setup", "Linear refused the API key.")
                publish(force: true)
            case .failure(let e):
                connectedAs = nil
                status("offline", "Can't reach Linear: \(e). Trying again in a minute.")
                publish(force: true)
            }
        }
    }

    // MARK: sessions and links

    func sessionsChanged(_ p: [String: Any]) {
        if p["full"] as? Bool == true { sessions = [:]; lastSent = [:] }
        let changed = ((p["sessions"] as? [[String: Any]]) ?? []).compactMap(LinearSession.init)
        for s in changed { sessions[s.id] = s }
        for id in (p["removed"] as? [String]) ?? [] { sessions[id] = nil; links[id] = nil; votes[id] = nil; lastSent[id] = nil; gitBranch[id] = nil; scanQueue.async { self.scanState[id] = nil } }
        scan(changed) { [unowned self] in
            relinkAll(fetch: false)
            // A session Maxwell sent again gets a fresh answer, even if nothing changed (Safe to close
            // needs it), and the answer waits for a fresh read of its ticket.
            for s in changed { lastSent[s.id] = nil }
            let now = Date()
            let stale = Set(changed.compactMap { links[$0.id] }).filter { fetchedAt[$0].map { now.timeIntervalSince($0) > 30 } ?? true }
            if connected, !stale.isEmpty { refresh(Array(stale)) } else { publish(force: false) }
        }
    }

    /// Reads the new part of each transcript off the main queue.
    func scan(_ list: [LinearSession], then: @escaping () -> Void) {
        // Before the team keys are known any "ABC-1" would vote; wait for them (a rescan follows).
        let jobs = teams.isEmpty ? [] : list.compactMap { s in s.transcriptPath.map { (s.id, $0) } }
        let noBranch = list.filter { $0.branch == nil && !$0.cwd.isEmpty }.map { ($0.id, $0.cwd) }
        let teams = self.teams
        scanQueue.async {
            var branches: [(String, String?)] = []
            for (id, cwd) in noBranch { branches.append((id, Self.currentBranch(cwd))) }
            var out: [(String, TranscriptVotes)] = []
            for (id, path) in jobs {
                let v = Self.read(path, from: self.scanState[id] ?? TranscriptVotes(), teams: teams)
                self.scanState[id] = v
                out.append((id, v))
            }
            DispatchQueue.main.async {
                for (id, v) in out { self.votes[id] = v }
                for (id, b) in branches { self.gitBranch[id] = b }
                then()
            }
        }
    }

    func relinkAll(fetch: Bool = true) {
        var next: [String: String] = [:]
        for s in sessions.values {
            // Transcript votes only count once the team keys are known, and only for those teams.
            let fromTranscript = teams.isEmpty ? nil : votes[s.id]?.winner().flatMap { w in teams.contains(String(w.split(separator: "-")[0])) ? w : nil }
            if let id = LinearLink.fromBranch(s.branch ?? gitBranch[s.id], teams: teams) ?? fromTranscript { next[s.id] = id }
        }
        let fresh = Set(next.values).subtracting(issues.keys)
        links = next
        guard fetch else { return }
        if connected, !fresh.isEmpty { refresh(Array(fresh)) } else { publish(force: false) }
    }

    /// Reads tickets again (all linked ones by default). A read that started before the one already
    /// applied is dropped, so overlapping reads can't put an older status back.
    func refresh(_ only: [String]? = nil) {
        guard let client else { return publish(force: false) }
        let ids = (only ?? Array(Set(links.values))).sorted()
        let started = Date()
        if only == nil {
            client.mine { [unowned self] r in
                if case .success(let list) = r { mine = list; publish(force: false) }
            }
        }
        client.issues(ids) { [unowned self] r in
            switch r {
            case .success(let found):
                for id in ids where fetchedAt[id].map({ started > $0 }) ?? true {
                    if let i = found[id] { issues[id] = i; fetchedAt[id] = started; errors[id] = nil }
                    else { errors[id] = "not found in Linear" }
                }
                if connected { status("ok", "Connected as \(connectedAs!)\(dryRun ? ", dry run" : "")") }
            case .failure(let e):
                for id in ids { errors[id] = "\(e)" }
                if case .unauthorized = e { connectedAs = nil; status("setup", "Linear refused the API key.") }
                else { status("offline", "Can't reach Linear: \(e)") }
            }
            publish(force: false)
        }
    }

    // MARK: telling Maxwell

    func pending(_ s: LinearSession) -> [LinearSuggestion] {
        guard connected, sync != "off", let id = links[s.id], let i = issues[id] else { return [] }
        return LinearRules.suggestions(s, i, settled: settled)
    }

    func publish(force: Bool) {
        let now = Date()
        var suggested: [[String: Any]] = []
        for s in sessions.values.sorted(by: { $0.lastEventAt > $1.lastEventAt }) {
            let id = links[s.id]
            let p = pending(s)
            let a = LinearRules.annotation(s, issueId: id, issue: id.flatMap { issues[$0] }, error: id.flatMap { errors[$0] },
                                           fetchedAt: id.flatMap { fetchedAt[$0] }, now: now, hasKey: hasKey, connected: connected, pending: p)
            let data = (try? JSONSerialization.data(withJSONObject: a, options: [.sortedKeys])) ?? Data()
            if force || lastSent[s.id] != data {
                // Unlinked sessions get one empty note, to clear an old one, then nothing.
                if id != nil || lastSent[s.id] != nil || force { io.notify("session/annotate", a) }
                lastSent[s.id] = data
            }
            guard let id else { continue }
            let issue = issues[id]
            for sug in p {
                if sync == "auto" { perform(sug) { _ in }; continue }
                suggested.append(["id": "\(sug.key)@\(s.id)", "title": "\(id) \(issue?.title ?? "")", "subtitle": "\(sug.why(s)) · \(s.title)",
                                  "badge": issue.map { ["text": $0.state.name, "tone": LinearRules.tone($0)] } ?? NSNull(), "session": s.id,
                                  "actions": [["action": sug.action, "title": issue.map { sug.title($0) } ?? sug.action], ["action": "dismiss", "title": "Not now"]]])
            }
        }
        let view = LinearBoard.view(mine: mine, issues: issues, links: links, sessions: sessions, suggested: suggested, connected: connected)
        io.notify("panel/set", ["panel": "tickets", "view": view])
    }


    // MARK: actions

    func run(_ p: [String: Any], _ reply: @escaping PluginIO.Reply) {
        let action = (p["action"] as? String) ?? ""
        let item = p["item"] as? String
        var sessionId = p["session"] as? String
        var key: String?
        if let item, let at = item.lastIndex(of: "@") {
            sessionId = String(item[item.index(after: at)...])
            key = String(item[..<at])
        }
        let s = sessionId.flatMap { sessions[$0] }
        let issue = s.flatMap { links[$0.id] }.flatMap { issues[$0] }
        let fail = { (m: String) in reply(.failure(.init(code: 1, message: m))) }
        switch action {
        case "refresh":
            connect(); reply(.success(["message": "Refreshing Linear…"]))
        case "open-ticket" where item?.hasPrefix("issue:") == true:
            let id = String(item!.dropFirst(6))
            guard let i = issues[id] ?? mine.first(where: { $0.identifier == id }) else { return fail("\(id) isn't read from Linear yet.") }
            io.request("open", ["url": i.url]) { _ in }
            reply(.success([String: Any]()))
        case "open-ticket":
            guard let issue else { return fail("This session isn't linked to a Linear ticket.") }
            io.request("open", ["url": issue.url]) { _ in }
            reply(.success([String: Any]()))
        case "dismiss":
            guard let key else { return fail("Nothing to dismiss.") }
            settled.insert(key); saveSettled(); publish(force: false)
            reply(.success([String: Any]()))
        case "move-started", "move-done", "comment-pr":
            guard let s else { return fail("No session.") }
            guard let sug = pending(s).first(where: { $0.action == action && (key == nil || $0.key == key) }) else {
                return fail(issue == nil ? "This session isn't linked to a Linear ticket." : "Nothing to do: \(issue!.identifier) is \(issue!.state.name).")
            }
            perform(sug) { r in
                switch r {
                case .success(let m): reply(.success(["message": m]))
                case .failure(let e): fail("Linear: \(e)")
                }
            }
        default: fail("Unknown action \(action).")
        }
    }

    func perform(_ sug: LinearSuggestion, _ done: @escaping (Result<String, LinearError>) -> Void) {
        guard let client, let issue = issues[sug.issue], !inFlight.contains(sug.key) else { return done(.failure(.graphql("not connected"))) }
        inFlight.insert(sug.key)
        let finish = { [unowned self] (r: Result<String, LinearError>) in
            inFlight.remove(sug.key)
            if case .success = r { settled.insert(sug.key); saveSettled(); if !dryRun { refresh() } else { publish(force: false) } }
            done(r)
        }
        switch sug.kind {
        case .start:
            guard let st = issue.target("started") else { return finish(.failure(.graphql("the team has no started state"))) }
            client.move(issue, to: st, finish)
        case .done:
            guard let st = issue.target("completed") else { return finish(.failure(.graphql("the team has no completed state"))) }
            client.move(issue, to: st, finish)
        case .prOpened(let n):
            let cwd = sessions[sug.session]?.cwd ?? ""
            DispatchQueue.global().async {
                let url = Self.prURL(n, cwd: cwd)
                DispatchQueue.main.async { client.comment(issue, body: "PR #\(n) is open\(url.map { ": \($0)" } ?? ".")", finish) }
            }
        }
    }

    /// The new part of a transcript, 1 MB at a time: transcripts reach hundreds of MB, and only
    /// lines that can name a ticket are parsed.
    static func read(_ path: String, from start: TranscriptVotes, teams: Set<String>) -> TranscriptVotes {
        var v = start
        guard let h = FileHandle(forReadingAtPath: path) else { return v }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        if size < v.offset { v = TranscriptVotes() }
        try? h.seek(toOffset: v.offset)
        var carry = Data()
        while true {
            let more: Bool = autoreleasepool {
                guard let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
                var buf = carry + chunk
                guard let last = buf.lastIndex(of: 0x0A) else { carry = buf; return true }
                let whole = buf[buf.startIndex...last]
                carry = Data(buf[buf.index(after: last)...])
                buf = Data()
                v.offset += UInt64(whole.count)
                var lineStart = whole.startIndex
                while let nl = whole[lineStart...].firstIndex(of: 0x0A) {
                    let line = whole[lineStart..<nl]
                    lineStart = whole.index(after: nl)
                    if TranscriptVotes.worthParsing(line, pending: !v.creating.isEmpty) { v.feed(Substring(String(decoding: line, as: UTF8.self)), teams: teams) }
                }
                return true
            }
            if !more { break }
        }
        return v
    }

    static func currentBranch(_ cwd: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", cwd, "branch", "--show-current"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let b = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return p.terminationStatus == 0 && !b.isEmpty ? b : nil
    }

    /// The PR's link from `gh`, in the session's folder; nil when gh can't say within 5 s.
    static func prURL(_ n: Int, cwd: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["gh", "pr", "view", "\(n)", "--json", "url", "-q", ".url"]
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(5)
        while p.isRunning, Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); return nil }
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.hasPrefix("https://") ? s : nil
    }

    // MARK: memory

    var settledFile: URL { dataDir.appendingPathComponent("settled.json") }
    func loadSettled() { settled = Set((try? JSONSerialization.jsonObject(with: Data(contentsOf: settledFile))) as? [String] ?? []) }
    func saveSettled() {
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: settled.sorted()).write(to: settledFile)
    }
}

LinearPlugin().start()
