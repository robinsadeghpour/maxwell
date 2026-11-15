import Foundation

// ./build.sh test. Fixtures are anonymised conversations shaped like two weeks of real Slack.

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok { failures += 1; print("FAIL line \(line): \(what)") }
}
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let t0 = Date(timeIntervalSince1970: 1_767_603_600)  // 2026-01-05 09:00 UTC
func ts(_ minutes: Double) -> String { String(format: "%.6f", t0.timeIntervalSince1970 + minutes * 60) }
let me = "U_ME"
let users: [String: Person] = ["U_ME": Person(name: "Me", kind: .member), "U_A": Person(name: "Teammate A", kind: .member),
                               "U_B": Person(name: "Teammate B", kind: .member), "U_C": Person(name: "Customer C", kind: .external),
                               "B_1": Person(name: "Bot", kind: .bot)]
func snap(_ cs: [Conversation]) -> Snapshot { Snapshot(me: me, workspace: "https://example.slack.com/", team: "T1", users: users, conversations: cs) }
func msg(_ m: Double, _ u: String, _ text: String, thread: Double? = nil, reactions: [Reaction] = []) -> Message {
    Message(ts: ts(m), user: u, text: text, threadTs: thread.map(ts), reactions: reactions, mentions: WebSource.mentions(in: text))
}
let now = t0.addingTimeInterval(6 * 3600)

// MARK: words

check(Rules.classify("danke!") == .thanks, "danke is thanks")
check(Rules.classify("ok cool, thanks a lot") == .thanks, "short thanks")
check(Rules.classify("kannst du dir das mal anschauen?") == .request, "German request")
check(Rules.classify("the export page throws a 500 since this morning") == .bug, "bug words")
check(Rules.classify("checkout geht nicht mehr") == .bug, "German bug")
check(Rules.classify("wann ist das live?") == .question, "German question")
check(Rules.classify("is the new build out") == .question, "question without a mark")
check(Rules.classify("downloaded it") != .bug, "down inside a word isn't a bug")
check(Rules.classify("<https://example.com/x>") == .fyi, "bare link is FYI")
check(Rules.classify("haha") == .thanks, "laugh is an ack")
check(Rules.plain("hey <@U_A> see <https://x.io/a|the doc> &amp; <https://y.io/b>", users: users) == "hey @Teammate A see the doc & y.io",
      "markup to plain text")

// MARK: rules

let dmQuestion = Conversation(id: "D1", kind: .dm, name: "dm-1", messages: [
    msg(0, "U_A", "hey"), msg(1, "U_A", "can you check why the invoice total is off?"),
])
var w = Rules.waiting(snap([dmQuestion]), now: now)
check(w.count == 1 && w.first?.kind == .request && w.first?.count == 2, "a DM burst is one ask: \(w)")
check(w.first?.since == t0, "waiting since the first message of the burst")
check(w.first?.link == "https://example.slack.com/archives/D1/p\(ts(1).replacingOccurrences(of: ".", with: ""))", "links the ask itself")

let dmAnswered = Conversation(id: "D2", kind: .dm, name: "dm-2", messages: [
    msg(0, "U_A", "can you check the invoice?"), msg(30, me, "done, fixed it"), msg(31, "U_A", "danke!"),
])
check(Rules.waiting(snap([dmAnswered]), now: now).isEmpty, "a thanks after my answer doesn't wait")

