import Foundation

/// Everything that changes AppState. Hook lines and usage samples come from the event
/// log; agent snapshots and done checks come from the app's own probes. Model reads,
/// closes, reopens, "Not safe" marks and project moves are Maxwell's own lines in the same log,
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
    case markedNotSafe(SessionID, at: Date)
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
    }

    enum Status: Equatable {
        case busy, idle
        case waiting(String)
    }
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
        let entries: [AgentsSnapshot.Entry] = arr.compactMap { a in
            guard let sid = a["sessionId"] as? String, let cwd = a["cwd"] as? String else { return nil }
            let kind = a["kind"] as? String
            let reach: Reach = kind == "background"
                ? .background(shortId: a["id"] as? String ?? String(sid.prefix(8)))
                : .elsewhere(pid: a["pid"] as? Int)
            let status: AgentsSnapshot.Status
            switch a["status"] as? String {
            case "busy": status = .busy
            case "waiting": status = .waiting(a["waitingFor"] as? String ?? "waiting")
            default: status = a["state"] as? String == "working" ? .busy : .idle
            }
            let started = (a["startedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } ?? at
            return .init(sessionId: sid, name: a["name"] as? String ?? String(sid.prefix(8)), cwd: cwd,
                         startedAt: started, reach: reach, status: status)
        }
        return AgentsSnapshot(at: at, accountId: accountId, entries: entries)
    }
}
