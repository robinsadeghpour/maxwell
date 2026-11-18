import Foundation
import CoreServices

/// Watches directories with FSEvents and calls back (on main) after a quiet period.
final class DirWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: ([String]) -> Void

    init(paths: [String], latency: Double = 0.3, fileEvents: Bool = false, onChange: @escaping ([String]) -> Void) {
        self.onChange = onChange
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, n, paths, _, _ in
            let me = Unmanaged<DirWatcher>.fromOpaque(info!).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            me.onChange(Array(list.prefix(n)))
        }
        var flags = kFSEventStreamCreateFlagUseCFTypes
        if fileEvents { flags |= kFSEventStreamCreateFlagFileEvents }
        stream = FSEventStreamCreate(nil, cb, &ctx, existing as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                     FSEventStreamCreateFlags(flags))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
    }
}

/// `claude agents --json` per account, re-run when that account's sessions/ or jobs/
/// folder changes (and every 30 s as a fallback). Results become `.agents` events.
final class AgentsProbe {
    private let queue = DispatchQueue(label: "maxwell.agents")
    private var watchers: [DirWatcher] = []
    private var timer: Timer?
    private var pending = Set<AccountID>()
    private let emit: (Event) -> Void
    private var accounts: [Account]

    init(accounts: [Account], emit: @escaping (Event) -> Void) {
        self.accounts = accounts
        self.emit = emit
        for a in accounts {
            let dirs = ["sessions", "jobs"].map { a.configDir.appendingPathComponent($0).path }
            watchers.append(DirWatcher(paths: dirs, latency: 0.5) { [weak self] _ in self?.refresh(a.id) })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refreshAll() }
        refreshAll()
    }

    func refreshAll() { accounts.forEach { refresh($0.id) } }

    /// Last reply per transcript, keyed by its modification date. Touched only on `queue` (or the CLI's one thread).
    private static var replies: [String: (Date, (text: String?, at: Date?))] = [:]
    private static var firstPrompts: [String: String?] = [:]

    /// One account's live sessions, with title, last reply and last activity read from disk.
    static func snapshot(_ account: Account) -> AgentsSnapshot? {
        let at = Date()
        guard var snap = ClaudeCLI.agents(account).flatMap({ EventParser.parseAgents($0, accountId: account.id, at: at) }) else { return nil }
        for i in snap.entries.indices {
            let e = snap.entries[i]
            // The listing folds "shell" into "busy" and drops when the status changed; the
            // process's own file keeps both. Background sessions also have Claude Code's verdict on the turn.
            // A running process always has both files; one Maxwell can't read means Claude Code changed
            // them, and the groups fall back to weaker evidence: say so instead of guessing quietly.
            if let pid = e.pid {
                let file = account.configDir.appendingPathComponent("sessions/\(pid).json")
                let data = FileManager.default.contents(atPath: file.path)
                snap.entries[i].nameIsYours = data.flatMap { EventParser.parseNameIsYours($0, sessionId: e.sessionId) }
                if let data, let own = EventParser.parsePidFile(data, sessionId: e.sessionId) {
                    snap.entries[i].status = own.status
                    snap.entries[i].statusAt = own.at
                } else {
                    snap.entries[i].unverified = "can't read \(file.path)"
                }
            }
            if case .background(let short) = e.reach {
                let file = account.configDir.appendingPathComponent("jobs/\(short)/state.json")
                if let data = FileManager.default.contents(atPath: file.path), let job = EventParser.parseJob(data) {
                    snap.entries[i].job = job
                } else if e.pid != nil {
                    snap.entries[i].unverified = snap.entries[i].unverified ?? "can't read \(file.path)"
                }
            }
            snap.entries[i].title = Transcripts.tabTitle(e.sessionId)
            let path = Transcripts.defaultPath(sessionId: e.sessionId, cwd: e.cwd, account: account)
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            snap.entries[i].used = (attrs?[.size] as? Int ?? 0) > 0
            let mtime = attrs?[.modificationDate] as? Date
            let reply: (text: String?, at: Date?)
            if let mtime, let (seen, cached) = replies[path], seen == mtime {
                reply = cached
            } else {
                reply = Transcripts.lastReply(path)
                if let mtime { replies[path] = (mtime, reply) }
            }
            snap.entries[i].lastMessage = reply.text
            snap.entries[i].lastActiveAt = reply.at
            snap.entries[i].runningTasks = mtime == nil ? nil : Transcripts.runningTasks(path, since: e.startedAt)
            if let cached = firstPrompts[path] { snap.entries[i].firstPrompt = cached } else if mtime != nil {
                let p = Transcripts.firstPrompt(path)
                firstPrompts[path] = p
                snap.entries[i].firstPrompt = p
            }
        }
        Transcripts.TaskScans.shared.save()
        return snap
    }

