import Foundation

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static var stateDir: URL {
        if let d = ProcessInfo.processInfo.environment["MAXWELL_STATE_DIR"], !d.isEmpty { return URL(fileURLWithPath: d) }
        return home.appendingPathComponent(".local/state/maxwell")
    }
    static var eventLog: URL { stateDir.appendingPathComponent("events.jsonl") }
    static var configFile: URL {
        if let d = ProcessInfo.processInfo.environment["MAXWELL_CONFIG"], !d.isEmpty { return URL(fileURLWithPath: d) }
        return home.appendingPathComponent(".config/maxwell/config")
    }
    static let defaultConfigDir = home.appendingPathComponent(".claude")

    /// Same spelling the hook writes: no trailing slash, symlinks kept.
    static func normalize(_ path: String) -> String {
        var p = (path as NSString).expandingTildeInPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
}

typealias AccountID = String
typealias SessionID = String

struct UsageWindow: Equatable {
    var usedPercent: Double
    var resetsAt: Date
}

struct Account: Equatable {
    let id: AccountID
    var name: String
    let configDir: URL
    var fiveHour: UsageWindow?
    var week: UsageWindow?
    var sampledAt: Date?

    /// CLAUDE_CONFIG_DIR for processes on this account. The default account must run
    /// without it: Claude Code then reads ~/.claude.json instead of ~/.claude/.claude.json.
    var configDirEnv: String? { Paths.normalize(configDir.path) == Paths.normalize(Paths.defaultConfigDir.path) ? nil : configDir.path }

    /// The tighter of the two windows; nil until a sample arrives.
    var usedPercent: Double? {
        [fiveHour?.usedPercent, week?.usedPercent].compactMap { $0 }.max()
    }

    /// The reset that ends a limit right now, if the account is at a limit.
    func limitResetsAt(now: Date) -> Date? {
        [fiveHour, week].compactMap { $0 }.filter { $0.usedPercent >= 100 && $0.resetsAt > now }.map(\.resetsAt).max()
    }
}

enum Phase: Equatable {
    case working
    case needsYou(String)
    /// Stopped without asking anything: the next move is yours (read, test, reply or close).
    case yourTurn
    case limited(Date?)
    case ended
}

/// Sidebar sections, in display order. `safeToClose` and `idle` are not phases: they are
/// verdicts on a stopped session at a given time (see `AppState.group`). `recentlyClosed`
/// lists sessions Maxwell stopped in the last 7 days.
enum PhaseGroup: Int, CaseIterable {
    case needsYou, yourTurn, working, limited, safeToClose, idle, recentlyClosed
    var title: String {
        switch self {
        case .needsYou: return "Needs you"
        case .yourTurn: return "Your turn"
        case .working: return "Working"
        case .limited: return "Limited"
        case .safeToClose: return "Safe to close"
        case .idle: return "Idle"
        case .recentlyClosed: return "Recently closed"
        }
    }
    /// Groups that wait on you: the "All" view and the project badges count these.
    var needsHim: Bool { self == .needsYou || self == .yourTurn }
    /// Groups that start folded and open on a click on their header.
    var folds: Bool { self == .idle || self == .recentlyClosed }
}

/// The clock-dependent thresholds the sidebar groups by (config: idle-after, safe-after, judge).
struct GroupRules: Equatable {
    var idleAfter: TimeInterval = 24 * 3600
    var safeAfter: TimeInterval = 2 * 3600
    /// Off: no model read, so no session is ever safe to close.
    var judge = true
    /// An agents listing older than this no longer proves the session is there and idle.
    var listingFresh: TimeInterval = 5 * 60
    static let recentlyClosed: TimeInterval = 7 * 86400
}

enum Origin: Equatable { case maxwell, external }

/// How Maxwell can reach the session's terminal.
enum Reach: Equatable {
    case background(shortId: String)   // `claude attach <shortId>`
    case elsewhere(pid: Int?)          // interactive in another terminal: shown read-only
}

/// What the session's folder says about unfinished work. Facts only, nil where git could
/// not say; `AppState.checks` turns them into pass, fail or unknown.
struct DoneCheck: Equatable {
    var at: Date
    var repo: Bool               // false: not a git work tree
    var dirtyFiles: Int?         // nil: git status failed
    var unpushed: Int?           // commits on neither a remote nor the default branch; nil: rev-list failed
    var pr: PRState
    var branch: String?

    enum PRState: Equatable {
        case none(String)        // why there is no PR to wait for: default branch, no PR, no GitHub remote
        case merged(Int)
        case open(Int)
        case closed(Int)
        case unknown(String)     // gh failed
    }
}

struct Session: Equatable {
    let id: SessionID
    var name: String
    var accountId: AccountID
    var cwd: String
    var branch: String?
    var hookTitle: String?      // Claude Code's session_title
    var tabTitle: String?       // ~/.claude/tab-titles (an optional hook)
    var promptTitle: String?    // first words of the first prompt
    var phase: Phase
    var lastMessage: String?
    var contextTokens: Int?
    var lastEventAt: Date
    var startedAt: Date
    var origin: Origin
    var reach: Reach
    var doneCheck: DoneCheck?
    var transcriptPath: String?
    /// False until the first prompt: a session nobody has used yet is never "safe to close".
    var prompted = false
    /// When the session's account listing last included it, and the status it gave.
    var listedAt: Date?
    var listedStatus: AgentsSnapshot.Status?
    /// Background shells and async subagents started since the process started and not yet
    /// reported done in the transcript; nil when the transcript could not be read.
    var runningTasks: Int?
    /// The last hook event from this session: proof the Maxwell hooks run in it.
    var hookSeenAt: Date?
    /// You pressed "Not safe": it stays out of Safe to close until new activity.
    var markedNotSafeAt: Date?
}

