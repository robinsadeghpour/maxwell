import AppKit
import UserNotifications

/// Owns AppState. Every change goes through `apply(_:)`, which runs the reducer and
/// tells the UI. Probes (event log, agents, done check) only produce events.
final class Store {
    private(set) var state: AppState
    private(set) var config: Config
    private let log: EventLog
    private var agents: AgentsProbe?
    private lazy var doneChecker = DoneChecker { [weak self] in self?.apply([$0]) }
    private var transcripts: TranscriptWatcher?
    private lazy var hints = ProjectHintScanner { [weak self] in self?.apply($0) }
    private var checkTimer: Timer?
    private var resumeTimers: [SessionID: Timer] = [:]
    private(set) var scheduledResumes: [SessionID: Date] = [:]
    private var notifyAfter: Date?
    var onChange: ((AppState) -> Void)?
    var onViewerItem: ((SessionID, ViewerItem, Bool) -> Void)?
    /// Plugins (docs/plugins.md). Started with the other live sources, after the window.
    let plugins: PluginHost
    var onPluginsChanged: (() -> Void)?
    private var projects: Projects
    private var pluginSyncQueued = false
    var onToast: ((String) -> Void)?
    /// macOS answered the notification permission request (or had answered it before).
    var onNotificationsAnswered: (() -> Void)?

    init(config: Config) {
        self.config = config
        log = EventLog(url: Paths.eventLog)
        projects = Projects(rules: config.projects)
        let env = ProcessInfo.processInfo.environment
        plugins = PluginHost(paths: .init(
            user: env["MAXWELL_PLUGINS_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? Paths.configFile.deletingLastPathComponent().appendingPathComponent("plugins"),
            bundled: Bundle.main.resourceURL?.appendingPathComponent("plugins"),
            logs: Paths.stateDir.appendingPathComponent("plugins"),
            data: Paths.stateDir.appendingPathComponent("plugins")),
            // Test and agent runs never touch the Keychain: a rebuilt app is a new app to macOS and would ask.
            secrets: quietTest ? MemorySecrets() : KeychainSecrets(),
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
        state = log.readNew().reduce(into: AppState(accounts: config.accounts)) { reduce(into: &$0, $1) }
        Titles.auto = config.autoTitles
    }

    /// Starts the live sources. Called once the window is on screen.
    func start() {
        notifyAfter = Date().addingTimeInterval(8)
        log.tail { [weak self] in self?.apply($0); self?.confirmHooks($0) }
        agents = AgentsProbe(accounts: config.accounts) { [weak self] in self?.apply([$0]) }
        let tw = TranscriptWatcher(accounts: config.accounts)
        tw.cwdFor = { [weak self] id in self?.state.sessions[id]?.cwd }
        tw.onItem = { [weak self] id, item, reload in self?.onViewerItem?(id, item, reload) }
        transcripts = tw
        checkTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in self?.recheckAll() }
        recheckAll()
        plugins.apply = { [weak self] in self?.apply($0) }
        plugins.onChange = { [weak self] in self?.onPluginsChanged?() }
        plugins.onNotify = { [weak self] title, body, sid in
            guard let self, self.config.notify else { return }
            self.post(title: title, subtitle: nil, body: body, session: sid, sound: self.config.notifySound)
        }
        plugins.onOpen = { NSWorkspace.shared.open($0) }
        plugins.reload(config)
        syncPlugins()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            mark("notifications \(granted ? "allowed" : "not allowed")\(error.map { " (\($0.localizedDescription))" } ?? "")")
            DispatchQueue.main.async { self.onNotificationsAnswered?() }
        }
    }