    /// A listing taken now on the probe's queue, handed back on main without folding it in.
    func snapshotNow(_ account: Account, then: @escaping (AgentsSnapshot?) -> Void) {
        queue.async {
            let snap = Self.snapshot(account)
            DispatchQueue.main.async { then(snap) }
        }
    }

    /// Accounts whose files changed while a listing of them was running: list them once more after it,
    /// or that change waits for the 30 s timer.
    private var again = Set<AccountID>()

    func refresh(_ id: AccountID, then: (() -> Void)? = nil) {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        if then == nil {
            guard !pending.contains(id) else { again.insert(id); return }
            pending.insert(id)
        }
        queue.async { [weak self] in
            let snap = Self.snapshot(account)
            DispatchQueue.main.async {
                guard let self else { return }
                if then == nil { self.pending.remove(id) }
                if let snap { self.emit(.agents(snap)) }
                then?()
                if self.again.remove(id) != nil { self.refresh(id) }
            }
        }
    }
}

/// The plain-code repo check: clean worktree, nothing unpushed, PR merged or none.
final class DoneChecker {
    private let queue = DispatchQueue(label: "maxwell.donecheck")
    private var inFlight = Set<SessionID>()
    private var prCache: [String: (DoneCheck.PRState, Date)] = [:]
    private let emit: (Event) -> Void

    init(emit: @escaping (Event) -> Void) { self.emit = emit }

    func check(_ s: Session) {
        guard !inFlight.contains(s.id) else { return }
        inFlight.insert(s.id)
        let id = s.id, cwd = s.cwd
        queue.async { [weak self] in
            guard let self else { return }
            let check = self.evaluate(cwd: cwd)
            DispatchQueue.main.async {
                self.inFlight.remove(id)
                self.emit(.doneCheck(id, check))
            }
        }
    }

    /// `evaluate` on the checker's queue, handed back on main.
    func evaluateNow(cwd: String, then: @escaping (DoneCheck) -> Void) {
        queue.async {
            let check = self.evaluate(cwd: cwd)
            DispatchQueue.main.async { then(check) }
        }
    }

    /// Worktree, unpushed commits and PR state for a folder. Blocking; call off the main thread.
    /// Anything git or gh cannot answer stays nil or unknown, never a pass.
    func evaluate(cwd: String) -> DoneCheck {
        var check = DoneCheck(at: Date(), repo: false, dirtyFiles: nil, unpushed: nil, pr: .unknown("not checked"), branch: nil)
        let git = "/usr/bin/git"
        guard ClaudeCLI.run(git, ["-C", cwd, "rev-parse", "--is-inside-work-tree"], timeout: 5).status == 0 else { return check }
        check.repo = true
        // Claude Code keeps worktrees in .claude/worktrees inside the repo: other sessions' checkouts, not
        // changes here. -uall lists untracked files one by one, so other files under .claude/ still count.
        let status = ClaudeCLI.run(git, ["-C", cwd, "status", "--porcelain", "-uall", "--", ":/", ":(top,exclude).claude/worktrees"], timeout: 10)
        if status.status == 0 { check.dirtyFiles = status.out.split(separator: "\n").count }
        let branch = ClaudeCLI.run(git, ["-C", cwd, "branch", "--show-current"], timeout: 5).out.trimmingCharacters(in: .whitespacesAndNewlines)
        check.branch = branch.isEmpty ? nil : branch
        let base = ["main", "master"].first {
            ClaudeCLI.run(git, ["-C", cwd, "rev-parse", "--verify", "--quiet", "refs/heads/\($0)"], timeout: 5).status == 0
        }
        let ahead = ClaudeCLI.run(git, ["-C", cwd, "rev-list", "--count", "HEAD", "--not", "--remotes"] + (base.map { [$0] } ?? []), timeout: 10)
        if ahead.status == 0 { check.unpushed = Int(ahead.out.trimmingCharacters(in: .whitespacesAndNewlines)) }
        check.pr = prState(cwd: cwd, branch: branch)
        return check
    }

