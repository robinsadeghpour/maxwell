import Foundation

/// The running plugin: polls the source, applies the rules and marks, and keeps the panel current.
final class Plugin {
    let wire: Wire
    private let q = DispatchQueue(label: "slack.plugin")
    private var source: SlackSource?
    private var snapshot: Snapshot?
    private var items: [Waiting] = []
    private var health = Health.loading
    private var marks = Marks()
    private var marksURL: URL?
    private var settings: [String: String] = [:]
    private var timer: DispatchSourceTimer?
    private var links = Links()
    private var linksURL: URL?
    /// Each session's sidebar group, from `sessions/changed`; nil until the first full list.
    private var groups: [String: String]?
    private var linked: [String: Panel.Linked] = [:]
    private var annotated: [String: Data] = [:]
    private var checkedAt: Date?
    private var waitingCount: Int { Panel.count(items, linked: linked) }

    init(wire: Wire) { self.wire = wire }

    var days: Double { Double(settings["days"] ?? "") ?? 14 }
    var pollSeconds: Int {
        switch settings["poll"] ?? "2m" { case "1m": return 60; case "5m": return 300; default: return 120 }
    }
    var snooze: TimeInterval { 3 * 3600 }

    func start() {
        wire.onRequest("initialize") { [unowned self] p in
            let plugin = p["plugin"] as? [String: Any] ?? [:]
            if let dir = plugin["dataDir"] as? String {
                marksURL = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).appendingPathComponent("marks.json")
                marks = Marks.load(marksURL!)
                linksURL = marksURL!.deletingLastPathComponent().appendingPathComponent("links.json")
                links = Links.load(linksURL!)
            }
            settings = (p["settings"] as? [String: Any] ?? [:]).compactMapValues { "\($0)" }
            // Start after Maxwell has our answer, so the first status doesn't arrive before it.
            q.asyncAfter(deadline: .now() + 0.2) { self.connect() }
            return [String: Any]()
        }
        wire.onNotification("settings/changed") { [unowned self] p in
            q.async {
                self.settings = (p["settings"] as? [String: Any] ?? [:]).compactMapValues { "\($0)" }
                self.connect()
            }
        }
        wire.onNotification("sessions/changed") { [unowned self] p in q.async { self.sessionsChanged(p) } }
        wire.onNotification("secrets/changed") { [unowned self] _ in q.async { self.connect() } }
        wire.onRequest("action/run") { [unowned self] p in try q.sync { try self.run(p["action"] as? String ?? "", item: p["item"] as? String) } }
        wire.onRequest("shutdown") { _ in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { exit(0) }
            return nil
        }
        wire.run()
    }

    /// Picks the source from settings and the secret, then polls it.
    private var generation = 0

    private func connect() {
        generation += 1
        timer?.cancel(); timer = nil
        source = nil
        if settings["source"] == "demo" || ProcessInfo.processInfo.environment["MAXWELL_SLACK_FIXTURES"] != nil {
            let path = ProcessInfo.processInfo.environment["MAXWELL_SLACK_FIXTURES"]
                ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("fixtures.json").path
            source = FixtureSource(url: URL(fileURLWithPath: path))
        } else {
            switch wire.call("secrets/get", ["key": "user-token"]) {
            case .success(let r):
                let token = (r as? [String: Any])?["value"] as? String ?? ""
                guard token.hasPrefix("xoxp-") else {
                    return show(.setup(token.isEmpty ? "Slack isn't connected yet."
                                                     : "That isn't a user token (xoxp-…)."))
                }
                source = WebSource(api: SlackAPI(transport: SlackHTTP.transport(token: token)))
            case .failure(let e):
                return show(.error("Maxwell didn't hand over the token: \(e.message)"))
            }
        }
        show(.loading)
        poll()
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + .seconds(pollSeconds), repeating: .seconds(pollSeconds))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    private let fetchQueue = DispatchQueue(label: "slack.fetch")
    private var fetching = false

    /// Fetches off the plugin queue, so actions stay quick while Slack is slow.
    private func poll() {
        guard let source, !fetching else { return }
        fetching = true
        let gen = generation
        let since = Date().addingTimeInterval(-days * 86400)
        fetchQueue.async {
            let r = Result { try source.fetch(since: since) }
            self.q.async {
                self.fetching = false
                // A source swapped while this fetch ran (new token, settings) has its own poll coming.
                guard gen == self.generation else { return self.poll() }
                self.apply(r)
            }
        }
    }

    private func apply(_ r: Result<Snapshot, Error>) {
        let now = Date()
        do {
            snapshot = try r.get()
            checkedAt = now
            marks.prune(before: now.addingTimeInterval(-days * 86400))
            show(.ok(checked: now))
        } catch let e as SlackError where ["invalid_auth", "token_revoked", "not_authed", "account_inactive", "missing_scope"].contains(e.code) {
            show(.setup(e.code == "missing_scope"
                ? "The Slack app lacks a permission. Re-create it."
                : "Slack refused the token (\(e.code)). Paste a new one."))
        } catch let e as URLError {
            log("offline: \(e.code.rawValue)")
            if case .offline = health {} else { show(snapshot == nil ? .error("Can't reach Slack.") : .offline(since: now)) }
        } catch {
            log("poll failed: \(error)")
            show(.error("\(error)"))
        }
    }

    private func show(_ h: Health) {
        health = h
        let now = Date()
        items = snapshot.map { Rules.waiting($0, marks: marks, now: now) } ?? []
        linked = [:]
        for w in items {
            guard let l = links.byKey[w.key] else { continue }
            let replied = snapshot.flatMap { Loop.replied($0, key: w.key, after: l.at) }
            linked[w.key] = Panel.Linked(status: Loop.status(w, link: l, group: groups?[l.session], replied: replied),
                                         session: groups == nil || groups?[l.session] != nil ? l.session : nil, group: groups?[l.session])
        }
        annotateLinked(force: [])
        let state: String
        let message: String
        switch h {
        case .loading: state = "loading"; message = "Reading Slack…"
        case .setup(let m): state = "setup"; message = m
        case .ok: state = "ok"; message = waitingCount == 0 ? "Nobody is waiting on you" : "\(waitingCount) waiting on you"
        case .offline: state = "offline"; message = "Can't reach Slack"
        case .error(let m): state = "error"; message = m
        }
        wire.notify("status", ["state": state, "message": message])
        var p: [String: Any] = ["panel": Panel.id, "view": Panel.view(items, health: h, linked: linked, now: now)]
        if case .setup = h {} else { p["count"] = waitingCount; p["tone"] = items.contains { linked[$0.key] == nil && $0.state == .waiting && Panel.isUrgent($0) } ? "bad" : "warn" }
        wire.notify("panel/set", p)
    }

    private func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

    private func item(_ key: String?) throws -> Waiting {
        guard let key else { throw Wire.WireError(code: -32602, message: "Pick a row first.") }
        guard let w = items.first(where: { $0.key == key }) else { throw Wire.WireError(code: -32602, message: "That message isn't waiting any more.") }
        return w
    }

    private func save() {
        if let marksURL { try? marks.save(marksURL) }
        if let linksURL { try? links.save(linksURL) }
    }

    /// Keeps each session's group, drops links to sessions that are gone, and re-checks the ones that moved.
    private func sessionsChanged(_ p: [String: Any]) {
        let list = p["sessions"] as? [[String: Any]] ?? []
        var g = (p["full"] as? Bool == true) ? [:] : (groups ?? [:])
        for s in list { if let id = s["id"] as? String { g[id] = s["group"] as? String ?? "" } }
        for id in p["removed"] as? [String] ?? [] { g[id] = nil }
        groups = g
        let before = links
        links.prune(sessions: Set(g.keys), before: Date().addingTimeInterval(-days * 86400))
        if links != before { save() }
        // A session that changed needs fresh evidence, or its check counts as old (docs/plugins.md, Safe to close).
        let changed = Set(list.compactMap { $0["id"] as? String })
        let h = health
        show(h)
        annotateLinked(force: changed)
    }

    /// Tells Maxwell about each linked session: a badge, its Slack field, and the Replied on Slack check.
    private func annotateLinked(force: Set<String>) {
        for (key, l) in links.byKey where groups?[l.session] != nil {
            let replied = snapshot.flatMap { Loop.replied($0, key: key, after: l.at) }
            let a = Loop.annotation(session: l.session, link: l, replied: replied, checkedAt: checkedAt)
            let data = (try? JSONSerialization.data(withJSONObject: a, options: [.sortedKeys])) ?? Data()
            guard force.contains(l.session) || annotated[l.session] != data else { continue }
            annotated[l.session] = data
            wire.notify("session/annotate", a)
        }
    }

    /// One action from a row, the menu or ⌘K. Answers with the toast text.
    private func run(_ action: String, item key: String?) throws -> [String: Any] {
        switch action {
        case "refresh":
            poll(); return ["message": "Checking Slack…"]
        case "connect":
            _ = wire.call("open", ["url": Manifest.createAppURL])
            return ["message": "Install the app, then paste its User OAuth Token in Settings › Plugins › Slack."]
        case "open-message", "open-next":
            guard let w = action == "open-next" ? items.first(where: { $0.state == .waiting }) : try item(key) else {
                return ["message": "Nobody is waiting on you."]
            }
            _ = wire.call("open", ["url": w.link])
            return [:]
        case "handled", "not-for-me", "snooze":
            let w = try item(key)
            let kind: Marks.Kind = action == "handled" ? .handled : action == "snooze" ? .snoozed : .notForMe
            let until = kind == .snoozed ? Date().addingTimeInterval(snooze) : nil
            marks.mark(w, kind, until: until)
            save(); let h = health; show(h)
            let msg = kind == .handled ? "Marked \(w.who) as handled." : kind == .snoozed ? "Snoozed \(w.who) until \(Panel.clock(until!))." : "Hidden: \(w.who) in \(w.place)."
            return ["message": msg, "undo": ["action": "undo", "item": w.key]]
        case "undo":
            guard let key else { throw Wire.WireError(code: -32602, message: "Nothing to undo.") }
            marks.clear(key); save(); let h = health; show(h)
            return ["message": "Back in the list."]
        case "start-session":
            let w = try item(key)
            if let l = links.byKey[w.key], groups?[l.session] != nil {
                return ["message": "\(w.who)'s message already has a session."]
            }
            let prompt = Panel.prompt(w, context: context(for: w), demo: source is FixtureSource)
            var name = "slack-" + w.who.lowercased().split(whereSeparator: { !$0.isLetter }).joined(separator: "-")
            // Demo data starts throwaway test sessions: cheap model, mxtest- name.
            if source is FixtureSource { name = "mxtest-" + name }
            // Answer now (actions have 10 s); the session can take longer to start. Link it when it's up.
            DispatchQueue.global().async { self.startSession(for: w, prompt: prompt, name: name) }
            return ["message": "Starting a session for \(w.who)'s message…"]
        default:
            throw Wire.WireError(code: -32601, message: "unknown action \(action)")
        }
    }

    private func startSession(for w: Waiting, prompt: String, name: String) {
        var p: [String: Any] = ["prompt": prompt, "name": name]
        if name.hasPrefix("mxtest-") {
            p["model"] = "haiku"
            if let cwd = ProcessInfo.processInfo.environment["MAXWELL_SLACK_TEST_CWD"] { p["cwd"] = cwd }
        }
        let r = wire.call("session/start", p, timeout: 60)
        q.async {
            switch r {
            case .success(let v):
                guard let sid = (v as? [String: Any])?["session"] as? String else { return }
                self.links.byKey[w.key] = Links.Link(session: sid, at: Date(), who: w.who, place: w.place, url: w.link)
                if self.groups != nil, self.groups![sid] == nil { self.groups![sid] = "working" }
                self.save()
                let h = self.health; self.show(h)
                self.annotateLinked(force: [sid])
            case .failure(let e) where e.code == -32601:
                self.copy(prompt)
                self.wire.notify("notify", ["title": "Copied \(w.who)'s message", "body": "This Maxwell can't start sessions for plugins yet. ⌘T, then paste."])
            case .failure(let e):
                self.log("session/start failed: \(e.message)")
            }
        }
    }

    /// The thread or DM lines around the ask, plain text, oldest first, at most 8.
    private func context(for w: Waiting) -> [String] {
        guard let s = snapshot, let c = s.conversations.first(where: { w.key.hasPrefix($0.id + ":") }) else { return [w.ask] }
        let root = String(w.key.dropFirst(c.id.count + 1))
        let ms = c.messages.filter { root == "top" ? $0.threadTs == nil || $0.threadTs == $0.ts : $0.threadTs == root }
            .filter { $0.ts <= w.lastTs }.suffix(8)
        return ms.map { "\(s.users[$0.user]?.name ?? "someone"): \(Rules.oneLine($0.text, users: s.users))" }
    }

    private func copy(_ s: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
        let pipe = Pipe()
        p.standardInput = pipe
        try? p.run()
        pipe.fileHandleForWriting.write(s.data(using: .utf8)!)
        try? pipe.fileHandleForWriting.close()
        p.waitUntilExit()
    }
}
