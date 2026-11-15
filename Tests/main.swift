import Foundation

// Runs with ./build.sh test. Fixtures are real hook lines recorded from test sessions.

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok { failures += 1; print("FAIL line \(line): \(what)") }
}

let home = URL(fileURLWithPath: "/Users/me")  // the home the fixtures were recorded under
let accounts = [
    Account(id: "work", name: "work", configDir: home.appendingPathComponent(".claude")),
    Account(id: "work2", name: "work2", configDir: home.appendingPathComponent(".claude-work2")),
    Account(id: "private", name: "private", configDir: home.appendingPathComponent(".claude-personal")),
]
let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
let w1 = "d2f54676-0adf-42a3-afe0-57587d528fdd", w2 = "ab71f936-0878-48e7-b8dc-4ac066b0d0d4", p = "ffd2e4f9-fa28-4b7e-8268-69d9b7be2a05"

let folded = EventLog.fold(url: fixtures.appendingPathComponent("test-sessions.jsonl"), accounts: accounts)
check(folded.sessions[w1]?.phase == .yourTurn, "w1 stopped with 'ok' says done")
check(folded.sessions[p]?.phase == .yourTurn, "private stopped with 'ok' says done")
check(folded.sessions[w2]?.phase == .limited(Date(timeIntervalSince1970: 1794599400)), "work2 rate_limit is limited until the 5h reset")
check(folded.sessions[w1]?.title == "mxtest-w1", "title from session_title")
check(folded.account("work2")?.fiveHour?.usedPercent == 100, "work2 usage sample folded")
check(folded.sessions[w1]?.accountId == "work" && folded.sessions[p]?.accountId == "private", "accounts from configDir")

let t0 = Date(timeIntervalSince1970: 1_800_000_000)
func hook(_ kind: Hook.Kind, _ sid: String = "s1", dir: String = home.appendingPathComponent(".claude").path, at: Double = 0) -> Event {
    .hook(Hook(at: t0.addingTimeInterval(at), configDir: dir, sessionId: sid, cwd: "/tmp/x", transcriptPath: nil, kind: kind))
}
var s = AppState(accounts: accounts)
s = reduce(s, hook(.sessionStart(source: "startup")))
check(s.sessions["s1"]?.phase == .yourTurn, "fresh session is idle (says done until checked)")
s = reduce(s, hook(.promptSubmitted(prompt: "fix the login bug please", title: nil), at: 1))
check(s.sessions["s1"]?.phase == .working, "prompt -> working")
check(s.sessions["s1"]?.title == "fix the login bug please", "title falls back to the prompt")
s = reduce(s, hook(.promptSubmitted(prompt: "and the logout", title: "Login fixes"), at: 1.5))
check(s.sessions["s1"]?.title == "Login fixes", "session_title wins over the prompt")
let cfgOff = Config.parse("auto-titles = off\n"), cfgOn = Config.parse("")
check(!cfgOff.autoTitles && cfgOn.autoTitles, "auto-titles is on unless turned off")
s = reduce(s, hook(.notification(type: "permission_prompt", message: "Claude needs your permission to use Bash"), at: 2))
check(s.sessions["s1"]?.phase == .needsYou("Claude needs your permission to use Bash"), "permission prompt -> needs you")
s = reduce(s, hook(.stopped(lastMessage: "Done.\n\nShould I also update the docs?"), at: 3))
check(s.sessions["s1"]?.phase == .needsYou("Should I also update the docs?"), "stop on a question -> needs you")
s = reduce(s, hook(.notification(type: "idle_prompt", message: "Claude is waiting for your input"), at: 4))
check(s.sessions["s1"]?.phase == .needsYou("Should I also update the docs?"), "idle_prompt does not change the phase")
s = reduce(s, hook(.promptSubmitted(prompt: "no", title: nil), at: 5))
s = reduce(s, hook(.stopped(lastMessage: "Fixed and pushed. PR #12 is merged."), at: 6))
check(s.sessions["s1"]?.phase == .yourTurn, "stop without question -> says done")

let rules = GroupRules(idleAfter: 86400)
let pass = DoneCheck(at: t0.addingTimeInterval(8), repo: true, dirtyFiles: 0, unpushed: 0, pr: .merged(12), branch: "fix")
/// Everything a stopped session needs to be safe at `at`: a fresh idle listing with no
/// background tasks, a repo check after the last activity, and a "finished" model read.
func evidence(_ st: AppState, _ id: String, at: Double, status: AgentsSnapshot.Status = .idle, tasks: [BackgroundTask]? = [], check: DoneCheck? = nil, verdict: Judgment.Verdict? = .finished) -> AppState {
    var st = st
    let sess = st.sessions[id]!
    let snapAt = t0.addingTimeInterval(at - 10)
    st = reduce(st, .agents(AgentsSnapshot(at: snapAt, accountId: sess.accountId, entries: [
        .init(sessionId: id, name: sess.name, cwd: sess.cwd, startedAt: t0, reach: .background(shortId: String(id.prefix(8))), status: status,
              lastMessage: nil, runningTasks: tasks),
    ])))
    var c = check ?? pass
    c.at = t0.addingTimeInterval(at - 5)
    st = reduce(st, .doneCheck(id, c))
    if let verdict, let m = st.sessions[id]?.lastMessage {
        st = reduce(st, .judged(hash: Reply.hash(m), Judgment(verdict: verdict, at: snapAt, account: "work", costUSD: 0.0001)))
    }
    return st
}
func verdictOf(_ st: AppState, _ id: String, at: Double, _ r: GroupRules = rules) -> [Check] { st.checks(st.sessions[id]!, now: t0.addingTimeInterval(at), rules: r) }
func outcome(_ checks: [Check], _ k: Check.Kind) -> Check.Outcome? { checks.first { $0.kind == k }?.outcome }
func groupOf(_ st: AppState, _ id: String, at: Double, _ r: GroupRules = rules) -> PhaseGroup? { st.group(st.sessions[id]!, now: t0.addingTimeInterval(at), rules: r) }