let dmReacted = Conversation(id: "D3", kind: .dm, name: "dm-3", messages: [
    msg(0, "U_A", "shipped the new onboarding, fyi", reactions: [Reaction(name: "eyes", users: [me])]),
])
check(Rules.waiting(snap([dmReacted]), now: now).isEmpty, "FYI doesn't wait")
let dmReactedQuestion = Conversation(id: "D4", kind: .dm, name: "dm-4", messages: [
    msg(0, "U_A", "do we still need the old webhook?", reactions: [Reaction(name: "eyes", users: [me])]),
])
check(Rules.waiting(snap([dmReactedQuestion]), now: now).map(\.state) == [.owed], "👀 on a question: I owe the answer")
var dmChecked = dmReactedQuestion
dmChecked.messages[0].reactions = [Reaction(name: "white_check_mark", users: [me])]
check(Rules.waiting(snap([dmChecked]), now: now).isEmpty, "✅ on a yes/no question answers it")
let dmAck = Conversation(id: "D7", kind: .dm, name: "dm-7", messages: [
    msg(0, "U_A", "can you unlock the new workspace?"), msg(2, me, "on it"),
])
check(Rules.waiting(snap([dmAck]), now: now).map(\.state) == [.owed], "\"on it\" makes it owed, not waiting")
var dmAckThanks = dmAck
dmAckThanks.messages.append(msg(3, "U_A", "thx!"))
check(Rules.waiting(snap([dmAckThanks]), now: now).map(\.state) == [.owed], "a thanks for my \"on it\" still leaves it owed")
dmAckThanks.messages.append(msg(30, "U_A", "never mind, figured it out"))
check(Rules.waiting(snap([dmAckThanks]), now: now).isEmpty, "\"figured it out\" closes it")
var dmBump = dmAck
dmBump.messages.append(msg(90, "U_A", "any news here?"))
w = Rules.waiting(snap([dmBump]), now: now)
check(w.map(\.state) == [.waiting] && w.first?.bumped == true, "a bump after my ack waits again, flagged: \(w)")
let dmWhat = Conversation(id: "D8", kind: .dm, name: "dm-8", messages: [
    msg(0, "U_A", "can you add the missing API secret?"), msg(3, me, "what"),
])
check(Rules.waiting(snap([dmWhat]), now: now).map(\.state) == [.waiting], "\"what\" doesn't answer")
check(Rules.oneLine("token: xoxp-1234567890-abcdefghijk", users: users) == "token: •••", "secrets never show")
check(Rules.oneLine("any news here? :eyes: call at 10:30:00", users: users) == "any news here? call at 10:30:00", "emoji codes dropped, times kept")

let channelNoMention = Conversation(id: "C1", kind: .channel, name: "#general", messages: [
    msg(0, "U_A", "anyone know why staging is slow?"),
])
check(Rules.waiting(snap([channelNoMention]), now: now).isEmpty, "a channel question to everyone isn't mine")

let channelMention = Conversation(id: "C2", kind: .channel, name: "#dev", messages: [
    msg(0, "U_A", "<@U_ME> the deploy failed again, can you look?"),
    msg(5, "U_B", "on it too"),
])
w = Rules.waiting(snap([channelMention]), now: now)
check(w.count == 1 && w.first?.who == "Teammate A" && w.first?.kind == .bug, "a mention with a bug waits even if others talk after: \(w)")
check(w.first?.ask == "the deploy failed again, can you look?", "ask reads as plain text, without the leading mention of me")

let mentionThenChatter = Conversation(id: "C9", kind: .channel, name: "#dev", messages: [
    msg(0, "U_A", "<@U_ME> can you review the export PR?", thread: 0), msg(5, "U_B", "I can look at the tests", thread: 0),
    msg(30, "U_B", "anyone know why staging is slow?"),
])
w = Rules.waiting(snap([mentionThenChatter]), now: now)
check(w.map(\.key) == ["C9:\(ts(0))"], "a mention that opened a thread is listed once, as the thread: \(w.map(\.key))")

let thread = Conversation(id: "C3", kind: .channel, name: "#support", external: true, messages: [
    msg(0, "U_C", "the dashboard shows no data for yesterday", thread: 0),
    msg(10, me, "looking, which store?", thread: 0),
    msg(20, "U_C", "the second one, any news?", thread: 0),
])
w = Rules.waiting(snap([thread]), now: now)
check(w.count == 1 && w.first?.whoKind == .external && w.first?.place == "#support thread", "a customer answering me in a thread waits: \(w)")
check(w.first?.link.hasSuffix("/archives/C3/p\(ts(0).replacingOccurrences(of: ".", with: ""))") == true, "a bumped thread links its first ask, which opens the thread")

let threadOthers = Conversation(id: "C4", kind: .channel, name: "#dev", messages: [
    msg(0, "U_A", "should we move the cron to 6am?", thread: 0),
    msg(10, me, "fine by me", thread: 0),
    msg(20, "U_B", "what about the reports though?", thread: 0),
    msg(25, "U_A", "good point, reports first", thread: 0),
])
check(Rules.waiting(snap([threadOthers]), now: now).isEmpty, "others talking among themselves after me isn't mine")

