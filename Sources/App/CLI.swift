import Foundation

/// `Maxwell <command>` from a shell. Returns nil when the arguments ask for the app.
func runCLI(_ args: [String]) -> Int32? {
    guard let cmd = args.dropFirst().first, !cmd.hasPrefix("-") else { return nil }
    let config = Config.load()
    do {
        switch cmd {
        case "install-hooks":
            print(try HookInstaller.install(accounts: config.accounts, bundledHook: bundledHookURL()))
        case "uninstall-hooks":
            print(try HookInstaller.uninstall(accounts: config.accounts))
        case "render-iconset":
            guard args.count >= 4 else { return 2 }
            try IconArt.writeIconset(args[2], to: URL(fileURLWithPath: args[3]))
        case "logo-sheet":
            // logo-sheet <out.png> <Name=repo root>...: each project's logo, both treatments, both themes.
            guard args.count >= 4 else { return 2 }
            let projects = args.dropFirst(3).map { a -> (String, String) in
                let kv = a.split(separator: "=", maxSplits: 1).map(String.init)
                return (kv[0], Paths.normalize(kv.count > 1 ? kv[1] : ""))
            }
            try ProjectLogos.writeSheet(projects, overrides: config.logos, to: URL(fileURLWithPath: args[2]))
        case "accounts":
            for a in config.accounts { print("\(a.id)\t\(a.configDir.path)\tenv=\(a.configDirEnv ?? "(unset)")") }
        case "state":
            // The audit: what the sidebar would show now, from the event log, live listings, repo
            // checks and model reads (made here for candidates without one), with every check.
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
            let mark: [Check.Outcome: String] = [.pass: "✓", .fail: "✗", .unknown: "?"]
            for (g, items) in state.grouped(now: now, rules: rules) where g != .recentlyClosed {
                print("## \(g.title) \(items.count)")
                for s in items {
                    print("  \(s.id.prefix(8))  \(s.accountId)\t\(state.project(s, in: projects))\t\(s.title)\t\(Reply.span(now.timeIntervalSince(s.lastEventAt)))")
                    guard g != .working else { continue }
                    let checks = state.checks(s, now: now, rules: rules)
                    for c in checks where g == .safeToClose || c.outcome != .pass {
                        print("      \(mark[c.outcome]!) \(c.kind.title): \(c.detail)  [\(c.source)]")
                    }
                }
            }
            let stopped = state.sessions.values.filter { $0.phase == .yourTurn }
            let verdicts = stopped.map { state.checks($0, now: now, rules: rules) }
            let safe = verdicts.filter(Check.allPass).count
            let unknownOnly = verdicts.filter { v in !Check.allPass(v) && !v.contains { $0.outcome == .fail } }.count
            print("\nstopped \(stopped.count): safe \(safe), blocked by a failing check \(verdicts.filter { $0.contains { $0.outcome == .fail } }.count), blocked only by unknowns \(unknownOnly)")
            for k in Check.Kind.allCases {
                let f = verdicts.filter { $0.contains { $0.kind == k && $0.outcome == .fail } }.count
                let u = verdicts.filter { $0.contains { $0.kind == k && $0.outcome == .unknown } }.count
                if f + u > 0 { print("  \(k.title): \(f) fail, \(u) unknown") }
            }
            let reads = state.judgments.values
            print("model reads cached \(reads.count), cost $\(String(format: "%.4f", reads.compactMap(\.costUSD).reduce(0, +)))")
            for a in state.accounts {
                print("\(a.id): 5h \(a.fiveHour.map { "\(Int($0.usedPercent))%" } ?? "-") wk \(a.week.map { "\(Int($0.usedPercent))%" } ?? "-")")
            }
        default:
            FileHandle.standardError.write("usage: Maxwell [install-hooks | uninstall-hooks | accounts | state [--no-judge]]\n".data(using: .utf8)!)
            return 2
        }
        return 0
    } catch {
        FileHandle.standardError.write("maxwell: \(error)\n".data(using: .utf8)!)
        return 1
    }
}

func bundledHookURL() -> URL {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    return exe.deletingLastPathComponent().appendingPathComponent("maxwell-hook")
}