    /// The PR for the branch (cached 5 minutes). The default branch never has one.
    private func prState(cwd: String, branch: String) -> DoneCheck.PRState {
        if branch.isEmpty { return .unknown("detached HEAD") }
        if ["main", "master", "develop"].contains(branch) { return .none("on \(branch), no PR") }
        let key = cwd + "#" + branch
        if let (state, at) = prCache[key], Date().timeIntervalSince(at) < 300 { return state }
        let r = ClaudeCLI.run(ClaudeCLI.ghPath, ["pr", "view", branch, "--json", "state,number"], cwd: cwd, timeout: 15)
        let state: DoneCheck.PRState
        let err = r.err.lowercased()
        if r.status != 0 {
            // gh's answers that mean "nothing to merge"; any other failure (auth, network) is unknown.
            if err.contains("no pull requests found") { state = .none("no PR for \(branch)") }
            else if err.contains("no git remotes found") || err.contains("none of the git remotes") { state = .none("no GitHub remote") }
            else { state = .unknown("gh failed: \(r.err.split(separator: "\n").first.map(String.init) ?? "exit \(r.status)")") }
        } else if let obj = try? JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any],
                  let n = obj["number"] as? Int {
            switch obj["state"] as? String {
            case "MERGED": state = .merged(n)
            case "CLOSED": state = .closed(n)
            default: state = .open(n)
            }
        } else {
            state = .unknown("gh output unreadable")
        }
        if case .unknown = state {} else { prCache[key] = (state, Date()) }
        return state
    }
}

