import AppKit

/// Cloud sessions in the window: starting one, sending a local session there, opening, bringing
/// one to this Mac and closing (archiving) it. The pane draws them; the store does the work.
extension MainWindowController {
    var currentIsCloud: Bool { current.flatMap { store.state.sessions[$0] }?.isCloud ?? false }

    /// A background session waiting at its prompt can be sent; a cloud one is already there.
    var canSendToCloud: Bool {
        guard let s = current.flatMap({ store.state.sessions[$0] }), case .background = s.reach else { return false }
        // Only at the prompt: on a permission dialog the typed Enter would answer it.
        return s.phase == .yourTurn && s.parkedAt == nil && store.handoffs[s.id] == nil
    }

    /// Whether a folder builds for macOS, which a cloud machine (Linux) can't: an Xcode project or a Swift package.
    static func buildsOnMac(_ folder: String) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.contains { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") || $0 == "Package.swift" }
    }

    /// What a cloud session started in `folder` gets: the branch it starts from, and a warning when
    /// work here won't go along. `blocks`: there is nothing it could start from.
    static func cloudCheck(_ folder: String) -> NewSessionPanel.CloudCheck {
        func git(_ args: [String]) -> ClaudeCLI.Result { ClaudeCLI.run("/usr/bin/git", ["-C", folder] + args, timeout: 5) }
        guard git(["rev-parse", "--is-inside-work-tree"]).status == 0 else {
            return .init(branch: nil, note: "Not a git repository. A cloud session starts from a repository.", blocks: true)
        }
        let branch = git(["branch", "--show-current"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = branch.isEmpty ? nil : branch
        if git(["remote", "get-url", "origin"]).status != 0 {
            return .init(branch: b, note: "No GitHub remote: Claude Code uploads committed files (up to 100 MB).", blocks: false)
        }
        let ahead = git(["rev-list", "--count", "@{upstream}..HEAD"])
        if ahead.status != 0 { return .init(branch: b, note: "\(b ?? "This branch") isn't pushed. Push it first; the cloud starts from GitHub.", blocks: false) }
        let n = Int(ahead.out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        if n > 0 { return .init(branch: b, note: "\(n) commit\(n == 1 ? "" : "s") on \(b ?? "this branch") aren't pushed; the cloud starts without them.", blocks: false) }
        let dirty = git(["status", "--porcelain"]).out.split(separator: "\n").count
        if dirty > 0 { return .init(branch: b, note: "\(dirty) uncommitted change\(dirty == 1 ? "" : "s") stay on this Mac.", blocks: false) }
        return .init(branch: b, note: nil, blocks: false)
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    func startCloudSession(account a: Account, folder: String, task: String) {
        // `claude --cloud` asks to trust the folder first, in its own dialog, which Maxwell can't answer; ask here.
        guard ClaudeCLI.isTrusted(folder, account: a) else {
            newPanel.show(error: "Claude needs your OK to work in this folder.")
            return askToTrust(folder, account: a, retry: { [weak self] in self?.startCloudSession(account: a, folder: folder, task: task) },
                              cancelled: { [weak self] in self?.newPanel.show(error: "Not started: Claude may not work in this folder yet.") })
        }
        newPanel.show(error: "Starting in the cloud on \(a.name)…")
        store.startCloud(task, cwd: folder, account: a) { [weak self] r in
            guard let self else { return }
            switch r {
            case .success(let id):
                self.newPanel.dismiss()
                self.toast("Started in the cloud on \(a.name). It works from the branch's last push.")
                self.open(id)
            case .failure(let f):
                self.newPanel.show(error: "Not started: \(f)")
            }
        }
    }

    /// Asks first: the session commits and pushes its branch, writes a brief, and stops once the
    /// cloud session runs. Recently closed brings it back.
    func sendToCloud(_ id: SessionID) {
        guard canSendToCloud, let s = store.state.sessions[id], let w = window else { return }
        let a = NSAlert()
        a.messageText = "Send “\(s.title)” to the cloud?"
        a.informativeText = "It commits and pushes its branch, then writes a brief. A cloud session continues from the pushed branch, "
            + "and this one stops once that runs. Recently closed brings it back.\n\nOnly what is pushed goes along: local services, "
            + "secrets that aren't set up in the cloud and macOS-only tools stay here."
        a.addButton(withTitle: "Send to Cloud")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: w) { [weak self] r in
            guard r == .alertFirstButtonReturn, let self else { return }
            self.send(CloudHandoff.prompt, to: id)
            self.toast("“\(s.title)” is committing, pushing and writing a brief for the cloud…")
            self.store.awaitBrief(id) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let cloudId):
                    self.forget(id)
                    self.root.status.show(toast: "“\(s.title)” continues in the cloud.", action: ("Open", { [weak self] in self?.open(cloudId) }), seconds: 10)
                case .failure(let f):
                    self.toast("“\(s.title)” stays on this Mac: \(f)")
                }
                self.render(self.store.state)
            }
            self.render(self.store.state)
        }
    }

    func openCloud(_ id: SessionID) {
        guard let s = store.state.sessions[id], case .cloud(let url) = s.reach, let u = URL(string: url), let a = store.state.account(s.accountId) else { return }
        openExternally(u, account: a)
    }

    /// `claude --teleport <id>` in a new terminal in the project's checkout. Claude Code checks out the
    /// session's branch there and needs a clean worktree; anything it refuses shows in that terminal.
    func bringToMac(_ id: SessionID) {
        guard let s = store.state.sessions[id], s.isCloud, let a = store.state.account(s.accountId) else { return }
        guard !s.cwd.isEmpty, FileManager.default.fileExists(atPath: s.cwd) else {
            return toast("Maxwell doesn't know where “\(s.title)”'s repository is on this Mac. Run claude --teleport \(id) in its checkout.")
        }
        openShell(in: s.cwd, command: CloudSessions.teleportCommand(id, account: a))
        toast("Bringing “\(s.title)” to this Mac in a new terminal and worktree.")
    }

    /// Archiving can't be undone from Maxwell, so it asks.
    func closeCloud(_ id: SessionID) {
        guard let s = store.state.sessions[id], s.isCloud, let w = window else { return }
        let a = NSAlert()
        a.messageText = "Archive “\(s.title)”?"
        a.informativeText = s.phase == .working
            ? "It is still working. Claude stops in the cloud and the session is archived. Its conversation stays on claude.ai."
            : "Claude stops in the cloud and the session is archived. Its conversation stays on claude.ai."
        a.addButton(withTitle: "Archive")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: w) { [weak self] r in
            guard r == .alertFirstButtonReturn, let self else { return }
            self.store.archiveCloud(id) { [weak self] failure in
                guard let self else { return }
                if let failure { return self.toast("Couldn't archive “\(s.title)”: \(failure)") }
                self.forget(id)
                self.toast("Archived “\(s.title)”. Its conversation stays on claude.ai.")
            }
        }
    }

    func cloudNote(_ s: Session) -> String? {
        guard let (f, at) = store.cloudFailure(s.accountId) else { return nil }
        return "listing from \(Format.clock.string(from: s.listedAt ?? at)) · \(f)"
    }
}
