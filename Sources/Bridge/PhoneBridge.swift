import AppKit
import SystemConfiguration

/// What Settings › Phone shows.
struct PhoneStatus: Equatable {
    enum Relay: Equatable { case notSet, connecting, connected, cantReach(String) }
    struct Phone: Equatable { var id: String; var name: String; var lastSeen: Date?; var online: Bool }
    var relay: Relay = .notSet
    var relayURL: String?
    var pairLink: String?
    var pairExpires: Date?
    var phones: [Phone] = []
}

/// One paired phone's connection right now.
struct PhoneLink {
    var online = false
    /// It said `hello` since it came online: it gets `state`.
    var ready = false
    var focus: SessionID?
    /// The Terminal tab is open on `focus`: it gets `term`.
    var terminal: (cols: Int, rows: Int)?
    var offlineSince: Date?
}

/// Maxwell's side of the phone app (docs/phone.md): pairs phones, keeps them in step with the Store
/// through the relay, and answers their commands. Main thread only.
final class PhoneBridge {
    let store: Store
    let registry: PhoneRegistry
    private(set) var relay: RelayConnection?
    private(set) var relayURL: String?
    private var codes = PairingCodes()
    var links: [String: PhoneLink] = [:]
    var commands = CommandLog()
    let terminals = PhoneTerminals()
    var transcripts: [SessionID: PhoneTranscript] = [:]
    var artifacts: [String: PhoneArtifact] = [:]
    private var pushes = PushPlanner()
    private var rev = 0
    private var folders: [ProjectFolder] = []
    private var emails: [AccountID: String] = [:]
    private var sweep: Timer?
    private lazy var stateSend = Debounce(0.3, .atMost) { [weak self] in self?.stateTick() }
    /// Settings drops the QR code when it expires.
    private lazy var codeExpiry = Debounce(PairingCodes.lifetime + 1) { [weak self] in self?.onStatus?() }
    /// Settings shows the status: redraw it.
    var onStatus: (() -> Void)?
    /// A phone closed a session: the Mac's window lets go of its terminal, as its own Close does.
    var onClosed: ((SessionID) -> Void)?
    static let releaseAfter: TimeInterval = 120

    init(store: Store, vault: PhoneVault) {
        self.store = store
        registry = PhoneRegistry(vault: vault)
        terminals.onOutput = { [weak self] sid, data in self?.terminalOutput(sid, data) }
        NotificationCenter.default.addObserver(forName: ClaudeWeb.changed, object: nil, queue: .main) { [weak self] _ in self?.stateChanged() }
    }

    // MARK: settings

