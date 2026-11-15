import Foundation

/// Each account's cloud sessions, every 20 s and right after Maxwell starts, sends or closes one.
/// Results become `.cloud` events. An account without a Claude Code login is skipped quietly; any
/// other failure is kept per account, so the pane can say the state is from an older listing.
final class CloudProbe {
    static let every: TimeInterval = 20
    private let queue = DispatchQueue(label: "maxwell.cloud")
    private var timer: Timer?
    private var accounts: [Account]
    private let emit: (Event) -> Void
    /// Local folders Maxwell knows sessions in, to find the checkout of a cloud session's repository.
    private let folders: () -> [String]
    private var checkouts: [String: String] = [:]      // "owner/name" → folder, on `queue`
    private var looked = Set<String>()                 // folders already asked for their remote, on `queue`
    /// Why the last listing of an account failed; cleared by the next one that works. Main thread.
    private(set) var failures: [AccountID: (CloudSessions.Failure, Date)] = [:]
    var onFailure: (() -> Void)?

    init(accounts: [Account], folders: @escaping () -> [String], emit: @escaping (Event) -> Void) {
        self.accounts = accounts
        self.folders = folders
        self.emit = emit
        timer = Timer.scheduledTimer(withTimeInterval: Self.every, repeats: true) { [weak self] _ in self?.refreshAll() }
        refreshAll()
    }

    deinit { timer?.invalidate() }

    func refreshAll() { accounts.forEach { refresh($0.id) } }

    func refresh(_ id: AccountID) {
        guard let a = accounts.first(where: { $0.id == id }) else { return }
        let known = folders()
        queue.async { [weak self] in
            guard let self else { return }
            let result = CloudSessions.list(a)
            if case .success = result { self.learnCheckouts(known) }
            let located = result.map { snap -> CloudSnapshot in
                var s = snap
                for i in s.sessions.indices { s.sessions[i].folder = s.sessions[i].repo.flatMap { self.checkouts[$0] } }
                return s
            }
            DispatchQueue.main.async {
                switch located {
                case .success(let snap):
                    self.failures[a.id] = nil
                    self.emit(.cloud(snap))
                case .failure(.noLogin):
                    self.failures[a.id] = nil
                case .failure(let f):
                    self.failures[a.id] = (f, Date())
                    mark("cloud listing (\(a.name)): \(f)")
                    self.onFailure?()
                }
            }
        }
    }

    /// The main checkout of each repository among `known` folders (a worktree's top level is its
    /// own folder, so the shortest path wins).
    private func learnCheckouts(_ known: [String]) {
        for f in known where !looked.contains(f) {
            looked.insert(f)
            let top = ClaudeCLI.run("/usr/bin/git", ["-C", f, "rev-parse", "--show-toplevel"], timeout: 5).out.trimmingCharacters(in: .whitespacesAndNewlines)
            let remote = ClaudeCLI.run("/usr/bin/git", ["-C", f, "remote", "get-url", "origin"], timeout: 5).out.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !top.isEmpty, let repo = CloudParser.repoName(remote) else { continue }
            if let had = checkouts[repo], had.count <= top.count { continue }
            checkouts[repo] = top
        }
    }
}
