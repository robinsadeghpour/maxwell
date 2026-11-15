import Foundation
import CryptoKit

/// One piece of evidence for "safe to close". A session is safe only when every check
/// passes; a check that could not find out is unknown, and unknown is never safe.
struct Check: Equatable {
    enum Kind: String, CaseIterable {
        case listed, idle, hooks, reply, wrap, worktree, pushed, pr, marked, plugin, judge
        var title: String {
            switch self {
            case .listed: return "still running"
            case .idle: return "not busy"
            case .hooks: return "hooks report it"
            case .reply: return "reply hands nothing back"
            case .wrap: return "session says safe to close"
            case .worktree: return "worktree clean"
            case .pushed: return "everything pushed"
            case .pr: return "PR merged or none"
            case .marked: return "not marked unsafe"
            case .plugin: return "plugin check"
            case .judge: return "model read: finished"
            }
        }
    }
    enum Outcome: String { case pass, fail, unknown }

    var kind: Kind
    var outcome: Outcome
    var detail: String    // what was found
    var source: String    // where it came from
    /// A plugin check's own title ("Linear ticket done"); built-in checks use their kind's.
    var name: String? = nil

    var title: String { name ?? kind.title }

    static func allPass(_ checks: [Check]) -> Bool { checks.allSatisfy { $0.outcome == .pass } }
    /// Every check but the model read passes: the session may be worth a model read.
    static func candidate(_ checks: [Check]) -> Bool { checks.allSatisfy { $0.kind == .judge || $0.outcome == .pass } }
}

/// A model read of one last reply (`claude -p --model haiku`), cached by the reply's hash.
struct Judgment: Equatable {
    enum Verdict: String { case finished, pending, unsure }
    var verdict: Verdict
    var at: Date
    var account: AccountID
    var costUSD: Double?

    /// Exactly one of the three words (any case, a trailing full stop allowed); anything else is unsure.
    static func parse(_ text: String) -> Verdict {
        Verdict(rawValue: text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".!*` \n"))) ?? .unsure
    }
}

/// A session Maxwell stopped. Enough to list it and `claude attach` it again after a restart.
struct ClosedSession: Equatable {
    var at: Date
    var session: Session
    var checks: [Check]
}

