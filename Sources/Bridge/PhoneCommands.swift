import AppKit

/// How a phone command ended: its `ack` (docs/phone.md, `cmd`).
enum PhoneReply {
    case ok([String: Any])
    case failed(code: String, message: String, detail: Any? = nil)

    func ack(_ id: String) -> [String: Any] {
        switch self {
        case .ok(let result): return ["t": "ack", "id": id, "ok": true, "result": result]
        case .failed(let code, let message, let detail):
            return ["t": "ack", "id": id, "ok": false, "error": ["code": code, "message": message, "detail": detail ?? NSNull()] as [String: Any]]
        }
    }
}

extension PhoneBridge {
    /// Runs a `cmd` once per id; a resend gets the first answer, and one still running gets none yet.
    func command(_ m: [String: Any], from phone: String) {
        guard let id = m["id"] as? String, !id.isEmpty, id.count <= 128 else { return }
        switch commands.seen(id) {
        case .answered(let ack): send(ack, to: phone); return
        case .running: return
        case .new: break
        }
        commands.start(id)
        let op = m["op"] as? String ?? ""
        run(op, m) { [weak self] reply in
            guard let self else { return }
            let ack = reply.ack(id)
            self.commands.finish(id, ack: ack)
            self.send(ack, to: phone)
            if case .failed(let code, let message, _) = reply { mark("phone: \(op) failed: \(code) (\(message))") } else { mark("phone: \(op) done") }
        }
    }

    private func run(_ op: String, _ m: [String: Any], _ reply: @escaping (PhoneReply) -> Void) {
        let st = store.state
        if op == "start" { return start(m, reply) }
        if op == "closeSafe" { return closeSafe(m["sessions"] as? [String] ?? [], reply) }
        if op == "artifactLogin" { return artifactLogin(m["account"] as? String, reply) }
        guard let sid = m["session"] as? String, let s = st.sessions[sid] else {
            return reply(.failed(code: "unknown-session", message: "Maxwell doesn't know that session any more."))
        }
        switch op {
        case "send":
            guard let text = m["text"] as? String, !text.isEmpty else { return reply(.failed(code: "bad-request", message: "Nothing to send.")) }
            typeInto(s, text: text, reply)
        case "permission": permission(s, m["decision"] as? String, reply)
        case "interrupt": press(s, "\u{1b}", reply)
        case "close": close(s, reply)
        case "forceClose": forceClose(s, reply)
        case "move": move(s, account: m["account"] as? String, reply)
        case "resumeAtReset": resumeAtReset(s, reply)
        case "rename":
            guard let title = m["title"] as? String else { return reply(.failed(code: "bad-request", message: "No title.")) }
            store.rename(s.id, to: String(title.prefix(200)))
            reply(.ok([:]))
        default: reply(.failed(code: "unknown-op", message: "This Maxwell doesn't know \(op)."))
        }
    }

    // MARK: typing

    /// Only background sessions can be typed into: a terminal session belongs to its terminal.
    private func readOnly(_ s: Session) -> PhoneReply? {
        switch s.reach {
        case .background: return nil
        case .elsewhere: return .failed(code: "read-only", message: "“\(s.title)” runs in a terminal on your Mac. Answer it there, or bring it into Maxwell.")
        case .cloud: return .failed(code: "read-only", message: "“\(s.title)” runs in the cloud. Open it on claude.ai.")
        }
    }

    /// Attaches if needed (which resumes a session Claude Code stopped while idle), then types.
    private func attach(_ s: Session) -> PhoneReply? {
        if let no = readOnly(s) { return no }
        guard case .background(let short) = s.reach, let a = store.state.account(s.accountId) else {
            return .failed(code: "failed", message: "No account \(s.accountId).")
        }
        let size = links.values.first { $0.focus == s.id && $0.terminal != nil }?.terminal ?? (100, 30)
        if let why = terminals.ensure(s.id, shortId: short, account: a, cwd: s.cwd, cols: size.cols, rows: size.rows) {
            return .failed(code: "failed", message: "Couldn't attach: \(why).")
        }
        return nil
    }

