import AppKit

/// `/resume` in a session can pick a conversation from another folder. Claude Code then only
/// prints the command to run (see `ResumeElsewhere`). Maxwell does what the command says: it
/// resumes the conversation in its folder as a background session and opens it.
extension MainWindowController {
    /// How long after a key press an answer on the screen still counts as the answer to it.
    private static let answerWindow: TimeInterval = 15

    /// After Ghostty draws: looks at the open session's screen for Claude Code's answer and
    /// follows each answer once, for as long as it stays on the screen. Only an answer to a pick
    /// you just made is followed: one drawn again from an old screen (a reattach, a restart) is not.
    func followResumeElsewhere() {
        guard let from = current, let terminal = terminal(for: from) else { return }
        let screen = terminal.viewportText()
        guard screen.contains("claude --resume"), let found = ResumeElsewhere.parse(screen: screen) else {
            resumeFollowed[from] = nil
            return
        }
        guard resumeFollowed[from] != found.sessionId else { return }
        resumeFollowed[from] = found.sessionId
        guard let pressed = terminal.lastKeyDownAt, Date().timeIntervalSince(pressed) < Self.answerWindow else { return }
        resumeElsewhere(found, from: from)
    }

    private func resumeElsewhere(_ found: ResumeElsewhere, from: SessionID) {
        let state = store.state
        let id = found.sessionId
        // Maxwell knows it already: closed here earlier, or still listed (running or stopped while idle).
        if state.closed[id] != nil { reopen(id); return closeIfEmpty(from) }
        if let known = state.sessions[id], known.phase != .ended {
            reattach(id)
            toast("Opened “\(known.title)”.")
            return closeIfEmpty(from)
        }
        guard let folder = found.folders.first(where: Self.isFolder) else {
            return toast("Can't resume here: \((found.folders[0] as NSString).abbreviatingWithTildeInPath) isn't there any more.")
        }
        let account = state.sessions[from].flatMap { state.account($0.accountId) } ?? state.roomiest(now: Date()) ?? state.accounts.first
        guard let account else { return }
        let path = (folder as NSString).abbreviatingWithTildeInPath
        toast("Resuming in \(path)…")
        store.resume(id, in: folder, account: account) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let resumed):
                mark("resume elsewhere: \(id.prefix(8)) in \(path)")
                self.toast("Resumed in \(path).")
                self.open(resumed)
                self.closeIfEmpty(from)
            case .failure(.untrusted):
                self.askToTrust(folder, account: account, retry: { self.resumeElsewhere(found, from: from) }, cancelled: {})
            case .failure(let error):
                self.toast("Couldn't resume in \(path): \(error)")
            }
        }
    }

    /// The session `/resume` was typed in, when it was only opened to resume another one: no
    /// reply in it yet, so nothing is lost. `claude stop`, like every close; it stays under Recently closed.
    private func closeIfEmpty(_ id: SessionID) {
        guard let s = store.state.sessions[id], case .background = s.reach, s.lastMessage == nil, s.phase != .working else { return }
        store.closeNow(id) { [weak self] outcome in
            guard case .closed = outcome else { return }
            self?.forget(id)
            mark("resume elsewhere: closed the empty session \(s.title)")
        }
    }

    private static func isFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
