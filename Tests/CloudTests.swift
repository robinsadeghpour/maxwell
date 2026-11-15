import Foundation

/// Cloud sessions from the Sessions API. Shapes copied from `GET /v1/sessions` (Claude Code 2.1.325),
/// names and ids from the invented world in demo/.
func cloudTests() {
    let accounts = [Account(id: "work", name: "work", configDir: Paths.home.appendingPathComponent(".claude"))]
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func entry(_ id: String, kind: String = "anthropic_cloud", status: String, category: String? = nil, needs: String = "",
               detail: String = "", repo: String? = nil, branch: String = "") -> String {
        let pts = category.map { #","post_turn_summary":{"status_category":"\#($0)","status_detail":"\#(detail)","needs_action":"\#(needs)","title":""}"# } ?? ""
        let sources = repo.map { #"[{"type":"git_repository","url":"https://github.com/\#($0).git"}]"# } ?? "[]"
        return #"{"id":"\#(id)","environment_kind":"\#(kind)","session_status":"\#(status)","title":"Orbit \#(id.suffix(2))","#
            + #""session_url":"\#(id == "session_a1" ? "" : "https://claude.ai/code/cshk_" + id)","created_at":"2026-11-15T21:00:00.000000Z","updated_at":"2026-11-15T22:00:00.123456Z","#
            + #""session_context":{"sources":\#(sources)},"external_metadata":{"current_branches":{"":"\#(branch)"}}\#(pts)}"#
    }
    let body = "{\"data\":[" + [
        entry("session_a1", status: "running"),
        entry("session_a2", status: "idle", category: "completed", detail: "opened PR #41", repo: "orbit-labs/web", branch: "claude/fix-upload"),
        entry("session_a3", status: "idle", category: "needs_action", needs: "Pick the retry limit: 3 or 5?"),
        entry("session_a4", status: "requires_action", category: "working"),
        entry("session_a5", status: "archived", category: "completed"),
        entry("session_a6", kind: "bridge", status: "idle", category: "completed"),
        entry("session_a7", status: "warming_up"),
    ].joined(separator: ",") + "]}"
    let snap = CloudParser.parse(Data(body.utf8), accountId: "work", at: t0)
    check(snap?.sessions.map(\.id) == ["session_a1", "session_a2", "session_a3", "session_a4", "session_a5", "session_a7"], "cloud sessions only: a Remote Control session (bridge) is left to claude agents")
    let byId = Dictionary(uniqueKeysWithValues: (snap?.sessions ?? []).map { ($0.id, $0) })
    check(byId["session_a1"]?.phase == .working && byId["session_a1"]?.url == "https://claude.ai/code/session_a1", "running is working; an empty session_url falls back to its page")
    check(byId["session_a2"]?.phase == .yourTurn && byId["session_a2"]?.repo == "orbit-labs/web" && byId["session_a2"]?.branch == "claude/fix-upload", "a finished turn is your turn, with its repo and branch")
    check(byId["session_a3"]?.phase == .needsYou("Pick the retry limit: 3 or 5?"), "a turn that ended needing you says what it needs")
    check(byId["session_a4"]?.phase == .needsYou("Waiting for your answer"), "requires action needs you")
    check(byId["session_a5"]?.phase == .ended, "archived has ended")
    check(byId["session_a7"]?.status == .unknown("warming_up") && byId["session_a7"]?.phase == .yourTurn, "an unknown status stays unknown, never working or safe")
    check(byId["session_a2"]?.updatedAt == Date(timeIntervalSince1970: 1_794_780_000.123), "fractional ISO dates parse")

    // The list: a cloud session sits in the groups like any other, and is never Safe to close.
    var s = reduce(AppState(accounts: accounts), .cloud(snap!))
    check(s.sessions["session_a5"] == nil, "an archived session Maxwell never saw stays out")
    check(s.sessions["session_a2"]?.reach == .cloud(url: "https://claude.ai/code/cshk_session_a2") && s.sessions["session_a2"]?.lastMessage == "opened PR #41", "reach is its page; the last message is Claude's note")
    let rules = GroupRules(idleAfter: 86400)
    let soon = byId["session_a2"]!.updatedAt.addingTimeInterval(60)
    check(s.group(s.sessions["session_a2"]!, now: soon, rules: rules) == .yourTurn, "a finished cloud session is Your turn, not Safe to close")
    check(s.group(s.sessions["session_a3"]!, now: soon, rules: rules) == .needsYou, "a cloud question needs you")
    let archived = CloudSnapshot(at: t0.addingTimeInterval(60), accountId: "work", sessions: snap!.sessions.filter { $0.id != "session_a2" }.map { var c = $0; if c.id == "session_a3" { c.status = .archived }; return c })
    s = reduce(s, .cloud(archived))
    check(s.sessions["session_a3"]?.phase == .ended && s.sessions["session_a2"]?.phase == .ended, "archived or gone: ended")

    // Started from Maxwell: Working at once, in the folder it started from, before any listing.
    let rec = MaxwellRecord.cloudStarted("session_b1", account: "work", title: "Fix the flaky upload test", cwd: "/tmp/orbit", from: "local-1")
    if case .cloudStarted(let id, _, let title, let cwd, let from, _)? = MaxwellRecord.parse(rec, at: t0) {
        let replayed = reduce(AppState(accounts: accounts), .cloudStarted(id, "work", title: title, cwd: cwd, from: from, at: t0))
        check(replayed.sessions["session_b1"] == nil && replayed.cloudFolders["session_b1"] == "/tmp/orbit" && replayed.cloudFrom["session_b1"] == "local-1",
              "the logged start only remembers folder and origin: replaying the log brings back no old starts")
        let started = reduce(replayed, .cloudStarting(id, "work", title: title, cwd: cwd, at: t0))
        check(started.sessions["session_b1"]?.phase == .working && started.sessions["session_b1"]?.cwd == "/tmp/orbit", "a fresh start shows at once, Working, under its folder")
    } else { check(false, "cloud-started record parses") }

    // claude agents never lists cloud sessions; its listing must not end them.
    let afterAgents = reduce(s, .agents(AgentsSnapshot(at: t0.addingTimeInterval(120), accountId: "work", entries: [])))
    check(afterAgents.sessions["session_a1"]?.phase == .working, "a local listing leaves cloud sessions alone")

    let printed = "\u{1B}[?25lCreated cloud session: Fix the flaky upload test\nView: https://claude.ai/code/session_01Abc?from=cli&m=0\nResume with: claude --teleport session_01Abc\n"
    let made = CloudParser.created(printed)
    check(made?.id == "session_01Abc" && made?.title == "Fix the flaky upload test" && made?.url == "https://claude.ai/code/session_01Abc?from=cli&m=0", "claude --cloud's output gives id, title and page")
    check(CloudParser.created("Error: --cloud cannot be combined with --print.") == nil, "an error is no session")
    check(CloudParser.repoName("git@github.com:orbit-labs/web.git") == "orbit-labs/web" && CloudParser.repoName("https://gitlab.com/a/b") == nil, "GitHub remotes name the repo")
}