let bot = Conversation(id: "D5", kind: .dm, name: "dm-bot", messages: [msg(0, "B_1", "Your build failed, please check")])
check(Rules.waiting(snap([bot]), now: now).isEmpty, "bots never wait on me")

let topWithThread = Conversation(id: "D6", kind: .dm, name: "dm-6", messages: [
    msg(0, "U_A", "can you review my PR?", thread: 0), msg(5, me, "yes, done", thread: 0),
])
check(Rules.waiting(snap([topWithThread]), now: now).isEmpty, "a DM question answered in its thread is answered")

let sorted = Rules.waiting(snap([dmQuestion, channelMention, thread]), now: now)
check(sorted.map(\.whoKind).first == .external && sorted[1].kind == .bug, "customers first, then bugs, then oldest")

let wqPrompt = Rules.waiting(snap([dmQuestion]), now: now)[0]

// MARK: marks

var marks = Marks()
let item = Rules.waiting(snap([dmQuestion]), now: now)[0]
marks.mark(item, .handled, now: now)
check(Rules.waiting(snap([dmQuestion]), marks: marks, now: now).isEmpty, "handled hides it")
var later = dmQuestion
later.messages.append(msg(60, "U_A", "also, can you resend the invite?"))
check(Rules.waiting(snap([later]), marks: marks, now: now).count == 1, "a new message brings a handled item back")
marks = Marks()
marks.mark(item, .snoozed, until: now.addingTimeInterval(3600), now: now)
check(Rules.waiting(snap([dmQuestion]), marks: marks, now: now).isEmpty, "snoozed hides it")
check(Rules.waiting(snap([dmQuestion]), marks: marks, now: now.addingTimeInterval(7200)).count == 1, "snooze ends")
marks = Marks()
let threadItem = Rules.waiting(snap([thread]), now: now)[0]
marks.mark(threadItem, .notForMe, now: now)
var threadLater = thread
threadLater.messages.append(msg(40, "U_C", "still nothing showing", thread: 0))
check(Rules.waiting(snap([threadLater]), marks: marks, now: now).isEmpty, "not for me stays hidden without a mention")
threadLater.messages.append(msg(41, "U_C", "<@U_ME> can you check?", thread: 0))
check(Rules.waiting(snap([threadLater]), marks: marks, now: now).count == 1, "a mention brings a not-for-me item back")
let url = FileManager.default.temporaryDirectory.appendingPathComponent("slack-marks-\(getpid()).json")
try marks.save(url)
check(Marks.load(url) == marks, "marks survive a restart")
try? FileManager.default.removeItem(at: url)

// MARK: panel

let v = Panel.view(Rules.waiting(snap([dmQuestion, thread]), now: now), health: .ok(checked: now), now: now)
let sections = v["sections"] as? [[String: Any]] ?? []
check(v["type"] as? String == "list" && sections.count == 2, "two sections: answer first, then the rest")
check((sections.first?["title"] as? String) == "Answer first", "bugs, customers and bumps first")
let row = (sections.first?["rows"] as? [[String: Any]])?.first ?? [:]
check(row["subtitle"] as? String == "5h · #support thread", "row says how long and where: \(row["subtitle"] ?? "")")
check(row["title"] as? String == "Customer C · the dashboard shows no data for yesterday", "after a bump the row shows the first ask: \(row["title"] ?? "")")
check(row["url"] as? String == Rules.waiting(snap([thread]), now: now)[0].link, "clicking the row opens the message")
check(((row["actions"] as? [[String: String]])?.first?["action"]) == "start-session", "starting a session is the first button")
check(Panel.view([], health: .ok(checked: now), now: now)["title"] as? String == "Nobody is waiting on you", "empty state")
check(Panel.view([], health: .setup("x"), now: now)["type"] as? String == "empty", "setup state")
check(Panel.view([], health: .loading, now: now)["type"] as? String == "loading", "loading state")
check(JSONSerialization.isValidJSONObject(v), "panel view is JSON")

// MARK: session loop

check(Panel.prompt(wqPrompt, context: ["Teammate A: hi"]).contains("Don't post, react or draft anything in Slack yourself"), "sessions are told not to write in Slack")
check(Panel.prompt(wqPrompt, context: [], demo: true).hasPrefix("This is a made-up test message"), "demo sessions don't go looking in real Slack")