/// Reads session transcripts for the files a session writes or names.
enum Transcripts {
    /// An optional UserPromptSubmit hook can keep a short task title per session here.
    /// Model-written, so it can carry a "Tab title:" prefix or a limit message instead of a title.
    static func tabTitle(_ sessionId: SessionID) -> String? {
        let f = Paths.home.appendingPathComponent(".claude/tab-titles/\(sessionId)")
        guard var t = (try? String(contentsOf: f, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if t.lowercased().hasPrefix("tab title:") { t = String(t.dropFirst("tab title:".count)).trimmingCharacters(in: .whitespaces) }
        if t.contains("hit your") || t.contains("limit") && t.contains("resets") || t.contains("API Error") || t.hasPrefix("Failed to")
            || t.count < 3 || t.contains("\n") { return nil }
        return t
    }

    /// The last assistant text in a transcript (its last 256 KB), and when the last prompt or
    /// reply was written. The file's mtime is no use: Claude Code rewrites old transcripts on resume.
    static func lastReply(_ path: String, window: UInt64 = 256 * 1024) -> (text: String?, at: Date?) {
        guard let h = FileHandle(forReadingAtPath: path) else { return (nil, nil) }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > window ? size - window : 0)
        let data = (try? h.readToEnd()) ?? Data()
        var at: Date?
        for line in data.split(separator: 0x0A).reversed() {
            guard line.count < 2_000_000, let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = obj["type"] as? String, type == "assistant" || type == "user" else { continue }
            if at == nil, let ts = obj["timestamp"] as? String { at = iso.date(from: ts) }
            guard type == "assistant", let msg = obj["message"] as? [String: Any], let content = msg["content"] as? [[String: Any]] else { continue }
            let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n\n")
            if !text.isEmpty { return (String(text.suffix(2000)), at) }
        }
        return (nil, at)
    }

    /// Background shells and async subagents still running (see `TaskLedger`). Reads only the
    /// bytes added since the last scan, 4 MB at a time (a first read can be a 160 MB transcript).
    /// Scans persist across launches, keyed by path and inode; nil when there is no transcript.
    static func runningTasks(_ path: String, since: Date) -> [BackgroundTask]? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let inode = ((try? FileManager.default.attributesOfItem(atPath: path))?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (try? h.seekToEnd()) ?? 0
        var scan = TaskScans.shared.scans[path] ?? TaskScan(inode: inode)
        if size < scan.offset || scan.inode != inode { scan = TaskScan(inode: inode) }
        let start = scan.offset
        try? h.seek(toOffset: scan.offset)
        var carry = Data()
        while true {
            let more: Bool = autoreleasepool {
                guard let chunk = try? h.read(upToCount: 4 << 20), !chunk.isEmpty else { return false }
                let buf = carry + chunk
                // Only whole lines; a half-written last line waits for the next chunk or scan.
                guard let lastNL = buf.lastIndex(of: 0x0A) else { carry = buf; return true }
                for line in buf[buf.startIndex...lastNL].split(separator: 0x0A) { scan.ledger.read(line) }
                scan.offset += UInt64(lastNL - buf.startIndex + 1)   // carry bytes were not counted yet
                carry = Data(buf[(lastNL + 1)...])
                return true
            }
            if !more { break }
        }
        if scan.offset != start || TaskScans.shared.scans[path] == nil { TaskScans.shared.scans[path] = scan; TaskScans.shared.dirty = true }
        return scan.ledger.running(since: since)
    }

    struct TaskScan: Codable { var inode: UInt64; var offset: UInt64 = 0; var ledger = TaskLedger() }

    /// ~/.local/state/maxwell/task-scans-2.json: where each transcript's scan stopped, so a launch
    /// reads only what was written since. A cache: deleting it costs one full read, and a file
    /// in an older shape fails to decode and is rebuilt the same way. The name changes when the
    /// ledger starts reading notices differently, so scans made by the old rules aren't reused.
    final class TaskScans {
        static let shared = TaskScans()
        var scans: [String: TaskScan]
        var dirty = false
        private let url = Paths.stateDir.appendingPathComponent("task-scans-2.json")
        private init() {
            scans = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: TaskScan].self, from: $0) } ?? [:]
        }
        func save() {
            guard dirty, let data = try? JSONEncoder().encode(scans) else { return }
            try? data.write(to: url, options: .atomic)
            dirty = false
        }
    }

    /// The first thing typed into a session (its first 256 KB), skipping command and system lines.
    static func firstPrompt(_ path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let data = h.readData(ofLength: 256 * 1024)
        for line in data.split(separator: 0x0A) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], obj["type"] as? String == "user",
                  obj["isMeta"] as? Bool != true, let msg = obj["message"] as? [String: Any] else { continue }
            let text = (msg["content"] as? String)
                ?? (msg["content"] as? [[String: Any]])?.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: " ")
            guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, !t.hasPrefix("<"), !t.hasPrefix("Caveat:") else { continue }
            return t
        }
        return nil
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func path(_ s: Session, account: Account?) -> String? {
        if let t = s.transcriptPath { return t }
        return account.map { defaultPath(sessionId: s.id, cwd: s.cwd, account: $0) }
    }

    /// Where Claude Code keeps a session's transcript: projects/<cwd with non-alphanumerics as "-">/<id>.jsonl.
    static func defaultPath(sessionId: SessionID, cwd: String, account: Account) -> String {
        let slug = String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        return account.configDir.appendingPathComponent("projects/\(slug)/\(sessionId).jsonl").path
    }

    /// What the viewer should show from one transcript line: a Markdown file the session wrote or
    /// named, or an artifact it published, opened or named. `reload` marks a republish.
    static func viewerItem(inLine s: String, cwd: String) -> (item: ViewerItem, reload: Bool)? {
        if s.contains("claude.ai/"), let a = ArtifactTranscript.sighting(inLine: s) { return (.artifact(a.link, title: a.title), a.republished) }
        if s.contains(".md"), let u = markdown(inLine: s, cwd: cwd) { return (.file(u), false) }
        return nil
    }

    /// The last file or artifact the session made or named in the last `window` bytes.
    static func lastItem(transcript: String, cwd: String, window: Int = 512 * 1024) -> ViewerItem? {
        guard let h = FileHandle(forReadingAtPath: transcript) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > UInt64(window) ? size - UInt64(window) : 0)
        let data = (try? h.readToEnd()) ?? Data()
        var found: ViewerItem?
        for line in data.split(separator: 0x0A) where line.count < 4_000_000 {
            guard let s = String(data: line, encoding: .utf8), s.contains(".md") || s.contains("claude.ai/") else { continue }
            if let hit = viewerItem(inLine: s, cwd: cwd) { found = hit.item }
        }
        return found
    }

    /// The last Markdown file the session wrote or named in the last `window` bytes.
    static func lastMarkdown(transcript: String, cwd: String, window: Int = 512 * 1024) -> URL? {
        guard let h = FileHandle(forReadingAtPath: transcript) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > UInt64(window) ? size - UInt64(window) : 0)
        let data = (try? h.readToEnd()) ?? Data()
        var found: URL?
        for line in data.split(separator: 0x0A) where line.count < 4_000_000 {
            guard let s = String(data: line, encoding: .utf8), s.contains(".md") else { continue }
            if let u = markdown(inLine: s, cwd: cwd) { found = u }
        }
        return found
    }

    /// A Markdown path from one transcript line: a Write/Edit tool call, or a path in assistant text.
    static func markdown(inLine s: String, cwd: String) -> URL? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
              obj["type"] as? String == "assistant",
              let msg = obj["message"] as? [String: Any], let content = msg["content"] as? [[String: Any]] else { return nil }
        var found: URL?
        for c in content {
            if c["type"] as? String == "tool_use", ["Write", "Edit", "MultiEdit"].contains(c["name"] as? String ?? ""),
               let input = c["input"] as? [String: Any], let p = input["file_path"] as? String, isMarkdown(p) {
                found = URL(fileURLWithPath: p)
            } else if c["type"] as? String == "text", let text = c["text"] as? String {
                for p in paths(in: text, cwd: cwd) { found = p }
            }
        }
        return found.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    static func isMarkdown(_ p: String) -> Bool { p.hasSuffix(".md") || p.hasSuffix(".markdown") }

    static func paths(in text: String, cwd: String) -> [URL] {
        let pattern = #"(?:~|/|\.{0,2}/|[A-Za-z0-9_\-]+/)[A-Za-z0-9_\-./~]*\.md\b"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            var p = ns.substring(with: m.range)
            if p.hasPrefix("~") { p = (p as NSString).expandingTildeInPath }
            if !p.hasPrefix("/") { p = (cwd as NSString).appendingPathComponent(p) }
            let u = URL(fileURLWithPath: p).standardizedFileURL
            return FileManager.default.fileExists(atPath: u.path) ? u : nil
        }
    }
}

