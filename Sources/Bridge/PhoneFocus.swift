import Foundation

/// A session's conversation while a phone has it open: the transcript followed line by line, and
/// the newest 300 items, so a second phone opening it gets them at once.
final class PhoneTranscript {
    let tail: TranscriptTail
    var parser: ChatParser
    var items: [ChatItem] = []
    var loaded = false
    /// Phones that focused before the backlog was read: they get it when it is.
    var waiting: Set<String> = []

    init(path: String, cwd: String) {
        tail = TranscriptTail(path: path)
        parser = ChatParser(cwd: cwd)
    }
}

extension PhoneBridge {
    static let transcriptItems = 300

    /// `focus`: the phone opened a session (or none). Its conversation follows, and with `terminal`, the screen.
    func focus(_ phone: String, session: SessionID?, terminal: (cols: Int, rows: Int)?) {
        let was = links[phone]?.focus
        links[phone, default: PhoneLink()].focus = session
        links[phone]?.terminal = terminal
        if let was, was != session { letGo(was) }
        guard let sid = session, let s = store.state.sessions[sid] else { return }
        openTranscript(s, for: phone)
        guard let terminal else { return }
        guard case .background(let short) = s.reach, let a = store.state.account(s.accountId) else { return }
        if let why = terminals.ensure(sid, shortId: short, account: a, cwd: s.cwd, cols: terminal.cols, rows: terminal.rows) {
            mark("phone: terminal for \(s.title): \(why)")
        } else {
            terminals.resize(sid, cols: terminal.cols, rows: terminal.rows)
        }
    }

    /// The phone went away or removed: let go of what only it held open.
    func unfocus(_ phone: String) {
        guard let was = links[phone]?.focus else { return }
        links[phone]?.focus = nil
        links[phone]?.terminal = nil
        letGo(was)
    }

    private func letGo(_ sid: SessionID) {
        guard !links.values.contains(where: { $0.focus == sid }) else { return }
        transcripts.removeValue(forKey: sid)?.tail.stop()
        terminals.release(sid)
    }

    private func openTranscript(_ s: Session, for phone: String) {
        if let t = transcripts[s.id] {
            if t.loaded { sendTranscript(s.id, items: t.items, reset: true, to: [phone]) } else { t.waiting.insert(phone) }
            return
        }
        guard let path = Transcripts.path(s, account: store.state.account(s.accountId)) else {
            return sendTranscript(s.id, items: [], reset: true, to: [phone])
        }
        let t = PhoneTranscript(path: path, cwd: s.cwd)
        t.waiting = [phone]
        transcripts[s.id] = t
        let sid = s.id
        t.tail.onLines = { [weak self, weak t] lines in
            guard let self, let t else { return }
            // A call and its result written together go out once, as the result.
            var new: [ChatItem] = []
            for line in lines { ChatParser.merge(t.parser.read(line), into: &new, limit: .max) }
            guard !new.isEmpty else { return }
            ChatParser.merge(new, into: &t.items, limit: Self.transcriptItems)
            self.noteArtifacts(new, session: sid)
            self.sendTranscript(sid, items: new, reset: false, to: self.focusing(sid))
        }
        t.tail.start { [weak self, weak t] lines in
            guard let self, let t else { return }
            t.items = t.parser.recent(lines, limit: Self.transcriptItems)
            t.loaded = true
            self.noteArtifacts(t.items, session: sid)
            self.sendTranscript(sid, items: t.items, reset: true, to: Array(t.waiting))
            t.waiting = []
        }
    }

    func focusing(_ sid: SessionID) -> [String] { links.filter { $0.value.focus == sid && $0.value.online }.map(\.key) }

    private func noteArtifacts(_ items: [ChatItem], session sid: SessionID) {
        for case .artifact(let url, let title) in items {
            guard let link = ArtifactLink.parse(url) else { continue }
            artifactSeen(sid, .artifact(link, title: title))
        }
    }

    /// `transcript` in parts small enough for the relay: the first part carries `reset`.
    func sendTranscript(_ sid: SessionID, items: [ChatItem], reset: Bool, to phones: [String]) {
        guard !phones.isEmpty else { return }
        var parts: [[[String: Any]]] = [[]]
        var size = 0
        for item in items {
            let j = item.json
            let n = (try? JSONSerialization.data(withJSONObject: j).count) ?? 0
            if size + n > 500_000, !(parts.last?.isEmpty ?? true) { parts.append([]); size = 0 }
            parts[parts.count - 1].append(j)
            size += n
        }
        for (i, part) in parts.enumerated() {
            let m: [String: Any] = ["t": "transcript", "session": sid, "reset": reset && i == 0, "items": part]
            for p in phones { send(m, to: p) }
        }
    }

    // MARK: terminal

    /// Output of a session's `claude attach`, to the phones with its Terminal tab open, in parts under the relay's limit.
    func terminalOutput(_ sid: SessionID, _ data: Data) {
        let phones = links.filter { $0.value.focus == sid && $0.value.terminal != nil && $0.value.online }.map(\.key)
        guard !phones.isEmpty else { return }
        var at = data.startIndex
        while at < data.endIndex {
            let end = data.index(at, offsetBy: 256 * 1024, limitedBy: data.endIndex) ?? data.endIndex
            let m: [String: Any] = ["t": "term", "session": sid, "data": data[at..<end].base64EncodedString()]
            for p in phones { send(m, to: p) }
            at = end
        }
    }

    /// `input`: keys typed in the Terminal tab, as they are.
    func input(_ bytes: Data, session sid: SessionID, from phone: String) {
        guard let s = store.state.sessions[sid], case .background(let short) = s.reach, let a = store.state.account(s.accountId) else { return }
        let size = links[phone]?.terminal ?? (100, 30)
        if let why = terminals.ensure(sid, shortId: short, account: a, cwd: s.cwd, cols: size.cols, rows: size.rows) {
            return mark("phone: terminal for \(s.title): \(why)")
        }
        terminals.write(bytes, to: sid)
    }
}
