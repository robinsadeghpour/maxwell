import AppKit

/// A session at its usage limit continues on another account: the same row and its whole
/// conversation (`Store.continueOn`). From the banner and ⇧⌘M (one session), the row menu
/// (pick the account) and the Limited group's header (all of them).
extension MainWindowController {
    /// ⇧⌘M and the banner: the account with the most room.
    func move(_ id: SessionID) {
        guard let s = store.state.sessions[id] else { return }
        guard let target = roomiest(for: id) else { return toast(noRoomText()) }
        continueOn([s], account: target)
    }

    /// The Limited header's button and ⌘K: the limited sessions the list shows, to the account with the most room.
    /// Ones running in a terminal can't go; the toast says how many stayed.
    func continueAllLimited(_ ids: [SessionID]) {
        let state = store.state
        guard let target = state.roomiestToContinue(now: Date()) else { return toast(noRoomText()) }
        let inTerminal = root.sidebar.list.limitedInTerminal
        let movable = ids.compactMap { state.sessions[$0] }.filter { $0.accountId != target.id && store.canContinueElsewhere($0) }
        guard !movable.isEmpty else { return toast("No limited session here can move. Sessions in a terminal can't move: bring them into Maxwell first.") }
        continueOn(movable, account: target, skipped: inTerminal)
    }

    func movingTo(_ id: SessionID) -> Account? { store.state.sessions[id]?.movingTo.flatMap(store.state.account) }

    /// The account with the most room for the Limited header's button, when one has room.
    func roomiestForLimited() -> Account? { store.state.roomiestToContinue(now: Date()) }

    /// Row menu: Continue on ▸ each other account, with the room it has; one at its limit shows when it resets.
    func continueMenu(_ s: Session) -> NSMenuItem? {
        guard let sub = continueAccounts(s.id) else { return nil }
        let item = NSMenuItem(title: "Continue on", action: nil, keyEquivalent: "")
        item.submenu = sub
        return item
    }

    /// The accounts a session can continue on, for the row menu and the banner's ▾.
    func continueAccounts(_ id: SessionID) -> NSMenu? {
        guard let s = store.state.sessions[id], case .background = s.reach, s.phase != .ended, store.state.accounts.count > 1 else { return nil }
        let sub = NSMenu()
        let now = Date(), can = store.canContinueElsewhere(s)
        for a in store.state.accounts where a.id != s.accountId {
            let reset = a.limitResetsAt(now: now)
            let room = reset.map { " · resets \(Format.reset($0, now: now))" } ?? a.usedPercent.map { " · \(100 - Int($0))% left" } ?? " · usage not read yet"
            let action = MenuAction(a.name + room) { [weak self] in self?.continueOn([s], account: a) }
            action.isEnabled = can && reset == nil
            if !action.isEnabled { action.action = nil }
            sub.addItem(action)
        }
        return sub
    }

    func continueOn(_ sessions: [Session], account: Account, skipped: Int = 0) {
        let one = sessions.count == 1 ? sessions.first : nil
        toast(one.map { "Continuing “\($0.title)” on \(account.name)…" } ?? "Continuing \(sessions.count) sessions on \(account.name)…")
        sessions.forEach { releaseTerminal($0.id) }
        render(store.state)
        store.continueOn(sessions, account: account, each: { [weak self] s, outcome in
            if case .moved = outcome { self?.reattachIfShown(s.id) }
            self?.render(self?.store.state ?? AppState(accounts: []))
        }) { [weak self] moved, failed in
            guard let self else { return }
            self.render(self.store.state)
            self.toast(Self.outcome(moved: moved, failed: failed, skipped: skipped, account: account, from: { self.store.state.account($0)?.name ?? $0 }))
        }
    }

    static func outcome(moved: [Session], failed: [Store.MoveFailure], skipped: Int, account: Account, from: (AccountID) -> String) -> String {
        var parts: [String] = []
        if moved.count == 1, failed.isEmpty, let s = moved.first { parts.append("“\(s.title)” continues on \(account.name).") }
        else if !moved.isEmpty { parts.append("\(moved.count) session\(moved.count == 1 ? "" : "s") continue on \(account.name).") }
        if let f = failed.first, failed.count == 1 {
            let home = from(f.session.accountId)
            parts.append("Couldn't continue “\(f.session.title)” on \(account.name): \(f.why). "
                         + (f.stillThere ? "It's still on \(home)." : "It's stopped on \(home): open it to resume it there."))
        } else if !failed.isEmpty {
            let stopped = failed.filter { !$0.stillThere }
            parts.append("\(failed.count) couldn't move: " + failed.map { "“\($0.session.title)”" }.joined(separator: ", ") + "."
                         + (stopped.isEmpty ? " They're still where they were." : " \(stopped.count) of them are stopped: open them to resume."))
        }
        if skipped > 0 { parts.append("\(skipped) run in a terminal: bring them into Maxwell to move them.") }
        return parts.joined(separator: " ")
    }

    private func noRoomText() -> String {
        let now = Date()
        guard let first = store.state.accounts.compactMap({ a in a.limitResetsAt(now: now).map { (a, $0) } }).min(by: { $0.1 < $1.1 }) else {
            return "No other account has room right now."
        }
        return "Every account is at its limit. \(first.0.name) resets first, at \(Format.reset(first.1, now: now))."
    }
}