/// Live: FSEvents on each account's projects/ folder; new transcript bytes are scanned
/// for Markdown writes and mentions and artifact publishes, per session.
final class TranscriptWatcher {
    private var watchers: [DirWatcher] = []
    private var offsets: [String: UInt64] = [:]
    private let queue = DispatchQueue(label: "maxwell.transcripts")
    private let startedAt = Date()
    var onItem: ((SessionID, ViewerItem, Bool) -> Void)?
    var cwdFor: ((SessionID) -> String?)?

    init(accounts: [Account]) {
        let dirs = accounts.map { $0.configDir.appendingPathComponent("projects").path }
        watchers.append(DirWatcher(paths: dirs, latency: 0.15, fileEvents: true) { [weak self] paths in
            self?.changed(paths.filter { $0.hasSuffix(".jsonl") && !$0.contains("/subagents/") })
        })
    }

    private func changed(_ paths: [String]) {
        for p in Set(paths) {
            let sid = ((p as NSString).lastPathComponent as NSString).deletingPathExtension
            guard let cwd = cwdFor?(sid) else { continue }
            queue.async { [weak self] in
                guard let self, let h = FileHandle(forReadingAtPath: p) else { return }
                defer { try? h.close() }
                let size = (try? h.seekToEnd()) ?? 0
                // A transcript seen for the first time is read from its start if it was created
                // while Maxwell runs (a new session, or one that moved into a worktree), else from its end.
                let born = (try? FileManager.default.attributesOfItem(atPath: p))?[.creationDate] as? Date
                let start = self.offsets[p] ?? (born.map { $0 > self.startedAt } == true ? 0 : size)
                self.offsets[p] = size
                guard size > start else { return }
                try? h.seek(toOffset: start)
                let data = (try? h.readToEnd()) ?? Data()
                // The last item wins; a republish of it anywhere in this chunk still asks for a reload.
                var found: ViewerItem?, reload = false
                for line in data.split(separator: 0x0A) {
                    guard let s = String(data: line, encoding: .utf8), s.contains(".md") || s.contains("claude.ai/") else { continue }
                    if let hit = Transcripts.viewerItem(inLine: s, cwd: cwd) {
                        if !hit.item.same(as: found) { reload = false }
                        found = hit.item
                        reload = reload || hit.reload
                    }
                }
                if let found { DispatchQueue.main.async { self.onItem?(sid, found, reload) } }
            }
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// What each live session's transcript points at (see `ProjectVotes`), off the main thread.
/// The first read of a transcript is its last 4 MB; later reads take only what was added.
final class ProjectHintScanner {
    private struct Scan { var inode: UInt64; var offset: UInt64; var votes = ProjectVotes() }
    private let queue = DispatchQueue(label: "maxwell.hints", qos: .utility)
    private var scans: [String: Scan] = [:]
    private var keysByRoot: [String: String?] = [:]
    private var sent: [SessionID: String?] = [:]
    private var projects = Projects(rules: [])
    private let emit: ([Event]) -> Void
    static let window: UInt64 = 4 << 20

    init(emit: @escaping ([Event]) -> Void) { self.emit = emit }

    func scan(_ sessions: [(id: SessionID, cwd: String, transcript: String)], rules: [ProjectRule]) {
        queue.async { [self] in
            if projects.rules != rules { projects = Projects(rules: rules) }
            var keys: [String: String] = [:]
            for root in Set(sessions.compactMap { Projects.repoRoot($0.cwd) }) {
                if keysByRoot[root] == nil { keysByRoot[root] = .some(LinearKeys.key(branches: Self.branches(root))) }
                if let k = keysByRoot[root] ?? nil { keys[k] = projects.name(for: root) }
            }
            var events: [Event] = []
            for s in sessions {
                guard let votes = autoreleasepool(invoking: { read(s.transcript) }) else { continue }
                let current = projects.name(for: s.cwd)
                let hint = votes.suggestion(current: current, project: { p in
                    self.projects.known(p) ?? (p == s.cwd || p.hasPrefix(s.cwd + "/") ? current : nil)
                }, keys: keys)
                if sent[s.id] != .some(hint) { sent[s.id] = .some(hint); events.append(.projectSuggested(s.id, hint)) }
            }
            if !events.isEmpty { DispatchQueue.main.async { self.emit(events) } }
        }
    }

    /// Votes so far for one transcript, reading only bytes not read before.
    private func read(_ path: String) -> ProjectVotes? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let inode = ((try? FileManager.default.attributesOfItem(atPath: path))?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (try? h.seekToEnd()) ?? 0
        var scan = scans[path] ?? Scan(inode: inode, offset: size > Self.window ? size - Self.window : 0)
        if size < scan.offset || scan.inode != inode { scan = Scan(inode: inode, offset: size > Self.window ? size - Self.window : 0) }
        guard size > scan.offset else { return scan.votes }
        try? h.seek(toOffset: scan.offset)
        let data = (try? h.read(upToCount: Int(min(size - scan.offset, Self.window)))) ?? Data()
        // Whole lines only; a window that starts mid-line drops that first part.
        guard let lastNL = data.lastIndex(of: 0x0A) else { scans[path] = scan; return scan.votes }
        var lines = data[data.startIndex...lastNL].split(separator: 0x0A)
        if scan.offset > 0, scans[path] == nil, !lines.isEmpty { lines.removeFirst() }
        for line in lines where line.count < 4_000_000 {
            if let s = String(data: line, encoding: .utf8) { scan.votes.read(Substring(s)) }
        }
        scan.offset += UInt64(lastNL - data.startIndex + 1)
        scans[path] = scan
        return scan.votes
    }

    /// Branch names from the repo's refs, read as files (no git process).
    static func branches(_ root: String) -> [String] {
        let git = root + "/.git"
        var out: [String] = []
        for dir in ["refs/heads", "refs/remotes"] {
            let base = git + "/" + dir
            if let e = FileManager.default.enumerator(atPath: base) { while let f = e.nextObject() as? String { out.append(f) } }
        }
        let packed = (try? String(contentsOfFile: git + "/packed-refs", encoding: .utf8)) ?? ""
        for l in packed.split(separator: "\n") {
            guard let r = l.range(of: " refs/") else { continue }
            out.append(String(l[r.upperBound...]))
        }
        return out
    }
}
