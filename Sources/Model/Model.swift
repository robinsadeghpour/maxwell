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
    /// Groups that wait on you: the rail badges count these.
    var needsHim: Bool { self == .needsYou || self == .yourTurn }
    /// Groups that start folded and open on a click on their header.
    var folds: Bool { self == .idle || self == .recentlyClosed }
}

/// A group you put a session in by hand, over Maxwell's verdict: you disagree with it.
/// Never Working: only the session itself can say it works.
enum Mark: String, CaseIterable {
    case yourTurn = "your-turn", safe, idle
    var group: PhaseGroup {
        switch self {
        case .yourTurn: return .yourTurn
        case .safe: return .safeToClose
        case .idle: return .idle
        }
    }
}

/// A mark holds until the session's next turn: then Maxwell's verdict is news again.
struct Marked: Equatable {
    var mark: Mark
    var at: Date
}

/// The clock-dependent thresholds the sidebar groups by (config: idle-after, judge).
struct GroupRules: Equatable {
    var idleAfter: TimeInterval = 24 * 3600
    /// Off: no model read, so no session is ever safe to close.
    var judge = true
    /// An agents listing older than this no longer proves the session is there and idle.
    var listingFresh: TimeInterval = 5 * 60
    static let recentlyClosed: TimeInterval = 7 * 86400
    /// A question waits longer than a finished turn before it counts as forgotten: a few days
    /// with no answer (a permission prompt left in a terminal last week) is no longer news.
    var questionIdleAfter: TimeInterval { max(idleAfter, 3 * 86400) }
}

enum Origin: Equatable { case maxwell, external }

/// How Maxwell can reach the session's terminal.
enum Reach: Equatable {
    case background(shortId: String)   // `claude attach <shortId>`
    case elsewhere(pid: Int?)          // interactive in another terminal: shown read-only
    case cloud(url: String)            // on Anthropic's cloud machines: its claude.ai/code page
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

/// A title from Maxwell's log. `replaced`: Claude's title when a model wrote this one.
struct SessionTitle: Equatable {
    var text: String
    var byYou: Bool
    var replaced: String?
}

struct Session: Equatable {
    let id: SessionID
    var name: String
    var accountId: AccountID
    var cwd: String
    var branch: String?
    /// `name` is one you gave it in Claude Code (`/rename`, `claude --name`), not a generated one.
    var nameIsYours = false
    var hookTitle: String?      // Claude Code's session_title
    var tabTitle: String?       // ~/.claude/tab-titles (an optional hook)
    var firstPrompt: String?    // the first prompt, up to 400 characters
    /// A title you gave it in Maxwell, or one a model wrote because Claude's said little.
    var named: SessionTitle?
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
    /// When Claude Code last changed that status; nil when its sessions/<pid>.json was not read.
    var statusAt: Date?
    /// Claude Code's own verdict on the last turn (background sessions only).
    var job: JobState?
    /// Why the latest listing could not check the group against Claude Code's own files; nil when it could.
    var unverified: String?
    /// When the latest turn began (a prompt hook, or the listing going busy): a job record older
    /// than this is about an earlier turn.
    var turnAt: Date?
    /// The error a turn stopped on (StopFailure), until the next turn.
    var stopFailure: String?
    /// Set while the phase is working although the turn is over: the background work it waits for.
    var waitingOn: String?
    /// Where the phase came from, in a few words: the evidence `Maxwell state` and the header show.
    var phaseSource = ""
    /// Background shells and async subagents started since the process started and not yet
    /// reported done in the transcript; nil when the transcript could not be read.
    var runningTasks: [BackgroundTask]?
    /// The last hook event from this session: proof the Maxwell hooks run in it.
    var hookSeenAt: Date?
    /// When Claude Code stopped this background session's process while it waited on you, to free
    /// memory. The conversation is kept and attaching resumes it. Nil while its process runs.
    var parkedAt: Date?
}

extension Session {
    /// What the session is about. Yours wins: the name you gave it here, then the one you gave it
    /// in Claude Code (`/rename`), whatever `Titles.auto` says. A model's shows only while the
    /// session's own title is weak. With `Titles.auto` off, what Claude Code itself shows.
    var title: String {
        if let n = named, n.byYou { return n.text }
        if nameIsYours { return name }
        if let n = named, Titles.auto && ownTitleWeak { return n.text }
        return Titles.auto ? ownTitle : hookTitle ?? name
    }
    /// Claude's title, the tab title, the first prompt's words, or the generated name.
    var ownTitle: String { hookTitle ?? tabTitle ?? promptTitle ?? name }
    /// First words of the first prompt.
    var promptTitle: String? { firstPrompt.map(Titles.fromPrompt) }
    /// True when the title is only the generated name ("acme-75"), so it says nothing about the work.
    var untitled: Bool { named == nil && !nameIsYours && hookTitle == nil && tabTitle == nil && firstPrompt == nil }
    /// A background session that leaves Claude Code's listing in one of these phases was stopped
    /// while idle (it never stops a working one), not ended: it stays where it was, parked.
    var parkable: Bool {
        guard case .background = reach else { return false }
        switch phase {
        case .yourTurn, .needsYou, .limited: return true
        case .working, .ended: return false
        }
    }
    /// The title says little about the work: none, a generated slug ("acme-75"), only generic
    /// words ("Continue Previous Task"), or the first words of the first prompt ("hi, do I need
    /// to do"). Such sessions get a model-written title.
    var weakTitle: Bool { named == nil && !nameIsYours && ownTitleWeak }
    var ownTitleWeak: Bool {
        guard let t = (hookTitle ?? tabTitle)?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return true }
        return Titles.isSlug(t) || Titles.isGeneric(t) || (firstPrompt.map { Titles.isFragment(t, of: $0) } ?? false)
    }

