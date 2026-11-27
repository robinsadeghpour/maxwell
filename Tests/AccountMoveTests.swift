import Foundation

/// A limited session continued on another account (`AccountMove`): the same row moves with it.
/// Claude Code 2.1.332 lists a `claude stop`ped session as "stopped" on its old account, which
/// Maxwell reads as not listed, and the resumed one as running on the new account.
func accountMoveTests() {
    let id = "4c1f0d2e-1111-4000-8000-00000000a0a0", short = "4c1f0d2e"
    func listing(_ acct: AccountID, at: Double, _ status: AgentsSnapshot.Status?) -> Event {
        let entries = status.map { [AgentsSnapshot.Entry(sessionId: id, name: "stop-churn", cwd: "/tmp/acme", startedAt: t0,
                                                          reach: .background(shortId: short), status: $0)] } ?? []
        return .agents(AgentsSnapshot(at: t0.addingTimeInterval(at), accountId: acct, entries: entries))
    }
    var st = reduce(AppState(accounts: accounts), listing("work", at: 1, .idle))
    st.sessions[id]?.phase = .limited(t0.addingTimeInterval(3600))
    st.sessions[id]?.transcriptPath = "/Users/me/.claude/projects/-tmp-acme/\(id).jsonl"
    // On its way: the old account stops it. Its end hook and the listing without it don't end or park the row.
    st = reduce(st, .moving(id, to: "work2"))
    st = reduce(st, .hook(Hook(at: t0.addingTimeInterval(5), configDir: home.appendingPathComponent(".claude").path, sessionId: id,
                               cwd: "/tmp/acme", transcriptPath: nil, kind: .sessionEnd(reason: "other"))))
    st = reduce(st, listing("work", at: 6, nil))
    check(st.sessions[id]?.phase == .limited(t0.addingTimeInterval(3600)) && st.sessions[id]?.parkedAt == nil,
          "while it moves, the old account ending its process leaves the row where it was")
    st = reduce(st, .started(id, "work2", name: "stop-churn", cwd: "/tmp/acme", shortId: short, at: t0.addingTimeInterval(10)))
    check(st.sessions[id]?.phase == .working && st.sessions[id]?.movingTo == nil, "started on work2 with \"continue\": Working there, no longer at the old limit")
    check(st.sessions[id]?.accountId == "work2" && st.sessions[id]?.reach == .background(shortId: short), "continued on work2: the same row, now on work2")
    check(st.sessions[id]?.transcriptPath == nil, "the old account's transcript path goes: work2's own copy is read from now on")
    st = reduce(st, listing("work", at: 12, nil))
    check(st.sessions[id]?.phase != .ended && st.sessions[id]?.accountId == "work2", "the old account no longer listing it doesn't end the moved session")
    st = reduce(st, listing("work2", at: 14, .busy))
    check(st.sessions[id]?.accountId == "work2" && st.sessions[id]?.parkedAt == nil, "the new account lists it running")
    check(st.sessions.values.filter { $0.id == id }.count == 1 && st.sessions.count == 1, "one row, no copy")
    st = reduce(st, listing("work", at: 20, nil))
    check(st.sessions[id]?.accountId == "work2" && st.sessions[id]?.phase != .ended, "later listings of the old account leave it alone")

    // Moved back again: the account that starts it last has it.
    st = reduce(st, .started(id, "work", name: "stop-churn", cwd: "/tmp/acme", shortId: short, at: t0.addingTimeInterval(30)))
    st = reduce(st, listing("work2", at: 32, nil))
    check(st.sessions[id]?.accountId == "work" && st.sessions[id]?.phase != .ended, "moved back: on work again, not ended by work2's listing")

    // A move that failed: the mark goes and the old account's listings speak for it again.
    var back = reduce(AppState(accounts: accounts), listing("work", at: 1, .idle))
    back = reduce(back, .moving(id, to: "work2"))
    back = reduce(back, .moving(id, to: nil))
    back = reduce(back, listing("work", at: 3, .idle))
    check(back.sessions[id]?.accountId == "work" && back.sessions[id]?.movingTo == nil, "a failed move leaves it on its own account")

    // Where limited work goes: never an account whose usage Maxwell hasn't read.
    var room = AppState(accounts: accounts)
    check(room.roomiestToContinue(now: t0) == nil, "no usage read yet: nowhere to continue")
    room = reduce(room, .usage(UsageSample(at: t0, configDir: home.appendingPathComponent(".claude-work2").path, sessionId: nil,
                                          fiveHour: UsageWindow(usedPercent: 20, resetsAt: t0.addingTimeInterval(3600)), week: nil,
                                          contextTokens: nil, contextPercent: nil)))
    check(room.roomiestToContinue(now: t0)?.id == "work2", "the one account with a reading and room")
    check(room.roomiestToContinue(now: t0, excluding: "work2") == nil, "excluding it leaves none")
}
