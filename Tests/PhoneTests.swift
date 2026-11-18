import CryptoKit
import Foundation

/// The phone bridge's pure parts (docs/phone.md): boxes the relay's Node reference can open and
/// make, pairing codes, the command log, transcript items, the state payload and push news.
func phoneTests() {
    let dir = fixtures.deletingLastPathComponent().appendingPathComponent("phone")
    phoneBoxTests(dir)
    phonePairingTests(dir)
    chatItemTests(dir)
    phoneStateTests()
}

private func phoneBoxTests(_ dir: URL) {
    guard let data = try? Data(contentsOf: dir.appendingPathComponent("noble-boxes.json")),
          let f = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let k = (f["k"] as? String).flatMap(Base64URL.decode) else { return check(false, "noble-boxes.json fixture readable") }
    let keys = PhoneKeys(pairingKey: k)
    let raw = { (key: SymmetricKey) in Base64URL.encode(key.withUnsafeBytes { Data($0) }) }
    check(raw(keys.macToPhone) == f["macToPhone"] as? String && raw(keys.phoneToMac) == f["phoneToMac"] as? String,
          "HKDF keys match @noble/hashes")
    let pair = PhoneBox.open(f["phoneToMacBox"] as? String ?? "", key: keys.phoneToMac)
    check(pair?["t"] as? String == "pair" && pair?["name"] as? String == "Test iPhone", "a box @noble/ciphers sealed opens here")
    let paired = PhoneBox.open(f["macToPhoneBox"] as? String ?? "", key: keys.macToPhone)
    check((paired?["mac"] as? [String: Any])?["name"] as? String == "Test Mac", "the other direction opens too")
    check(PhoneBox.open(f["phoneToMacBox"] as? String ?? "", key: keys.macToPhone) == nil, "the wrong direction's key doesn't open it")

    let box = PhoneBox.seal(["t": "ack", "id": "c1", "ok": true, "url": "https://claude.ai/artifact/x"], key: keys.macToPhone)
    let back = box.flatMap { PhoneBox.open($0, key: keys.macToPhone) }
    check(back?["id"] as? String == "c1" && back?["url"] as? String == "https://claude.ai/artifact/x", "seal then open round-trips")
    check(box.map { !$0.contains("=") && !$0.contains("+") && !$0.contains("/") } == true, "boxes are base64url without padding")
    var tampered = Array(Base64URL.decode(box ?? "") ?? Data())
    if !tampered.isEmpty { tampered[tampered.count - 1] ^= 1 }
    check(PhoneBox.open(Base64URL.encode(Data(tampered)), key: keys.macToPhone) == nil, "a changed box doesn't open")

    let link = PairLink(relay: "wss://relay.example/x", mac: "bWFjLWlkLWZpeHR1cmUx", key: k, name: "Robin's Mac & co")
    check(PairLink.parse(link.url) == link, "pair link round-trips")
    check(link.url.hasPrefix("maxwell://pair?v=1&relay=wss%3A%2F%2Frelay.example%2Fx&mac="), "relay is encoded in the link")
}