let linkAt = t0.addingTimeInterval(30 * 60)
let link = Links.Link(session: "S1", at: linkAt, who: "Teammate A", place: "DM", url: "https://example.slack.com/x")
check(Loop.replied(snap([dmQuestion]), key: "D1:top", after: linkAt) == false, "no reply after the session started")
var dmReplied = dmQuestion
dmReplied.messages.append(msg(90, me, "fixed, works again"))
check(Loop.replied(snap([dmReplied]), key: "D1:top", after: linkAt) == true, "my message after the session started is the reply")
check(Loop.replied(snap([dmReplied]), key: "D1:\(ts(0))", after: linkAt) == false, "a top-level reply doesn't answer a thread")
check(Loop.replied(snap([]), key: "D1:top", after: linkAt) == nil, "a conversation Slack didn't return is unknown, never a pass")
let wq = Rules.waiting(snap([dmQuestion]), now: now)[0]
check(Loop.status(wq, link: nil, group: nil, replied: nil) == .needsYou, "no link: needs you")
check(Loop.status(wq, link: link, group: "working", replied: false) == .inSession, "linked, session working: in session")
check(Loop.status(wq, link: link, group: "yourTurn", replied: false) == .readyToClose, "linked, session done, no reply: reply and close")
check(Loop.status(wq, link: link, group: "yourTurn", replied: true) == .done, "replied: done")
check(Loop.status(wq, link: link, group: nil, replied: false) == .needsYou, "session gone: back to needs you")
let ann = Loop.annotation(session: "S1", link: link, replied: false, checkedAt: now)
let annCheck = (ann["checks"] as? [[String: String]])?.first ?? [:]
check(annCheck["id"] == "replied-slack" && annCheck["outcome"] == "fail" && annCheck["detail"] == "Teammate A is still waiting (DM)", "the check holds the session until I've replied: \(annCheck)")
check((Loop.annotation(session: "S1", link: link, replied: nil, checkedAt: nil)["checks"] as? [[String: String]])?.first?["outcome"] == "unknown", "unknown stays unknown")
check((Loop.annotation(session: "S1", link: link, replied: true, checkedAt: now)["checks"] as? [[String: String]])?.first?["outcome"] == "pass", "a reply passes the check")
let lv = Panel.view([wq], health: .ok(checked: now), linked: ["D1:top": Panel.Linked(status: .readyToClose, session: "S1", group: "yourTurn")], now: now)
let lsec = (lv["sections"] as? [[String: Any]]) ?? []
let lrow = (lsec.first?["rows"] as? [[String: Any]])?.first ?? [:]
check(lsec.first?["title"] as? String == "Session done, reply", "a finished session's item comes first")
check(lrow["session"] as? String == "S1" && lrow["status"] as? String == "readyToClose", "the row points at its session")
check((lrow["actions"] as? [[String: String]])?.first?["title"] == "Reply in Slack", "the first button replies")
check(Panel.count([wq], linked: ["D1:top": Panel.Linked(status: .inSession, session: "S1", group: "working")]) == 0, "an item a session works on isn't counted")
check(Panel.count([wq], linked: ["D1:top": Panel.Linked(status: .readyToClose, session: "S1", group: "yourTurn")]) == 1, "but it counts again once the session is done")
var links = Links(byKey: ["D1:top": link])
links.prune(sessions: ["S2"], before: t0)
check(links.byKey.isEmpty, "links to closed sessions go")

// MARK: read-only client