let later = 6.0 + 7200 + 60
do {
    let asked = reduce(s, hook(.stopped(lastMessage: "Should I also update the docs?"), at: 7))
    check(groupOf(asked, "s1", at: 7 + 2 * 86400) == .needsYou, "a question two days old still needs you")
    check(groupOf(asked, "s1", at: 7 + 3 * 86400 + 60) == .idle, "a question nobody answered for 3 days is idle")
    check(groupOf(asked, "s1", at: 7 + 4 * 86400, GroupRules(idleAfter: 5 * 86400)) == .needsYou, "a longer idle-after keeps it longer")
}
var safe = evidence(s, "s1", at: later)
check(groupOf(safe, "s1", at: later) == .safeToClose, "every check passing -> safe to close")
check(verdictOf(safe, "s1", at: later).allSatisfy { !$0.source.isEmpty && !$0.detail.isEmpty }, "every check names what it found and where")
check(Set(verdictOf(safe, "s1", at: later).map(\.kind)) == Set(Check.Kind.allCases).subtracting([.marked, .plugin, .wrap]), "the checklist has every check")
check(groupOf(evidence(s, "s1", at: 6 + 180), "s1", at: 6 + 180) == .safeToClose, "no waiting: 3 minutes after a finished reply is already safe")

// Unknown is never safe.
let notRepo = evidence(s, "s1", at: later, check: DoneCheck(at: t0, repo: false, dirtyFiles: nil, unpushed: nil, pr: .unknown("not checked"), branch: nil))
check(outcome(verdictOf(notRepo, "s1", at: later), .worktree) == .unknown && groupOf(notRepo, "s1", at: later) == .yourTurn, "not a git repo is unknown, never safe")
let ghDown = evidence(s, "s1", at: later, check: DoneCheck(at: t0, repo: true, dirtyFiles: 0, unpushed: 0, pr: .unknown("gh failed: HTTP 401"), branch: "fix"))
check(outcome(verdictOf(ghDown, "s1", at: later), .pr) == .unknown && groupOf(ghDown, "s1", at: later) == .yourTurn, "gh failing is unknown, never safe")
let gitStatusFailed = evidence(s, "s1", at: later, check: DoneCheck(at: t0, repo: true, dirtyFiles: nil, unpushed: 0, pr: .merged(1), branch: "fix"))
check(outcome(verdictOf(gitStatusFailed, "s1", at: later), .worktree) == .unknown && groupOf(gitStatusFailed, "s1", at: later) == .yourTurn, "git status failing is unknown")
let noTranscript = evidence(s, "s1", at: later, tasks: nil)
check(outcome(verdictOf(noTranscript, "s1", at: later), .idle) == .unknown && groupOf(noTranscript, "s1", at: later) == .yourTurn, "no transcript to read is unknown")
var noReply = safe
noReply.sessions["s1"]!.lastMessage = nil
check(outcome(verdictOf(noReply, "s1", at: later), .reply) == .unknown && groupOf(noReply, "s1", at: later) == .yourTurn, "no reply found is unknown")
check(outcome(verdictOf(safe, "s1", at: later + 600), .listed) == .unknown && groupOf(safe, "s1", at: later + 600) == .yourTurn, "a listing older than 5 minutes is unknown")
var unlisted = safe
unlisted.listedAt["work"] = t0.addingTimeInterval(later - 1)
check(outcome(verdictOf(unlisted, "s1", at: later), .listed) == .unknown && groupOf(unlisted, "s1", at: later) == .yourTurn, "missing from the latest listing is unknown")
var noHooks = safe
noHooks.sessions["s1"]!.hookSeenAt = nil
check(outcome(verdictOf(noHooks, "s1", at: later), .hooks) == .unknown && groupOf(noHooks, "s1", at: later) == .yourTurn, "a session the hooks never reported is unknown")
let unchecked = reduce(safe, .hook(Hook(at: t0.addingTimeInterval(later - 1), configDir: home.appendingPathComponent(".claude").path, sessionId: "s1", cwd: "/tmp/x", transcriptPath: nil, kind: .notification(type: "idle_prompt", message: ""))))
check(outcome(verdictOf(unchecked, "s1", at: later), .worktree) == .unknown, "a repo check older than the last activity is unknown")

// Fails.
check(outcome(verdictOf(evidence(s, "s1", at: later, check: DoneCheck(at: t0, repo: true, dirtyFiles: 3, unpushed: 0, pr: .none("on main, no PR"), branch: "main")), "s1", at: later), .worktree) == .fail, "dirty worktree fails")
check(outcome(verdictOf(evidence(s, "s1", at: later, check: DoneCheck(at: t0, repo: true, dirtyFiles: 0, unpushed: 1, pr: .none("no GitHub remote"), branch: "x")), "s1", at: later), .pushed) == .fail, "unpushed commits fail")
check(outcome(verdictOf(evidence(s, "s1", at: later, check: DoneCheck(at: t0, repo: true, dirtyFiles: 0, unpushed: 0, pr: .closed(4), branch: "x")), "s1", at: later), .pr) == .fail, "a PR closed without merging fails")
check(outcome(verdictOf(evidence(s, "s1", at: later, check: DoneCheck(at: t0, repo: true, dirtyFiles: 0, unpushed: 0, pr: .open(4), branch: "x")), "s1", at: later), .pr) == .fail, "an open PR fails")

// Busy: the listing says busy, or a background task or subagent is still running.
let busy = evidence(s, "s1", at: later, status: .busy)
check(busy.sessions["s1"]?.phase == .working && groupOf(busy, "s1", at: later) == .working, "listed busy -> working")
check(outcome(verdictOf(busy, "s1", at: later), .idle) == .fail, "busy fails the idle check")
let bgTask = evidence(s, "s1", at: later, tasks: [BackgroundTask(id: "a1", kind: .agent, label: "Review", startedAt: t0),
                                                  BackgroundTask(id: "a2", kind: .agent, startedAt: t0), BackgroundTask(id: "b1", kind: .shell, startedAt: t0)])
