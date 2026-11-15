import Foundation

/// The Linear plugin: links, suggestions and the done check on recorded, anonymised fixtures.
/// Every write is a dry run: logged to a file, never sent.
func linearTests() {
    let fx = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("fixtures/linear")
    let teams: Set<String> = ["ENG", "OPS"]

    // Links from the branch.
    check(LinearLink.fromBranch("robin/eng-12-billing-totals", teams: teams) == "ENG-12", "Linear's branch format links the ticket")
    check(LinearLink.fromBranch("eng-12-billing", teams: teams) == "ENG-12", "a branch without a user prefix links too")
    check(LinearLink.fromBranch("robin/fix-12-thing", teams: teams) == nil, "a key that isn't a team doesn't link")
    check(LinearLink.fromBranch("robin/acme-56-x", teams: []) == "ACME-56", "before teams are known, Linear's format is enough")
    check(LinearLink.fromBranch("main", teams: teams) == nil && LinearLink.fromBranch(nil, teams: teams) == nil, "main and no branch link nothing")
    check(LinearLink.fromBranch("mx/plugins-linear", teams: []) == nil, "a word after the key is not a ticket number")

    // Links from the transcript.
    var v = TranscriptVotes()
    let text = (try? String(contentsOf: fx.appendingPathComponent("transcript.jsonl"), encoding: .utf8)) ?? ""
    for line in text.split(separator: "\n") { v.feed(line, teams: teams) }
    check(v.scores["ENG-56"] == nil, "tickets named in CLAUDE.md or system reminders don't count")
    check(v.scores["ENG-7"] == 6, "a prompt (2), a read (1) and a comment (3) add up (got \(v.scores["ENG-7"] ?? 0))")
    check(v.scores["ENG-99"] == 1, "filing a ticket is a weak vote")
    check(v.winner() == "ENG-7", "the session works on the ticket it commented on")
    var compact = TranscriptVotes()
    compact.feed(#"{"type":"user","isCompactSummary":true,"message":{"role":"user","content":"Summary: worked on ENG-7 and ENG-12"}}"#, teams: teams)
    compact.feed(#"{"type":"user","message":{"role":"user","content":"This session is being continued from a previous conversation. ENG-7"}}"#, teams: teams)
    check(compact.scores.isEmpty, "compaction summaries don't vote again for tickets already counted")
    check(TranscriptVotes(scores: ["ENG-1": 4, "ENG-2": 3]).winner() == nil, "two close candidates link nothing")
    check(TranscriptVotes(scores: ["ENG-1": 2]).winner() == nil, "one mention isn't enough")
    check(TranscriptVotes.linearTool("mcp__claude_ai_Linear__save_comment") == "save_comment" && TranscriptVotes.linearTool("mcp__linear__get_issue") == "get_issue"
          && TranscriptVotes.linearTool("mcp__slack__send") == nil, "both Linear connectors are recognised")

    // Fixture issues.
    func issue(_ id: String) -> LinearIssue {
        LinearIssue.parse((try? JSONSerialization.jsonObject(with: Data(contentsOf: fx.appendingPathComponent("\(id).json")))) as? [String: Any] ?? [:])!
    }
    let started = issue("ENG-12"), todo = issue("ENG-7"), done = issue("ENG-30"), canceled = issue("ENG-41")
    check(todo.target("started")?.name == "In Progress" && todo.target("completed")?.name == "Done", "In Progress and Done are found by type, in team order")

    func session(branch: String? = nil, pr: (String, Int)? = nil, phase: String = "yourTurn") -> LinearSession {
        var d: [String: Any] = ["id": "s1", "title": "billing fix", "cwd": "/tmp", "phase": phase, "lastEventAt": "2026-11-14T10:00:00Z"]
        if let branch { d["branch"] = branch }
        if let pr { d["pr"] = ["state": pr.0, "number": pr.1] }
        return LinearSession(d)!
    }
    check(LinearRules.suggestions(session(), todo, settled: []).map(\.action) == ["move-started"], "work on a Todo ticket suggests In Progress")
    check(LinearRules.suggestions(session(pr: ("open", 212)), started, settled: []).map(\.action) == ["comment-pr"], "an open PR suggests a comment")
    check(LinearRules.suggestions(session(pr: ("merged", 212)), started, settled: []).map(\.action) == ["move-done"], "a merged PR suggests Done")
    check(LinearRules.suggestions(session(pr: ("merged", 212)), done, settled: []).isEmpty, "a done ticket suggests nothing")
    check(LinearRules.suggestions(session(pr: ("merged", 212)), started, settled: ["ENG-12/done"]).isEmpty, "a suggestion done or waved away isn't offered again")

    // The done check.
    let now = Date()
    let pass = LinearRules.check(issueId: "ENG-30", issue: done, error: nil, fetchedAt: now, now: now, hasKey: true, connected: true)
    check(pass?["outcome"] as? String == "pass" && (pass?["detail"] as? String) == "ENG-30 is Done", "a done ticket passes")
    check(LinearRules.check(issueId: "ENG-41", issue: canceled, error: nil, fetchedAt: now, now: now, hasKey: true, connected: true)?["outcome"] as? String == "pass", "a canceled ticket leaves nothing to do")
    check(LinearRules.check(issueId: "ENG-12", issue: started, error: nil, fetchedAt: now, now: now, hasKey: true, connected: true)?["outcome"] as? String == "fail", "an open ticket fails")
    check(LinearRules.check(issueId: "ENG-12", issue: started, error: nil, fetchedAt: now.addingTimeInterval(-900), now: now, hasKey: true, connected: true)?["outcome"] as? String == "unknown", "a status older than 10 minutes is unknown")
    check(LinearRules.check(issueId: "ENG-12", issue: nil, error: "offline", fetchedAt: nil, now: now, hasKey: true, connected: true)?["outcome"] as? String == "unknown", "can't read the ticket: unknown")
    check(LinearRules.check(issueId: "ENG-12", issue: started, error: nil, fetchedAt: now, now: now, hasKey: false, connected: false) == nil, "no key: no check at all, so it never blocks")
    check(LinearRules.check(issueId: "ENG-30", issue: done, error: nil, fetchedAt: now, now: now, hasKey: true, connected: false)?["outcome"] as? String == "unknown", "a key but no connection: unknown, even for a ticket last seen done")
    check(LinearRules.check(issueId: "ENG-30", issue: done, error: "offline", fetchedAt: now, now: now, hasKey: true, connected: true)?["outcome"] as? String == "unknown", "a failed read is unknown even with a fresh cache")
    let a = LinearRules.annotation(session(branch: "robin/eng-12-x"), issueId: "ENG-12", issue: started, error: nil, fetchedAt: now, now: now, hasKey: true, connected: true, pending: [])
    check(((a["badges"] as? [[String: Any]])?.first?["text"] as? String) == "ENG-12 · In Progress", "the row badge says the ticket and its status")

    // The panel: all tickets by status, each with its sessions' state.
    let sA = LinearSession(["id": "a", "title": "email draft", "group": "needsYou", "phase": "needsYou", "lastEventAt": ""])!
    let sB = LinearSession(["id": "b", "title": "overview page", "group": "safeToClose", "phase": "yourTurn", "lastEventAt": ""])!
    let board = LinearBoard.view(mine: [todo, started, done], issues: ["ENG-12": started], links: ["a": "ENG-12", "b": "ENG-12"],
                                 sessions: ["a": sA, "b": sB], suggested: [], connected: true)
    let secs = (board["sections"] as? [[String: Any]]) ?? []
    check(secs.map { $0["title"] as? String ?? "" } == ["In progress  1", "Todo  1", "Done this week  1"], "tickets group by status, in work order (\(secs.map { $0["title"] ?? "" }))")
    let r12 = (secs.first?["rows"] as? [[String: Any]])?.first
    check(r12?["session"] as? String == "a" && (r12?["badge"] as? [String: Any])?["text"] as? String == "needs you", "a ticket's badge is its most urgent session, and a click opens that one")
    check(r12?["subtitle"] as? String == "2 sessions · 1 needs you, 1 safe to close", "the line says how its sessions stand")
    let r7 = ((secs.dropFirst().first?["rows"] as? [[String: Any]])?.first)
    check(r7?["subtitle"] == nil && r7?["key"] as? String == todo.identifier && r7?["url"] as? String == todo.url, "a ticket with no session opens in Linear")

    // Writes are dry runs here: logged, never sent.
    final class Recorder: LinearTransport {
        var sent = 0
        func send(_ q: String, _ v: [String: Any], _ done: @escaping (Result<[String: Any], LinearError>) -> Void) { sent += 1; done(.success([:])) }
    }
    let rec = Recorder()
    let log = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mx-linear-dry-\(getpid()).jsonl")
    defer { try? FileManager.default.removeItem(at: log) }
    var msg: String?
    LinearClient(transport: rec, dryRunLog: log).move(started, to: started.target("completed")!) { if case .success(let m) = $0 { msg = m } }
    let end = Date().addingTimeInterval(2)
    while msg == nil && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    check(rec.sent == 0 && msg == "Dry run: would move ENG-12 to Done", "a dry-run move sends nothing and says what it would do")
    check(((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains("uuid-eng-12"), "the dry-run move is logged with Linear's id")
    check(HTTPTransport.decode(Data(#"{"errors":[{"message":"Authentication required","extensions":{"code":"AUTHENTICATION_ERROR"}}]}"#.utf8)) .failureValue == .unauthorized, "a refused key is told apart from other errors")
}

extension Result { var failureValue: Failure? { if case .failure(let e) = self { return e }; return nil } }
