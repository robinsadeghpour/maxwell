import Foundation

/// The compiled Linear plugin under the real host, on fixtures, writes in dry run: a session on
/// a branch gets its ticket badge and a done check; a merged PR suggests Done; the move is logged.
func linearPluginTests() {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mx-linear-\(getpid())")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let dir = tmp.appendingPathComponent("plugins/linear")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? FileManager.default.copyItem(at: cwd.appendingPathComponent("plugins/linear/plugin.json"), to: dir.appendingPathComponent("plugin.json"))
    try? FileManager.default.copyItem(at: cwd.appendingPathComponent("build/linear-plugin"), to: dir.appendingPathComponent("linear"))
    setenv("MAXWELL_LINEAR_FIXTURES", cwd.appendingPathComponent("fixtures/linear").path, 1)
    defer { unsetenv("MAXWELL_LINEAR_FIXTURES") }
    func pump(_ seconds: TimeInterval = 5, until done: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }
    let host = PluginHost(paths: .init(user: tmp.appendingPathComponent("plugins"), bundled: nil, logs: tmp.appendingPathComponent("logs"), data: tmp.appendingPathComponent("data")),
                          secrets: MemorySecrets(), version: "test")
    var st = safe
    host.apply = { evs in st = evs.reduce(into: st) { reduce(into: &$0, $1) } }
    host.reload(Config.parse("account = work ~/.claude\n"))
    pump { host.status["linear"]?.isRunning == true && host.status["linear"]?.reported == .ok }
    check(host.status["linear"]?.line == "Connected as Sam Example, dry run", "the plugin connects on fixtures, in dry run (\(host.status["linear"]?.line ?? "-"))")

    var sess = st.sessions["s1"]!
    sess.doneCheck?.branch = "robin/eng-12-billing-totals"
    sess.doneCheck?.pr = .merged(212)
    let at = later
    st.sessions["s1"] = sess
    host.sessionsChanged([PluginHost.json(sess, state: st, group: .safeToClose, project: "Acme")])
    pump { st.notes["s1"]?["linear"]?.checks.isEmpty == false }
    let note = st.notes["s1"]?["linear"]
    check(note?.badges.first?.text == "ENG-12 · In Progress" && note?.badges.first?.tone == .warn, "the row shows the ticket, its status, and that a move is suggested (\(note?.badges.first?.text ?? "-"))")
    check(note?.checks.first?.outcome == .fail && note?.checks.first?.detail == "ENG-12 is In Progress", "the done check fails while the ticket is open")
    var timed = st
    timed.notes["s1"]?["linear"]?.at = t0.addingTimeInterval(at)
    check(outcome(verdictOf(timed, "s1", at: at), .plugin) == .fail && groupOf(timed, "s1", at: at) == .yourTurn, "an open ticket keeps the session out of Safe to close")
    check(note?.actions?.contains("move-done") == true, "Move to Done is offered for this session")
    if case .list(let sections)? = host.panels["linear"]?["tickets"] {
        check(sections.first?.title == "Suggested" && sections.first?.rows.first?.actions.first?.title == "Move to Done", "the panel lists the suggestion first")
        check(sections.map(\.title) == ["Suggested", "In progress  2", "Todo  1", "Backlog  1", "Done this week  1"], "then every ticket of yours by status (\(sections.map(\.title)))")
    } else { check(false, "the Linear panel is set") }

    var message: String?
    host.run("linear", action: "move-done", session: "s1", item: nil) { r in
        switch r { case .success(let m): message = m ?? "ok"; case .failure(let e): message = "error: \(e.message)" }
    }
    pump { message != nil }
    check(message == "Dry run: would move ENG-12 to Done", "the move is a dry run (\(message ?? "no answer"))")
    let log = (try? String(contentsOf: tmp.appendingPathComponent("data/linear/dry-run.jsonl"), encoding: .utf8)) ?? ""
    check(log.contains("issueUpdate") && log.contains("st-done"), "the dry-run log has the exact write that would have gone out")
    pump(1) { st.notes["s1"]?["linear"]?.actions?.contains("move-done") == false }
    check(st.notes["s1"]?["linear"]?.actions?.contains("move-done") == false, "once done, it isn't suggested again")

    sess.doneCheck?.branch = "main"
    sess.transcriptPath = cwd.appendingPathComponent("fixtures/linear/transcript.jsonl").path
    sess.lastEventAt = sess.lastEventAt.addingTimeInterval(1)
    host.sessionsChanged([PluginHost.json(sess, state: st, group: .yourTurn, project: "Acme")])
    pump { st.notes["s1"]?["linear"]?.badges.first?.text.hasPrefix("ENG-7") == true }
    check(st.notes["s1"]?["linear"]?.badges.first?.text == "ENG-7 · Todo", "without a ticket branch, the transcript links the ticket it worked on")
    host.shutdownAll()
}
