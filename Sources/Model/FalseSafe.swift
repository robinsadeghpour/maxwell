import Foundation

/// A session you marked "Not safe" while Maxwell called it safe: every fact the verdict
/// read, as JSON. `./build.sh test` replays each one in Tests/fixtures/false-safe/ and fails
/// until the rules no longer call it safe.
enum FalseSafe {
    static func encode(_ s: Session, in state: AppState, now: Date, rules: GroupRules) -> [String: Any] {
        func ts(_ d: Date?) -> Any { d.map { $0.timeIntervalSince1970 } ?? NSNull() }
        var facts: [String: Any] = [
            "prompted": s.prompted, "lastMessage": s.lastMessage ?? NSNull(), "lastEventAt": ts(s.lastEventAt),
            "listedAt": ts(s.listedAt), "accountListedAt": ts(state.listedAt[s.accountId]),
            "runningTasks": s.runningTasks.map { $0.map { t -> [String: Any] in ["id": t.id, "kind": t.kind.rawValue, "label": t.label ?? NSNull(), "startedAt": ts(t.startedAt)] } } ?? NSNull(),
            "hookSeenAt": ts(s.hookSeenAt),
        ]
        switch s.listedStatus {
        case .busy?: facts["listedStatus"] = "busy"
        case .idle?: facts["listedStatus"] = "idle"
        case .shell?: facts["listedStatus"] = "shell"
        case .waiting(let w)?: facts["listedStatus"] = "waiting: " + w
        case nil: facts["listedStatus"] = NSNull()
        }
        // What the phase rested on, so a rule added later can be checked against the same facts.
        facts["statusAt"] = ts(s.statusAt)
        facts["turnAt"] = ts(s.turnAt)
        facts["stopFailure"] = s.stopFailure ?? NSNull()
        facts["phaseSource"] = s.phaseSource
        if let j = s.job {
            facts["job"] = ["state": j.state, "tempo": j.tempo ?? NSNull(), "needs": j.needs ?? NSNull(), "detail": j.detail ?? NSNull(),
                            "work": j.work, "updatedAt": ts(j.updatedAt)]
        }
        if let c = s.doneCheck {
            var pr: [String: Any]
            switch c.pr {
            case .none(let why): pr = ["state": "none", "why": why]
            case .merged(let n): pr = ["state": "merged", "number": n]
            case .open(let n): pr = ["state": "open", "number": n]
            case .closed(let n): pr = ["state": "closed", "number": n]
            case .unknown(let why): pr = ["state": "unknown", "why": why]
            }
            facts["doneCheck"] = ["at": ts(c.at), "repo": c.repo, "dirtyFiles": c.dirtyFiles ?? NSNull(), "unpushed": c.unpushed ?? NSNull(),
                                  "branch": c.branch ?? NSNull(), "pr": pr]
        }
        if let m = s.lastMessage, let j = state.judgments[Reply.hash(m)] { facts["judgment"] = j.verdict.rawValue }
        return ["session": s.id, "title": s.title, "account": s.accountId, "cwd": s.cwd, "now": now.timeIntervalSince1970,
                "hash": s.lastMessage.map(Reply.hash) ?? "", "facts": facts,
                "checksSeen": state.checks(s, now: now, rules: rules).map(MaxwellRecord.encode)]
    }

    /// Rebuilds the state the verdict saw. The "Not safe" mark itself is left out: the
    /// question is whether the rules alone would still call it safe.
    static func decode(_ o: [String: Any]) -> (AppState, Session, Date, GroupRules)? {
        guard let id = o["session"] as? String, let acct = o["account"] as? String, let f = o["facts"] as? [String: Any],
              let now = (o["now"] as? NSNumber)?.doubleValue else { return nil }
        func date(_ any: Any?) -> Date? { (any as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } }
        var s = Session(id: id, name: id, accountId: acct, cwd: o["cwd"] as? String ?? "", at: date(f["lastEventAt"]) ?? .distantPast,
                        origin: .external, reach: .elsewhere(pid: nil))
        s.prompted = f["prompted"] as? Bool ?? false
        s.lastMessage = f["lastMessage"] as? String
        s.phase = .yourTurn
        s.listedAt = date(f["listedAt"])
        s.runningTasks = (f["runningTasks"] as? [[String: Any]])?.map {
            BackgroundTask(id: $0["id"] as? String ?? "", kind: BackgroundTask.Kind(rawValue: $0["kind"] as? String ?? "") ?? .shell,
                           label: $0["label"] as? String, startedAt: date($0["startedAt"]) ?? .distantPast)
        }
        // Fixtures written before tasks had kinds hold only a count.
        ?? (f["runningTasks"] as? NSNumber).map { n in (0..<n.intValue).map { BackgroundTask(id: "\($0)", kind: .shell, startedAt: .distantPast) } }
        s.hookSeenAt = date(f["hookSeenAt"])
        switch f["listedStatus"] as? String {
        case "busy"?: s.listedStatus = .busy
        case "idle"?: s.listedStatus = .idle
        case "shell"?: s.listedStatus = .shell
        case let w? where w.hasPrefix("waiting: "): s.listedStatus = .waiting(String(w.dropFirst(9)))
        default: s.listedStatus = nil
        }
        s.statusAt = date(f["statusAt"])
        s.turnAt = date(f["turnAt"])
        s.stopFailure = f["stopFailure"] as? String
        s.phaseSource = f["phaseSource"] as? String ?? ""
        if let j = f["job"] as? [String: Any], let state = j["state"] as? String {
            s.job = JobState(state: state, tempo: j["tempo"] as? String, needs: j["needs"] as? String, detail: j["detail"] as? String,
                             work: (j["work"] as? NSNumber)?.intValue ?? 0, updatedAt: date(j["updatedAt"]))
        }
        if let c = f["doneCheck"] as? [String: Any], let at = date(c["at"]) {
            let pr = c["pr"] as? [String: Any] ?? [:]
            let n = (pr["number"] as? NSNumber)?.intValue ?? 0, why = pr["why"] as? String ?? ""
            let state: DoneCheck.PRState
            switch pr["state"] as? String {
            case "none"?: state = .none(why)
            case "merged"?: state = .merged(n)
            case "open"?: state = .open(n)
            case "closed"?: state = .closed(n)
            default: state = .unknown(why)
            }
            s.doneCheck = DoneCheck(at: at, repo: c["repo"] as? Bool ?? false, dirtyFiles: (c["dirtyFiles"] as? NSNumber)?.intValue,
                                    unpushed: (c["unpushed"] as? NSNumber)?.intValue, pr: state, branch: c["branch"] as? String)
        }
        var st = AppState(accounts: [Account(id: acct, name: acct, configDir: URL(fileURLWithPath: "/nonexistent/\(acct)"))])
        st.listedAt[acct] = date(f["accountListedAt"])
        if let v = (f["judgment"] as? String).flatMap(Judgment.Verdict.init), let m = s.lastMessage {
            st.judgments[Reply.hash(m)] = Judgment(verdict: v, at: Date(timeIntervalSince1970: now), account: acct, costUSD: nil)
        }
        st.sessions[id] = s
        let rules = GroupRules(idleAfter: 24 * 3600, judge: true)
        return (st, s, Date(timeIntervalSince1970: now), rules)
    }
}