extension Reply {
    /// Stable key for a message: the judgment cache and false-safe records use it.
    static func hash(_ message: String) -> String {
        SHA256.hash(data: Data(message.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

extension AppState {
    /// The checklist behind a session's verdict, in the order the evidence UI shows it.
    func checks(_ s: Session, now: Date, rules: GroupRules) -> [Check] {
        let acct = account(s.accountId)?.name ?? s.accountId
        var out: [Check] = []
        func add(_ k: Check.Kind, _ o: Check.Outcome, _ detail: String, _ source: String) { out.append(Check(kind: k, outcome: o, detail: detail, source: source)) }

        let listing = "claude agents --json (\(acct))"
        if s.phase == .ended {
            add(.listed, .fail, "no longer listed", listing)
        } else if let at = s.listedAt, at == listedAt[s.accountId] {
            let age = now.timeIntervalSince(at)
            if age > rules.listingFresh { add(.listed, .unknown, "last listing \(Reply.span(age)) old", listing) }
            else { add(.listed, .pass, "listed \(Reply.span(age)) ago", listing) }
        } else {
            add(.listed, .unknown, "not in the latest listing", listing)
        }

        let busySource = "agents --json status + transcript"
        switch (s.phase, s.listedStatus, s.runningTasks) {
        case (.working, _, _), (_, .busy?, _): add(.idle, .fail, "working", busySource)
        case (_, .waiting(let why)?, _): add(.idle, .fail, "waiting: \(why)", busySource)
        case (_, nil, _): add(.idle, .unknown, "no status from a listing", busySource)
        case (_, _, nil): add(.idle, .unknown, "transcript not readable for background tasks", busySource)
        case (_, _, let tasks?) where !tasks.isEmpty:
            let a = tasks.agents.count, sh = tasks.count - a
            let what = [a > 0 ? "\(a) subagent\(a == 1 ? "" : "s")" : nil, sh > 0 ? "\(sh) background shell\(sh == 1 ? "" : "s")" : nil]
            add(.idle, .fail, what.compactMap { $0 }.joined(separator: " and ") + " running", busySource)
        default: add(.idle, .pass, "idle, no background tasks", busySource)
        }

        if let at = s.hookSeenAt { add(.hooks, .pass, "last hook \(Reply.span(now.timeIntervalSince(at))) ago", "events.jsonl") }
        else { add(.hooks, .unknown, "no hook events from this session (started before install-hooks?)", "events.jsonl") }

        let replySource = "last assistant message"
        if !s.prompted {
            add(.reply, .fail, "never prompted", replySource)
        } else {
            switch s.lastMessage.map(Reply.classify) {
            case nil: add(.reply, .unknown, "no reply found", replySource)
            case .question(let q)?: add(.reply, .fail, "asks: \(q)", replySource)
            case .offer(let o)?: add(.reply, .fail, "leaves for you: \(o)", replySource)
            case .limitHit?: add(.reply, .fail, "stopped at a usage limit", replySource)
            case .statement?: add(.reply, .pass, "reports, asks and offers nothing", replySource)
            }
        }
        if let w = s.lastMessage.flatMap(Wrap.parse) {
            if w.state == .safe { add(.wrap, .pass, w.note.isEmpty ? "safe to close" : w.note, "session's status line") }
            else { add(.wrap, .fail, w.state.rawValue + (w.note.isEmpty ? "" : " · " + w.note), "session's status line") }
        }

        repoChecks(s, into: &out)

        if let m = s.markedNotSafeAt, m >= s.lastEventAt {
            add(.marked, .fail, "you marked it not safe \(Reply.span(now.timeIntervalSince(m))) ago", "Not safe button")
        }

        out += pluginChecks(s)

        let judgeSource = "claude -p --model haiku"
        if !rules.judge {
            add(.judge, .fail, "model read is off (judge = off)", "config")
        } else if let m = s.lastMessage, let j = judgments[Reply.hash(m)] {
            let cost = j.costUSD.map { String(format: ", $%.4f", $0) } ?? ""
            add(.judge, j.verdict == .finished ? .pass : .fail, j.verdict.rawValue, "\(judgeSource) on \(account(j.account)?.name ?? j.account)\(cost)")
        } else {
            add(.judge, .unknown, Check.candidate(out) ? "waiting for the model read" : "read only once every other check passes", judgeSource)
        }
        return out
    }

    /// Sessions that pass every other check and whose last reply has no model read yet, one per reply.
    func judgeCandidates(now: Date, rules: GroupRules) -> [(Session, String)] {
        guard rules.judge else { return [] }
        var seen = Set<String>()
        return sessions.values.compactMap { s in
            guard s.phase == .yourTurn, let m = s.lastMessage, Check.candidate(checks(s, now: now, rules: rules)) else { return nil }
            let h = Reply.hash(m)
            guard judgments[h] == nil, seen.insert(h).inserted else { return nil }
            return (s, h)
        }
    }

    private func repoChecks(_ s: Session, into out: inout [Check]) {
        func add(_ k: Check.Kind, _ o: Check.Outcome, _ detail: String, _ source: String) { out.append(Check(kind: k, outcome: o, detail: detail, source: source)) }
        guard let c = s.doneCheck else {
            for k in [Check.Kind.worktree, .pushed, .pr] { add(k, .unknown, "not checked yet", "git, gh") }
            return
        }
        let when = hhmm(c.at)
        if c.at < s.lastEventAt {
            for k in [Check.Kind.worktree, .pushed, .pr] { add(k, .unknown, "checked \(when), before the last activity", "git, gh") }
            return
        }
        guard c.repo else {
            for k in [Check.Kind.worktree, .pushed, .pr] { add(k, .unknown, "not a git repo", "git rev-parse \(when)") }
            return
        }
        switch c.dirtyFiles {
        case nil: add(.worktree, .unknown, "git status failed", "git status \(when)")
        case 0?: add(.worktree, .pass, "clean", "git status \(when)")
        case let n?: add(.worktree, .fail, "\(n) uncommitted", "git status \(when)")
        }
        switch c.unpushed {
        case nil: add(.pushed, .unknown, "git rev-list failed", "git rev-list \(when)")
        case 0?: add(.pushed, .pass, "nothing unpushed", "git rev-list \(when)")
        case let n?: add(.pushed, .fail, "\(n) unpushed commit\(n == 1 ? "" : "s")", "git rev-list \(when)")
        }
        let gh = "gh pr view \(when)"
        switch c.pr {
        case .none(let why): add(.pr, .pass, why, gh)
        case .merged(let n): add(.pr, .pass, "PR #\(n) merged", gh)
        case .open(let n): add(.pr, .fail, "PR #\(n) open", gh)
        case .closed(let n): add(.pr, .fail, "PR #\(n) closed unmerged", gh)
        case .unknown(let why): add(.pr, .unknown, why, gh)
        }
    }
}

/// "14:05", without the UI's formatters.
private func hhmm(_ d: Date) -> String {
    let c = Calendar.current.dateComponents([.hour, .minute], from: d)
    return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
}