extension Session {
    /// What the session is about, best source first.
    var title: String { hookTitle ?? tabTitle ?? promptTitle ?? name }
    /// True when the title is only the generated name ("acme-75"), so it says nothing about the work.
    var untitled: Bool { hookTitle == nil && tabTitle == nil && promptTitle == nil }

    init(id: SessionID, name: String, accountId: AccountID, cwd: String, at: Date, origin: Origin, reach: Reach) {
        self.init(id: id, name: name, accountId: accountId, cwd: cwd, branch: nil, hookTitle: nil, tabTitle: nil, promptTitle: nil,
                  phase: .yourTurn, lastMessage: nil, contextTokens: nil, lastEventAt: at, startedAt: at,
                  origin: origin, reach: reach, doneCheck: nil, transcriptPath: nil)
    }
}

struct AppState: Equatable {
    var accounts: [Account]
    var sessions: [SessionID: Session] = [:]
    /// Sessions Maxwell started; their SessionStart arrives after we know the id.
    var startedByMaxwell: Set<SessionID> = []
    /// When each account was last listed by `claude agents --json`.
    var listedAt: [AccountID: Date] = [:]
    /// Model reads of last replies, by `Reply.hash` of the message.
    var judgments: [String: Judgment] = [:]
    /// Sessions Maxwell stopped, for Undo and Recently closed.
    var closed: [SessionID: ClosedSession] = [:]
    /// Sessions you moved to another project than their folder's.
    var moved: [SessionID: String] = [:]
    /// The project a session's transcript points at, from the background scan.
    var suggested: [SessionID: String] = [:]
    /// Suggestions you waved away, per session.
    var dismissed: [SessionID: Set<String>] = [:]

    func account(_ id: AccountID) -> Account? { accounts.first { $0.id == id } }

    /// The project a session shows under: where you moved it, else its folder's.
    func project(_ s: Session, in projects: Projects) -> String { moved[s.id] ?? projects.name(for: s.cwd) }

    /// "→ Acme?" for a row: the transcript points at another project, you have not moved
    /// the session himself and has not dismissed that suggestion.
    func suggestion(_ s: Session, in projects: Projects) -> String? {
        guard moved[s.id] == nil, let p = suggested[s.id], p != projects.name(for: s.cwd), dismissed[s.id]?.contains(p) != true else { return nil }
        return p
    }

    func accountId(forConfigDir dir: String) -> AccountID? {
        let d = Paths.normalize(dir)
        return accounts.first { Paths.normalize($0.configDir.path) == d }?.id
    }

    /// The sidebar group a session shows in right now.
    func group(_ s: Session, now: Date, rules: GroupRules) -> PhaseGroup? {
        switch s.phase {
        case .needsYou: return .needsYou
        case .working: return .working
        case .limited: return .limited
        case .ended: return closed[s.id].map { now.timeIntervalSince($0.at) < GroupRules.recentlyClosed } == true ? .recentlyClosed : nil
        case .yourTurn:
            if Check.allPass(checks(s, now: now, rules: rules)) { return .safeToClose }
            return now.timeIntervalSince(s.lastEventAt) > rules.idleAfter ? .idle : .yourTurn
        }
    }

    /// Visible sessions by sidebar group, newest activity first. `only` keeps a subset (a project).
    /// Recently closed also lists stopped sessions this run of Maxwell has not seen, from their record.
    func grouped(now: Date, rules: GroupRules, only keep: (Session) -> Bool = { _ in true }) -> [(PhaseGroup, [Session])] {
        var all = sessions
        for (id, c) in closed where all[id] == nil { all[id] = c.session }
        // One verdict per session: the checks behind it are the expensive part of a render.
        var byGroup: [PhaseGroup: [Session]] = [:]
        for s in all.values where keep(s) {
            if let g = group(s, now: now, rules: rules) { byGroup[g, default: []].append(s) }
        }
        return PhaseGroup.allCases.compactMap { g in
            guard let items = byGroup[g] else { return nil }
            return (g, items.sorted { g == .recentlyClosed ? closed[$0.id]!.at > closed[$1.id]!.at : $0.lastEventAt > $1.lastEventAt })
        }
    }

    /// The account with the most 5-hour room, for small calls Maxwell makes itself.
    func most5hRoom(now: Date) -> Account? {
        accounts.filter { $0.limitResetsAt(now: now) == nil }.min { ($0.fiveHour?.usedPercent ?? 50) < ($1.fiveHour?.usedPercent ?? 50) }
    }

    /// The account with the most room left now, preferring ones with fresh samples.
    func roomiest(now: Date, excluding: AccountID? = nil) -> Account? {
        accounts.filter { $0.id != excluding && $0.limitResetsAt(now: now) == nil }
            .min { ($0.usedPercent ?? 50) < ($1.usedPercent ?? 50) }
    }
}