check(outcome(verdictOf(bgTask, "s1", at: later), .idle) == .fail && groupOf(bgTask, "s1", at: later) == .yourTurn, "a running background task keeps it out of safe")
check(verdictOf(bgTask, "s1", at: later).first { $0.kind == .idle }?.detail == "2 subagents and 1 background shell running", "the idle check names what runs")
check(bgTask.sessions["s1"]?.runningTasks?.summary == "2 agents · 1 shell" && [BackgroundTask]().summary.isEmpty, "summary counts agents and shells")

// Background tasks from transcript lines (shapes copied from a real transcript, 13 Nov).
var ledger = TaskLedger()
for line in [
    #"{"type":"user","timestamp":"2026-11-13T14:30:00.000Z","toolUseResult":{"stdout":"","backgroundTaskId":"bbhrcph3h"}}"#,
    #"{"type":"user","timestamp":"2026-11-13T14:31:00.000Z","toolUseResult":{"isAsync":true,"status":"async_launched","agentId":"a8a3e6eb0e6f425c3"}}"#,
    #"{"type":"user","timestamp":"2026-11-13T14:32:00.000Z","toolUseResult":{"isAsync":true,"status":"async_launched","agentId":"add5cc1ffefedfd53"}}"#,
    #"{"type":"user","timestamp":"2026-11-13T09:00:00.000Z","toolUseResult":{"backgroundTaskId":"old-process"}}"#,
    #"{"type":"user","message":{"content":"grep backgroundTaskId in a tool output is not a task"}}"#,
    #"{"type":"queue-operation","operation":"enqueue","content":"<task-notification>\n<task-id>bbhrcph3h</task-id>\n<tool-use-id>toolu_1</tool-use-id>\n<status>completed</status>\n</task-notification>"}"#,
    #"{"type":"user","message":{"content":"<task-notification>\n<task-id>a8a3e6eb0e6f425c3</task-id>\n<status>running</status>\n</task-notification>"}}"#,
] { ledger.read(Data(line.utf8)) }
let processStart = ISO8601DateFormatter().date(from: "2026-11-13T14:00:00Z")!
check(ledger.running(since: processStart).count == 2, "two async subagents still running; the finished shell and the pre-restart task are not")
ledger.read(Data(#"{"type":"user","message":{"content":"<task-notification><task-id>a8a3e6eb0e6f425c3</task-id><status>completed</status></task-notification> <task-notification><task-id>add5cc1ffefedfd53</task-id><status>killed</status></task-notification>"}}"#.utf8))
check(ledger.running(since: processStart).count == 0, "completed and killed notifications end their tasks")
ledger.read(Data(#"{"type":"user","timestamp":"2026-11-13T15:00:00.000Z","toolUseResult":{"backgroundTaskId":"bs1tbv9ag"}}"#.utf8))
check(ledger.running(since: processStart).count == 1, "a new background shell runs")
ledger.read(Data(#"{"type":"user","toolUseResult":{"message":"Successfully stopped task: bs1tbv9ag (npx expo start)","task_id":"bs1tbv9ag","task_type":"local_bash"}}"#.utf8))
check(ledger.running(since: processStart).count == 0, "TaskStop ends a task")
var kinds = TaskLedger()
for line in [
    #"{"type":"user","timestamp":"2026-11-15T10:00:00.000Z","toolUseResult":{"isAsync":true,"status":"async_launched","agentId":"a14a","description":"Sleep 400 seconds, reply done 1","resolvedModel":"claude-haiku-5-5"}}"#,
    #"{"type":"user","timestamp":"2026-11-15T10:01:00.000Z","toolUseResult":{"isAsync":true,"status":"async_launched","agentId":"a15b","description":"Review the diff"}}"#,
    #"{"type":"user","timestamp":"2026-11-15T10:02:00.000Z","toolUseResult":{"stdout":"","backgroundTaskId":"b5zcokrb2"}}"#,
    #"{"type":"user","message":{"content":"<task-notification>\n<task-id>a15b</task-id>\n<status>completed</status>\n</task-notification>"}}"#,
] { kinds.read(Data(line.utf8)) }
let kindsRun = kinds.running(since: processStart)
check(kindsRun.map(\.kind) == [.agent, .shell] && kindsRun.map(\.label) == ["Sleep 400 seconds, reply done 1", nil] && kindsRun.map(\.id) == ["a14a", "b5zcokrb2"],
      "running tasks keep their kind and the agent's description, oldest first")
check(kindsRun.summary == "1 agent · 1 shell", "one agent and one shell")
check((try? JSONDecoder().decode(TaskLedger.self, from: Data(#"{"started":{"a1":721000000},"finished":[]}"#.utf8))) == nil,
      "a scan saved before tasks had kinds fails to decode, so task-scans.json resets and rescans")
check(safe.judgeCandidates(now: t0.addingTimeInterval(later), rules: GroupRules(idleAfter: 86400, judge: false)).isEmpty, "judge = off asks the model nothing")

// The model read: candidates only; anything but finished is not safe; off means never safe.
for v in [Judgment.Verdict.pending, .unsure] {
    check(groupOf(evidence(s, "s1", at: later, verdict: v), "s1", at: later) == .yourTurn, "model says \(v.rawValue) -> not safe")
}
let unread = evidence(s, "s1", at: later, verdict: nil)
check(outcome(verdictOf(unread, "s1", at: later), .judge) == .unknown && Check.candidate(verdictOf(unread, "s1", at: later)), "an unread candidate waits for the model")
check(groupOf(safe, "s1", at: later, GroupRules(idleAfter: 86400, judge: false)) == .yourTurn, "judge = off -> never safe")
let notRepoUnread = evidence(s, "s1", at: later, check: notRepo.sessions["s1"]!.doneCheck, verdict: nil)
check(!Check.candidate(verdictOf(notRepoUnread, "s1", at: later)) && notRepoUnread.judgeCandidates(now: t0.addingTimeInterval(later), rules: rules).isEmpty, "a session failing other checks is not a candidate")
check(unread.judgeCandidates(now: t0.addingTimeInterval(later), rules: rules).map(\.0.id) == ["s1"], "an unread session passing everything else is a candidate")
check(Judgment.parse("Finished.") == .finished && Judgment.parse("finished, nothing left") == .unsure && Judgment.parse("PENDING") == .pending, "model output must be exactly one word")
check(Reply.hash("a") == Reply.hash("a") && Reply.hash("a") != Reply.hash("b") && Reply.hash("a").count == 16, "message hash is stable")

// "Not safe" holds until new activity.
let marked = reduce(safe, .markedNotSafe("s1", at: t0.addingTimeInterval(later)))
check(outcome(verdictOf(marked, "s1", at: later + 1), .marked) == .fail && groupOf(marked, "s1", at: later + 1) == .yourTurn, "marked not safe leaves safe to close")
var active = reduce(marked, hook(.promptSubmitted(prompt: "more", title: nil), at: later + 2))
active = reduce(active, hook(.stopped(lastMessage: "Fixed and pushed. PR #12 is merged."), at: later + 3))
check(outcome(verdictOf(active, "s1", at: later + 7300), .marked) == nil, "new activity clears the mark")

// Closing: a record moves it to Recently closed; reopening clears it.
let closedRec = ClosedSession(at: t0.addingTimeInterval(later), session: { var c = safe.sessions["s1"]!; c.phase = .ended; return c }(), checks: verdictOf(safe, "s1", at: later))
var closed = reduce(safe, .closed(closedRec))
check(groupOf(closed, "s1", at: later + 60) == .recentlyClosed, "a closed session shows in recently closed")
check(closed.grouped(now: t0.addingTimeInterval(later + 8 * 86400), rules: rules).isEmpty, "recently closed lasts 7 days")
var fresh = AppState(accounts: accounts)
fresh = reduce(fresh, hook(.stopped(lastMessage: "done."), "s1", at: 1))
check(fresh.sessions["s1"]?.reach == .elsewhere(pid: nil), "hooks alone do not know a session is a background one")
fresh = reduce(fresh, .closed(closedRec))
check(fresh.sessions["s1"]?.reach == .background(shortId: "s1"), "the close record restores the background reach, so Reopen can attach after a restart")
check(fresh.grouped(now: t0.addingTimeInterval(later + 60), rules: rules).first?.0 == .recentlyClosed, "recently closed survives a restart from the record alone")
fresh = reduce(fresh, .reopened("s1", at: t0.addingTimeInterval(later + 90)))
check(fresh.sessions["s1"]?.reach == .background(shortId: "s1") && fresh.closed["s1"] == nil, "reopen restores the session from its record")
closed = reduce(closed, .reopened("s1", at: t0.addingTimeInterval(later + 90)))
check(groupOf(closed, "s1", at: later + 100) == nil, "reopened: out of recently closed until listed again")

// Maxwell's own records round-trip through the event log.
let logURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mx-test-\(getpid()).jsonl")
MaxwellRecord.append(MaxwellRecord.judged(hash: "abc", session: "s1", verdict: "finished", account: "work", costUSD: 0.0002, ms: 900, raw: "finished"), at: t0, to: logURL)
MaxwellRecord.append(MaxwellRecord.judged(hash: "def", session: "s1", verdict: "error", account: "work", costUSD: nil, ms: 10, raw: "boom"), at: t0, to: logURL)
MaxwellRecord.append(MaxwellRecord.closed(safe.sessions["s1"]!, checks: verdictOf(safe, "s1", at: later)), at: t0, to: logURL)
MaxwellRecord.append(MaxwellRecord.notSafe(safe.sessions["s1"]!, checks: []), at: t0, to: logURL)
let replayed = EventLog.fold(url: logURL, accounts: accounts)
try? FileManager.default.removeItem(at: logURL)
check(replayed.judgments["abc"]?.verdict == .finished && replayed.judgments["abc"]?.costUSD == 0.0002, "judgments cache through the log")
check(replayed.judgments["def"] == nil, "a failed model call is logged, not cached")
check(replayed.closed["s1"]?.checks.count == verdictOf(safe, "s1", at: later).count && replayed.closed["s1"]?.session.title == safe.sessions["s1"]!.title, "close records keep the evidence")

s = reduce(s, .started("fresh", "work", name: "mxtest-new", cwd: "/tmp/x", shortId: "fresh", at: t0))
let unused = evidence(s, "fresh", at: 3 * 86400 - 1)
check(outcome(verdictOf(unused, "fresh", at: 3 * 86400 - 1), .reply) == .fail && groupOf(unused, "fresh", at: 3 * 86400 - 1) != .safeToClose, "a session that never had a prompt is not safe to close")
s = reduce(s, hook(.sessionEnd(reason: "x"), "fresh", at: 1))

let snapAt = t0.addingTimeInterval(10)
s = reduce(s, .agents(AgentsSnapshot(at: snapAt, accountId: "work", entries: [
    .init(sessionId: "s2", name: "other", cwd: "/tmp/y", startedAt: snapAt, reach: .background(shortId: "s2"), status: .waiting("dialog open")),
])))
check(s.sessions["s1"]?.phase == .ended, "session missing from the account's listing has ended")
check(s.sessions["s2"]?.phase == .needsYou("dialog open"), "listed waiting session -> needs you")
check(s.sessions["s2"]?.reach == .background(shortId: "s2"), "reach from listing")
s = reduce(s, hook(.stopped(lastMessage: "x"), "s1", at: 11))
check(s.sessions["s1"]?.phase == .ended, "ended sessions ignore late hooks")
s = reduce(s, hook(.sessionEnd(reason: "other"), "s2", at: 12))
check(s.sessions["s2"]?.phase == .ended, "session end -> ended")
s = reduce(s, hook(.promptSubmitted(prompt: "x", title: nil), "s3", dir: "/nowhere", at: 13))
check(s.sessions["s3"] == nil, "unknown config dir ignored")
s = reduce(s, .hook(Hook(at: t0, configDir: home.appendingPathComponent(".claude").path, sessionId: "s4",
                         cwd: home.appendingPathComponent(".claude/tab-titles").path, transcriptPath: nil, kind: .sessionStart(source: "startup"))))
check(s.sessions["s4"] == nil, "helper sessions inside a config dir are ignored")
check(s.grouped(now: t0, rules: rules).isEmpty, "ended sessions are not listed")

var idle = AppState(accounts: accounts)
for (sid, ago) in [("fresh-done", 3600.0), ("old-done", 3 * 86400.0)] {
    idle = reduce(idle, hook(.promptSubmitted(prompt: "x", title: nil), sid, at: -ago))
    idle = reduce(idle, hook(.stopped(lastMessage: "Done."), sid, at: -ago + 1))
}
idle = reduce(idle, hook(.promptSubmitted(prompt: "x", title: nil), "old-working", at: -3 * 86400))
let g = idle.grouped(now: t0, rules: rules)
check(g.map(\.0) == [.yourTurn, .working, .idle], "idle folds to the bottom; unchecked sessions are never safe")
check(g.first { $0.0 == .idle }?.1.map(\.id) == ["old-done"], "says done quiet for more than the threshold is idle")
check(g.first { $0.0 == .working }?.1.map(\.id) == ["old-working"], "only says done folds; a quiet working session stays working")
check(idle.grouped(now: t0, rules: GroupRules(idleAfter: 7 * 86400)).contains { $0.0 == .idle } == false, "the threshold comes from config")
check(Config.parse("idle-after = 2d").idleAfter == 2 * 86400 && Config.parse("idle-after = 36").idleAfter == 36 * 3600, "idle-after parses 2d and plain hours")

check(Reply.classify("All green.\n\nWant me to open a PR?") == .question("Want me to open a PR?"), "question detection")
check(Reply.classify("## What changed?\n\nEverything is merged.") == .statement, "a heading that ends in ? is not a question")
check(Reply.classify("Fixed. Want me to also run it on staging? It takes 2 minutes.") == .question("Want me to also run it on staging?"), "a question mid-line counts")
check(Reply.classify("Merged and live.\n\nNext step is the backfill, I can start it when you say go.") != .statement, "an offer of next steps is not a statement")
check(Reply.classify("You've hit your 5-hour limit · resets 8:50pm (Europe/Berlin)") == .limitHit, "Claude Code's limit line is a limit, not a report")
check(Reply.phase(after: "You've hit your 5-hour limit · resets 8:50pm (Europe/Berlin)") == .limited(nil), "a limit reply -> limited")
// Real last replies from sessions the old check called safe (13 Nov audit).
for handBack in [
    "Still waiting on your pick of concept A, B or C (I recommend B, falling back to A). No code until then.\n\nLinear: I edited the ACM-9 comment.",
    "There's no LinkedIn text for those four. If you paste me your own descriptions for those four, I'll put them in as they are.",
    "**Next:** connect the shop account in the provider's dashboard and tell me when it's done.",
    "Für TikTok ist die gleiche Datei direkt nutzbar. Gib Bescheid, wenn es online ist, dann mach ich den TikTok-Draft.",
] { check(Reply.classify(handBack) != .statement, "hand-back is not a finished report: \(handBack.prefix(40))") }
check(Config.parse("project = Orbit ~/projects/orbit*").projects == [ProjectRule(name: "Orbit", glob: "~/projects/orbit*")], "project rules parse")
check(Config.parse("safe-after = 90m\nidle-after = 2d").idleAfter == 2 * 86400, "an old safe-after line is ignored")
check(Config().skipPermissions && Config.parse(Config.starter).skipPermissions && !Config.parse("skip-permissions = off").skipPermissions, "skip-permissions defaults on, off turns it off")
check({ let c = Config.parse("notify-sound = Glass\nnotify-done = true\nnotify-done-sound = none"); return c.notifySound == "Glass" && c.notifyDone && c.notifyDoneSound == "none" }()
      && Config.parse("notify-sound = Nope").notifySound == "Funk" && !Config.parse(Config.starter).notifyDone, "notification sounds parse; unknown sounds and the starter keep the defaults")
check(Config().theme(systemDark: true) == "graphite" && Config().theme(systemDark: false) == "paper", "the pair follows the system")
check(Config.parse("appearance = light").theme(systemDark: true) == "paper" && Config.parse("theme-dark = silver\nappearance = dark").theme(systemDark: false) == "silver", "appearance pins a side")
check(Config.parse("theme = silver\nappearance = light").theme(systemDark: false) == "silver", "theme = stays a fixed override")
check(Config.parse("background-blur = 30").backgroundBlur == 30 && Config.parse("background-blur = 99").backgroundBlur == nil, "background-blur parses within 0…64")
check(Config.setting("theme", to: "", in: "theme = silver\nfont-size = 13\n") == "font-size = 13\n", "an empty value removes the key")
check(Config.parse("project-pin = Acme\nproject-pin = Orbit\nrail = shown\nrail-delay = 0.5").pinned == ["Acme", "Orbit"]
      && Config.parse("rail = shown").rail == "shown" && Config.parse("rail-delay = 0.5").railDelay == 0.5, "rail keys parse")
do {
    let text = "theme = paper\nproject-pin = A\nfont-size = 13\nproject-pin = B\n"
    let out = Config.setting("project-pin", to: "B\nC\n", in: text)
    check(out == "theme = paper\nproject-pin = B\nproject-pin = C\nfont-size = 13\n", "list setting replaces every line in place")
    check(Config.setting("theme", to: "graphite", in: text).hasPrefix("theme = graphite\n"), "single setting unchanged")
}
do {
    let text = "theme = paper\nproject-logo = Acme ~/t/icon.png\n"
    let chosen = Config.setting("project-logo", to: "Meta agent tool ~/m/logo.svg\nAcme ~/t/icon.png\n", in: text)
    check(Config.parse(chosen).logos == ["Acme": Paths.normalize("~/t/icon.png"), "Meta agent tool": Paths.normalize("~/m/logo.svg")], "Choose… writes a project-logo line; names may have spaces")
    check(Config.parse(Config.setting("project-logo", to: "\n", in: chosen)).logos.isEmpty, "Reset of the last override removes every project-logo line")
}
let projects = Projects(rules: [ProjectRule(name: "Orbit", glob: home.path + "/projects/orbit*")])
check(projects.name(for: home.appendingPathComponent("projects/orbit-mcp/src").path) == "Orbit", "a project rule matches a folder above the cwd")
check(Projects.pretty("/x/acme-workspace/dai") == "Acme" && Projects.pretty("/x/orbit-v2") == "Orbit", "workspace parents and -v2 suffixes fold")

// Moving a session to another project: a Maxwell line in the log, so it survives a restart.
do {
    let acmeRepo = home.appendingPathComponent("projects/acme-workspace/acme").path
    let rules = Projects(rules: [ProjectRule(name: "Acme", glob: acmeRepo + "*"), ProjectRule(name: "Meta agent tool", glob: "/tmp/meta*")])
    var st = AppState(accounts: accounts)
    st = reduce(st, .hook(Hook(at: t0, configDir: home.appendingPathComponent(".claude").path, sessionId: "m1", cwd: "/tmp/meta-agent-tool",
                               transcriptPath: nil, kind: .promptSubmitted(prompt: "fix ACM-56", title: nil))))
    let m1 = { st.sessions["m1"]! }
    check(st.project(m1(), in: rules) == "Meta agent tool", "a session starts under its folder's project")
    st = reduce(st, .projectSuggested("m1", "Acme"))
    check(st.suggestion(m1(), in: rules) == "Acme", "a transcript pointing at Acme suggests it")
    st = reduce(st, .movedToProject("m1", "Acme"))
    check(st.project(m1(), in: rules) == "Acme" && st.suggestion(m1(), in: rules) == nil, "moved: shows under Acme, no chip")
    st = reduce(st, .movedToProject("m1", nil))
    check(st.project(m1(), in: rules) == "Meta agent tool", "move back returns it to its folder's project")
    st = reduce(st, .suggestionDismissed("m1", project: "Acme"))
    check(st.suggestion(m1(), in: rules) == nil, "a dismissed suggestion stays hidden")
    st = reduce(st, .projectSuggested("m1", "Orbit"))
    check(st.suggestion(m1(), in: rules) == "Orbit", "dismissing Acme does not hide another project")

    let log = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mx-move-\(getpid()).jsonl")
    // The move can be logged before the session's first hook; the fold must not drop it.
    MaxwellRecord.append(MaxwellRecord.moved("m2", to: "Acme"), at: t0, to: log)
    MaxwellRecord.append(MaxwellRecord.moved("m3", to: "Acme"), at: t0, to: log)
    MaxwellRecord.append(MaxwellRecord.moved("m3", to: nil), at: t0.addingTimeInterval(1), to: log)
    MaxwellRecord.append(MaxwellRecord.dismissed("m3", suggestion: "Acme"), at: t0.addingTimeInterval(2), to: log)
    let restarted = EventLog.fold(url: log, accounts: accounts)
    try? FileManager.default.removeItem(at: log)
    check(restarted.moved == ["m2": "Acme"], "after a restart the move holds and the undone one is gone")
    check(restarted.dismissed["m3"] == ["Acme"], "after a restart a dismissal holds")
}
// Titles: weak ones get a model's, yours always wins, a /rename in Claude beats the model's.
do {
    let dir = home.appendingPathComponent(".claude").path
    func prompt(_ p: String, title: String?, at dt: Double) -> Event {
        .hook(Hook(at: t0.addingTimeInterval(dt), configDir: dir, sessionId: "n1", cwd: "/tmp/x", transcriptPath: nil,
                   kind: .promptSubmitted(prompt: p, title: title)))
    }
    var st = reduce(AppState(accounts: accounts), prompt("hi, do I need to do anything for the stripe webhook", title: "hi, do I need to do", at: 0))
    let n1 = { st.sessions["n1"]! }
    check(n1().weakTitle, "a title that is the prompt's first words is weak")
    st = reduce(st, .titled("n1", SessionTitle(text: "Stripe Webhook Setup", byYou: false, replaced: "hi, do I need to do")))
    check(n1().title == "Stripe Webhook Setup" && !n1().weakTitle, "the model's title shows")
    st = reduce(st, prompt("next", title: "Webhooks", at: 1))
    check(n1().title == "Webhooks", "a /rename in Claude beats the model's title")
    st = reduce(st, .titled("n1", SessionTitle(text: "Billing", byYou: true, replaced: nil)))
    st = reduce(st, .titled("n1", SessionTitle(text: "Model Again", byYou: false, replaced: "Webhooks")))
    check(n1().title == "Billing", "yours is never replaced by a model's")
    st = reduce(st, .titled("n1", SessionTitle(text: "", byYou: true, replaced: nil)))
    check(n1().title == "Webhooks", "clearing yours goes back to the automatic title")
    Titles.auto = false
    st = reduce(st, .titled("n1", SessionTitle(text: "Haiku Title", byYou: false, replaced: "Webhooks")))
    check(n1().title == "Webhooks", "auto-titles off: Claude Code's title (/rename) shows, never the model's")
    st = reduce(st, .titled("n1", SessionTitle(text: "Mine", byYou: true, replaced: nil)))
    check(n1().title == "Mine", "auto-titles off: Rename… in Maxwell still shows")
    var bare = reduce(AppState(accounts: accounts), prompt("fix the login bug please", title: nil, at: 0))
    bare.sessions["n1"]!.name = "joschua-login"
    check(bare.sessions["n1"]!.title == "joschua-login", "auto-titles off: the session's name, not the prompt's words")
    Titles.auto = true
    st = reduce(AppState(accounts: accounts), prompt("fix ACM-56 in the billing page", title: "Billing Page ACM-56", at: 0))
    check(!st.sessions["n1"]!.weakTitle, "Claude's own title is kept")
    check(Titles.isSlug("mx-slack") && !Titles.isSlug("Find File Tree Panel"), "a lowercase slug is a generated name")
    check(Titles.isGeneric("Continue Previous Task") && !Titles.isGeneric("Resume Maxwell Work"), "only generic words is weak")
    check(Titles.clean("\"Stripe Webhook Setup.\"\nextra") == "Stripe Webhook Setup" && Titles.clean("Title: Foo Bar") == "Foo Bar", "model answers are cleaned")

    let log = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mx-title-\(getpid()).jsonl")
    MaxwellRecord.append(MaxwellRecord.titled("n2", "Renamed", byYou: true), at: t0, to: log)
    let restarted = EventLog.fold(url: log, accounts: accounts)
    try? FileManager.default.removeItem(at: log)
    check(restarted.named["n2"]?.text == "Renamed", "a rename logged before the session's first event holds after a restart")
}
do {
    var v = ProjectVotes()
    let edit = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/r/acme/apps/web/x.ts"}},{"type":"tool_use","name":"Bash","input":{"command":"cd ~/projects/orbit && git -C /r/acme status"}}]}}"#
    for _ in 0..<3 { v.read(Substring(edit)) }
    v.read(#"{"type":"user","message":{"content":"look at ACM-56 and UTF-8"}}"#)
    check(v.paths["/r/acme/apps/web/x.ts"] == 3 && v.paths["/r/acme"] == 3 && v.paths[Paths.normalize("~/projects/orbit")] == 3, "edits and cd/git -C folders are counted")
    check(v.linear == ["ACM": 1, "UTF": 1], "Linear-style ids are counted by key")
    v.read(#"{"type":"attachment","attachment":{"type":"instructions","content":"branch me/acm-56, ticket ACM-56"}}"#)
    v.read(#"{"type":"user","isMeta":true,"message":{"content":"ACM-57"}}"#)
    check(v.linear["ACM"] == 1, "ids in CLAUDE.md attachments and meta lines do not count")
    let name = { (p: String) -> String? in p.hasPrefix("/r/acme") ? "Acme" : p.contains("orbit") ? "Orbit" : nil }
    check(v.suggestion(current: "Meta agent tool", project: name, keys: ["ACM": "Acme"]) == "Acme", "most votes for Acme suggest it")
    check(v.suggestion(current: "Acme", project: name, keys: ["ACM": "Acme"]) == nil, "no suggestion for the project it is already in")
    var split = ProjectVotes(paths: ["/r/acme/a": 2, "/x/orbit/b": 2])
    check(split.suggestion(current: "Meta agent tool", project: name, keys: [:]) == nil, "a tie is not most")
    split.paths["/r/acme/a"] = 1
    check(split.suggestion(current: "Meta agent tool", project: name, keys: [:]) == nil, "fewer than three votes suggest nothing")
    check(LinearKeys.key(branches: (1...25).map { "me/acm-\($0)-fix" } + ["mobile-1", "mobile-2", "issue-3", "main"]) == "ACM", "a repo's Linear key from its branches")
    check(LinearKeys.key(branches: ["main", "issue-1", "issue-2"]) == nil, "too few branches name no key")
}

// A recorded "GitHub Actions Billing Fix" session (work account): the Stop asks "Should I start that PR now…?"
// above a Linear line and a Sources trailer; the folder is not a git repo. It showed as Safe to close 3 min later.
let billing = "6a127e7c-b36a-4814-a46e-740d90d9dd04"
var recorded = EventLog.fold(url: fixtures.appendingPathComponent("billing.jsonl"), accounts: accounts)
check(recorded.sessions[billing]?.phase == .needsYou("Should I start that PR now, so it's ready when billing is fixed?"), "a question above the Linear and Sources trailers needs you")
let stoppedAt = recorded.sessions[billing]!.lastEventAt
func billingAt(_ st: AppState, _ later: TimeInterval) -> AppState {
    var st = st
    let at = stoppedAt.addingTimeInterval(later)
    st = reduce(st, .agents(AgentsSnapshot(at: at.addingTimeInterval(-10), accountId: "work", entries: [
        .init(sessionId: billing, name: "billing", cwd: "/Users/me/projects/meta-agent-tool", startedAt: stoppedAt.addingTimeInterval(-3600),
              reach: .elsewhere(pid: 1), status: .idle, runningTasks: []),
    ])))
    // The real folder: meta-agent-tool is not a git repo.
    st = reduce(st, .doneCheck(billing, DoneCheck(at: at.addingTimeInterval(-5), repo: false, dirtyFiles: nil, unpushed: nil, pr: .unknown("not checked"), branch: nil)))
    return st
}
for later: TimeInterval in [180, 3 * 3600, 3 * 86400] {
    let st = billingAt(recorded, later)
    check(st.group(st.sessions[billing]!, now: stoppedAt.addingTimeInterval(later), rules: rules) != .safeToClose, "billing session is never safe to close (+\(Int(later))s)")
}
var answered = recorded
answered.sessions[billing]!.lastMessage = "Opened PR #1301 moving the jobs to Ubicloud. CI is green and it is merged."
answered.sessions[billing]!.phase = .yourTurn
answered = billingAt(answered, 3 * 3600)
answered = reduce(answered, .judged(hash: Reply.hash(answered.sessions[billing]!.lastMessage!), Judgment(verdict: .finished, at: stoppedAt, account: "work", costUSD: nil)))
let answeredChecks = answered.checks(answered.sessions[billing]!, now: stoppedAt.addingTimeInterval(3 * 3600), rules: rules)
check(answeredChecks.filter { $0.outcome != .pass }.map(\.kind) == [.worktree, .pushed, .pr], "a plain finished report in a folder outside git: only the unknown repo checks block it")
check(answered.group(answered.sessions[billing]!, now: stoppedAt.addingTimeInterval(3 * 3600), rules: rules) == .yourTurn, "outside git it stays your turn: unknown is never safe")

// "Not safe" presses: each fixture replays the facts Maxwell saw (without the mark)
// and fails until the rules stop calling that session safe.
let falseSafeDir = fixtures.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tests/fixtures/false-safe")
let falseSafe = ((try? FileManager.default.contentsOfDirectory(at: falseSafeDir, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }
for f in falseSafe {
    guard let data = try? Data(contentsOf: f), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let (st, sess, now, r) = FalseSafe.decode(o) else {
        check(false, "false-safe fixture \(f.lastPathComponent) is readable"); continue
    }
    check(st.group(sess, now: now, rules: r) != .safeToClose, "false-safe \(f.lastPathComponent) (\(o["title"] ?? "")): the rules still call it safe")
}
var roundTrip = safe
roundTrip.sessions["s1"]!.listedStatus = .waiting("x")
if let (st, sess, now, r) = FalseSafe.decode((try? JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: FalseSafe.encode(safe.sessions["s1"]!, in: safe, now: t0.addingTimeInterval(later), rules: rules)))) as? [String: Any] ?? [:]) {
    check(st.group(sess, now: now, rules: r) == .safeToClose && st.checks(sess, now: now, rules: r).map(\.outcome) == verdictOf(safe, "s1", at: later).map(\.outcome), "a false-safe fixture rebuilds the verdict it recorded")
} else { check(false, "false-safe fixture encodes and decodes") }

// The status line a session ends its reply with.
check(Wrap.parse("Done.\n\n**Safe to close** · v0.1.17 shipped\n") == Wrap(state: .safe, note: "v0.1.17 shipped"), "bold safe line with a middle dot")
check(Wrap.parse("Not done - PR #25 waiting on CI") == Wrap(state: .open, note: "PR #25 waiting on CI"), "plain line with a hyphen")
check(Wrap.parse("🟡 __needs you__: pick a name") == Wrap(state: .needsYou, note: "pick a name"), "glyph prefix, underscores, any case, a colon")
check(Wrap.parse("✅ `Safe to close` — merged") == Wrap(state: .safe, note: "merged"), "backticks and an em dash")
check(Wrap.parse("**Safe to close**") == Wrap(state: .safe, note: ""), "no note")
check(Wrap.parse("Not done | waiting on review")?.note == "waiting on review", "pipe separator")
check(Wrap.parse("Not done · " + String(repeating: "x", count: 300))?.note.count == 120, "the note is capped")
check(Wrap.parse("**Safe to close** · shipped\nOne more thing.") == nil, "only the last line counts")
check(Wrap.parse("All merged and deployed.") == nil, "an unrelated last line is no status line")
check(Wrap.parse("Needs your review first") == nil, "a longer word is not the state")
check(Wrap.stripped("Merged.\n\n**Not done** · want me to tag it?") == "Merged.", "stripped drops the status line")
check(Wrap.stripped("Merged. Want me to tag it?") == "Merged. Want me to tag it?", "stripped keeps a message without one")
check(Reply.classify("Shipped v0.1.17.\n\n**Not done** · still waiting on CI, want me to watch it?") == .statement, "the status line is never a question or an offer")
check(Reply.classify("Shipped.\n\nWant me to tag it?\n\n**Not done** · tag") == .question("Want me to tag it?"), "a question above the status line still counts")
check(Reply.phase(after: "Built it.\n\n**Needs you** · pick a name for the setting") == .needsYou("pick a name for the setting"), "needs you from the status line")
check(Reply.phase(after: "Built it.\n\n**Needs you**") == .needsYou("Needs you"), "needs you without a note")
check(Reply.phase(after: "Built it.\n\n**Not done** · CI running") == .yourTurn, "not done is your turn")
var wrapped = safe
wrapped.sessions["s1"]!.lastMessage = "Shipped.\n\n**Safe to close** · v0.1.17 shipped"
wrapped = reduce(wrapped, .judged(hash: Reply.hash(wrapped.sessions["s1"]!.lastMessage!), Judgment(verdict: .finished, at: t0, account: "work", costUSD: nil)))
check(verdictOf(wrapped, "s1", at: later).first { $0.kind == .wrap } == Check(kind: .wrap, outcome: .pass, detail: "v0.1.17 shipped", source: "session's status line"), "safe status line passes")
check(groupOf(wrapped, "s1", at: later) == .safeToClose, "a safe status line plus every check is safe to close")
wrapped.sessions["s1"]!.lastMessage = "Shipped.\n\n**Not done** · PR #25 waiting on CI"
wrapped = reduce(wrapped, .judged(hash: Reply.hash(wrapped.sessions["s1"]!.lastMessage!), Judgment(verdict: .finished, at: t0, account: "work", costUSD: nil)))
check(verdictOf(wrapped, "s1", at: later).first { $0.kind == .wrap }.map { [$0.outcome.rawValue, $0.detail] } == ["fail", "Not done · PR #25 waiting on CI"], "not done fails the status line check")
check(groupOf(wrapped, "s1", at: later) != .safeToClose, "a session that says not done is never safe")

// Terminal sessions: the hook's pid says which process to stop when one moves into Maxwell.
let pidLine = #"{"ts":1800000000000,"configDir":"\#(home.path)/.claude","pid":4242,"hook":{"session_id":"t1","hook_event_name":"Stop","cwd":"/tmp/x"}}"#
var term = AppState(accounts: accounts)
term = reduce(term, EventParser.parse(line: Substring(pidLine))!)
check(term.sessions["t1"]?.reach == .elsewhere(pid: 4242), "a hook's pid marks the terminal process")
let oldLine = #"{"ts":1800000001000,"configDir":"\#(home.path)/.claude","hook":{"session_id":"t1","hook_event_name":"Stop","cwd":"/tmp/x"}}"#
term = reduce(term, EventParser.parse(line: Substring(oldLine))!)
check(term.sessions["t1"]?.reach == .elsewhere(pid: 4242), "a hook line without a pid keeps the one known")
term = reduce(term, hook(.stopped(lastMessage: "ok"), "t0", at: -100))
check(term.isNewestInFolder(term.sessions["t1"]!) && !term.isNewestInFolder(term.sessions["t0"]!), "only the newest session in a folder is a lone terminal's")

logoTests()
artifactTests()
pluginTests()
pluginHostTests()
linearTests()
linearPluginTests()

print(failures == 0 ? "reducer tests: all passed" : "reducer tests: \(failures) failed")
exit(failures == 0 ? 0 : 1)
