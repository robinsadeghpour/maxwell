import Foundation
import Security

/// Where plugin secrets live. Keychain in the app, memory in tests.
protocol SecretStore: AnyObject {
    func get(_ plugin: PluginID, _ key: String) -> String?
    func set(_ plugin: PluginID, _ key: String, _ value: String?)
}

/// Keychain items: service "Maxwell plugin <id>", account "<key>".
final class KeychainSecrets: SecretStore {
    private func query(_ p: PluginID, _ k: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Maxwell plugin \(p)", kSecAttrAccount as String: k]
    }
    func get(_ p: PluginID, _ k: String) -> String? {
        var q = query(p, k)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    func set(_ p: PluginID, _ k: String, _ value: String?) {
        SecItemDelete(query(p, k) as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var q = query(p, k)
        q[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
}

final class MemorySecrets: SecretStore {
    var values: [String: String] = [:]
    func get(_ p: PluginID, _ k: String) -> String? { values["\(p)/\(k)"] }
    func set(_ p: PluginID, _ k: String, _ v: String?) { values["\(p)/\(k)"] = v }
}

/// Finds plugins, runs the enabled ones, and turns what they say into events and panels.
/// Main thread only. Session state goes out as `sessions/changed`; annotations come back as
/// `.annotated` events through `apply`, so Safe to close stays a pure function of AppState.
final class PluginHost {
    struct Paths {
        var user: URL
        var bundled: URL?
        var logs: URL
        var data: URL
    }

    let paths: Paths
    let secrets: SecretStore
    let version: String
    private(set) var manifests: [PluginManifest] = []
    private(set) var broken: [(dir: URL, why: PluginManifest.LoadError)] = []
    private(set) var status: [PluginID: PluginStatus] = [:]
    /// Each plugin's panels, by panel id. Missing: not set yet (shown as loading).
    private(set) var panels: [PluginID: [String: PluginView]] = [:]
    /// `panel/set` `count`: how many items in a panel need you, shown on its tab.
    private(set) var counts: [PluginID: [String: Int]] = [:]
    private var settings: [PluginID: [String: String]] = [:]
    private var running: [PluginID: PluginConnection] = [:]
    private var ready: Set<PluginID> = []
    private var failures: [PluginID: [Date]] = [:]
    private var restartWork: [PluginID: DispatchWorkItem] = [:]
    /// The last session JSON each plugin was sent, to send only what changed.
    private var sent: [PluginID: [SessionID: Data]] = [:]
    private var lastSessions: [SessionID: [String: Any]] = [:]
    private var waiters: [(plugin: PluginID, session: SessionID, done: () -> Void)] = []

    /// Report state changes as events (the store's `apply`).
    var apply: (([Event]) -> Void)?
    /// Plugins, statuses or panels changed: redraw.
    var onChange: (() -> Void)?
    var onNotify: ((_ title: String, _ body: String, _ session: SessionID?) -> Void)?
    var onOpen: ((URL) -> Void)?
    struct StartFailure: Error { var message: String }
    /// `session/start`: start a session the way ⌘T does, with the plugin's prompt; answers its id.
    var onStartSession: ((_ plugin: PluginID, _ prompt: String, _ name: String?, _ cwd: String?, _ model: String?,
                          _ done: @escaping (Result<SessionID, PluginHost.StartFailure>) -> Void) -> Void)?

    var restartDelays: [TimeInterval] = [1, 5, 30]
    static let failureWindow: TimeInterval = 300

    init(paths: Paths, secrets: SecretStore, version: String) {
        self.paths = paths
        self.secrets = secrets
        self.version = version
        // A plugin that exits while Maxwell writes to it must not kill Maxwell.
        signal(SIGPIPE, SIG_IGN)
    }

    func manifest(_ id: PluginID) -> PluginManifest? { manifests.first { $0.id == id } }

    /// Finds plugins again and starts, stops or updates each to match the config.
    func reload(_ config: Config) {
        let d = PluginManifest.discover(user: paths.user, bundled: paths.bundled)
        broken = d.broken
        let gone = Set(manifests.map(\.id)).subtracting(d.found.map(\.id))
        let changed = Set(d.found.filter { m in manifests.first { $0.id == m.id }.map { $0 != m } ?? false }.map(\.id))
        manifests = d.found
        for id in gone { turnOff(id, removed: true) }
        for m in manifests {
            let want = config.pluginEnabled(m)
            let s = config.pluginSettings(m)
            if !want { turnOff(m.id, removed: false); continue }
            if changed.contains(m.id) { stopProcess(m.id) }
            if running[m.id] == nil, restartWork[m.id] == nil, !isFailed(m.id) {
                settings[m.id] = s
                launch(m)
            } else if settings[m.id] != s {
                settings[m.id] = s
                if ready.contains(m.id) { running[m.id]?.notify("settings/changed", ["settings": s]) }
            }
        }
        onChange?()
    }

    private func isFailed(_ id: PluginID) -> Bool { if case .failed = status[id]?.run { return true }; return false }

    /// Restart from Settings, after it gave up.
    func restart(_ id: PluginID) {
        guard let m = manifest(id) else { return }
        failures[id] = []
        restartWork.removeValue(forKey: id)?.cancel()
        stopProcess(id)
        launch(m)
    }

    func shutdownAll() { for id in Array(running.keys) { stopProcess(id) } }

    /// A secret was saved in Settings.
    func setSecret(_ id: PluginID, _ key: String, _ value: String?) {
        secrets.set(id, key, value)
        if ready.contains(id) { running[id]?.notify("secrets/changed", ["key": key]) }
    }

    // MARK: sessions

    /// Sends each running plugin the sessions that changed since it last heard.
    func sessionsChanged(_ sessions: [[String: Any]]) {
        lastSessions = Dictionary(sessions.compactMap { d in (d["id"] as? String).map { ($0, d) } }, uniquingKeysWith: { a, _ in a })
        for id in ready { sendSessions(to: id, full: false) }
    }

    private func sendSessions(to id: PluginID, full: Bool) {
        guard let c = running[id] else { return }
        var was = full ? [:] : sent[id] ?? [:]
        var changed: [[String: Any]] = []
        for (sid, d) in lastSessions {
            guard let data = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]) else { continue }
            if was[sid] != data { changed.append(d) }
            was[sid] = data
        }
        let removed = Array(Set(was.keys).subtracting(lastSessions.keys))
        for r in removed { was[r] = nil }
        sent[id] = was
        guard full || !changed.isEmpty || !removed.isEmpty else { return }
        c.notify("sessions/changed", ["full": full, "sessions": changed, "removed": removed])
    }

    /// Asks every running plugin with a check on the session to look again, and waits up to
    /// `timeout` for each to answer with a fresh annotation (Safe to close rule 4).
    /// `done` gets the plugins that didn't answer in time; the caller must treat their checks as unknown.
    func refresh(_ session: SessionID, plugins: [PluginID], timeout: TimeInterval = 5, done: @escaping (Set<PluginID>) -> Void) {
        let all = Set(plugins)
        let live = plugins.filter { ready.contains($0) }
        guard !live.isEmpty, let d = lastSessions[session] else { return done(all) }
        var silent = all
        var finished = false
        for p in live {
            waiters.append((p, session, {
                guard !finished else { return }
                silent.remove(p)
                if silent.isEmpty { finished = true; done([]) }
            }))
            running[p]?.notify("sessions/changed", ["full": false, "sessions": [d], "removed": []])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.waiters.removeAll { w in live.contains(w.plugin) && w.session == session }
            if !finished { finished = true; done(silent) }
        }
    }

    // MARK: actions

    /// Runs a plugin action. `done` gets the plugin's message, or an error line.
    func run(_ plugin: PluginID, action: String, session: SessionID?, item: String?, done: @escaping (Result<String?, PluginConnection.RPCError>) -> Void) {
        guard ready.contains(plugin), let c = running[plugin] else {
            return done(.failure(.init(code: -32000, message: "\(manifest(plugin)?.name ?? plugin) isn't running")))
        }
        var p: [String: Any] = ["action": action]
        p["session"] = session ?? NSNull()
        p["item"] = item ?? NSNull()
        c.request("action/run", p) { r in
            switch r {
            case .success(let v): done(.success((v as? [String: Any])?["message"] as? String))
            case .failure(let e): done(.failure(e))
            }
        }
    }

    // MARK: process lifecycle

    private func environment(_ m: PluginManifest) -> [String: String] {
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE") }
        env["MAXWELL_PLUGIN_ID"] = m.id
        env["MAXWELL_PLUGIN_DATA"] = dataDir(m.id).path
        env["MAXWELL_PROTOCOL"] = String(PluginManifest.protocolVersion)
        return env
    }

    private func dataDir(_ id: PluginID) -> URL { paths.data.appendingPathComponent(id) }
    func logURL(_ id: PluginID) -> URL { paths.logs.appendingPathComponent("\(id).log") }

    private func launch(_ m: PluginManifest) {
        try? FileManager.default.createDirectory(at: dataDir(m.id), withIntermediateDirectories: true)
        let c = PluginConnection(manifest: m, env: environment(m), logURL: logURL(m.id))
        c.onMessage = { [weak self, weak c] method, params, id in
            guard let self, let c, self.running[m.id] === c else { return }
            self.handle(m, c, method, params, id)
        }
        c.onExit = { [weak self, weak c] why in
            guard let self, let c, self.running[m.id] === c else { return }
            self.crashed(m, why)
        }
        running[m.id] = c
        ready.remove(m.id)
        sent[m.id] = nil
        set(m.id) { $0.run = .starting; $0.reported = nil; $0.message = nil }
        do { try c.start() } catch {
            return crashed(m, "couldn't start \(m.run[0]): \(error.localizedDescription)")
        }
        let params: [String: Any] = [
            "protocol": PluginManifest.protocolVersion,
            "maxwell": ["version": version],
            "plugin": ["id": m.id, "dir": m.dir.path, "dataDir": dataDir(m.id).path],
            "settings": settings[m.id] ?? [:],
            "appearance": "dark",
        ]
        c.request("initialize", params) { [weak self, weak c] r in
            guard let self, let c, self.running[m.id] === c else { return }
            switch r {
            case .failure(let e):
                c.kill("initialize failed: \(e.message)")
            case .success:
                self.ready.insert(m.id)
                self.set(m.id) { $0.run = .running }
                self.apply?([.pluginState(m.id, name: m.name, down: nil)])
                self.sendSessions(to: m.id, full: true)
            }
        }
    }

    private func crashed(_ m: PluginManifest, _ why: String) {
        running[m.id] = nil
        ready.remove(m.id)
        let now = Date()
        var f = (failures[m.id] ?? []).filter { now.timeIntervalSince($0) < Self.failureWindow }
        f.append(now)
        failures[m.id] = f
        apply?([.pluginState(m.id, name: m.name, down: why)])
        if f.count >= restartDelays.count {
            set(m.id) { $0.run = .failed(why) }
            return
        }
        set(m.id) { $0.run = .stopped(why) }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restartWork[m.id] = nil
            if let cur = self.manifest(m.id) { self.launch(cur) }
        }
        restartWork[m.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + restartDelays[f.count - 1], execute: work)
    }

    /// Stops the process. Until it runs again it can't vouch: its checks turn unknown.
    private func stopProcess(_ id: PluginID) {
        restartWork.removeValue(forKey: id)?.cancel()
        if let c = running.removeValue(forKey: id) {
            c.stop()
            apply?([.pluginState(id, name: manifest(id)?.name ?? id, down: "restarting")])
        }
        ready.remove(id)
    }

    private func turnOff(_ id: PluginID, removed: Bool) {
        guard status[id]?.run != .off || removed else { return }
        stopProcess(id)
        panels[id] = nil
        failures[id] = nil
        if removed { status[id] = nil } else { set(id) { $0 = PluginStatus(run: .off) } }
        apply?([.pluginOff(id)])
    }

    private func set(_ id: PluginID, _ f: (inout PluginStatus) -> Void) {
        var s = status[id] ?? PluginStatus()
        f(&s)
        guard s != status[id] else { return }
        status[id] = s
        onChange?()
    }

    // MARK: messages from a plugin

    private func handle(_ m: PluginManifest, _ c: PluginConnection, _ method: String, _ p: [String: Any], _ id: Any?) {
        switch method {
        case "session/annotate":
            guard let (sid, note) = PluginNote.parse(p, at: Date()) else { return }
            apply?([.annotated(m.id, sid, note)])
            let done = waiters.filter { $0.plugin == m.id && $0.session == sid }
            waiters.removeAll { $0.plugin == m.id && $0.session == sid }
            done.forEach { $0.done() }
        case "panel/set":
            guard let panel = p["panel"] as? String, m.panels.contains(where: { $0.id == panel }),
                  let v = (p["view"] as? [String: Any]).flatMap(PluginView.parse) else { return }
            let n = (p["count"] as? Int).map { max(0, $0) }
            if panels[m.id]?[panel] != v || counts[m.id]?[panel] != n {
                panels[m.id, default: [:]][panel] = v
                counts[m.id, default: [:]][panel] = n
                onChange?()
            }
        case "status":
            let st = (p["state"] as? String).flatMap(PluginStatus.Reported.init)
            set(m.id) { $0.reported = st; $0.message = p["message"] as? String }
        case "notify":
            if let t = p["title"] as? String { onNotify?(t, (p["body"] as? String) ?? "", p["session"] as? String) }
        case "log":
            break
        case "secrets/get":
            guard let id else { return }
            let key = (p["key"] as? String) ?? ""
            guard m.settings.contains(where: { $0.key == key && $0.type == .secret }) else {
                return c.respond(id, error: .init(code: -32602, message: "\(key) is not a secret this plugin declares"))
            }
            c.respond(id, result: ["value": (secrets.get(m.id, key) as Any?) ?? NSNull()])
        case "session/start":
            guard let id else { return }
            guard let prompt = p["prompt"] as? String, !prompt.isEmpty, let start = onStartSession else {
                return c.respond(id, error: .init(code: -32602, message: "session/start needs a prompt"))
            }
            let name = (p["name"] as? String).map { String($0.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(40)) }
            start(m.id, prompt, name?.isEmpty == false ? name : nil, p["cwd"] as? String, p["model"] as? String) { r in
                switch r {
                case .success(let sid): c.respond(id, result: ["session": sid])
                case .failure(let why): c.respond(id, error: .init(code: -32000, message: why.message))
                }
            }
        case "open":
            guard let id else { return }
            guard let s = p["url"] as? String, let u = URL(string: s), ["https", "http", "mailto"].contains(u.scheme ?? "") || u.scheme?.hasSuffix("linear") == true || u.scheme == "slack" else {
                return c.respond(id, error: .init(code: -32602, message: "not a link Maxwell opens"))
            }
            onOpen?(u)
            c.respond(id, result: [String: Any]())
        default:
            if let id { c.respond(id, error: .init(code: -32601, message: "unknown method \(method)")) }
        }
    }
}

extension PluginHost {
    /// The session as plugins see it (docs/plugins.md, `sessions/changed`).
    static func json(_ s: Session, state: AppState, group: PhaseGroup?, project: String) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var d: [String: Any] = [
            "id": s.id, "name": s.name, "title": s.title, "project": project,
            "account": ["id": s.accountId, "name": state.account(s.accountId)?.name ?? s.accountId],
            "cwd": s.cwd, "lastEventAt": iso.string(from: s.lastEventAt), "startedAt": iso.string(from: s.startedAt),
        ]
        d["branch"] = s.doneCheck?.branch ?? s.branch ?? NSNull()
        d["group"] = group.map { "\($0)" } ?? NSNull()
        switch s.phase {
        case .working: d["phase"] = "working"
        case .needsYou(let q): d["phase"] = "needsYou"; d["question"] = q
        case .yourTurn: d["phase"] = "yourTurn"
        case .limited: d["phase"] = "limited"
        case .ended: d["phase"] = "ended"
        }
        d["lastMessage"] = s.lastMessage.map { String($0.prefix(4000)) } ?? NSNull()
        d["transcriptPath"] = s.transcriptPath ?? NSNull()
        if let c = s.doneCheck {
            switch c.pr {
            case .none: d["pr"] = ["state": "none"]
            case .merged(let n): d["pr"] = ["state": "merged", "number": n]
            case .open(let n): d["pr"] = ["state": "open", "number": n]
            case .closed(let n): d["pr"] = ["state": "closed", "number": n]
            case .unknown: d["pr"] = ["state": "unknown"]
            }
            d["repo"] = c.repo ? ["dirty": c.dirtyFiles ?? NSNull(), "unpushed": c.unpushed ?? NSNull()] as [String: Any] : NSNull()
        } else {
            d["pr"] = NSNull()
            d["repo"] = NSNull()
        }
        return d
    }
}