    /// Connects to the relay (`phone-relay`, else Maxwell's own), or stays off with `phone-relay = off`.
    /// A quiet run connects only to a relay its config names: test runs don't make rooms on the real one.
    func reload(_ config: Config) {
        let url = quietTest && config.phoneRelay == nil ? nil : config.phoneRelayURL
        guard url != relayURL || (url != nil && relay == nil) else { return }
        relay?.stop()
        relay = nil
        relayURL = url
        for id in links.keys { wentOffline(id) }
        defer { onStatus?() }
        guard let url, let room = roomURL(url) else {
            if let url { mark("phone relay: \(url) is not a ws:// or wss:// address") }
            return
        }
        let r = RelayConnection(url: room)
        r.onFrame = { [weak self] in self?.frame($0) }
        r.onStatus = { [weak self] st in
            if st != .connected, let self { for id in self.links.keys { self.wentOffline(id) } }
            self?.onStatus?()
        }
        relay = r
        r.start()
        refreshLookups()
        for a in store.state.accounts { ClaudeWeb.shared.refresh(a) }
        if sweep == nil {
            let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.releaseOffline() }
            RunLoop.main.add(t, forMode: .common)
            sweep = t
        }
    }

    private func roomURL(_ relay: String) -> URL? {
        guard var c = URLComponents(string: relay), ["ws", "wss"].contains(c.scheme ?? "") else { return nil }
        c.path = (c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path) + "/room/\(registry.macId)"
        c.queryItems = [.init(name: "role", value: "mac"), .init(name: "token", value: registry.macToken)]
        return c.url
    }

    var status: PhoneStatus {
        var s = PhoneStatus(relayURL: relayURL)
        switch relay?.status {
        case nil: s.relay = .notSet
        case .connecting?: s.relay = .connecting
        case .connected?: s.relay = .connected
        case .cantReach(let why)?: s.relay = .cantReach(why)
        }
        if let c = codes.current(now: Date()), let relayURL {
            s.pairLink = PairLink(relay: relayURL, mac: registry.macId, key: c.key, name: Self.macName).url
            s.pairExpires = c.expires
        }
        s.phones = registry.phones.values.sorted { $0.pairedAt < $1.pairedAt }.map {
            PhoneStatus.Phone(id: $0.id, name: $0.name, lastSeen: links[$0.id]?.online == true ? Date() : $0.lastSeen, online: links[$0.id]?.online == true)
        }
        return s
    }

    /// Settings › Phone › Pair a phone: a new code, valid for 10 minutes or one pairing.
    @discardableResult
    func makePairingCode() -> String? {
        _ = codes.make(now: Date())
        codeExpiry.poke()
        onStatus?()
        return status.pairLink
    }

    /// Settings › Phone › Done: the code goes and stops working.
    func cancelPairingCodes() {
        codes.cancelAll()
        codeExpiry.cancel()
        onStatus?()
    }

    /// Settings › Phone › Remove: the phone hears `bye`, then its key is gone and its boxes no longer open.
    func remove(_ phone: String) {
        send(["t": "bye", "reason": "removed"], to: phone)
        unfocus(phone)
        links[phone] = nil
        registry.remove(phone)
        mark("phone: removed a paired phone")
        onStatus?()
    }

    /// Maxwell quits: terminals hang up (the sessions keep running) and the room goes quiet.
    func shutdown() {
        for sid in terminals.sessions { terminals.release(sid) }
        for t in transcripts.values { t.tail.stop() }
        relay?.stop()
    }

    static var macName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac"
    }

    // MARK: frames

    private func frame(_ f: [String: Any]) {
        if let p = f["presence"] as? [String: Any], let id = p["phone"] as? String, let online = p["online"] as? Bool {
            guard registry.phones[id] != nil else { return }
            if online { links[id, default: PhoneLink()].online = true; links[id]?.offlineSince = nil } else { wentOffline(id) }
            if online { registry.touch(id, at: Date()) }
            onStatus?()
            return
        }
        guard let from = f["from"] as? String, let box = f["box"] as? String else { return }
        if let phone = registry.phones[from], let m = PhoneBox.open(box, key: phone.keys.phoneToMac) {
            links[from, default: PhoneLink()].online = true
            registry.touch(from, at: Date())
            return message(m, from: from)
        }
        // An unknown phone, or a known one pairing again with a new code.
        if let (key, m) = codes.spend(box: box, from: from, now: Date()) { paired(from, key: key, m) }
    }

    private func paired(_ id: String, key: Data, _ m: [String: Any]) {
        let name = (m["name"] as? String).map { String($0.prefix(60)) } ?? "iPhone"
        registry.save(PairedPhone(id: id, name: name, key: key, push: nil, app: m["app"] as? String, pairedAt: Date(), lastSeen: Date()))
        links[id] = PhoneLink(online: true)
        mark("phone: paired \(name)")
        send(["t": "paired", "mac": ["name": Self.macName]], to: id)
        onStatus?()
    }

    private func message(_ m: [String: Any], from id: String) {
        switch m["t"] as? String {
        case "hello": hello(m, from: id)
        case "focus": focus(id, session: m["session"] as? String, terminal: Self.size(m["terminal"]))
        case "cmd": command(m, from: id)
        case "input":
            guard let sid = m["session"] as? String, let text = m["data"] as? String else { return }
            input(Data(text.utf8), session: sid, from: id)
        case "resize":
            guard let sid = m["session"] as? String, let size = Self.size(m) else { return }
            if links[id]?.focus == sid { links[id]?.terminal = size }
            terminals.resize(sid, cols: size.cols, rows: size.rows)
        case "pair": break   // a resent pair from a phone that already paired
        default: mark("phone: unknown message \(m["t"] as? String ?? "?")")
        }
    }

    static func size(_ v: Any?) -> (cols: Int, rows: Int)? {
        guard let d = v as? [String: Any], let c = d["cols"] as? Int, let r = d["rows"] as? Int, c > 0, r > 0 else { return nil }
        return (min(c, 500), min(r, 300))
    }

    private func hello(_ m: [String: Any], from id: String) {
        guard var p = registry.phones[id] else { return }
        p.push = (m["push"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        p.app = m["app"] as? String
        p.lastSeen = Date()
        registry.save(p)
        links[id, default: PhoneLink()].online = true
        links[id]?.ready = true
        links[id]?.offlineSince = nil
        refreshLookups()
        if let payload = statePayload() { send(payload, to: id) }
        focus(id, session: m["focus"] as? String, terminal: nil)
        onStatus?()
    }

    func wentOffline(_ id: String) {
        guard links[id]?.online == true || links[id]?.offlineSince == nil else { return }
        guard var l = links[id] else { return }
        l.online = false
        l.ready = false
        l.offlineSince = l.offlineSince ?? Date()
        links[id] = l
        registry.persist()
    }

    /// Phones gone for over 2 minutes let go of their terminals and transcripts.
    private func releaseOffline() {
        let now = Date()
        for (id, l) in links where !l.online && l.focus != nil {
            if let since = l.offlineSince, now.timeIntervalSince(since) > Self.releaseAfter { unfocus(id) }
        }
    }

    // MARK: sending

    /// Seals a message for one phone and hands it to the relay; false when it couldn't go.
    @discardableResult
    func send(_ m: [String: Any], to id: String) -> Bool {
        guard let phone = registry.phones[id], let relay, let box = PhoneBox.seal(m, key: phone.keys.macToPhone) else { return false }
        return relay.send(["to": id, "box": box])
    }

    /// Phones that said hello and are online now.
    var readyPhones: [String] { links.filter { $0.value.ready && $0.value.online }.map(\.key) }

    // MARK: state

    /// The Store changed: state goes out within 300 ms, focused transcripts look for new lines.
    func stateChanged() {
        guard relay != nil else { return }
        stateSend.poke()
        for t in transcripts.values { t.tail.check() }
    }

    private func stateTick() {
        pushNews()
        let phones = readyPhones
        guard !phones.isEmpty, let payload = statePayload() else { return }
        for id in phones { send(payload, to: id) }
    }

    func statePayload() -> [String: Any]? {
        rev += 1
        let st = store.state
        let config = store.config
        let signedIn = Set(st.accounts.filter { ClaudeWeb.shared.status[$0.name] == .signedIn }.map(\.name))
        var p = PhoneState.payload(.init(state: st, rules: config.rules, projects: Projects(rules: config.projects), pinned: config.pinned,
                                         folders: folders, webSignedIn: signedIn, emails: emails, artifacts: Array(artifacts.values),
                                         macName: Self.macName, rev: rev, now: Date()))
        // Over the relay's 1 MB: drop the replies' text, which the conversation tab has anyway.
        if let size = try? JSONSerialization.data(withJSONObject: p).count, size > 700_000, var sessions = p["sessions"] as? [[String: Any]] {
            for i in sessions.indices { sessions[i]["lastMessage"] = NSNull() }
            p["sessions"] = sessions
        }
        return p
    }

    /// Folders to start in and account emails: both read files, so off the main thread, now and then.
    private func refreshLookups() {
        let st = store.state, projects = Projects(rules: store.config.projects)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let used = st.sessions.values.filter { !$0.cwd.isEmpty }.map { (path: Projects.repoRoot($0.cwd) ?? $0.cwd, at: $0.lastEventAt) }
                .filter { Paths.normalize($0.path) != Paths.normalize(Paths.home.path) }
            let folders = ProjectFolders.all(used: used, projects: projects)
            let emails = Dictionary(st.accounts.compactMap { a in ClaudeWeb.expectedEmail(a).map { (a.id, $0) } }, uniquingKeysWith: { a, _ in a })
            DispatchQueue.main.async {
                guard let self else { return }
                let changed = self.folders != folders || self.emails != emails
                self.folders = folders
                self.emails = emails
                if changed { self.stateChanged() }
            }
        }
    }

    /// An artifact a session made or showed (the viewer's reading of its transcript).
    func artifactSeen(_ sid: SessionID, _ item: ViewerItem) {
        guard case .artifact(let link, let title) = item, let s = store.state.sessions[sid] else { return }
        let url = link.url.absoluteString
        artifacts[url] = PhoneArtifact(url: url, title: title ?? artifacts[url]?.title, session: sid, account: s.accountId, at: Date())
        stateChanged()
    }

    // MARK: pushes

    private func pushNews() {
        let st = store.state, now = Date()
        let news = pushes.news(st, rules: store.config.rules, now: now)
        let tokens = registry.phones.values.compactMap(\.push)
        guard !news.isEmpty, !tokens.isEmpty else { return }
        if PhonePushSender.macInUse() { return mark("phone: \(news.count) Needs you not pushed, the Mac is in use") }
        let counts = PhoneState.counts(st, rules: store.config.rules, now: now)
        let messages = news.flatMap { s, ask in tokens.map { PushPlanner.message(to: $0, session: s, ask: ask, counts: counts, now: now) } }
        PhonePushSender.send(messages) { [weak self] gone in
            guard let self else { return }
            for (id, p) in self.registry.phones where p.push.map(gone.contains) == true {
                var q = p
                q.push = nil
                self.registry.save(q)
            }
        }
    }
}
