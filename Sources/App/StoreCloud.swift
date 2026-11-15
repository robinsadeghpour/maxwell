import Foundation

/// A local session on its way to the cloud: it was asked to commit, push and write a brief, and
/// the brief is its next reply.
struct CloudHandoff {
    let since: Date
    var sawWorking = false
    let done: (Result<SessionID, CloudSessions.Failure>) -> Void
    /// The local session gets this long to reply before Maxwell gives up and leaves it where it is.
    static let wait: TimeInterval = 10 * 60
    /// What the local session is asked; the reply becomes the cloud session's task.
    static let prompt = "Maxwell is moving this work to a Claude Code cloud session. Commit what you have and push this branch. "
        + "Then reply with only a brief for the cloud session that continues from the pushed branch: the goal, what is done, "
        + "what is left, how to check it, and the branch name. Under 1500 characters. No questions."
}

extension Store {
    func makeCloudProbe(_ accounts: [Account]) -> CloudProbe {
        let p = CloudProbe(accounts: accounts, folders: { [weak self] in
            Array(Set((self?.state.sessions.values ?? [:].values).filter { !$0.isCloud && !$0.cwd.isEmpty }.map(\.cwd)))
        }) { [weak self] in self?.apply([$0]) }
        p.onFailure = { [weak self] in if let self { self.onChange?(self.state) } }
        return p
    }

    /// When the account's cloud listing last failed, and why; nil while it works.
    func cloudFailure(_ account: AccountID) -> (CloudSessions.Failure, Date)? { cloud?.failures[account] }

    /// `claude --cloud "<task>"` in `cwd`. `from`: the local session it continues.
    func startCloud(_ task: String, cwd: String, account a: Account, from: SessionID? = nil,
                    done: @escaping (Result<SessionID, CloudSessions.Failure>) -> Void) {
        DispatchQueue.global().async { [weak self] in
            let r = CloudSessions.start(task, cwd: cwd, account: a)
            DispatchQueue.main.async {
                guard let self else { return }
                switch r {
                case .success(let made):
                    self.record(MaxwellRecord.cloudStarted(made.id, account: a.id, title: made.title, cwd: cwd, from: from))
                    self.apply([.cloudStarting(made.id, a.id, title: made.title, cwd: cwd, at: Date())])
                    self.cloud?.refresh(a.id)
                    done(.success(made.id))
                case .failure(let f): done(.failure(f))
                }
            }
        }
    }

    /// Archives a cloud session: it stops in the cloud; its conversation stays on claude.ai.
    func archiveCloud(_ id: SessionID, done: @escaping (CloudSessions.Failure?) -> Void) {
        guard let s = state.sessions[id], let a = state.account(s.accountId) else { return done(.format) }
        DispatchQueue.global().async { [weak self] in
            let r = CloudSessions.archive(id, account: a)
            DispatchQueue.main.async {
                if case .failure(let f) = r { return done(f) }
                self?.cloud?.refresh(a.id)
                done(nil)
            }
        }
    }

    /// Why the branch in `cwd` isn't all on its remote, or nil when it is.
    static func notPushed(_ cwd: String) -> String? {
        let r = ClaudeCLI.run("/usr/bin/git", ["-C", cwd, "rev-list", "--count", "@{upstream}..HEAD"], timeout: 10)
        guard r.status == 0 else { return "its branch isn't pushed to a remote yet" }
        let n = Int(r.out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return n == 0 ? nil : "\(n) commit\(n == 1 ? "" : "s") on its branch aren't pushed"
    }

    /// The local session was just asked to wrap up (`CloudHandoff.prompt`); its next reply is the brief.
    func awaitBrief(_ id: SessionID, done: @escaping (Result<SessionID, CloudSessions.Failure>) -> Void) {
        handoffs[id] = CloudHandoff(since: Date(), done: done)
    }

    /// Called after every change: a handoff whose session has answered goes to the cloud; one that
    /// asked a question in its reply, ended, or took too long is dropped and the session stays here.
    /// A permission dialog on the way (`git push`) is waited out.
    func advanceHandoffs() {
        for (id, h) in handoffs {
            guard let s = state.sessions[id], s.phase != .ended else { handoffs[id] = nil; h.done(.failure(.refused("the session ended before it wrote the brief"))); continue }
            if Date().timeIntervalSince(h.since) > CloudHandoff.wait { handoffs[id] = nil; h.done(.failure(.refused("no brief after 10 minutes"))); continue }
            if s.phase == .working { handoffs[id]?.sawWorking = true; continue }
            let turned = h.sawWorking || (s.turnAt.map { $0 > h.since } ?? false)
            guard turned, s.lastEventAt > h.since else { continue }
            if case .needsYou(let q) = s.phase {
                if Self.replyAsked(s) { handoffs[id] = nil; h.done(.failure(.refused("it asked instead of writing the brief: \(q)"))) }
                continue
            }
            handoffs[id] = nil
            finishHandoff(s, h)
        }
    }

    /// Needs you because the reply asks (not a permission dialog, which the session gets past).
    private static func replyAsked(_ s: Session) -> Bool {
        ["reply", "session's status line", "turn stopped"].contains { s.phaseSource.hasPrefix($0) }
    }

    /// The brief is in: once the branch is pushed, start the cloud session from it, then stop this one.
    private func finishHandoff(_ s: Session, _ h: CloudHandoff) {
        guard let brief = s.lastMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !brief.isEmpty, let a = state.account(s.accountId) else {
            return h.done(.failure(.refused("its reply was empty")))
        }
        DispatchQueue.global().async { [weak self] in
            // The cloud starts from the branch's last push: work that isn't pushed would be left behind.
            let left = Self.notPushed(s.cwd)
            DispatchQueue.main.async {
                if let left { return h.done(.failure(.refused(left))) }
                self?.startCloud(brief, cwd: s.cwd, account: a, from: s.id) { [weak self] r in
                    // The local session stops once the cloud one runs; Recently closed brings it back.
                    if case .success = r { self?.closeNow(s.id) { _ in } }
                    h.done(r)
                }
            }
        }
    }
}
