import Foundation

/// Plugin checks follow Maxwell's rules, not the plugin's: unknown and stale evidence are never
/// safe, a stopped plugin can't vouch, and turning a plugin off removes what it said.
func pluginTests() {
    let at = later
    let now = t0.addingTimeInterval(at)
    func note(_ outcome: Check.Outcome, at when: Date = now) -> PluginNote {
        PluginNote(at: when, badges: [.init(text: "ACME-56 · Done", tone: .good, tooltip: nil, action: nil)],
                   checks: [.init(id: "ticket-done", title: "Linear ticket done", outcome: outcome, detail: "ACME-56 is Done", source: "Linear API")])
    }
    let on = reduce(safe, .pluginState("linear", name: "Linear", down: nil))
    check(groupOf(on, "s1", at: at) == .safeToClose, "a plugin with no note on a session leaves it alone")

    let done = reduce(on, .annotated("linear", "s1", note(.pass)))
    let checks = verdictOf(done, "s1", at: at)
    check(groupOf(done, "s1", at: at) == .safeToClose, "a passing plugin check keeps a safe session safe")
    check(checks.contains { $0.kind == .plugin && $0.title == "Linear ticket done" && $0.source.hasPrefix("Linear: ") }, "the plugin check shows with its own title and source")
    check(checks.firstIndex { $0.kind == .plugin }! < checks.firstIndex { $0.kind == .judge }!, "plugin checks come before the model read, so a failing one saves the read")

    let open = reduce(on, .annotated("linear", "s1", note(.fail)))
    check(groupOf(open, "s1", at: at) == .yourTurn, "a failing plugin check keeps the session out of Safe to close")
    let unsure = reduce(on, .annotated("linear", "s1", note(.unknown)))
    check(groupOf(unsure, "s1", at: at) == .yourTurn, "a plugin's unknown is never safe")

    let crashed = reduce(done, .pluginState("linear", name: "Linear", down: "exited with status 1"))
    let c = verdictOf(crashed, "s1", at: at).first { $0.kind == .plugin }
    check(c?.outcome == .unknown && c?.detail.contains("isn't running") == true && groupOf(crashed, "s1", at: at) == .yourTurn, "a plugin that stopped can't vouch: its checks turn unknown")
    check(groupOf(reduce(crashed, .pluginState("linear", name: "Linear", down: nil)), "s1", at: at) == .safeToClose, "back up, its last word counts again")

    let stale = reduce(on, .annotated("linear", "s1", note(.pass, at: t0)))
    check(outcome(verdictOf(stale, "s1", at: at), .plugin) == .unknown, "a check from before the session's last activity is unknown")

    let off = reduce(open, .pluginOff("linear"))
    check(off.notes.isEmpty && groupOf(off, "s1", at: at) == .safeToClose, "turning a plugin off removes its checks")
    check(reduce(done, .annotated("linear", "s1", nil)).notes.isEmpty, "an empty annotation clears the plugin's note")

    // Wire parsing.
    let parsed = PluginNote.parse(["session": "s1", "badges": [["text": "ACME-56", "tone": "loud"]],
                                   "checks": [["id": "x", "title": "X", "outcome": "maybe"]], "actions": ["open-ticket"]], at: now)
    check(parsed?.0 == "s1" && parsed?.1.badges.first?.tone == .neutral, "an unknown tone falls back to neutral")
    check(parsed?.1.checks.first?.outcome == .unknown, "an outcome Maxwell can't read is unknown, never pass")
    check(parsed?.1.actions == ["open-ticket"], "per-session actions parse")
    check(PluginNote.parse(["badges": []], at: now) == nil, "an annotation without a session is dropped")
    let view = PluginView.parse(["type": "list", "sections": [["title": "Suggested", "rows": [["id": "ACME-56", "title": "ACME-56 Totals",
        "badge": ["text": "In Review", "tone": "info"], "actions": [["action": "move-done", "title": "Move to Done"]]], ["title": "no id"]]]]])
    if case .list(let s)? = view { check(s.first?.rows.count == 1 && s.first?.rows.first?.actions.first?.action == "move-done", "a list view parses; rows without an id are dropped") }
    else { check(false, "a list view parses") }
    check(PluginView.parse(["type": "html"]) == nil, "unknown view types are refused")
    if case .list(let ss)? = PluginView.parse(["type": "list", "sections": [["title": "", "rows": [
        ["id": "a", "title": "A", "status": "readyToClose"], ["id": "b", "title": "B", "status": "sparkly"]]]]]) {
        check(ss[0].rows.map(\.status) == [.readyToClose, nil], "row status parses; an unknown one is left out")
        check(PluginView.ItemStatus.inSession.glyph == .working && PluginView.ItemStatus.readyToClose.glyph == .yourTurn, "statuses draw as session glyphs")
    } else { check(false, "list with statuses parses") }

    // Manifests.
    let dir = URL(fileURLWithPath: "/tmp/p")
    let good = #"{"id":"linear","name":"Linear","version":"0.1.0","protocol":1,"run":["./linear"],"actions":[{"id":"open","title":"Open","scope":"session"}]}"#
    if case .success(let m) = PluginManifest.parse(Data(good.utf8), dir: dir) { check(m.actions.first?.scope == .session && m.dir == dir, "a manifest parses") }
    else { check(false, "a manifest parses") }
    check(PluginManifest.parse(Data(good.replacingOccurrences(of: "\"linear\"", with: "\"Lin ear\"").utf8), dir: dir) == .failure(.badId("Lin ear")), "ids are a-z, 0-9 and -")
    check(PluginManifest.parse(Data(good.replacingOccurrences(of: "\"protocol\":1", with: "\"protocol\":2").utf8), dir: dir) == .failure(.newerProtocol(2)), "a newer protocol is refused with the reason")
    check(PluginManifest.parse(Data(#"{"id":"x","name":"X","version":"1","protocol":1}"#.utf8), dir: dir) == .failure(.unreadable("missing \"run\"")), "a missing field is named")

    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mx-plugins-\(getpid())")
    defer { try? FileManager.default.removeItem(at: root) }
    for (where_, name) in [("bundled", "Linear (bundled)"), ("user", "Linear (mine)")] {
        let d = root.appendingPathComponent("\(where_)/linear")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try? Data(good.replacingOccurrences(of: "\"Linear\"", with: "\"\(name)\"").utf8).write(to: d.appendingPathComponent("plugin.json"))
    }
    let broken = root.appendingPathComponent("user/broken")
    try? FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
    try? Data("{".utf8).write(to: broken.appendingPathComponent("plugin.json"))
    let found = PluginManifest.discover(user: root.appendingPathComponent("user"), bundled: root.appendingPathComponent("bundled"))
    check(found.found.map(\.name) == ["Linear (mine)"] && found.found.first?.bundled == false, "a user plugin replaces the bundled one with the same id")
    check(found.broken.count == 1 && found.broken.first?.why == .unreadable("not valid JSON"), "a broken manifest is reported, not skipped silently")

    // Settings.
    let cfg = Config.parse("linear.team = ACME\nlinear.enabled = false\nslack.sync = off\naccount = work ~/.claude\n")
    check(cfg.plugins["linear"]?["team"] == "ACME" && !cfg.pluginEnabled("linear") && cfg.pluginEnabled("slack"), "plugin settings are namespaced lines; on unless enabled = false")
    if case .success(var m) = PluginManifest.parse(Data(#"{"id":"linear","name":"L","version":"1","protocol":1,"run":["x"],"settings":[{"key":"team","title":"Team","type":"string","default":"ENG"},{"key":"sync","title":"Sync","type":"choice","default":"suggest"},{"key":"api-key","title":"Key","type":"secret"}]}"#.utf8), dir: dir) {
        m.dir = dir
        check(cfg.pluginSettings(m) == ["team": "ACME", "sync": "suggest"], "settings fill defaults and never include secrets")
    } else { check(false, "manifest with settings parses") }
}