private func phonePairingTests(_ dir: URL) {
    guard let data = try? Data(contentsOf: dir.appendingPathComponent("noble-boxes.json")),
          let f = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let k = (f["k"] as? String).flatMap(Base64URL.decode), let box = f["phoneToMacBox"] as? String else { return }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var codes = PairingCodes()
    _ = codes.make(now: now)
    _ = codes.make(now: now, key: k)
    check(codes.spend(box: box, from: "someone-else-phone", now: now) == nil, "a pair box only counts for the phone it names")
    check(codes.spend(box: box, from: "UGhvbmVJZEZpeHR1cmUx", now: now.addingTimeInterval(60))?.key == k, "the code whose key opens the box pairs")
    check(codes.spend(box: box, from: "UGhvbmVJZEZpeHR1cmUx", now: now.addingTimeInterval(61)) == nil, "a code is spent by the first pairing")
    var late = PairingCodes()
    _ = late.make(now: now, key: k)
    check(late.current(now: now.addingTimeInterval(599)) != nil, "a code shows for 10 minutes")
    check(late.spend(box: box, from: "UGhvbmVJZEZpeHR1cmUx", now: now.addingTimeInterval(601)) == nil && late.current(now: now.addingTimeInterval(601)) == nil,
          "a code expires after 10 minutes")

    // Replay protection: n only rises per phone, ts within 5 minutes (10 for pair).
    let ms = { (d: Date) in Int(d.timeIntervalSince1970 * 1000) }
    check(ReplayGuard.check(["t": "cmd", "n": 8, "ts": ms(now)], lastSeen: 7, now: now) == .fresh, "a fresh message is accepted")
    check(ReplayGuard.check(["t": "cmd", "n": 7, "ts": ms(now)], lastSeen: 7, now: now) == .replayed(n: 7, last: 7), "a replayed box is dropped")
    check(ReplayGuard.check(["t": "cmd", "n": 3, "ts": ms(now)], lastSeen: 7, now: now) == .replayed(n: 3, last: 7), "an older n is dropped")
    check(ReplayGuard.check(["t": "cmd", "n": 9, "ts": ms(now.addingTimeInterval(-301))], lastSeen: 7, now: now) == .stale(seconds: 301), "a stale ts is dropped")
    check(ReplayGuard.check(["t": "cmd", "n": 9, "ts": ms(now.addingTimeInterval(400))], lastSeen: 7, now: now) == .stale(seconds: 400), "a ts from the future too")
    check(ReplayGuard.check(["t": "cmd"], lastSeen: 0, now: now) == .missing, "a message without n and ts is dropped")
    check(ReplayGuard.checkPair(["t": "pair", "ts": ms(now.addingTimeInterval(-540))], now: now) == .fresh
            && ReplayGuard.checkPair(["t": "pair", "ts": ms(now.addingTimeInterval(-660))], now: now) == .stale(seconds: 660), "pair: no n, ts within 10 minutes")

    check(PhoneConnection.allowHash("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "allow hashes are hex SHA-256 of the id")
    let control = PhoneConnection.control(phones: ["abc"], pairing: true)
    check(control["allow"] as? [String] == [PhoneConnection.allowHash("abc")] && control["pairing"] as? Bool == true, "the relay control frame")

    let relay = Config.defaultPhoneRelay
    check(!PhoneConnection.wanted(relay: relay, pairedPhones: 0, codeShowing: false), "no phone and no code: no connection")
    check(PhoneConnection.wanted(relay: relay, pairedPhones: 0, codeShowing: true), "a code on screen connects")
    check(PhoneConnection.wanted(relay: relay, pairedPhones: 1, codeShowing: false), "a paired phone keeps it connected")
    check(!PhoneConnection.wanted(relay: nil, pairedPhones: 2, codeShowing: true), "phone-relay = off never connects")

    var log = CommandLog()
    if case .new = log.seen("c1") {} else { check(false, "an unknown command id is new") }
    log.start("c1")
    if case .running = log.seen("c1") {} else { check(false, "a command id in flight is running") }
    log.finish("c1", ack: ["t": "ack", "id": "c1", "ok": true])
    if case .answered(let a) = log.seen("c1") { check(a["ok"] as? Bool == true, "a repeated id gets the first answer") } else { check(false, "answered") }
    for i in 0..<CommandLog.size { log.finish("x\(i)", ack: [:]) }
    if case .new = log.seen("c1") {} else { check(false, "only the last 500 ids are remembered") }
}

private func chatItemTests(_ dir: URL) {
    guard let text = try? String(contentsOf: dir.appendingPathComponent("transcript.jsonl"), encoding: .utf8) else {
        return check(false, "transcript.jsonl fixture readable")
    }
    let lines = text.split(separator: "\n")
    let items = ChatParser.recent(lines, cwd: "/Users/me/projects/lumen")
    let kinds = items.map { ($0.json["k"] as? String ?? "?") + ":" + (($0.json["tool"] as? String) ?? "") }
    check(kinds == ["you:", "claude:", "tool:Read", "tool:Edit", "tool:Bash", "tool:Write", "tool:Artifact", "artifact:", "note:", "you:", "note:",
                    "claude:", "tool:Bash"], "transcript items in order, meta, thinking and subagent lines left out: \(kinds)")
    check(items.first == .you("Add passkey sign-in to lumen. Keep the password flow.", at: "2026-11-18T10:01:00.000Z"), "your prompt with its time")
    check(items[3] == .tool(id: "toolu_edit", tool: "Edit", summary: "src/auth/passkeys.ts", added: 2, removed: 1, status: nil),
          "an Edit folds in its result's added and removed lines, path relative to the folder")
    check(items[4] == .tool(id: "toolu_test1", tool: "Bash", summary: "npm test", added: nil, removed: nil, status: .failed), "a failed command")
    check(items[5].json["added"] as? Int == 3, "a new file counts its lines as added")
    check(items[7] == .artifact(url: "https://claude.ai/artifact/LumenPasskeyPlan01", title: "Passkey rollout plan"), "a published artifact with its title")
    check(items[8] == .note("Interrupted", at: "2026-11-18T10:09:00.000Z") && items[9] == .you("/rename passkeys", at: "2026-11-18T10:10:00.000Z"),
          "an interruption is a note, a slash command reads as typed")
    check(items.last == .tool(id: "toolu_test2", tool: "Bash", summary: "npm test -- --watch=false", added: nil, removed: nil, status: .running),
          "a command with no result yet is running")
    check(!items.contains(.artifact(url: "https://claude.ai/artifact/LumenPasskeyPlan01", title: nil)), "the same artifact named again right after isn't repeated")

    // The phone's artifact list: every artifact a transcript published or named, with its title and newest time.
    var ledger = ArtifactLedger()
    for line in lines { ledger.read(line) }
    let plan = ledger.entries["https://claude.ai/artifact/LumenPasskeyPlan01"]
    check(ledger.entries.count == 1 && plan?.title == "Passkey rollout plan", "one artifact, titled from its publish")
    check(plan.map { Int($0.at.timeIntervalSince1970) } == 1_794_996_720, "its time is the newest line that names it (10:12)")

    // Live: lines one at a time, the result comes back under the call's id.
    var p = ChatParser(cwd: "/Users/me/projects/lumen")
    let call = lines.firstIndex { $0.contains("\"id\":\"toolu_test1\"") }!
    check(p.read(lines[call]) == [.tool(id: "toolu_test1", tool: "Bash", summary: "npm test", added: nil, removed: nil, status: .running)], "a live call shows as running")
    check(p.read(lines[call + 1]).first?.id == "toolu_test1", "its result replaces it by id")
    check(ChatParser.recent(lines, cwd: "/x", limit: 2).count == 2, "only the newest items")
}

private func phoneStateTests() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var st = AppState(accounts: accounts)
    st.accounts[0].fiveHour = UsageWindow(usedPercent: 80, resetsAt: now.addingTimeInterval(3600))
    st.accounts[1].fiveHour = UsageWindow(usedPercent: 100, resetsAt: now.addingTimeInterval(1800))
    st.accounts[2].fiveHour = UsageWindow(usedPercent: 20, resetsAt: now.addingTimeInterval(7200))
    func session(_ id: String, _ phase: Phase, reach: Reach = .background(shortId: "ab12"), status: AgentsSnapshot.Status? = nil) -> Session {
        var s = Session(id: id, name: id, accountId: "work", cwd: "/Users/me/projects/lumen", at: now.addingTimeInterval(-60), origin: .maxwell, reach: reach)
        s.phase = phase
        s.listedStatus = status
        s.listedAt = now
        return s
    }
    st.sessions["perm"] = session("perm", .needsYou("approve Bash: npm run db:migrate -- --env staging"), status: .waiting("permission prompt"))
    st.sessions["hook"] = session("hook", .needsYou("Claude needs your permission to use Write"))
    st.sessions["q"] = session("q", .needsYou("Should I also update the docs?"), reach: .elsewhere(pid: 42), status: .waiting("input needed"))
    var lim = session("lim", .limited(now.addingTimeInterval(1800)))
    lim.accountId = "work2"
    lim.contextPercent = 130
    st.sessions["lim"] = lim
    st.sessions["run"] = session("run", .working, reach: .cloud(url: "https://claude.ai/code/x"))

    let input = PhoneState.Input(state: st, rules: GroupRules(idleAfter: 86400), projects: Projects(rules: []), pinned: ["lumen"],
                                 folders: [ProjectFolder(project: "orbit", path: "/Users/me/projects/orbit", lastUsed: nil),
                                           ProjectFolder(project: "lumen", path: "/Users/me/projects/lumen", lastUsed: now),
                                           ProjectFolder(project: "lumen", path: "/Users/me/projects/lumen", lastUsed: now)],
                                 webSignedIn: ["private"], artifacts: [PhoneArtifact(url: "https://claude.ai/artifact/LumenPasskeyPlan01", title: "Plan", session: "perm", account: "work", at: now)],
                                 macName: "Test Mac", rev: 7, now: now)
    let p = PhoneState.payload(input)
    let sessions = p["sessions"] as? [[String: Any]] ?? []
    let byId = Dictionary(sessions.map { ($0["id"] as? String ?? "", $0) }, uniquingKeysWith: { a, _ in a })
    check(p["t"] as? String == "state" && p["rev"] as? Int == 7 && sessions.count == 5, "state carries every listed session")
    check(byId["perm"]?["group"] as? String == "needsYou", "groups use the protocol's names")
    check(NSDictionary(dictionary: byId["perm"]?["ask"] as? [String: Any] ?? [:])
            .isEqual(to: ["kind": "permission", "tool": "Bash", "detail": "npm run db:migrate -- --env staging"]), "Claude Code's words give the tool and the command")
    check((byId["hook"]?["ask"] as? [String: Any])?["tool"] as? String == "Write", "a permission hook's words give the tool")
    check((byId["q"]?["ask"] as? [String: Any])?["kind"] as? String == "question" && byId["q"]?["reach"] as? String == "terminal", "a question; a terminal session is read-only")
    check(byId["run"]?["reach"] as? String == "cloud" && byId["run"]?["ask"] is NSNull, "cloud reach, no ask while working")
    check(byId["lim"]?["limitResetsAt"] as? String == PhoneState.iso.string(from: now.addingTimeInterval(1800)) && byId["lim"]?["contextPercent"] as? Int == 100,
          "limited sessions say when the limit resets; context is clamped to 100")
    let accts = p["accounts"] as? [[String: Any]] ?? []
    check(accts.filter { $0["mostRoom"] as? Bool == true }.map { $0["id"] as? String } == ["private"], "exactly one account has the most room")
    check(accts.first { $0["id"] as? String == "work2" }?["limited"] as? Bool == true, "an account at its limit is limited")
    check(accts.first { $0["id"] as? String == "private" }?["webSignedIn"] as? Bool == true, "claude.ai sign-in per account")
    let projects = p["projects"] as? [[String: Any]] ?? []
    check(projects.map { $0["name"] as? String } == ["lumen", "orbit"] && projects.first?["pinned"] as? Bool == true, "projects once per folder, pinned first")
    check(JSONSerialization.isValidJSONObject(p), "the payload is plain JSON")

    let counts = PhoneState.counts(st, rules: GroupRules(idleAfter: 86400), now: now)
    check(counts["needsYou"] == 3 && counts["working"] == 1 && counts["limited"] == 1, "counts per group for widgets")

    var planner = PushPlanner()
    check(planner.news(st, rules: GroupRules(idleAfter: 86400), now: now).isEmpty, "the first look after launch pushes nothing")
    st.sessions["new"] = session("new", .needsYou("Deploy to staging now?"))
    let news = planner.news(st, rules: GroupRules(idleAfter: 86400), now: now)
    check(news.map(\.0.id) == ["new"], "a new Needs you is news")
    check(planner.news(st, rules: GroupRules(idleAfter: 86400), now: now).isEmpty, "the same question isn't pushed twice")
    let msg = PushPlanner.message(to: "ExponentPushToken[x]", session: st.sessions["perm"]!, ask: PhoneAsk.of(st.sessions["perm"]!)!, counts: counts, now: now, detail: .full)
    check(msg["body"] as? String == "Run npm run db:migrate -- --env staging?" && msg["categoryId"] as? String == "permission" && msg["threadId"] as? String == "perm",
          "a permission push asks the question the prompt asks (full detail)")
    let hidden = PushPlanner.message(to: "ExponentPushToken[x]", session: st.sessions["perm"]!, ask: PhoneAsk.of(st.sessions["perm"]!)!, counts: counts, now: now)
    check(hidden["title"] as? String == "Maxwell" && hidden["body"] as? String == "A session needs you", "pushes say nothing about the session until the phone asks for full detail")

    check(Config.parse("").phoneRelayURL == Config.defaultPhoneRelay && Config.parse("").phoneRelay == nil, "Maxwell's relay unless the config names one")
    check(Config.parse("phone-relay = off\n").phoneRelayURL == nil && Config.parse("phone-relay =\n").phoneRelayURL == nil, "phone-relay = off, or empty, turns the phone off")
    check(Config.parse("phone-relay = ws://127.0.0.1:8787\n").phoneRelayURL == "ws://127.0.0.1:8787", "a config's relay wins")

    let usage = #"{"ts":1800000000000,"configDir":"/Users/me/.claude","usage":{"session_id":"perm","context_window":{"total_input_tokens":90000,"used_percentage":45}}}"#
    let folded = reduce(st, EventParser.parse(line: Substring(usage))!)
    check(folded.sessions["perm"]?.contextPercent == 45, "the status line's used_percentage is the session's context")
}