    func apply(_ events: [Event]) {
        let before = state
        state = events.reduce(into: state) { reduce(into: &$0, $1) }
        guard state != before else { return }
        judgeCandidates()
        titleWeak()
        for (id, s) in state.sessions {
            let old = before.sessions[id]?.phase
            // A repo check older than the last activity is unknown; take a new one.
            if s.phase == .yourTurn, old != .yourTurn || (s.doneCheck.map { $0.at < s.lastEventAt } ?? true) { doneChecker.check(s) }
            if case .needsYou(let q) = s.phase, !(old.map { if case .needsYou = $0 { return true }; return false } ?? false) {
                notify(s, question: q)
            }
            if s.phase == .yourTurn, old == .working { notifyDone(s) }
        }
        bringInQueued()
        queuePluginSync()
        onChange?(state)
    }

    /// A hook sets the phase at once; a listing a few seconds later (when it is allowed to
    /// override the hook, see `Live.covers`) confirms or corrects it, e.g. a Stop while a subagent still runs.
    /// The probe drops a refresh while one for the account is running, so these stay cheap.
    private func confirmHooks(_ events: [Event]) {
        let accounts = Set(events.compactMap { e -> AccountID? in
            guard case .hook(let h) = e else { return nil }
            return state.accountId(forConfigDir: h.configDir)
        })
        for a in accounts {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in self?.agents?.refresh(a) }
        }
    }

    // MARK: plugins

    /// One `sessions/changed` per run-loop turn, however many events came in it.
    private func queuePluginSync() {
        guard !pluginSyncQueued else { return }
        pluginSyncQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.pluginSyncQueued = false
            self?.syncPlugins()
        }
    }

    func syncPlugins() {
        let now = Date(), rules = config.rules
        plugins.sessionsChanged(state.sessions.values.filter { $0.phase != .ended }.map { s in
            PluginHost.json(s, state: state, group: state.group(s, now: now, rules: rules), project: state.project(s, in: projects))
        })
    }

    /// Plugins with a check on the session: the ones a close must hear from again.
    func pluginsChecking(_ id: SessionID) -> [PluginID] {
        (state.notes[id] ?? [:]).filter { !$0.value.checks.isEmpty }.map(\.key)
    }

    func runPluginAction(_ plugin: PluginID, _ action: String, session: SessionID?, item: String? = nil) {
        plugins.run(plugin, action: action, session: session, item: item) { [weak self] r in
            switch r {
            case .success(let m?): self?.onToast?(m)
            case .success(nil): break
            case .failure(let e): self?.onToast?(e.message)
            }
        }
    }

    // MARK: bringing terminal sessions in

    /// Sessions waiting to move in once they finish their turn.
    private(set) var bringQueue: Set<SessionID> = []
    private var bringing: Set<SessionID> = []
    /// Reports each move: the session, and nil or why it didn't move.
    var onBrought: ((Session, String?) -> Void)?

    /// A session running in a terminal can move now unless it is mid-turn.
    func canBringInNow(_ s: Session) -> Bool { s.phase != .working }

    /// Moves now, or once the current turn ends.
    func bringIn(_ s: Session, force: Bool = false) {
        guard case .elsewhere = s.reach, !bringing.contains(s.id) else { return }
        if force || canBringInNow(s) { bringQueue.remove(s.id); start(s) } else { bringQueue.insert(s.id); onChange?(state) }
    }

    private func bringInQueued() {
        for id in bringQueue {
            guard let s = state.sessions[id] else { bringQueue.remove(id); continue }
            if case .elsewhere = s.reach {} else { bringQueue.remove(id); continue }
            if canBringInNow(s) { bringQueue.remove(id); start(s) }
        }
    }

    /// Ends the terminal's process (SIGTERM; Claude Code saves as it goes and exits cleanly),
    /// waits until it is gone, then resumes the conversation in the background under the same id.
    private func start(_ s: Session) {
        guard let account = state.account(s.accountId) else { onBrought?(s, "no account \(s.accountId)"); return }
        bringing.insert(s.id)
        // With auto titles off the session keeps the name it has: no --name on resume.
        let name = config.autoTitles ? String((s.name.isEmpty ? s.title : s.name).prefix(40)) : nil
        let skip = config.skipPermissions
        let newest = state.isNewestInFolder(s)
        DispatchQueue.global().async { [weak self] in
            let why = Self.move(s, account: account, name: name, skipPermissions: skip, newestInFolder: newest)
            DispatchQueue.main.async {
                guard let self else { return }
                self.bringing.remove(s.id)
                self.agents?.refresh(account.id) {
                    self.onBrought?(self.state.sessions[s.id] ?? s, why)
                    self.onChange?(self.state)
                }
            }
        }
    }

    private static func move(_ s: Session, account: Account, name: String?, skipPermissions: Bool, newestInFolder: Bool) -> String? {
        // Background sessions only start in folders Claude Code trusts. The terminal session was
        // already let in here (for the home folder, Claude Code asks every time and never saves
        // it), so record that before ending the terminal's process, never after.
        guard ClaudeCLI.trust(s.cwd, account: account) else {
            return "Maxwell couldn't record that Claude may work in \((s.cwd as NSString).abbreviatingWithTildeInPath). It still runs in your terminal."
        }
        var skip = skipPermissions
        switch ClaudeCLI.terminalProcess(s, account: account, newestInFolder: newestInFolder) {
        case .found(let pid, let skips):
            skip = skipPermissions || skips
            kill(pid, SIGTERM)
            let until = Date().addingTimeInterval(15)
            while kill(pid, 0) == 0, Date() < until { usleep(200_000) }
            if kill(pid, 0) == 0 { return "its terminal process didn't exit. It still runs in your terminal." }
        case .unsure(let n):
            return "\(n) Claude sessions run in \((s.cwd as NSString).abbreviatingWithTildeInPath) in your terminals and Maxwell can't tell which is this one. Quit it there (Ctrl-C twice), then bring it in."
        case .none:
            break
        }
        for attempt in 0..<3 {
            usleep(useconds_t(1_500_000 * (attempt + 1)))
            switch ClaudeCLI.resumeBackground(account: account, cwd: s.cwd, sessionId: s.id, name: name, skipPermissions: skip) {
            case .failure(let e): return "\(e)"
            case .success(let r) where r.copy:
                // Claude still saw the old process: drop the copy and try again.
                _ = ClaudeCLI.stop(account: account, shortId: r.short)
            case .success: return nil
            }
        }
        return "Claude kept starting a copy. The conversation is safe: claude --resume \(s.id)"
    }

    func recheckAll() {
        for s in state.sessions.values where s.phase == .yourTurn { doneChecker.check(s) }
        scanHints()
        syncPlugins()
    }

    /// Looks again (in the background) at where each live session's work goes.
    func scanHints() {
        let live = state.sessions.values.filter { $0.phase != .ended }.compactMap { s in
            Transcripts.path(s, account: state.account(s.accountId)).map { (id: s.id, cwd: s.cwd, transcript: $0) }
        }
        hints.scan(live, rules: config.projects)
    }

    func reloadConfig(_ c: Config) {
        let accountsChanged = c.accounts.map(\.configDir) != config.accounts.map(\.configDir)
        config = c
        Titles.auto = c.autoTitles
        projects = Projects(rules: c.projects)
        plugins.reload(c)
        if accountsChanged {
            state = log.readNew().reduce(into: AppState(accounts: c.accounts)) { reduce(into: &$0, $1) }
            agents = AgentsProbe(accounts: c.accounts) { [weak self] in self?.apply([$0]) }
        }
        onChange?(state)
    }

    private func notify(_ s: Session, question: String) {
        guard config.notify, announcing(s) else { return }
        post(title: s.title, subtitle: "Needs you · \(state.account(s.accountId)?.name ?? s.accountId)", body: question, session: s.id,
             sound: config.notifySound, key: "needs-\(s.id)-\(Int(s.lastEventAt.timeIntervalSince1970))")
    }

    private func notifyDone(_ s: Session) {
        guard config.notifyDone, announcing(s) else { return }
        // The status line a session ends its reply with says it best; otherwise the reply's first line.
        let wrap = s.lastMessage.flatMap(Wrap.parse)
        let body = wrap.map { $0.note.isEmpty ? $0.state.rawValue : "\($0.state.rawValue) · \($0.note)" }
            ?? s.lastMessage?.split(separator: "\n").first.map(String.init) ?? "Finished its turn."
        post(title: s.title, subtitle: "Done · \(state.account(s.accountId)?.name ?? s.accountId)", body: body, session: s.id,
             sound: config.notifyDoneSound, key: "done-\(s.id)-\(Int(s.lastEventAt.timeIntervalSince1970))")
    }

    /// Whether a change to this session is news. The first listings after launch would re-announce every
    /// waiting session, and the session on screen in the front window needs no banner.
    private func announcing(_ s: Session) -> Bool {
        guard let quiet = notifyAfter, Date() > quiet else { return false }
        return !(isOnScreen?(s.id) ?? false)
    }

    /// The session shown in Maxwell's window while Maxwell is the front app.
    var isOnScreen: ((SessionID) -> Bool)?

    /// Whether macOS lets Maxwell post its own notifications. Until it does, they go through osascript
    /// and show Script Editor's icon.
    func notificationsAllowed(_ done: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let ok = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            DispatchQueue.main.async { done(ok) }
        }
    }

    /// A macOS notification; clicking it opens the session. Maxwell plays the sound itself, so it is the
    /// same whether macOS has allowed Maxwell or not.
    func post(title: String, subtitle: String?, body: String, session: SessionID?, sound: String, key: String = UUID().uuidString) {
        DispatchQueue.main.async { Self.play(sound) }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                // Until Maxwell is allowed in System Settings › Notifications, post through osascript.
                let esc = { (x: String) in x.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
                let sub = subtitle.map { " subtitle \"\(esc($0))\"" } ?? ""
                let script = "display notification \"\(esc(body))\" with title \"\(esc(title))\"\(sub)"
                DispatchQueue.global().async { ClaudeCLI.run("/usr/bin/osascript", ["-e", script], timeout: 5) }
                mark("notified \(title) (osascript)")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            if let subtitle { content.subtitle = subtitle }
            content.body = body
            if let session { content.userInfo = ["session": session] }
            let req = UNNotificationRequest(identifier: key, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req) { error in mark("notified \(title)\(error.map { ": \($0.localizedDescription)" } ?? "")") }
        }
    }

    /// One of `Config.sounds`; "none" is silence.
    static func play(_ sound: String) {
        guard sound != "none" else { return }
        NSSound(named: NSSound.Name(sound))?.play()
    }

    // MARK: actions

    /// Starts a background session and resolves its full id from the next listing.
    func newSession(account: Account, cwd: String, name: String, model: String? = nil, prompt: String? = nil,
                    done: @escaping (Swift.Result<SessionID, ClaudeCLI.StartError>) -> Void) {
        let skip = config.skipPermissions
        DispatchQueue.global().async { [weak self] in
            let r = ClaudeCLI.startBackground(account: account, cwd: cwd, name: name, skipPermissions: skip, model: model, prompt: prompt)
            DispatchQueue.main.async {
                guard let self else { return }
                switch r {
                case .failure(let e): done(.failure(e))
                case .success(let short):
                    self.agents?.refresh(account.id) {
                        let id = self.state.sessions.values.first { $0.reach == .background(shortId: short) }?.id ?? short
                        self.apply([.started(id, account.id, name: name, cwd: cwd, shortId: short, at: Date())])
                        done(.success(id))
                    }
                }
            }
        }
    }

    func checks(_ s: Session, now: Date = Date()) -> [Check] { state.checks(s, now: now, rules: config.rules) }

    /// Sessions safe to close right now (the same verdict the sidebar shows).
    func safeToClose(now: Date = Date()) -> [Session] {
        state.sessions.values.filter { state.group($0, now: now, rules: config.rules) == .safeToClose }
    }

    // MARK: model reads

    private let judgeQueue = DispatchQueue(label: "maxwell.judge")
    private var judging = Set<String>()
    private var judgeFailedAt: [String: Date] = [:]

    /// One model read per candidate reply, in the background, one at a time. The verdict comes
    /// back through the event log like every other record, so it is cached across launches.
    private func judgeCandidates() {
        let now = Date()
        for (s, hash) in state.judgeCandidates(now: now, rules: config.rules) where !judging.contains(hash) {
            if let failed = judgeFailedAt[hash], now.timeIntervalSince(failed) < 600 { continue }
            judging.insert(hash)
            let snapshot = state
            judgeQueue.async { [weak self] in
                Judge.judgeAndLog(s, hash: hash, state: snapshot, now: now)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.judging.remove(hash)
                    // A failed call is logged but not cached; wait before asking again.
                    if self.state.judgments[hash] == nil { self.judgeFailedAt[hash] = Date() }
                }
            }
        }
    }

    // MARK: titles

    private var titling = Set<SessionID>()
    private var titleFailedAt: [SessionID: Date] = [:]

    /// Sessions active in the last week whose title says little, once each has a first prompt
    /// and a reply to read. One at a time, on the judge's queue.
    private func titleWeak() {
        guard config.autoTitles else { return }
        let now = Date()
        let weak = state.sessions.values.filter {
            $0.weakTitle && $0.lastMessage != nil && $0.phase != .ended && $0.listedAt != nil
                && now.timeIntervalSince($0.lastEventAt) < 7 * 86400 && !titling.contains($0.id)
                && titleFailedAt[$0.id].map { now.timeIntervalSince($0) > 3600 } ?? true
        }
        for s in weak { suggestTitle(s) }
    }

    /// Asks the model for a title now (also "Suggest a Title" on a row).
    func suggestTitle(_ s: Session, done: ((String?) -> Void)? = nil) {
        guard !titling.contains(s.id), let account = state.most5hRoom(now: Date()) else { done?(nil); return }
        titling.insert(s.id)
        judgeQueue.async { [weak self] in
            let o = Titler.title(s, account: account)
            DispatchQueue.main.async {
                guard let self else { return }
                self.titling.remove(s.id)
                guard let t = o.title else { self.titleFailedAt[s.id] = Date(); done?(nil); return }
                self.record(MaxwellRecord.titled(s.id, t, byYou: false, replaced: s.hookTitle, costUSD: o.costUSD))
                done?(t)
            }
        }
    }

    /// Your title for a session; empty clears it, so the model's or Claude's shows again.
    func rename(_ id: SessionID, to text: String) {
        record(MaxwellRecord.titled(id, text.trimmingCharacters(in: .whitespacesAndNewlines), byYou: true))
    }

    // MARK: closing

    /// What happened to one session in a close.
    enum CloseOutcome { case closed, skipped(String), failed(String) }

    /// Closes the sessions you confirmed, one at a time. Right before each, it lists the
    /// account and checks the worktree again; anything not passing now, or a reply that changed
    /// since the sheet showed it, skips that session. Closing is `claude stop` only.
    func close(_ confirmed: [(id: SessionID, hash: String?)], done: @escaping ([(Session, CloseOutcome)]) -> Void) {
        var results: [(Session, CloseOutcome)] = []
        func next(_ rest: ArraySlice<(id: SessionID, hash: String?)>) {
            guard let item = rest.first else { return done(results) }
            let more = rest.dropFirst()
            guard let s = state.sessions[item.id], let a = state.account(s.accountId) else { return next(more) }
            recheck(s, account: a) { [weak self] fresh in
                guard let self else { return }
                let outcome: CloseOutcome? = {
                    guard let fresh else { return .skipped("gone from the session list") }
                    if fresh.lastMessage.map(Reply.hash) != item.hash { return .skipped("new reply since you confirmed") }
                    if let bad = self.checks(fresh).first(where: { $0.outcome != .pass }) {
                        return .skipped("\(bad.title): \(bad.detail)")
                    }
                    guard case .background = fresh.reach else { return .skipped("runs in another terminal; close it there") }
                    return nil
                }()
                if let outcome {
                    results.append((fresh ?? s, outcome))
                    return next(more)
                }
                self.stop(fresh!, account: a) { r in
                    results.append((fresh!, r))
                    next(more)
                }
            }
        }
        next(confirmed[...])
    }

    /// Stops idle background sessions with `claude stop`, without the safe-to-close checks: you
    /// chose them, and each keeps its conversation and shows under Recently closed. A session that
    /// woke up since the click (no longer idle) is left alone.
    func stopIdle(_ ids: [SessionID], done: @escaping (_ stopped: [SessionID], _ notes: [String]) -> Void) {
        var stopped: [SessionID] = [], notes: [String] = []
        func next(_ rest: ArraySlice<SessionID>) {
            guard let id = rest.first else { return done(stopped, notes) }
            guard let s = state.sessions[id], let a = state.account(s.accountId),
                  state.group(s, now: Date(), rules: config.rules) == .idle else { return next(rest.dropFirst()) }
            stop(s, account: a) { r in
                switch r {
                case .closed: stopped.append(id)
                case .skipped(let why), .failed(let why): notes.append("\(s.title): \(why)")
                }
                next(rest.dropFirst())
            }
        }
        next(ids[...])
    }

    /// A fresh listing of the session's account and a fresh repo check, folded in.
    private func recheck(_ s: Session, account: Account, then: @escaping (Session?) -> Void) {
        agents?.snapshotNow(account) { [weak self] snap in
            guard let self else { return }
            guard let snap else { return then(nil) }
            self.apply([.agents(snap)])
            self.doneChecker.evaluateNow(cwd: s.cwd) { check in
                self.apply([.doneCheck(s.id, check)])
                // Plugins with a check here look again too; one that doesn't answer leaves it unknown.
                // Before asking, so this session's own latest state goes out, not the queued copy.
                self.syncPlugins()
                self.plugins.refresh(s.id, plugins: self.pluginsChecking(s.id)) { silent in
                    // A plugin that didn't answer can't vouch now: its checks become unknown.
                    for p in silent {
                        guard var note = self.state.notes[s.id]?[p] else { continue }
                        note.checks = note.checks.map { var c = $0; c.outcome = .unknown; c.detail = "didn't answer when closing"; return c }
                        self.apply([.annotated(p, s.id, note)])
                    }
                    let fresh = self.state.sessions[s.id]
                    then(fresh?.phase == .ended ? nil : fresh)
                }
            }
        }
    }

    /// You chose to close it: `claude stop` now, without the safety checks. The conversation is kept.
    func closeNow(_ id: SessionID, done: @escaping (CloseOutcome) -> Void) {
        guard let s = state.sessions[id], let a = state.account(s.accountId) else { return done(.skipped("no longer listed")) }
        stop(s, account: a, then: done)
    }

    private func stop(_ s: Session, account a: Account, then: @escaping (CloseOutcome) -> Void) {
        guard case .background(let short) = s.reach else { return then(.skipped("runs in another terminal")) }
        let checks = self.checks(s)
        DispatchQueue.global().async { [weak self] in
            let r = ClaudeCLI.stop(account: a, shortId: short)
            DispatchQueue.main.async {
                guard let self else { return }
                guard r.status == 0 else { return then(.failed((r.err + r.out).trimmingCharacters(in: .whitespacesAndNewlines))) }
                self.record(MaxwellRecord.closed(s, checks: checks))
                self.agents?.refresh(a.id)
                then(.closed)
            }
        }
    }

    /// Logs one of Maxwell's own records and folds it in now (the log tail folds it again, harmlessly).
    private func record(_ fields: [String: Any]) {
        let at = Date()
        MaxwellRecord.append(fields, at: at)
        let line = (try? JSONSerialization.data(withJSONObject: ["ts": (at.timeIntervalSince1970 * 1000).rounded(), "maxwell": fields]))
            .flatMap { String(data: $0, encoding: .utf8) }
        if let e = line.flatMap({ EventParser.parse(line: Substring($0)) }) { apply([e]) }
    }

    /// Shows a session under another project (nil: back under its folder's), for good: a log line.
    func moveProject(_ id: SessionID, to project: String?) { record(MaxwellRecord.moved(id, to: project)) }

    func dismissSuggestion(_ id: SessionID, _ project: String) { record(MaxwellRecord.dismissed(id, suggestion: project)) }

    /// Undo and Recently closed: the record goes; `claude attach` (the caller's terminal) starts it again.
    func reopened(_ id: SessionID) { record(MaxwellRecord.reopened(id)) }

    /// "Not safe": out of Safe to close until new activity; the evidence goes to the event log and,
    /// as a replayable fixture, to Tests/fixtures/false-safe/. Returns the fixture path.
    @discardableResult
    func markNotSafe(_ id: SessionID) -> URL? {
        guard let s = state.sessions[id] else { return nil }
        let now = Date()
        let fixture = FalseSafe.encode(s, in: state, now: now, rules: config.rules)
        record(MaxwellRecord.notSafe(s, checks: checks(s, now: now)))
        let dir = Self.falseSafeDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(s.id.prefix(8))-\(Int(now.timeIntervalSince1970)).json")
        guard let data = try? JSONSerialization.data(withJSONObject: fixture, options: [.prettyPrinted, .sortedKeys]),
              (try? data.write(to: url)) != nil else { return nil }
        return url
    }

    /// The repo's Tests/fixtures/false-safe when Maxwell runs from its build folder, else the state dir.
    static var falseSafeDir: URL {
        var dir = Bundle.main.bundleURL
        for _ in 0..<4 {
            dir.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Tests/main.swift").path) {
                return dir.appendingPathComponent("Tests/fixtures/false-safe")
            }
        }
        return Paths.stateDir.appendingPathComponent("false-safe")
    }

    /// Moves limited work to another account: a new background session there with a short
    /// handover prompt that points at the old transcript.
    func move(_ s: Session, to account: Account, done: @escaping (Swift.Result<SessionID, ClaudeCLI.StartError>) -> Void) {
        let transcript = Transcripts.path(s, account: state.account(s.accountId)) ?? "(unknown)"
        let prompt = """
        Continue the work of session "\(s.title)" (\(s.id)), which stopped at a usage limit on another account. \
        Its transcript is \(transcript). Read the end of it to see what was asked and where it stopped, then carry on. \
        Same folder, same branch.
        """
        newSession(account: account, cwd: s.cwd, name: String((s.name + "-moved").prefix(40)), prompt: prompt, done: done)
    }

    /// Sends "continue" when the limit resets (now, if it already has).
    func scheduleResume(_ s: Session, at date: Date, send: @escaping (Session) -> Void) {
        resumeTimers[s.id]?.invalidate()
        scheduledResumes[s.id] = date
        let fire = max(date.timeIntervalSinceNow + 5, 0.1)
        resumeTimers[s.id] = Timer.scheduledTimer(withTimeInterval: fire, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.scheduledResumes[s.id] = nil
            self.resumeTimers[s.id] = nil
            if let current = self.state.sessions[s.id] { send(current) }
            self.onChange?(self.state)
        }
        onChange?(state)
    }
}
