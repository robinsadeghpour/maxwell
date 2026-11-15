import Foundation

/// Which group a session is in, from the best evidence there is. In order:
///
/// 1. What the Claude Code process says it is doing right now (sessions/<pid>.json, through
///    the listing): a dialog waiting for an answer is Needs you, a running turn is Working.
/// 2. Once the turn is over, what it left (`Outcome`): the session's own status line, then
///    Claude Code's verdict on the turn (jobs/<id>/state.json), then Maxwell's reading of the reply.
/// 3. Only then background work: a turn that ended on a question is Needs you even while a
///    shell it started keeps running; otherwise those shells keep it Working.
///
/// Hooks set the phase the moment they arrive; the next listing that has seen the same moment
/// replaces it. Each verdict keeps a few words on where it came from (`Session.phaseSource`).
enum Live {
    /// True when the latest listing already reflects a hook at `t`: Claude Code changed the
    /// status with it, or the listing is a few seconds younger than it.
    static func covers(_ s: Session, _ t: Date) -> Bool {
        guard let listed = s.listedAt, s.listedStatus != nil else { return false }
        if let at = s.statusAt, at >= t.addingTimeInterval(-1) { return true }
        return listed >= t.addingTimeInterval(3)
    }

    /// Sets the phase from the listing's facts. `reset` is when the account's limit ends, if it is at one.
    static func settle(_ s: inout Session, reset: Date?) {
        guard let status = s.listedStatus else { return }
        let was = s.phase
        s.waitingOn = nil
        switch status {
        case .waiting(let what):
            // A permission hook says which tool; keep its words over the bare "permission prompt".
            if case .needsYou(let q) = was, !q.isEmpty, s.phaseSource.hasPrefix("hook: ") || s.phaseSource.hasPrefix("Claude Code: waiting") {
                s.phase = .needsYou(q)
            } else if let needs = s.job?.needs, s.job?.tempo == "blocked" {
                s.phase = .needsYou(needs)
            } else {
                s.phase = .needsYou(describe(waitingFor: what))
            }
            s.phaseSource = "Claude Code: waiting for \(what)"
        case .busy:
            s.phase = .working
            s.phaseSource = "Claude Code: turn running"
        case .idle, .shell:
            let (phase, source) = Outcome.of(s, reset: reset, job: s.job)
            s.phase = phase
            s.phaseSource = source
            guard phase == .yourTurn else { break }
            // The turn is over and asks nothing; work it started in the background may still report back.
            // Claude Code's job record counts it for background sessions; without one, and without the
            // process's own status, the transcript's ledger is all there is.
            let ledger = s.job == nil && s.statusAt == nil ? s.runningTasks ?? [] : []
            let work = s.job?.work ?? ledger.count
            if status == .shell || work > 0 {
                let n = max(work, 1)
                s.phase = .working
                s.waitingOn = !ledger.isEmpty ? ledger.running
                    : status == .shell && s.job == nil ? "background shell running" : "\(n) background task\(n == 1 ? "" : "s") running"
                s.phaseSource = "Claude Code: turn over, \(s.waitingOn!)"
            }
        }
        if s.phase == .working, was != .working { s.doneCheck = nil }
    }

    /// Claude Code's waitingFor words, as a line for the header.
    static func describe(waitingFor w: String) -> String {
        switch w {
        case "permission prompt", "permission": return "Waiting for your permission"
        case "input needed": return "Waiting for your answer"
        case "worker request": return "A subagent asks for your permission"
        case "sandbox request": return "Asks to reach the network from its sandbox"
        case "goal proposal": return "Proposes a goal: approve or change it"
        case "dialog open": return "A dialog is open in the session"
        default: return w.prefix(1).uppercased() + w.dropFirst()
        }
    }
}

/// What a finished turn leaves for Robin.
enum Outcome {
    /// The phase after a turn and where it came from, best evidence first: how the turn stopped,
    /// the session's own status line, Claude Code's verdict on the turn, then the reply's wording.
    static func of(_ s: Session, reset: Date?, job: JobState?) -> (Phase, String) {
        if let e = s.stopFailure {
            if e.contains("rate_limit") || e.contains("usage_limit") { return (.limited(reset), "turn stopped at a usage limit") }
            return (.needsYou("Stopped on an error: \(e)"), "turn stopped on an error")
        }
        guard let m = s.lastMessage else {
            if let j = job, let verdict = jobVerdict(j) { return verdict }
            return (.yourTurn, "no reply yet")
        }
        if case .limitHit = Reply.classify(m) { return (.limited(reset), "reply is the usage-limit line") }
        // The session was told to end with this line, so it gets the last word on whether it needs Robin.
        if let w = Wrap.parse(m) {
            if w.state == .needsYou { return (.needsYou(w.note.isEmpty ? "Needs you" : w.note), "session's status line: Needs you") }
            return (.yourTurn, "session's status line: \(w.state.rawValue)")
        }
        if let j = job, let verdict = jobVerdict(j) { return verdict }
        if case .question(let q) = Reply.classify(m) { return (.needsYou(q), "reply asks a question") }
        return (.yourTurn, "reply asks nothing")
    }

    /// Claude Code's verdict, once it has settled (it writes it a moment after the turn ends).
    private static func jobVerdict(_ j: JobState) -> (Phase, String)? {
        guard j.tempo != "active" else { return nil }
        switch j.state {
        case "blocked": return (.needsYou(j.needs ?? j.detail ?? "Waiting for your reply"), "Claude Code: blocked on you")
        case "failed": return (.needsYou("Gave up: " + (j.detail ?? "the last turn failed")), "Claude Code: turn failed")
        case "done": return (.yourTurn, "Claude Code: done")
        default: return (.yourTurn, "Claude Code: \(j.state), idle")
        }
    }
}
