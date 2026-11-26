import Foundation

typealias PluginID = String

/// `plugin.json`: everything a plugin can show, known before its program runs (docs/plugins.md).
struct PluginManifest: Equatable, Decodable {
    var id: PluginID
    var name: String
    var version: String
    var description: String?
    var `protocol`: Int
    var run: [String]
    var settings: [Setting] = []
    var actions: [ActionDecl] = []
    var panels: [PanelDecl] = []
    /// A one-colour logo (SVG, PDF or PNG) in the plugin's folder, shown beside its panels' names.
    var icon: String?
    /// The folder the manifest came from; set by discovery.
    var dir: URL = URL(fileURLWithPath: "/")
    var bundled = false

    struct Setting: Equatable, Decodable {
        enum Kind: String, Decodable { case string, bool, choice, secret }
        var key: String
        var title: String
        var type: Kind
        var `default`: String?
        var choices: [String]?
        var placeholder: String?
        var help: String?
    }
    struct ActionDecl: Equatable, Decodable {
        enum Scope: String, Decodable { case global, session }
        var id: String
        var title: String
        var scope: Scope = .global
        var shortcut: String?
        enum CodingKeys: String, CodingKey { case id, title, scope, shortcut }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            title = try c.decode(String.self, forKey: .title)
            scope = try c.decodeIfPresent(Scope.self, forKey: .scope) ?? .global
            shortcut = try c.decodeIfPresent(String.self, forKey: .shortcut)
        }
    }
    struct PanelDecl: Equatable, Decodable {
        var id: String
        var title: String
    }

    enum CodingKeys: String, CodingKey { case id, name, version, description, `protocol`, run, settings, actions, panels, icon }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decode(String.self, forKey: .version)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        `protocol` = try c.decode(Int.self, forKey: .protocol)
        run = try c.decode([String].self, forKey: .run)
        settings = try c.decodeIfPresent([Setting].self, forKey: .settings) ?? []
        actions = try c.decodeIfPresent([ActionDecl].self, forKey: .actions) ?? []
        panels = try c.decodeIfPresent([PanelDecl].self, forKey: .panels) ?? []
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
    }

    /// The logo's file, only inside the plugin's folder.
    var iconURL: URL? {
        guard let icon, !icon.isEmpty, !icon.hasPrefix("/"), !icon.split(separator: "/").contains("..") else { return nil }
        return dir.appendingPathComponent(icon)
    }

    static let protocolVersion = 1

    enum LoadError: Error, Equatable, CustomStringConvertible {
        case unreadable(String), badId(String), newerProtocol(Int), noCommand
        var description: String {
            switch self {
            case .unreadable(let why): return "plugin.json: \(why)"
            case .badId(let id): return "id \"\(id)\" may use only a-z, 0-9 and -"
            case .newerProtocol(let v): return "needs plugin protocol \(v); this Maxwell speaks \(PluginManifest.protocolVersion)"
            case .noCommand: return "run is empty"
            }
        }
    }

    static func parse(_ data: Data, dir: URL) -> Result<PluginManifest, LoadError> {
        let m: PluginManifest
        do { m = try JSONDecoder().decode(PluginManifest.self, from: data) } catch {
            return .failure(.unreadable(Self.describe(error)))
        }
        guard !m.id.isEmpty, m.id.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }) else { return .failure(.badId(m.id)) }
        guard m.protocol <= protocolVersion else { return .failure(.newerProtocol(m.protocol)) }
        guard !m.run.isEmpty else { return .failure(.noCommand) }
        var out = m
        out.dir = dir
        return .success(out)
    }

    private static func describe(_ e: Error) -> String {
        switch e {
        case DecodingError.keyNotFound(let k, _): return "missing \"\(k.stringValue)\""
        case DecodingError.typeMismatch(_, let c), DecodingError.valueNotFound(_, let c):
            return "wrong type at \(c.codingPath.map(\.stringValue).joined(separator: "."))"
        case DecodingError.dataCorrupted: return "not valid JSON"
        default: return "\(e)"
        }
    }

    /// Plugins found in the folders, user ones first; a user plugin replaces a bundled one with the same id.
    /// Folders without a readable manifest come back as failures, so Settings can say why.
    static func discover(user: URL, bundled: URL?) -> (found: [PluginManifest], broken: [(dir: URL, why: LoadError)]) {
        var found: [PluginID: PluginManifest] = [:], broken: [(URL, LoadError)] = []
        for (root, isBundled) in [(bundled, true), (Optional(user), false)] {
            guard let root, let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let file = dir.appendingPathComponent("plugin.json")
                guard let data = try? Data(contentsOf: file) else { continue }
                switch parse(data, dir: dir) {
                case .success(var m): m.bundled = isBundled; found[m.id] = m
                case .failure(let why): broken.append((dir, why))
                }
            }
        }
        return (found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }, broken)
    }
}

