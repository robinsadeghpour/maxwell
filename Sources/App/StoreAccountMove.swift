import Foundation

/// Limited work continues on another account: the same session, its whole conversation (`AccountMove`).
extension Store {
    enum MoveOutcome {
        case moved
        /// `stillThere`: it runs on its own account as before; false when it is stopped there and needs opening.
        case failed(String, stillThere: Bool)
    }

    struct MoveFailure {
        var session: Session
        var why: String
        var stillThere: Bool
    }

    /// Whether `continueOn` can take this session: a background session between turns.
    func canContinueElsewhere(_ s: Session) -> Bool {
        guard case .background = s.reach, !s.isCloud, s.movingTo == nil else { return false }
        return s.phase != .working && s.phase != .ended
    }

    /// Stops the session on its account and resumes the same conversation on `account` with "continue".
    /// On failure it runs on its own account again and the reason comes back.
    func continueOn(_ s: Session, account: Account, done: @escaping (MoveOutcome) -> Void) {
        let s = state.sessions[s.id] ?? s
        guard canContinueElsewhere(s), account.id != s.accountId else { return done(.failed("it can't move right now", stillThere: true)) }
        apply([.moving(s.id, to: account.id)])
        perform(s, account: account, done: done)
    }

    /// Several sessions, one after another: each `claude` start takes a few seconds and thirty at once would collide.
    /// All of them show as on their way at once; `each` hears about every one as it lands.
    func continueOn(_ sessions: [Session], account: Account, each: @escaping (Session, MoveOutcome) -> Void,
                    done: @escaping (_ moved: [Session], _ failed: [MoveFailure]) -> Void) {
        let picked = sessions.compactMap { state.sessions[$0.id] }.filter { canContinueElsewhere($0) && $0.accountId != account.id }
        apply(picked.map { .moving($0.id, to: account.id) })
        var moved: [Session] = [], failed: [MoveFailure] = []
        func next(_ rest: ArraySlice<Session>) {
            guard let first = rest.first else { return done(moved, failed) }
            let s = state.sessions[first.id] ?? first
            let landed: (MoveOutcome) -> Void = { outcome in
                switch outcome {
                case .moved: moved.append(s)
                case .failed(let why, let there): failed.append(MoveFailure(session: s, why: why, stillThere: there))
                }
                each(s, outcome)
                next(rest.dropFirst())
            }
            // It may have started a turn or ended while it waited for its place.
            if s.phase == .working || s.phase == .ended {
                apply([.moving(s.id, to: nil)])
                landed(.failed("it started a turn before its move", stillThere: true))
            } else {
                perform(s, account: account, done: landed)
            }
        }
        next(picked[...])
    }

    /// One move, already marked in `moving`.
    private func perform(_ s: Session, account: Account, done: @escaping (MoveOutcome) -> Void) {
        guard let from = state.account(s.accountId), let transcript = Transcripts.path(s, account: from) else {
            apply([.moving(s.id, to: nil)])
            return done(.failed("Maxwell can't find its conversation", stillThere: true))
        }
        let skip = config.skipPermissions
        // With auto titles off the session keeps the name it has, like bringing one in.
        let name = config.autoTitles ? String((s.name.isEmpty ? s.title : s.name).prefix(40)) : nil
        DispatchQueue.global().async { [weak self] in
            let r = AccountMove.run(s, transcript: transcript, from: from, to: account, name: name, skipPermissions: skip)
            DispatchQueue.main.async {
                guard let self else { return }
                switch r {
                case .success(let short):
                    mark("continue on \(account.id): \(s.id.prefix(8))")
                    // A resume set for the old account's reset would type "continue" into the moved session.
                    self.cancelResume(s.id)
                    self.apply([.started(s.id, account.id, name: s.name, cwd: s.cwd, shortId: short, at: Date())])
                    self.agents?.refresh(account.id)
                    done(.moved)
                case .failure(let f):
                    mark("continue on \(account.id) failed: \(s.id.prefix(8)): \(f.why)\(f.stillThere ? "" : "; stopped on \(from.id)")")
                    self.apply([.moving(s.id, to: nil)])
                    self.agents?.refresh(from.id)
                    done(.failed(f.why, stillThere: f.stillThere))
                }
                self.onChange?(self.state)
            }
        }
    }
}
