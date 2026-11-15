import Foundation

/// `Maxwell state` and `Maxwell watch`: what the sidebar shows and why, from a shell.
enum StateAudit {
    /// `state [--no-judge]`: the groups now, from the event log, live listings, repo checks and model
    /// reads (made here for candidates without one), with what each group rests on and every check.
    static func state(args: [String], config: Config) {
        ClaudeCLI.scrubOwnEnvironment()
        Titles.auto = config.autoTitles
        print("claude: \(ClaudeCLI.claudeFound ? ClaudeCLI.claudePath : "not found (sessions can't be listed)")")
        for a in config.accounts where ClaudeCLI.agents(a) == nil { print("! claude agents --json failed on \(a.id) (\(a.configDir.path))") }
        let log = EventLog(url: Paths.eventLog)
        var state = log.readNew().reduce(into: AppState(accounts: config.accounts)) { reduce(into: &$0, $1) }
        for a in config.accounts { if let snap = AgentsProbe.snapshot(a) { state = reduce(state, .agents(snap)) } }
        let checker = DoneChecker { _ in }
        for s in state.sessions.values where s.phase == .yourTurn { state = reduce(state, .doneCheck(s.id, checker.evaluate(cwd: s.cwd))) }
        let now = Date(), rules = config.rules
        if !args.contains("--no-judge") {
            for (s, h) in state.judgeCandidates(now: now, rules: rules) { Judge.judgeAndLog(s, hash: h, state: state, now: now) }
            state = log.readNew().reduce(into: state) { reduce(into: &$0, $1) }
        }
        let projects = Projects(rules: config.projects)
        for (g, items) in state.grouped(now: now, rules: rules) where g != .recentlyClosed {
            print("## \(g.title) \(items.count)")
            for s in items { printSession(s, group: g, state: state, projects: projects, now: now, rules: rules) }
        }
        printSummary(state, now: now, rules: rules)
    }

    private static func printSession(_ s: Session, group g: PhaseGroup, state: AppState, projects: Projects, now: Date, rules: GroupRules) {
        print("  \(s.id.prefix(8))  \(s.accountId)\t\(state.project(s, in: projects))\t\(s.title)\t\(Reply.span(now.timeIntervalSince(s.lastEventAt)))")
        print("      ← " + why(s))
        guard g != .working else { return }
        let mark: [Check.Outcome: String] = [.pass: "✓", .fail: "✗", .unknown: "?"]
        for c in state.checks(s, now: now, rules: rules) where g == .safeToClose || c.outcome != .pass {
            print("      \(mark[c.outcome] ?? "?") \(c.title): \(c.detail)  [\(c.source)]")
        }
    }

    /// What the group rests on, and what it shows: the question, or that Claude Code's files couldn't be read.
    static func why(_ s: Session) -> String {
        var line = s.phaseSource.isEmpty ? "hooks" : s.phaseSource
        if case .needsYou(let q) = s.phase { line += " · \(q.prefix(100))" }
        if let u = s.unverified { line += " · UNVERIFIED: \(u)" }
        return line
    }

    private static func printSummary(_ state: AppState, now: Date, rules: GroupRules) {
        let stopped = state.sessions.values.filter { $0.phase == .yourTurn }
        let verdicts = stopped.map { state.checks($0, now: now, rules: rules) }
        let safe = verdicts.filter(Check.allPass).count
        let failing = verdicts.filter { $0.contains { $0.outcome == .fail } }.count
        let unknownOnly = verdicts.filter { v in !Check.allPass(v) && !v.contains { $0.outcome == .fail } }.count
        print("\nstopped \(stopped.count): safe \(safe), blocked by a failing check \(failing), blocked only by unknowns \(unknownOnly)")
        for k in Check.Kind.allCases {
            let f = verdicts.filter { $0.contains { $0.kind == k && $0.outcome == .fail } }.count
            let u = verdicts.filter { $0.contains { $0.kind == k && $0.outcome == .unknown } }.count
            if f + u > 0 { print("  \(k.title): \(f) fail, \(u) unknown") }
        }
        let unverified = state.sessions.values.filter { $0.phase != .ended && $0.unverified != nil }.count
        if unverified > 0 { print("! \(unverified) session(s) could not be checked against Claude Code's own files") }
        let reads = state.judgments.values
        print("model reads cached \(reads.count), cost $\(String(format: "%.4f", reads.compactMap(\.costUSD).reduce(0, +)))")
        for a in state.accounts {
            print("\(a.id): 5h \(a.fiveHour.map { "\(Int($0.usedPercent))%" } ?? "-") wk \(a.week.map { "\(Int($0.usedPercent))%" } ?? "-")")
        }
    }

    /// `watch [name prefix]`: the app's own pipeline (event log, and a listing whenever Claude Code's
    /// files change), printing every group change with its source, to check the groups against reality.
    /// A change into Needs you or Your turn is announced by the app once it has held for `Store.settleDelay`.
    static func watch(prefix: String, config: Config) -> Never {
        let log = EventLog(url: Paths.eventLog)
        var state = log.readNew().reduce(into: AppState(accounts: config.accounts)) { reduce(into: &$0, $1) }
        var shown: [SessionID: String] = [:]
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss.SSS"
        func apply(_ events: [Event]) {
            let before = state
            state = events.reduce(into: state) { reduce(into: &$0, $1) }
            for (id, s) in state.sessions where prefix.isEmpty || s.name.hasPrefix(prefix) || s.title.hasPrefix(prefix) {
                let text = label(s.phase) + "  ← " + why(s)
                guard shown[id] != text else { continue }
                shown[id] = text
                let announces = announcement(from: before.sessions[id]?.phase, to: s.phase).map { "  (announces \($0) if it holds)" } ?? ""
                print("\(clock.string(from: Date()))  \(s.name.prefix(20))\t\(text)\(announces)")
                fflush(stdout)
            }
        }
        log.tail { apply($0) }
        let probe = AgentsProbe(accounts: config.accounts) { apply([$0]) }
        withExtendedLifetime(probe) { RunLoop.main.run() }
        exit(0)
    }

    private static func label(_ p: Phase) -> String {
        switch p {
        case .working: return "Working"
        case .needsYou: return "Needs you"
        case .yourTurn: return "Your turn"
        case .limited: return "Limited"
        case .ended: return "Ended"
        }
    }

    /// The notification a change would send, as `Store.apply` decides it.
    private static func announcement(from old: Phase?, to new: Phase) -> String? {
        if case .needsYou = new { if case .needsYou? = old { return nil }; return "needs you" }
        return new == .yourTurn && old == .working ? "done" : nil
    }
}
