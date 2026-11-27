import Foundation

/// Continues a background session's conversation on another account: same session id, the whole
/// conversation, so its row, pin, name and project stay. Claude Code 2.1.332: a conversation whose
/// transcript sits in an account's projects/ resumes there with `claude --bg --resume <id>`, and
/// `claude stop` on the old account leaves it listed as "stopped" (see docs/claude-code-internals.md).
///
/// Blocking: runs `claude` several times. Call it off the main thread.
enum AccountMove {
    /// Why a move didn't happen, and whether the session is back on (or never left) its own account.
    struct Failure: Error, CustomStringConvertible {
        var why: String
        /// False when it is stopped on its own account and resuming it there failed too: `claude attach` brings it back.
        var stillThere: Bool
        var description: String { why }
    }

    /// The prompt the moved session gets: its last turn stopped at the limit, so it picks that turn up again.
    static let prompt = "continue"

    /// Stop on `from`, put the conversation where `to` reads it, resume it there with "continue".
    /// When that fails, the session is resumed on `from` again (without a prompt), so nothing is lost.
    /// `name`: the name it gets on an account that never ran it (Claude Code names a session resumed
    /// without one anew). An account that ran it before keeps its saved options, and any flag would
    /// make a copy there (2.1.332), so it gets none.
    static func run(_ s: Session, transcript: String, from: Account, to: Account, name: String?, skipPermissions: Bool) -> Result<String, Failure> {
        guard ClaudeCLI.trust(s.cwd, account: to) else {
            return .failure(Failure(why: "Maxwell couldn't record that Claude may work in \((s.cwd as NSString).abbreviatingWithTildeInPath) on \(to.name)", stillThere: true))
        }
        if case .background(let short) = s.reach {
            _ = ClaudeCLI.stop(account: from, shortId: short)
            guard waitUntilStopped(s.id, account: from) else {
                return .failure(Failure(why: "it kept running after claude stop", stillThere: putBack(s, on: from)))
            }
        }
        if let why = carry(transcript, sessionId: s.id, cwd: s.cwd, to: to) {
            return .failure(Failure(why: "its conversation couldn't be copied: \(why)", stillThere: putBack(s, on: from)))
        }
        let known = knows(s.id, account: to)
        switch ClaudeCLI.resumeBackground(account: to, cwd: s.cwd, sessionId: s.id, name: known ? nil : name,
                                          skipPermissions: known ? false : skipPermissions,
                                          model: known ? nil : lastModel(transcript), prompt: prompt) {
        case .success(let r) where !r.copy:
            return .success(r.short)
        case .success(let r):
            _ = ClaudeCLI.stop(account: to, shortId: r.short)
            return .failure(Failure(why: "Claude Code started a copy instead", stillThere: putBack(s, on: from)))
        case .failure(let e):
            return .failure(Failure(why: "\(e)", stillThere: putBack(s, on: from)))
        }
    }

    /// Wakes it again on its own account, with its saved options: no flags, which would make a copy.
    private static func putBack(_ s: Session, on account: Account) -> Bool {
        guard case .background = s.reach else { return true }
        switch ClaudeCLI.resumeBackground(account: account, cwd: s.cwd, sessionId: s.id, name: nil, skipPermissions: false) {
        case .success(let r) where !r.copy: return true
        case .success(let r): _ = ClaudeCLI.stop(account: account, shortId: r.short); return true  // it was still running there
        case .failure: return false
        }
    }

    /// The model its last real reply came from (a limit line is `<synthetic>`): a fresh account would
    /// otherwise run it on that account's default.
    static func lastModel(_ transcript: String, window: UInt64 = 512 * 1024) -> String? {
        guard let h = FileHandle(forReadingAtPath: transcript) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > window ? size - window : 0)
        let data = (try? h.readToEnd()) ?? Data()
        for line in data.split(separator: 0x0A).reversed() where line.count < 2_000_000 {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], obj["type"] as? String == "assistant",
                  let model = (obj["message"] as? [String: Any])?["model"] as? String, model.hasPrefix("claude") else { continue }
            return model
        }
        return nil
    }

    /// Whether the account has a background record of this session, in any state.
    private static func knows(_ id: SessionID, account: Account) -> Bool {
        guard let data = ClaudeCLI.agents(account),
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return false }
        return list.contains { $0["sessionId"] as? String == id }
    }

    /// `claude stop` returns before the process is gone; the account's listing says when it is.
    private static func waitUntilStopped(_ id: SessionID, account: Account) -> Bool {
        let until = Date().addingTimeInterval(15)
        repeat {
            // A listing that fails says nothing: keep asking, and count it as running if it never answers.
            if let data = ClaudeCLI.agents(account), let snap = EventParser.parseAgents(data, accountId: account.id, at: Date()),
               !snap.entries.contains(where: { $0.sessionId == id && snap.stopped[id] == nil }) { return true }
            usleep(300_000)
        } while Date() < until
        return false
    }

    /// Puts the transcript, and the folder of the same name beside it (subagents, tool results),
    /// at the path `to` reads. Nothing to do when both accounts share projects/ (a symlink).
    /// Returns why it couldn't, or nil.
    static func carry(_ transcript: String, sessionId: SessionID, cwd: String, to account: Account) -> String? {
        let fm = FileManager.default
        let target = Transcripts.defaultPath(sessionId: sessionId, cwd: cwd, account: account)
        guard fm.fileExists(atPath: transcript) else { return "no transcript at \((transcript as NSString).abbreviatingWithTildeInPath)" }
        if sameFile(transcript, target) { return nil }
        let source = URL(fileURLWithPath: transcript), dest = URL(fileURLWithPath: target)
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try replace(dest, with: source)
            let sidecar = source.deletingPathExtension(), destSidecar = dest.deletingPathExtension()
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: sidecar.path, isDirectory: &isDir), isDir.boolValue { try replace(destSidecar, with: sidecar) }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// A copy next to `dest`, then swapped in: a reader never sees half a transcript.
    private static func replace(_ dest: URL, with source: URL) throws {
        let fm = FileManager.default
        let staging = dest.deletingLastPathComponent().appendingPathComponent(".\(dest.lastPathComponent).maxwell-move")
        try? fm.removeItem(at: staging)
        try fm.copyItem(at: source, to: staging)
        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: dest)
        }
    }

    private static func sameFile(_ a: String, _ b: String) -> Bool {
        let fm = FileManager.default
        guard let x = try? fm.attributesOfItem(atPath: a), let y = try? fm.attributesOfItem(atPath: b) else { return false }
        return (x[.systemFileNumber] as? NSNumber) == (y[.systemFileNumber] as? NSNumber)
            && (x[.systemNumber] as? NSNumber) == (y[.systemNumber] as? NSNumber)
    }
}