    func typeInto(_ s: Session, text: String, _ reply: @escaping (PhoneReply) -> Void) {
        if let no = attach(s) { return reply(no) }
        terminals.type(text, into: s.id) { why in reply(why.map { .failed(code: "failed", message: "Not sent: \($0).") } ?? .ok([:])) }
    }

    private func press(_ s: Session, _ keys: String, _ reply: @escaping (PhoneReply) -> Void) {
        if let no = attach(s) { return reply(no) }
        terminals.press(Data(keys.utf8), into: s.id) { why in reply(why.map { .failed(code: "failed", message: "Not sent: \($0).") } ?? .ok([:])) }
    }

    /// The prompt's own keys: 1 allows, 2 allows from now on, Esc denies. Only while it still shows.
    private func permission(_ s: Session, _ decision: String?, _ reply: @escaping (PhoneReply) -> Void) {
        let keys: [String: String] = ["allow": "1", "allowAlways": "2", "deny": "\u{1b}"]
        guard let decision, let key = keys[decision] else { return reply(.failed(code: "bad-request", message: "Unknown decision.")) }
        guard store.state.group(s, now: Date(), rules: store.config.rules) == .needsYou, case .permission? = PhoneAsk.of(s) else {
            return reply(.failed(code: "no-prompt", message: "“\(s.title)” isn't asking for permission any more."))
        }
        press(s, key, reply)
    }

    // MARK: sessions