/// What one plugin says about one session (`session/annotate`). Each one replaces the last.
struct PluginNote: Equatable {
    var at: Date
    var badges: [Badge] = []
    var fields: [Field] = []
    var checks: [CheckNote] = []
    /// The plugin's session actions that apply now; nil: all of them.
    var actions: [String]?

    enum Tone: String { case neutral, info, good, warn, bad }
    struct Badge: Equatable { var text: String; var tone: Tone; var tooltip: String?; var action: String? }
    struct Field: Equatable { var label: String; var value: String; var url: String? }
    struct CheckNote: Equatable { var id: String; var title: String; var outcome: Check.Outcome; var detail: String; var source: String }

    var isEmpty: Bool { badges.isEmpty && fields.isEmpty && checks.isEmpty }

    /// Parses `session/annotate` params; the session id comes back separately.
    static func parse(_ p: [String: Any], at: Date) -> (SessionID, PluginNote)? {
        guard let sid = p["session"] as? String, !sid.isEmpty else { return nil }
        let list = { (k: String) in (p[k] as? [[String: Any]]) ?? [] }
        let str = { (d: [String: Any], k: String) in (d[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        var n = PluginNote(at: at)
        n.badges = list("badges").compactMap { d in
            str(d, "text").map { Badge(text: String($0.prefix(60)), tone: str(d, "tone").flatMap(Tone.init) ?? .neutral, tooltip: str(d, "tooltip"), action: str(d, "action")) }
        }
        n.fields = list("fields").compactMap { d in
            guard let l = str(d, "label"), let v = str(d, "value") else { return nil }
            return Field(label: l, value: v, url: str(d, "url"))
        }
        n.checks = list("checks").compactMap { d in
            guard let id = str(d, "id"), let t = str(d, "title") else { return nil }
            // An outcome the host can't read is unknown, never a pass.
            return CheckNote(id: id, title: t, outcome: str(d, "outcome").flatMap(Check.Outcome.init) ?? .unknown,
                             detail: str(d, "detail") ?? "no detail", source: str(d, "source") ?? "plugin")
        }
        n.actions = (p["actions"] as? [Any])?.compactMap { $0 as? String }
        return (sid, n)
    }
}

/// A plugin panel's content (`panel/set`), drawn with Maxwell's own rows.
enum PluginView: Equatable {
    case loading(String?)
    case empty(title: String, body: String?, action: Button?)
    case list([Section])

    struct Button: Equatable { var action: String; var title: String }
    struct Row: Equatable {
        var id: String
        var title: String
        var subtitle: String?
        var badge: PluginNote.Badge?
        var session: SessionID?
        var url: String?
        var actions: [Button]
        /// Where the item stands, in the words every plugin shares; drawn with the session glyphs.
        var status: ItemStatus? = nil
        /// A short identifier drawn dim before the title in its own column ("TIN-33").
        var key: String? = nil
    }
    /// A plugin item's status (issue #1): the host picks glyph and colour, plugins never do.
    enum ItemStatus: String {
        case needsYou, inSession, owed, readyToClose, done
        /// The session glyph that says the same thing.
        var glyph: PhaseGroup {
            switch self {
            case .needsYou: return .needsYou
            case .inSession: return .working
            case .readyToClose: return .yourTurn
            case .owed: return .limited
            case .done: return .safeToClose
            }
        }
    }
    struct Section: Equatable { var title: String; var rows: [Row] }

    static func parse(_ v: [String: Any]) -> PluginView? {
        let str = { (d: [String: Any], k: String) in (d[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let button = { (d: [String: Any]?) -> Button? in
            guard let d, let a = str(d, "action"), let t = str(d, "title") else { return nil }
            return Button(action: a, title: t)
        }
        switch v["type"] as? String {
        case "loading": return .loading(str(v, "title"))
        case "empty": return .empty(title: str(v, "title") ?? "Nothing here", body: str(v, "body"), action: button(v["action"] as? [String: Any]))
        case "list":
            let sections = ((v["sections"] as? [[String: Any]]) ?? []).map { s in
                Section(title: str(s, "title") ?? "", rows: ((s["rows"] as? [[String: Any]]) ?? []).compactMap { r in
                    guard let id = str(r, "id"), let title = str(r, "title") else { return nil }
                    let b = (r["badge"] as? [String: Any]).flatMap { d in
                        str(d, "text").map { PluginNote.Badge(text: $0, tone: str(d, "tone").flatMap(PluginNote.Tone.init) ?? .neutral, tooltip: nil, action: nil) }
                    }
                    return Row(id: id, title: title, subtitle: str(r, "subtitle"), badge: b, session: str(r, "session"), url: str(r, "url"),
                               actions: ((r["actions"] as? [[String: Any]]) ?? []).compactMap { button($0) },
                               status: str(r, "status").flatMap(ItemStatus.init), key: str(r, "key"))
                })
            }
            return .list(sections)
        default: return nil
        }
    }
}

/// How a plugin is doing, from Maxwell's side (process) and the plugin's own `status`.
struct PluginStatus: Equatable {
    enum Run: Equatable {
        case off                     // disabled in the config
        case starting
        case running
        case stopped(String)         // crashed or failed; restarting
        case failed(String)          // gave up after repeated failures; Restart in Settings
    }
    enum Reported: String { case ok, loading, setup, offline, error }
    var run: Run = .starting
    var reported: Reported?
    var message: String?

    var isRunning: Bool { run == .running }
    /// One short line for Settings and panel headers.
    var line: String {
        switch run {
        case .off: return "Off"
        case .starting: return "Starting…"
        case .stopped(let why): return "Stopped: \(why). Restarting…"
        case .failed(let why): return "Stopped: \(why)"
        case .running:
            switch reported {
            case nil, .ok?: return message ?? "Running"
            case .loading?: return message ?? "Loading…"
            case .setup?: return message ?? "Needs setup"
            case .offline?: return message ?? "Offline"
            case .error?: return message ?? "Error"
            }
        }
    }
}

extension AppState {
    /// Plugin checks for one session, with Maxwell's rules applied: a plugin that isn't running
    /// can't vouch, and a check from before the session's last activity is old evidence.
    func pluginChecks(_ s: Session) -> [Check] {
        guard let byPlugin = notes[s.id] else { return [] }
        var out: [Check] = []
        for (pid, note) in byPlugin.sorted(by: { $0.key < $1.key }) {
            let name = pluginNames[pid] ?? pid
            let down = pluginDown[pid]
            for c in note.checks {
                var check = Check(kind: .plugin, outcome: c.outcome, detail: c.detail, source: "\(name): \(c.source)", name: c.title)
                if let down { check.outcome = .unknown; check.detail = "\(name) isn't running (\(down))" }
                else if note.at < s.lastEventAt { check.outcome = .unknown; check.detail = "checked before the last activity" }
                out.append(check)
            }
        }
        return out
    }
}
