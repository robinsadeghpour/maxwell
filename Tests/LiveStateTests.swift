import Foundation

/// Working, Needs you and Your turn from Claude Code's own state. Every case here is one the
/// sidebar got wrong on 15 Nov 2026, with the files' shapes copied from those sessions.
func liveStateTests() {
    let home = Paths.home
    let accounts = [Account(id: "work", name: "work", configDir: home.appendingPathComponent(".claude"))]
    let dir = home.appendingPathComponent(".claude").path
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
    func hook(_ kind: Hook.Kind, _ sid: String = "s1", at s: Double) -> Event {
        .hook(Hook(at: at(s), configDir: dir, sessionId: sid, cwd: "/tmp/x", transcriptPath: nil, kind: kind))
    }
    func listing(_ sid: String = "s1", at s: Double, status: AgentsSnapshot.Status, statusAt: Double? = nil, job: JobState? = nil,
                 message: String? = nil, background: Bool = true, tasks: [BackgroundTask]? = []) -> Event {
        var e = AgentsSnapshot.Entry(sessionId: sid, name: "n", cwd: "/tmp/x", startedAt: t0,
                                     reach: background ? .background(shortId: String(sid.prefix(8))) : .elsewhere(pid: 7), status: status,
                                     lastMessage: message, runningTasks: tasks)
        e.statusAt = statusAt.map(at)
        e.job = job
        return .agents(AgentsSnapshot(at: at(s), accountId: "work", entries: [e]))
    }
    func job(_ state: String, tempo: String = "idle", needs: String? = nil, detail: String? = nil, work: Int = 0) -> JobState {
        JobState(state: state, tempo: tempo, needs: needs, detail: detail, work: work, updatedAt: nil)
    }
    func phase(_ s: AppState, _ id: String = "s1") -> Phase? { s.sessions[id]?.phase }
    func fresh() -> AppState { reduce(AppState(accounts: accounts), hook(.promptSubmitted(prompt: "go", title: nil), at: 0)) }

    // MARK: Claude Code's files

    let crashesJob = #"{"state":"blocked","detail":"staging deploy ready; needs your approval","tempo":"blocked","inFlight":{"tasks":1,"queued":0,"kinds":["local_bash"],"drainableMonitors":0},"needs":"approve the staging deploy in the dashboard, then tell me","updatedAt":"2026-11-15T16:45:12.000Z"}"#
    let j = EventParser.parseJob(Data(crashesJob.utf8))
    check(j?.state == "blocked" && j?.tempo == "blocked" && j?.work == 1, "job record: state, tempo and one running shell")
    check(j?.needs == "approve the staging deploy in the dashboard, then tell me", "job record: what it needs, in its words")
    check(j?.updatedAt == Date(timeIntervalSince1970: 1794761112), "job record: when it was written")
    let watcherJob = #"{"state":"done","tempo":"idle","inFlight":{"tasks":1,"queued":0,"kinds":["artifact_watch"],"drainableMonitors":1}}"#
    check(EventParser.parseJob(Data(watcherJob.utf8))?.work == 0, "a file watcher is not background work")
    let askJob = #"{"state":"blocked","tempo":"blocked","needs":"pick one","block":{"questions":[{"question":"Which logo style?","options":[]}]}}"#
    check(EventParser.parseJob(Data(askJob.utf8))?.needs == "Which logo style?", "an AskUserQuestion dialog's question is what it needs")
    check(EventParser.parseJob(Data("{}".utf8)) == nil, "a job record without a state is no record")

    let pidFile = #"{"pid":5151,"sessionId":"e5f6a7b8-aaaa","status":"shell","statusUpdatedAt":1794762545932,"kind":"bg"}"#
    let own = EventParser.parsePidFile(Data(pidFile.utf8), sessionId: "e5f6a7b8-aaaa")
    check(own?.status == .shell && own?.at == Date(timeIntervalSince1970: 1794762545.932), "pid file: shell and when it changed")
    check(EventParser.parsePidFile(Data(pidFile.utf8), sessionId: "other") == nil, "a pid file of another session (pid reused) is ignored")
    let waitingPid = #"{"sessionId":"s","status":"waiting","waitingFor":"permission prompt"}"#
    check(EventParser.parsePidFile(Data(waitingPid.utf8), sessionId: "s")?.status == .waiting("permission prompt"), "pid file: waiting and for what")

    // claude agents --json: `state` is the job's verdict, not activity (an idle session sat in Working for 45 minutes).
    let agents = #"[{"pid":4242,"id":"a1b2c3d4","cwd":"/x","kind":"background","sessionId":"a1b2c3d4-1","name":"acme-32","status":"idle","state":"working"},{"id":"1fc2e8d4","cwd":"/y","kind":"background","sessionId":"1fc2e8d4-1","name":"no process","state":"blocked"},{"pid":3,"id":"c","cwd":"/z","kind":"interactive","sessionId":"c-1","status":"busy"}]"#
    let snap = EventParser.parseAgents(Data(agents.utf8), accountId: "work", at: t0)!
    check(snap.entries[0].status == .idle, "idle with job state working is idle")
    check(snap.entries[0].pid == 4242, "the listing's pid is kept, to read the process's own file")
    check(snap.entries[1].status == .idle, "a job with no process has nothing running")
    check(snap.entries[2].status == .busy && snap.entries[2].reach == .elsewhere(pid: 3), "a terminal session's busy")

    // MARK: Needs you

    // A session blocked on you: turn over on a question while a shell it started keeps running. It was Working for 27 minutes.
    var crashes = j!
    crashes.updatedAt = at(9)   // written for this turn
    var s = reduce(fresh(), listing(at: 10, status: .shell, statusAt: 9, job: crashes, message: "Built it. Open the link and tell me."))
    check(phase(s) == .needsYou("approve the staging deploy in the dashboard, then tell me"), "blocked on you beats a background shell")
    check(s.sessions["s1"]?.phaseSource == "Claude Code: blocked on you", "and says where that came from")
    check(s.checks(s.sessions["s1"]!, now: at(11), rules: GroupRules()).first { $0.kind == .idle }?.outcome == .fail, "a running shell still fails not-busy")

    // A research session: an "Open questions" list above "Safe to close" read as a question. It sat in Needs you.
    let research = "## Open questions\n- Can self-hosted environments run on macOS?\n- Is there a supported way to list cloud sessions?\n\nIf you want, I can turn this into a Linear project.\n\n**Safe to close** · research delivered, no code changed"
    s = reduce(fresh(), hook(.stopped(lastMessage: research), at: 5))
    check(phase(s) == .yourTurn, "the status line outranks questions in the body (hook)")
    s = reduce(s, listing(at: 9, status: .idle, statusAt: 5, job: job("done"), message: research))
    check(phase(s) == .yourTurn && s.sessions["s1"]?.phaseSource == "session's status line: Safe to close", "the status line outranks questions in the body (listing)")
    check(Reply.phase(after: "Done.\n\nWant me to tag it?\n\n**Not done** · tag v1") == .yourTurn, "Not done with an offer above it is your turn")

    // Without a status line, Claude Code's settled verdict decides.
    s = reduce(fresh(), listing(at: 9, status: .idle, statusAt: 8, job: job("blocked", tempo: "blocked", needs: "Go?"), message: "Fly is my pick. Go?"))
    check(phase(s) == .needsYou("Go?"), "Claude Code says blocked: needs you")
    s = reduce(fresh(), listing(at: 9, status: .idle, statusAt: 8, job: job("done"), message: "Shipped. Anything else you can think of?\n\nAll merged."))
    check(phase(s) == .yourTurn, "Claude Code says done: a question in the middle doesn't make it needs you")
    // Claude Code writes its verdict a moment after the turn ends: wait for it rather than announce
    // "done" from the reply and then "needs you" from the verdict (review, 15 Nov).
    s = reduce(fresh(), listing(at: 9, status: .idle, statusAt: 8, job: job("working", tempo: "active"), message: "Built it. Open the link and tell me."))
    check(phase(s) == .working && s.sessions["s1"]?.phaseSource == "Claude Code: turn over, its verdict not written yet", "verdict not written yet: still working")
    s = reduce(s, listing(at: 10, status: .idle, statusAt: 8, job: job("blocked", tempo: "blocked", needs: "open the link and tell me"), message: "Built it. Open the link and tell me."))
    check(phase(s) == .needsYou("open the link and tell me"), "then the verdict, once: needs you")
    s = reduce(fresh(), listing(at: 17, status: .idle, statusAt: 8, job: job("working", tempo: "active"), message: "Should I merge it?"))
    check(phase(s) == .needsYou("Should I merge it?"), "no verdict 9 s after the turn: the reply decides")
    s = reduce(fresh(), listing(at: 9, status: .idle, statusAt: 8, job: job("working", tempo: "active"), message: "Merged.\n\n**Needs you** · tag it?"))
    check(phase(s) == .needsYou("tag it?"), "a status line needs no verdict to wait for")
    // A verdict left from the turn before isn't this turn's.
    var old = job("blocked", tempo: "blocked", needs: "approve the deploy")
    old.updatedAt = at(-60)
    s = reduce(fresh(), listing(at: 30, status: .idle, statusAt: 20, job: old, message: "Released it."))
    check(phase(s) == .yourTurn && s.sessions["s1"]?.phaseSource == "reply asks nothing", "an earlier turn's verdict is ignored")
    // A server or watcher left running doesn't keep a finished session in Working.
    s = reduce(fresh(), listing(at: 30, status: .shell, statusAt: 20, job: job("done", work: 1), message: "Server is up at localhost:3000."))
    check(phase(s) == .yourTurn, "done, with a dev server still running: your turn")
    check(s.checks(s.sessions["s1"]!, now: at(31), rules: GroupRules()).first { $0.kind == .idle }?.outcome == .fail, "but never safe to close while it runs")
    // A limit from an earlier turn doesn't outlive a clean turn that began without a prompt hook.
    s = reduce(fresh(), hook(.stopFailed(error: "rate_limit"), at: 5))
    s = reduce(s, listing(at: 600, status: .busy, statusAt: 599))
    s = reduce(s, hook(.stopped(lastMessage: "All done.\n\n**Safe to close** · released"), at: 700))
    s = reduce(s, listing(at: 700.5, status: .idle, statusAt: 700, job: job("done"), message: "All done.\n\n**Safe to close** · released"))
    check(phase(s) == .yourTurn, "a clean turn after a limit: your turn, not limited")
    // Two file watchers are not work (record shape from 15 Nov).
    check(EventParser.parseJob(Data(#"{"state":"done","tempo":"idle","inFlight":{"tasks":2,"kinds":["artifact_watch"],"drainableMonitors":2}}"#.utf8))?.work == 0, "two watchers: no work")
    check(EventParser.parseJob(Data(#"{"state":"working","tempo":"idle","inFlight":{"tasks":1,"kinds":["local_bash"]},"fan":[{"kind":"shell","label":"x"},{"kind":"agent","label":"y","doneAt":5}]}"#.utf8))?.work == 1, "fan: unfinished entries are the work")
    s = reduce(fresh(), listing(at: 9, status: .idle, statusAt: 8, job: job("failed", detail: "can't reach the database"), message: "x"))
    check(phase(s) == .needsYou("Gave up: can't reach the database"), "a failed turn needs you")
    s = reduce(fresh(), listing(at: 9, status: .idle, statusAt: 8, message: "Should I merge it?", background: false))
    check(phase(s) == .needsYou("Should I merge it?") && s.sessions["s1"]?.phaseSource == "reply asks a question", "a terminal session (no job record) is read from its reply")

    // Dialogs: a permission prompt is needs you while it is open, and only then.
    s = reduce(fresh(), hook(.notification(type: "permission_prompt", message: "Claude needs your permission to use Bash"), at: 5))
    check(phase(s) == .needsYou("Claude needs your permission to use Bash"), "permission hook: needs you at once")
    s = reduce(s, listing(at: 6, status: .waiting("permission prompt"), statusAt: 5))
    check(phase(s) == .needsYou("Claude needs your permission to use Bash"), "the listing keeps the hook's words for the same prompt")
    s = reduce(s, listing(at: 8, status: .waiting("permission prompt"), statusAt: 5))
    check(phase(s) == .needsYou("Claude needs your permission to use Bash"), "and keeps them on the next listing")
    s = reduce(s, listing(at: 20, status: .busy, statusAt: 19))
    check(phase(s) == .working, "approved: working again, though no hook said so")
    s = reduce(s, hook(.notification(type: "permission_prompt", message: "Claude needs your permission to use Edit"), at: 30))
    s = reduce(s, listing(at: 40, status: .idle, statusAt: 39, job: job("done"), message: "Stopped as you asked."))
    check(phase(s) == .yourTurn, "denied and the turn ended: no longer needs you")
    s = reduce(fresh(), listing(at: 9, status: .waiting("input needed"), statusAt: 8))
    check(phase(s) == .needsYou("Waiting for your answer"), "a question dialog, in words")
    s = reduce(fresh(), hook(.notification(type: "agent_needs_input", message: "Your agent needs input"), at: 3))
    check(phase(s) == .needsYou("Your agent needs input"), "agent_needs_input: needs you")
    s = reduce(fresh(), hook(.notification(type: "agent_completed", message: "Agent finished"), at: 3))
    check(phase(s) == .working, "agent_completed only reports")

    // MARK: Working

    s = reduce(fresh(), listing(at: 9, status: .shell, statusAt: 8, job: job("done", detail: "deploy started", work: 1), message: "Deploying.\n\n**Not done** · deploy running"))
    check(phase(s) == .working && s.sessions["s1"]?.waitingOn == "1 background task running", "turn over, a shell still running: working, and says so")
    s = reduce(s, listing(at: 60, status: .idle, statusAt: 59, job: job("done"), message: "Deployed.\n\n**Safe to close** · live"))
    check(phase(s) == .yourTurn && s.sessions["s1"]?.waitingOn == nil, "the shell finished: your turn")
    s = reduce(fresh(), listing(at: 9, status: .shell, statusAt: 8, message: "Watching CI.", background: false))
    check(phase(s) == .working && s.sessions["s1"]?.waitingOn == "background shell running", "a terminal session's background shell: working")
    s = reduce(fresh(), listing(at: 9, status: .idle, statusAt: 8, job: job("working", detail: "five background sessions running"), message: "Filed #4-#8."))
    check(phase(s) == .yourTurn, "idle, nothing in flight, job says working: your turn")

    // MARK: hooks and listings in either order

    // A listing that hasn't seen the newest hook doesn't undo it...
    s = reduce(fresh(), listing(at: 0.2, status: .idle, statusAt: -50, message: "old reply"))
    check(phase(s) == .working, "prompt hook stands against a listing taken before Claude Code went busy")
    // ...until one has: its status changed after the hook, or it is a few seconds younger.
    s = reduce(s, listing(at: 1, status: .busy, statusAt: 0.5))
    check(phase(s) == .working, "then busy")
    // Lost Stop hook (Esc, a queued prompt): 16% of turns in the log had none.
    s = reduce(s, listing(at: 30, status: .idle, statusAt: 25, message: "Interrupted.\n\n**Not done** · stopped halfway"))
    check(phase(s) == .yourTurn, "no Stop hook: the listing ends the turn")
    // Stop hook while a subagent still runs: Claude Code stays busy without changing its status.
    // (Soak test, 15 Nov: Your turn showed for 0.2 s and "done" was announced three times.)
    s = reduce(fresh(), listing(at: 1, status: .busy, statusAt: 0.5))
    s = reduce(s, hook(.stopped(lastMessage: "Started the reviewers."), at: 40))
    check(phase(s) == .working && s.sessions["s1"]?.phaseSource == "hook: turn ended, waiting for Claude Code to confirm",
          "Stop while the last listing said busy: still working until Claude Code confirms")
    s = reduce(s, listing(at: 41, status: .busy, statusAt: 0.5))
    check(phase(s) == .working, "a listing right after can't tell yet: still working")
    s = reduce(s, listing(at: 44, status: .busy, statusAt: 0.5))
    check(phase(s) == .working && s.sessions["s1"]?.phaseSource == "Claude Code: turn running", "a few seconds later the listing wins: still working")
    // The ordinary case: the turn ends and Claude Code goes idle with it.
    s = reduce(fresh(), listing(at: 1, status: .busy, statusAt: 0.5))
    s = reduce(s, hook(.stopped(lastMessage: "Fixed it.\n\n**Safe to close** · fixed"), at: 20))
    check(phase(s) == .working, "Stop: working until the listing confirms")
    s = reduce(s, listing(at: 20.3, status: .idle, statusAt: 20.1, message: "Fixed it.\n\n**Safe to close** · fixed"))
    check(phase(s) == .yourTurn, "idle in the listing a moment later: your turn")
    // A Stop that asks something needs no confirmation.
    s = reduce(fresh(), listing(at: 1, status: .busy, statusAt: 0.5))
    s = reduce(s, hook(.stopped(lastMessage: "Done.\n\n**Needs you** · pick a name"), at: 20))
    check(phase(s) == .needsYou("pick a name"), "Stop on Needs you shows at once")
    // A session no listing has seen yet (no status) goes by the hook alone.
    s = reduce(fresh(), hook(.stopped(lastMessage: "ok"), at: 5))
    check(phase(s) == .yourTurn, "Stop with no listing: your turn")

    // The permission hook comes ~6 s after Claude Code's status and says less; it keeps Claude Code's words.
    s = reduce(fresh(), listing(at: 9, status: .waiting("permission prompt"), statusAt: 8.9,
                                job: job("working", tempo: "blocked", needs: "approve Bash: curl -s https://example.com")))
    check(phase(s) == .needsYou("approve Bash: curl -s https://example.com"), "waiting: Claude Code's own words first")
    s = reduce(s, hook(.notification(type: "permission_prompt", message: "Claude needs your permission"), at: 15))
    check(phase(s) == .needsYou("approve Bash: curl -s https://example.com"), "a later permission hook doesn't replace them")
    s = reduce(s, listing(at: 19, status: .waiting("permission prompt"), statusAt: 8.9,
                          job: job("working", tempo: "blocked", needs: "approve Bash: curl -s https://example.com")))
    check(phase(s) == .needsYou("approve Bash: curl -s https://example.com"), "nor does the listing after it")
    // A Stop hook that arrives after the listing that saw it end keeps the listing's facts.
    s = reduce(fresh(), listing(at: 10, status: .idle, statusAt: 9, job: job("blocked", tempo: "blocked", needs: "approve the deploy"), message: "Ready."))
    s = reduce(s, hook(.stopped(lastMessage: "Ready."), at: 9.2))
    check(phase(s) == .needsYou("approve the deploy"), "a late Stop hook doesn't drop Claude Code's verdict")

    // Limits stay limits until the next prompt.
    s = reduce(fresh(), hook(.stopFailed(error: "rate_limit"), at: 5))
    s = reduce(s, listing(at: 10, status: .idle, statusAt: 6, message: "x"))
    check({ if case .limited = phase(s)! { return true }; return false }(), "an idle listing keeps a usage limit")
    s = reduce(s, hook(.promptSubmitted(prompt: "continue", title: nil), at: 20))
    check(phase(s) == .working && s.sessions["s1"]?.stopFailure == nil, "a new prompt clears it")
    s = reduce(fresh(), hook(.stopFailed(error: "server_error"), at: 5))
    s = reduce(s, listing(at: 10, status: .idle, statusAt: 6, message: "x"))
    check(phase(s) == .needsYou("Stopped on an error: server_error"), "an error stop stays needs you through listings")

    // A session that left the listing has ended; it comes back when listed again.
    s = reduce(fresh(), listing("other", at: 10, status: .idle))
    check(phase(s) == .ended && s.sessions["s1"]?.phaseSource == "no longer in claude agents --json", "unlisted: ended, and why")
    s = reduce(s, listing(at: 20, status: .busy, statusAt: 19))
    check(phase(s) == .working, "listed again (resumed): working")
}