var sent: [String] = []
let recorder = SlackAPI { method, _ in sent.append(method); return Data(#"{"ok":true}"#.utf8) }
for m in ["chat.postMessage", "chat.scheduleMessage", "reactions.add", "chat.update", "chat.delete", "conversations.mark", "drafts.create"] {
    do { _ = try recorder.call(m); check(false, "\(m) must throw") } catch { check(error as? SlackError == .notReadOnly, "\(m) refused") }
}
check(sent.isEmpty, "a refused method never reaches the network")
let writeVerbs = ["post", "add", "remove", "update", "delete", "set", "create", "schedule", "mark", "invite", "join", "kick", "archive", "open", "close", "rename"]
check(ReadOnly.methods.allSatisfy { m in !writeVerbs.contains { m.split(separator: ".").last!.lowercased().hasPrefix($0) } }, "every allowed method reads")
let sources = try FileManager.default.contentsOfDirectory(at: dir.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources"), includingPropertiesForKeys: nil)
for f in sources {
    let text = try String(contentsOf: f, encoding: .utf8)
    for bad in ["chat.post", "chat.schedule", "reactions.add", "chat.update", "chat.delete", "drafts."] {
        check(!text.contains("\"" + bad), "\(f.lastPathComponent) names a write method \(bad)")
    }
}
check(Manifest.userScopes.allSatisfy { $0.hasSuffix(":read") || $0.hasSuffix(":history") }, "the app asks only for read scopes")
check(Manifest.createAppURL.hasPrefix("https://api.slack.com/apps?new_app=1&manifest_json=%7B"), "create-app link carries the manifest")

// MARK: web source against recorded responses

let api = (try? Data(contentsOf: dir.appendingPathComponent("api.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
var calls: [String] = []
let replay = SlackAPI { method, params in
    calls.append(method + (params["query"].map { " " + $0 } ?? "") + (params["channel"].map { " " + $0 } ?? ""))
    let key = method == "search.messages" ? "search.messages " + (params["query"]!.split(separator: " ").first.map(String.init) ?? "")
        : method == "conversations.history" || method == "conversations.replies" ? method + " " + params["channel"]!
        : method == "users.info" ? "users.info " + params["user"]! : method
    let body = api[key] ?? ["ok": false, "error": "no_fixture:\(key)"]
    return try JSONSerialization.data(withJSONObject: body)
}
do {
    let s = try WebSource(api: replay).fetch(since: Date(timeIntervalSince1970: 1_767_000_000))
    check(s.me == "U_ME" && s.workspace == "https://example.slack.com/", "auth.test gives me and the workspace")
    check(s.conversations.map(\.id).sorted() == ["C_SUPPORT", "D_A"], "searches find the DM and the channel thread: \(s.conversations.map(\.id))")
    check(s.users["U_C"]?.kind == .external, "a user from another team is external")
    let ws = Rules.waiting(s, now: Date(timeIntervalSince1970: 1_767_610_000))
    check(ws.map(\.key).sorted() == ["C_SUPPORT:1767603600.000100", "D_A:top"], "API path ends in the same rules: \(ws.map(\.key))")
    check(!calls.contains { $0.hasPrefix("conversations.history C_SUPPORT") }, "a channel without a mention: only its thread is read")
} catch {
    check(false, "web source replay: \(error)")
}

// MARK: fixtures from real patterns

if let data = try? Data(contentsOf: dir.appendingPathComponent("conversations.json")) {
    let f = try JSONDecoder().decode(FixtureFile.self, from: data)
    let s = f.snapshot
    let latest = s.conversations.flatMap(\.messages).map(\.date).max() ?? Date()
    let got = Rules.waiting(s, now: latest.addingTimeInterval(1800))
    var tp = 0, fp = 0, fn = 0, tn = 0, owedOK = 0, owedMissed = 0
    for e in f.expected ?? [] {
        let here = got.filter { $0.key.hasPrefix(e.conversation + ":") }
        let at = Date(timeIntervalSince1970: Double(e.ts) ?? 0)
        let waits = here.contains { $0.state == .waiting && $0.lastTs >= e.ts && $0.since <= at }
        if e.state == "owed" {
            if here.contains(where: { $0.state == .owed }) && !waits { owedOK += 1 } else { owedMissed += 1; print("  owed missed: \(e.conversation) \(e.why ?? "")") }
            continue
        }
        switch (e.waiting, waits) {
        case (true, true): tp += 1
        case (false, true): fp += 1; print("  extra: \(e.conversation) \(e.why ?? "") -> \(here.map(\.reason))")
        case (true, false): fn += 1; print("  missed: \(e.conversation) \(e.why ?? "")")
        case (false, false): tn += 1
        }
    }
    print("fixtures: \(tp) found, \(fn) missed, \(fp) extra, \(tn) left out, owed \(owedOK) right / \(owedMissed) wrong")
    check(owedMissed == 0, "owed items in the fixtures")
    check(fn == 0, "no missed asks in the fixtures")
    check(fp == 0, "no extra items in the fixtures")
}

print(failures == 0 ? "all slack tests passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
