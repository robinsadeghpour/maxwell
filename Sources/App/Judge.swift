import Foundation

/// The last step before Safe to close: one cheap model read of a candidate's last reply.
/// Runs `claude -p --model haiku` on the account with the most 5-hour room, with no tools,
/// no settings (so no hooks fire) and no saved session. Anything but "finished" is not safe.
enum Judge {
    static let system = """
    You decide whether a coding assistant's last message means its work is completely finished, \
    so its terminal session can be closed and nothing is lost. Answer with exactly one word: \
    finished, pending or unsure.
    finished: the message reports work that is done, and leaves nothing for the user to do, decide, \
    answer, test, review, reply to or wait for. No question, offer, next step, promise, caveat about \
    unfinished parts, failure, blocker, or waiting on CI, a deploy or a person.
    pending: anything is asked, offered, proposed, left open, partly done, failed, blocked or waiting.
    unsure: anything else, or you cannot tell. When in doubt, answer unsure.
    """

    struct Outcome { var verdict: String; var costUSD: Double?; var ms: Int; var raw: String }

    /// Blocking; call off the main thread.
    static func read(_ message: String, account: Account) -> Outcome {
        let start = Date()
        let args = ["-p", "--model", "haiku", "--output-format", "json", "--no-session-persistence",
                    "--tools", "", "--setting-sources", "", "--strict-mcp-config", "--disable-slash-commands",
                    "--system-prompt", system, "The assistant's last message:\n<<<\n\(message)\n>>>"]
        // cwd inside the config dir: should a hook fire anyway, the reducer ignores that session.
        let r = ClaudeCLI.run(ClaudeCLI.claudePath, args, cwd: account.configDir.path, env: ClaudeCLI.env(for: account), timeout: 60)
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        guard r.status == 0, let obj = try? JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any] else {
            return Outcome(verdict: "error", costUSD: nil, ms: ms, raw: (r.err + r.out).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let text = (obj["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return Outcome(verdict: Judgment.parse(text).rawValue, costUSD: (obj["total_cost_usd"] as? NSNumber)?.doubleValue, ms: ms, raw: text)
    }

    /// One read, appended to the event log (cached there by hash; errors are logged, not cached).
    static func judgeAndLog(_ s: Session, hash: String, state: AppState, now: Date) {
        guard let m = s.lastMessage, let account = state.most5hRoom(now: now) else { return }
        let o = read(m, account: account)
        MaxwellRecord.append(MaxwellRecord.judged(hash: hash, session: s.id, verdict: o.verdict, account: account.id, costUSD: o.costUSD, ms: o.ms, raw: o.raw))
    }
}
