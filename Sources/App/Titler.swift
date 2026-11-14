import Foundation

/// Names sessions whose own title says little ("hi, do I need to do", "acme-75"). One
/// `claude -p --model haiku` read of the first prompt and the last reply, run like the Judge:
/// no tools, no settings, no saved session. About $0.0003 a title, once per session.
enum Titler {
    static let system = """
    You name a coding assistant's work session so its owner recognises it at a glance in a list \
    of twenty. Answer with the title only: 2 to 5 words, in Title Case, in the language the owner \
    writes in. Name what the session as a whole is about, from the first message, not the latest \
    detail in the reply. Write it the way a ticket would ("Stripe Webhook Retries", "Onboarding Email Copy", \
    "Fix Flaky Login Test"). Use the specific product, feature, file, customer or tool. \
    Never generic words like Task, Session, Help, Question, Continue, Work, Chat. No quotes, \
    no emoji, no closing period.
    """

    struct Outcome { var title: String?; var costUSD: Double?; var raw: String }

    /// Blocking; call off the main thread.
    static func title(_ s: Session, account: Account) -> Outcome {
        var input = "First message from the owner:\n<<<\n\(s.firstPrompt ?? "(none)")\n>>>"
        if let m = s.lastMessage { input += "\n\nThe assistant's latest reply:\n<<<\n\(m.prefix(1500))\n>>>" }
        input += "\n\nFolder: \((s.cwd as NSString).lastPathComponent)"
        if let b = s.branch { input += "\nBranch: \(b)" }
        let args = ["-p", "--model", "haiku", "--output-format", "json", "--no-session-persistence",
                    "--tools", "", "--setting-sources", "", "--strict-mcp-config", "--disable-slash-commands",
                    "--system-prompt", system, input]
        let r = ClaudeCLI.run(ClaudeCLI.claudePath, args, cwd: account.configDir.path, env: ClaudeCLI.env(for: account), timeout: 60)
        guard r.status == 0, let obj = try? JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any] else {
            return Outcome(title: nil, costUSD: nil, raw: (r.err + r.out).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let text = obj["result"] as? String ?? ""
        return Outcome(title: Titles.clean(text), costUSD: (obj["total_cost_usd"] as? NSNumber)?.doubleValue, raw: text)
    }
}
