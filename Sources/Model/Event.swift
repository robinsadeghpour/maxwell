import Foundation

/// Everything that changes AppState. Hook lines and usage samples come from the event
/// log; agent snapshots and done checks come from the app's own probes. Model reads,
/// closes, reopens, marks, pins and project moves are Maxwell's own lines in the same log,
/// so they survive a restart and leave an audit trail.
enum Event: Equatable {
    case hook(Hook)
    case usage(UsageSample)
    case agents(AgentsSnapshot)
    case doneCheck(SessionID, DoneCheck)
    case started(SessionID, AccountID, name: String, cwd: String, shortId: String, at: Date)
    case judged(hash: String, Judgment)
    case closed(ClosedSession)
    case reopened(SessionID, at: Date)
    /// You put a session in a group by hand ("Not safe" marks it Your turn); nil hands it back to Maxwell.
    case marked(SessionID, Mark?, at: Date)
    /// You pinned (true) or unpinned a session.
    case pinned(SessionID, Bool)
    /// You moved a session to another project; nil moves it back to its folder's project.
    case movedToProject(SessionID, String?)
    /// What the session's transcript points at (see `ProjectHints`); nil when nothing stands out.
    case projectSuggested(SessionID, String?)
    case suggestionDismissed(SessionID, project: String)
    /// You renamed a session, or a model titled one whose own title said little; empty text clears yours.
    case titled(SessionID, SessionTitle)
    /// A plugin's annotation of a session (docs/plugins.md); nil clears it. In memory only.
    case annotated(PluginID, SessionID, PluginNote?)
    /// A plugin is on; `down` says why it isn't running right now, nil while it runs.
    case pluginState(PluginID, name: String, down: String?)
    /// A plugin was turned off or removed: its notes and checks go with it.
    case pluginOff(PluginID)
}

struct Hook: Equatable {
    var at: Date
    var configDir: String
    var sessionId: SessionID
    var cwd: String?
    var transcriptPath: String?
    var kind: Kind
    /// The Claude Code process the hook ran for (hooks from Maxwell 0.1.24 on).
    var pid: Int? = nil

    enum Kind: Equatable {
        case sessionStart(source: String)
        case promptSubmitted(prompt: String, title: String?)
        case stopped(lastMessage: String?)
        case stopFailed(error: String)
        case notification(type: String, message: String)
        case sessionEnd(reason: String)
    }
}

struct UsageSample: Equatable {
    var at: Date
    var configDir: String
    var sessionId: SessionID?
    var fiveHour: UsageWindow?
    var week: UsageWindow?
    var contextTokens: Int?
}

/// One `claude agents --json` listing for one account: the live sessions right now.
struct AgentsSnapshot: Equatable {
    var at: Date
    var accountId: AccountID
    var entries: [Entry]
    /// Background sessions with no process, by short id: stopped, conversation kept; `claude attach`
    /// resumes them. Ones waiting on you are entries too; finished ones only `--all` lists, as done.
    var stopped: [SessionID: String] = [:]

    struct Entry: Equatable {
        var sessionId: SessionID
        var name: String
        var cwd: String
        var startedAt: Date
        var reach: Reach
        var status: Status
        var title: String?
        var lastMessage: String?
        var lastActiveAt: Date?   // last prompt or reply in the transcript
        var firstPrompt: String?  // for sessions that predate the hooks and have no title
        var used = false          // has a transcript, so someone prompted it
        var runningTasks: [BackgroundTask]?    // background tasks started since startedAt and not reported done; nil: no transcript
        var pid: Int? = nil
        /// When Claude Code last changed `status` (its sessions/<pid>.json); nil when that file was not read.
        var statusAt: Date? = nil
        /// Claude Code's own record of a background session's last turn (jobs/<id>/state.json).
        var job: JobState? = nil
        /// Set when Claude Code's own files for this session could not be read: its group then rests
        /// on the listing and the reply alone. Says which file.
        var unverified: String? = nil
    }

    /// What the Claude Code process is doing, as it writes it in sessions/<pid>.json.
    enum Status: Equatable {
        /// A turn is running, or a subagent it started.
        case busy
        /// The turn is over and nothing runs.
        case idle
        /// The turn is over; only background shells it started still run.
        case shell
        /// A permission prompt, question or other dialog waits for an answer.
        case waiting(String)
    }
}

