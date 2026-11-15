import Foundation

/// The host against real processes: the example plugin end to end, and a plugin that crashes.
func pluginHostTests() {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mx-host-\(getpid())")
    defer { try? FileManager.default.removeItem(at: tmp) }
    func pump(_ seconds: TimeInterval = 5, until done: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }
    let examples = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("examples/plugins")
    let host = PluginHost(paths: .init(user: examples, bundled: nil, logs: tmp.appendingPathComponent("logs"), data: tmp.appendingPathComponent("data")),
                          secrets: MemorySecrets(), version: "test")
    var st = safe
    host.apply = { evs in st = evs.reduce(into: st) { reduce(into: &$0, $1) } }
    host.reload(Config.parse("hello.greeting = Hi\naccount = work ~/.claude\n"))
    pump { host.status["hello"]?.isRunning == true }
    check(host.status["hello"]?.isRunning == true, "the example plugin starts and answers initialize (\(host.status["hello"]?.line ?? "no status"))")
    check(st.pluginNames["hello"] == "Hello" && st.pluginDown["hello"] == nil, "a running plugin is reported up")

    var sess = st.sessions["s1"]!
    sess.doneCheck?.branch = "robin/acme-56-totals"
    host.sessionsChanged([PluginHost.json(sess, state: st, group: .safeToClose, project: "Acme")])
    pump { st.notes["s1"]?["hello"] != nil && host.panels["hello"]?["branches"] != nil }
    check(st.notes["s1"]?["hello"]?.badges.first?.text == "robin/acme-56-totals", "the plugin's badge for the session arrives as an event")
    if case .list(let sections)? = host.panels["hello"]?["branches"] { check(sections.first?.rows.first?.session == "s1", "its panel lists the session") }
    else { check(false, "its panel is set") }

    var message: String?
    host.run("hello", action: "greet", session: "s1", item: nil) { if case .success(let m) = $0 { message = m } }
    pump { message != nil }
    check(message == "Hi, \(sess.title)", "an action runs with the session and the plugin's settings (got \(message ?? "nothing"))")

    var annotations = 0
    host.apply = { evs in for e in evs { if case .annotated = e { annotations += 1 } }; st = evs.reduce(into: st) { reduce(into: &$0, $1) } }
    host.sessionsChanged([PluginHost.json(sess, state: st, group: .safeToClose, project: "Acme")])
    pump(0.3) { false }
    check(annotations == 0, "an unchanged session is not sent again")

    var refreshed = false
    var silent: Set<PluginID> = ["x"]
    host.refresh("s1", plugins: ["hello"]) { refreshed = true; silent = $0 }
    pump { refreshed }
    check(refreshed && annotations == 1 && silent.isEmpty, "a re-check at close asks the plugin again and waits for its answer")
    var notRunning: Set<PluginID> = []
    host.refresh("s1", plugins: ["hello", "gone"]) { notRunning = $0 }
    pump { !notRunning.isEmpty }
    check(notRunning == ["gone"], "a plugin that can't answer at close is reported, so its checks count as unknown")

    host.reload(Config.parse("hello.enabled = false\naccount = work ~/.claude\n"))
    check(st.notes["s1"]?["hello"] == nil && host.status["hello"]?.run == .off, "turning it off removes its notes")

    // A plugin that dies on start: restarted, then given up on, with its last stderr line.
    let crashDir = tmp.appendingPathComponent("user/crash")
    try? FileManager.default.createDirectory(at: crashDir, withIntermediateDirectories: true)
    try? Data(#"{"id":"crash","name":"Crash","version":"1","protocol":1,"run":["./run.sh"]}"#.utf8).write(to: crashDir.appendingPathComponent("plugin.json"))
    try? Data("#!/bin/sh\necho 'boom: no API key' >&2\nexit 3\n".utf8).write(to: crashDir.appendingPathComponent("run.sh"))
    chmod(crashDir.appendingPathComponent("run.sh").path, 0o755)
    let h2 = PluginHost(paths: .init(user: tmp.appendingPathComponent("user"), bundled: nil, logs: tmp.appendingPathComponent("logs"), data: tmp.appendingPathComponent("data")),
                        secrets: MemorySecrets(), version: "test")
    h2.restartDelays = [0.05, 0.05, 0.05]
    var st2 = reduce(safe, .annotated("crash", "s1", PluginNote(at: t0.addingTimeInterval(later), checks: [.init(id: "x", title: "X", outcome: .pass, detail: "ok", source: "t")])))
    h2.apply = { evs in st2 = evs.reduce(into: st2) { reduce(into: &$0, $1) } }
    h2.reload(Config.parse("account = work ~/.claude\n"))
    pump { if case .failed = h2.status["crash"]?.run { return true }; return false }
    if case .failed(let why)? = h2.status["crash"]?.run { check(why.contains("exited with status 3") && why.contains("boom: no API key"), "a plugin that keeps crashing stops with its exit status and last stderr line (\(why))") }
    else { check(false, "a plugin that keeps crashing is given up on (\(h2.status["crash"]?.line ?? "-"))") }
    check(outcome(verdictOf(st2, "s1", at: later), .plugin) == .unknown && groupOf(st2, "s1", at: later) == .yourTurn, "while it's down its checks are unknown")
    let log = (try? String(contentsOf: h2.logURL("crash"), encoding: .utf8)) ?? ""
    check(log.contains("boom: no API key"), "stderr goes to the plugin's log")
}