    private func start(_ m: [String: Any], _ reply: @escaping (PhoneReply) -> Void) {
        let st = store.state
        guard let cwd = (m["cwd"] as? String).map(Paths.normalize), FileManager.default.fileExists(atPath: cwd) else {
            return reply(.failed(code: "bad-request", message: "That folder isn't on your Mac."))
        }
        let account = (m["account"] as? String).flatMap(st.account) ?? st.roomiest(now: Date()) ?? st.accounts.first
        guard let account else { return reply(.failed(code: "no-room", message: "No account has room right now.")) }
        let base = (m["name"] as? String).map { String($0.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(36)) }
            .flatMap { $0.isEmpty ? nil : $0 } ?? (cwd as NSString).lastPathComponent.lowercased().replacingOccurrences(of: " ", with: "-")
        let name = "\(base)-\(String(format: "%02x", Int.random(in: 0..<256)))"
        let prompt = (m["prompt"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        store.newSession(account: account, cwd: cwd, name: name, prompt: prompt) { r in
            switch r {
            case .success(let id): reply(.ok(["session": id]))
            case .failure(.untrusted): reply(.failed(code: "untrusted", message: "Claude needs your OK to work in \((cwd as NSString).abbreviatingWithTildeInPath). Start a session there on your Mac once."))
            case .failure(let e): reply(.failed(code: "failed", message: "\(e)"))
            }
        }
    }

    /// Same as Close Session on the Mac, without the "Close anyway?" question: a session that isn't
    /// safe now (checked again, fresh) stays open and the phone hears what is still open.
    private func close(_ s: Session, _ reply: @escaping (PhoneReply) -> Void) {
        if let no = readOnly(s) { return reply(no) }
        store.close([(s.id, s.lastMessage.map(Reply.hash))]) { [weak self] results in
            guard let self, let (fresh, outcome) = results.first else { return reply(.failed(code: "unknown-session", message: "It's gone from the session list.")) }
            switch outcome {
            case .closed: self.closed(fresh.id); reply(.ok([:]))
            case .skipped(let why): reply(.failed(code: "not-safe", message: "Not safe to close: \(why).", detail: self.openChecks(fresh)))
            case .failed(let why): reply(.failed(code: "failed", message: why))
            }
        }
    }

    private func openChecks(_ s: Session) -> [[String: Any]] {
        store.checks(s).filter { $0.outcome != .pass }.map { ["name": $0.title, "ok": false, "detail": $0.detail] }
    }

    /// Close all safe: each one checked again on the Mac right before it closes.
    private func closeSafe(_ ids: [String], _ reply: @escaping (PhoneReply) -> Void) {
        let st = store.state
        let known = ids.compactMap { st.sessions[$0] }.filter { readOnly($0) == nil }
        let unknown = ids.filter { id in !known.contains { $0.id == id } }
        store.close(known.map { ($0.id, $0.lastMessage.map(Reply.hash)) }) { [weak self] results in
            var closed: [SessionID] = [], skipped = unknown
            for (s, outcome) in results {
                if case .closed = outcome { closed.append(s.id); self?.closed(s.id) } else { skipped.append(s.id) }
            }
            reply(.ok(["closed": closed, "skipped": skipped]))
        }
    }

    /// The phone asked "Close anyway?" first.
    private func forceClose(_ s: Session, _ reply: @escaping (PhoneReply) -> Void) {
        if let no = readOnly(s) { return reply(no) }
        store.closeNow(s.id) { [weak self] outcome in
            switch outcome {
            case .closed: self?.closed(s.id); reply(.ok([:]))
            case .skipped(let why), .failed(let why): reply(.failed(code: "failed", message: why))
            }
        }
    }

    /// Lets go of the phone's terminal and tells the Mac's window, as its own Close does.
    private func closed(_ sid: SessionID) {
        terminals.release(sid)
        onClosed?(sid)
    }

    private func move(_ s: Session, account: String?, _ reply: @escaping (PhoneReply) -> Void) {
        let st = store.state
        guard let target = account.flatMap(st.account) ?? st.roomiest(now: Date(), excluding: s.accountId) else {
            return reply(.failed(code: "no-room", message: "No account has room right now."))
        }
        store.move(s, to: target) { r in
            switch r {
            case .success(let id): reply(.ok(["session": id]))
            case .failure(let e): reply(.failed(code: "failed", message: "Move failed: \(e)"))
            }
        }
    }

    private func resumeAtReset(_ s: Session, _ reply: @escaping (PhoneReply) -> Void) {
        if let no = readOnly(s) { return reply(no) }
        var when = Date()
        if case .limited(let reset?) = s.phase { when = reset }
        store.scheduleResume(s, at: when) { [weak self] s in
            self?.typeInto(s, text: "continue") { r in if case .failed(_, let m, _) = r { mark("phone: resume at reset: \(m)") } }
        }
        reply(.ok(["at": PhoneState.iso.string(from: when)]))
    }

    // MARK: artifacts

    /// The account's claude.ai cookies from the Mac's sign-in, so artifacts open signed in on the phone.
    private func artifactLogin(_ id: String?, _ reply: @escaping (PhoneReply) -> Void) {
        guard let a = id.flatMap(store.state.account) else { return reply(.failed(code: "bad-request", message: "Unknown account.")) }
        ClaudeWeb.shared.store(a).httpCookieStore.getAllCookies { cookies in
            let now = Date()
            let mine = cookies.filter { $0.domain.hasSuffix("claude.ai") && ($0.expiresDate.map { $0 > now } ?? true) }
            guard mine.contains(where: { $0.name == "sessionKey" }) else {
                return reply(.failed(code: "signed-out", message: "\(a.name) isn't signed in to claude.ai on your Mac. Sign in under Settings › Accounts."))
            }
            reply(.ok(["cookies": mine.map { c in
                ["name": c.name, "value": c.value, "domain": c.domain, "path": c.path, "expires": c.expiresDate.map { PhoneState.iso.string(from: $0) } ?? NSNull(),
                 "secure": c.isSecure, "httpOnly": c.isHTTPOnly] as [String: Any]
            }]))
        }
    }
}