    init(id: SessionID, name: String, accountId: AccountID, cwd: String, at: Date, origin: Origin, reach: Reach) {
        self.init(id: id, name: name, accountId: accountId, cwd: cwd, branch: nil, hookTitle: nil, tabTitle: nil, firstPrompt: nil, named: nil,
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
    /// Titles you gave sessions, or a model wrote, by id (kept off the session: one can fold first).
    var named: [SessionID: SessionTitle] = [:]
    /// Groups you put sessions in by hand ("Not safe" is a Your turn mark). See `mark(_:)`.
    var marks: [SessionID: Marked] = [:]
    /// Sessions you pinned: listed first, under Pinned, and never closed by Close all.
    var pins: Set<SessionID> = []
    /// Suggestions you waved away, per session.
    var dismissed: [SessionID: Set<String>] = [:]
    /// What each plugin says about a session (badges, fields, checks), by session then plugin.
    var notes: [SessionID: [PluginID: PluginNote]] = [:]
    /// Display names of the plugins that are on.
    var pluginNames: [PluginID: String] = [:]
    /// Plugins that are on but not running, with why: their checks are unknown.
    var pluginDown: [PluginID: String] = [:]
    /// Cloud sessions: the folder each started from in Maxwell, and the local session it was sent from.
    var cloudFolders: [SessionID: String] = [:]
    var cloudFrom: [SessionID: SessionID] = [:]

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

    /// Your mark on a session, while it still holds: no turn has begun since you made it.
    func mark(_ s: Session) -> Marked? {
        guard let m = marks[s.id], s.turnAt.map({ $0 <= m.at }) ?? true else { return nil }
        return m
    }

    /// The sidebar group a session shows in right now: your mark, else Maxwell's verdict.
    func group(_ s: Session, now: Date, rules: GroupRules) -> PhaseGroup? {
        switch s.phase {
        case .needsYou, .yourTurn: if let m = mark(s) { return m.mark.group }
        default: break
        }
        switch s.phase {
        case .needsYou: return now.timeIntervalSince(s.lastEventAt) > rules.questionIdleAfter ? .idle : .needsYou
        case .working: return .working
        case .limited: return .limited
        case .ended: return closed[s.id].map { now.timeIntervalSince($0.at) < GroupRules.recentlyClosed } == true ? .recentlyClosed : nil
        case .yourTurn:
            let quiet = now.timeIntervalSince(s.lastEventAt) > rules.idleAfter
            // Stopped long ago: nothing runs and nothing new was said, so it folds away.
            if quiet && s.parkedAt != nil { return .idle }
            if Check.allPass(checks(s, now: now, rules: rules)) { return .safeToClose }
            return quiet ? .idle : .yourTurn
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

    /// True when no other session in another terminal, on the same account and folder, was active
    /// more recently: the only one a lone `claude` running in that folder can be.
    func isNewestInFolder(_ s: Session) -> Bool {
        !sessions.values.contains { o in
            guard o.id != s.id, o.accountId == s.accountId, o.cwd == s.cwd, o.phase != .ended, case .elsewhere = o.reach else { return false }
            return o.lastEventAt > s.lastEventAt
        }
    }
}