/// Claude Code's own verdict on a background session's last turn, from jobs/<id>/state.json.
/// It reads the reply when the turn ends, like Maxwell does, and says what the session needs.
struct JobState: Equatable {
    /// working | blocked | done | failed | stopped
    var state: String
    /// active: a turn runs; idle; blocked: waits on the user.
    var tempo: String?
    /// What it needs from the user, in its own words ("approve the deploy in the dashboard, then tell me").
    var needs: String?
    /// One line on where it stands.
    var detail: String?
    /// Background work still running that will report back: shells, agents, monitors.
    /// Watchers that only wait for files (artifact_watch) and scheduled wakes don't count.
    var work: Int
    var updatedAt: Date?

}

// MARK: parsing (the only place raw JSON is trusted)

enum EventParser {
    /// Parses one line of events.jsonl. Returns nil for lines Maxwell does not use.
    static func parse(line: Substring) -> Event? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ts = obj["ts"] as? Double else { return nil }
        let at = Date(timeIntervalSince1970: ts / 1000)
        if let m = obj["maxwell"] as? [String: Any] { return MaxwellRecord.parse(m, at: at) }
        guard let configDir = obj["configDir"] as? String else { return nil }
        if let h = obj["hook"] as? [String: Any] {
            let pid = (obj["pid"] as? NSNumber)?.intValue
            return parseHook(h, at: at, configDir: configDir).map { var h = $0; h.pid = pid.flatMap { $0 > 0 ? $0 : nil }; return .hook(h) }
        }
        if let u = obj["usage"] as? [String: Any] { return .usage(parseUsage(u, at: at, configDir: configDir)) }
        return nil
    }

    static func parseHook(_ h: [String: Any], at: Date, configDir: String) -> Hook? {
        guard let sid = h["session_id"] as? String, let name = h["hook_event_name"] as? String else { return nil }
        let kind: Hook.Kind
        switch name {
        case "SessionStart": kind = .sessionStart(source: h["source"] as? String ?? "startup")
        case "UserPromptSubmit":
            kind = .promptSubmitted(prompt: String((h["prompt"] as? String ?? "").prefix(400)), title: h["session_title"] as? String)
        case "Stop": kind = .stopped(lastMessage: (h["last_assistant_message"] as? String).map { String($0.suffix(2000)) })
        case "StopFailure": kind = .stopFailed(error: h["error"] as? String ?? h["error_type"] as? String ?? "unknown")
        case "Notification":
            kind = .notification(type: h["notification_type"] as? String ?? "", message: h["message"] as? String ?? "")
        case "SessionEnd": kind = .sessionEnd(reason: h["reason"] as? String ?? "")
        default: return nil
        }
        return Hook(at: at, configDir: configDir, sessionId: sid, cwd: h["cwd"] as? String,
                    transcriptPath: h["transcript_path"] as? String, kind: kind)
    }

    static func parseUsage(_ u: [String: Any], at: Date, configDir: String) -> UsageSample {
        func window(_ key: String) -> UsageWindow? {
            guard let rl = u["rate_limits"] as? [String: Any], let w = rl[key] as? [String: Any],
                  let pct = (w["used_percentage"] as? NSNumber)?.doubleValue,
                  let reset = (w["resets_at"] as? NSNumber)?.doubleValue else { return nil }
            return UsageWindow(usedPercent: pct, resetsAt: Date(timeIntervalSince1970: reset))
        }
        let ctx = u["context_window"] as? [String: Any]
        let tokens = (ctx?["total_input_tokens"] as? NSNumber)?.intValue
        return UsageSample(at: at, configDir: configDir, sessionId: u["session_id"] as? String,
                           fiveHour: window("five_hour"), week: window("seven_day"), contextTokens: tokens)
    }

    /// Parses `claude agents --json` output for one account.
    static func parseAgents(_ data: Data, accountId: AccountID, at: Date) -> AgentsSnapshot? {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var stopped: [SessionID: String] = [:]
        let entries: [AgentsSnapshot.Entry] = arr.compactMap { a in
            guard let sid = a["sessionId"] as? String, let cwd = a["cwd"] as? String else { return nil }
            let kind = a["kind"] as? String
            if kind == "background", a["pid"] == nil {
                // No process. "stopped" (`claude stop`) and "failed" ended for good. Claude Code's idle
                // stop leaves "done", which only `--all` lists, and keeps a waiting one listed as it was.
                let state = a["state"] as? String
                if state == "stopped" || state == "failed" { return nil }
                stopped[sid] = a["id"] as? String ?? String(sid.prefix(8))
                if state == "done" { return nil }
            }
            let reach: Reach = kind == "background"
                ? .background(shortId: a["id"] as? String ?? String(sid.prefix(8)))
                : .elsewhere(pid: a["pid"] as? Int)
            // `state` is the job's verdict on its last turn, not what the process does now:
            // "working" with status "idle" is a session that thinks more is coming, sitting idle.
            // A job with no process has no status: nothing runs.
            let status = parseStatus(a["status"] as? String, waitingFor: a["waitingFor"] as? String) ?? .idle
            let started = (a["startedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } ?? at
            return .init(sessionId: sid, name: a["name"] as? String ?? String(sid.prefix(8)), cwd: cwd,
                         startedAt: started, reach: reach, status: status, pid: (a["pid"] as? NSNumber)?.intValue)
        }
        return AgentsSnapshot(at: at, accountId: accountId, entries: entries, stopped: stopped)
    }

    /// Claude Code's process status. `claude agents --json` folds "shell" into "busy";
    /// sessions/<pid>.json keeps it. An unknown word counts as busy, as Claude Code's own listing does.
    static func parseStatus(_ s: String?, waitingFor: String?) -> AgentsSnapshot.Status? {
        switch s {
        case nil: return nil
        case "idle": return .idle
        case "shell": return .shell
        case "waiting": return .waiting(waitingFor ?? "waiting")
        default: return .busy
        }
    }

    /// One sessions/<pid>.json: the process's status and when it last changed, if it runs `sessionId`.
    static func parsePidFile(_ data: Data, sessionId: SessionID) -> (status: AgentsSnapshot.Status, at: Date?)? {
        guard let p = try? JSONSerialization.jsonObject(with: data) as? [String: Any], p["sessionId"] as? String == sessionId,
              let status = parseStatus(p["status"] as? String, waitingFor: p["waitingFor"] as? String) else { return nil }
        let at = (p["statusUpdatedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return (status, at)
    }

    /// One jobs/<id>/state.json.
    static func parseJob(_ data: Data) -> JobState? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let state = j["state"] as? String else { return nil }
        func text(_ v: Any?) -> String? {
            guard let s = (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return String(s.prefix(300))
        }
        // An AskUserQuestion dialog says exactly what it asks.
        let question = ((j["block"] as? [String: Any])?["questions"] as? [[String: Any]])?.first.flatMap { text($0["question"]) }
        // Real work (shells, agents, workflows, monitors) is listed in `fan` until it is done; file
        // watchers are not, and are counted in `drainableMonitors` instead (records from 15 Nov 2026:
        // {"tasks":2,"kinds":["artifact_watch"],"drainableMonitors":2}, fan empty). `kinds` lists each kind once.
        var work = 0
        let f = j["inFlight"] as? [String: Any]
        if let fan = j["fan"] as? [[String: Any]], !fan.isEmpty {
            work = fan.filter { $0["doneAt"] == nil || $0["doneAt"] is NSNull }.count
        } else if let f {
            let tasks = (f["tasks"] as? NSNumber)?.intValue ?? 0
            let watchers = (f["drainableMonitors"] as? NSNumber)?.intValue ?? 0
            let crons = ((f["kinds"] as? [String]) ?? []).contains("session_cron") ? 1 : 0
            work = max(0, tasks - watchers - crons)
        }
        if (f?["tasks"] as? NSNumber)?.intValue == 0 { work = 0 }
        let updated = (j["updatedAt"] as? String).flatMap { iso.date(from: $0) ?? isoPlain.date(from: $0) }
        return JobState(state: state, tempo: j["tempo"] as? String, needs: question ?? text(j["needs"]),
                        detail: text(j["detail"]), work: work, updatedAt: updated)
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()
}
