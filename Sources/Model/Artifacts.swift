import Foundation

/// A claude.ai artifact page: claude.ai/artifact/<id> or claude.ai/code/artifact/<uuid>.
/// Which claude.ai login can see it depends on the account that made it, so a link is always
/// opened for one account.
struct ArtifactLink: Hashable {
    let url: URL
    /// The last path part: the short id or the uuid.
    let id: String

    private static let re = try! NSRegularExpression(pattern: #"https://claude\.ai/(?:code/)?artifact/([A-Za-z0-9_\-]{8,})"#)

    /// The link in `s` when `s` is one (surrounding brackets, quotes and punctuation are ignored).
    static func parse(_ s: String) -> ArtifactLink? { all(in: s).first }

    /// Every artifact link in a piece of text, in order, without repeats.
    static func all(in text: String) -> [ArtifactLink] {
        guard text.contains("claude.ai/") else { return [] }
        let ns = text as NSString
        var seen = Set<String>(), out: [ArtifactLink] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let s = ns.substring(with: m.range)
            guard let u = URL(string: s), seen.insert(s).inserted else { continue }
            out.append(ArtifactLink(url: u, id: ns.substring(with: m.range(at: 1))))
        }
        return out
    }
}

/// What the viewer shows for a session: a file on disk, or an artifact on claude.ai.
enum ViewerItem: Equatable {
    case file(URL)
    case artifact(ArtifactLink, title: String?)

    var file: URL? { if case .file(let u) = self { return u }; return nil }
    var artifact: ArtifactLink? { if case .artifact(let a, _) = self { return a }; return nil }

    /// Same file or same artifact, whatever title it carries.
    func same(as o: ViewerItem?) -> Bool {
        switch (self, o) {
        case (.file(let a), .file(let b)?): return a == b
        case (.artifact(let a, _), .artifact(let b, _)?): return a == b
        default: return false
        }
    }
}

/// An artifact a transcript line points at, and whether it was published again (reload in place).
struct ArtifactSighting: Equatable {
    var link: ArtifactLink
    var title: String?
    /// A new version of an artifact that already existed: the viewer reloads it if it shows it.
    var republished = false
}

enum ArtifactTranscript {
    /// The artifact one transcript line points at:
    /// - the Artifact tool's result after a publish (url + version; `updated` is a republish) or an `open`,
    /// - the same results in the older text-only shape ("Published … at <url> (Version 2 …", "Updated the Artifact at …"),
    /// - a Claude Docs result (its frame's artifactUrl),
    /// - a link the assistant names in its own text.
    /// Links inside other tools' results (Linear, Bash, Read) or the Artifact tool's read/list are not
    /// things the session made or showed, so they are ignored.
    static func sighting(inLine s: String) -> ArtifactSighting? {
        guard s.contains("claude.ai/"), s.contains("artifact/"),
              let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
              let msg = obj["message"] as? [String: Any] else { return nil }
        let type = obj["type"] as? String
        if type == "user" {
            if let r = obj["toolUseResult"] as? [String: Any], let u = r["url"] as? String, let link = ArtifactLink.parse(u) {
                if r["version"] is String || r["seq"] != nil {
                    return ArtifactSighting(link: link, title: r["title"] as? String, republished: r["updated"] as? Bool == true)
                }
                if r["opened"] != nil { return ArtifactSighting(link: link, title: r["title"] as? String) }
                return nil
            }
            guard let content = msg["content"] as? [[String: Any]] else { return nil }
            for c in content where c["type"] as? String == "tool_result" {
                let text = (c["content"] as? String)
                    ?? (c["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? ""
                if let hit = textResult(text) { return hit }
            }
            return nil
        }
        guard type == "assistant", let content = msg["content"] as? [[String: Any]] else { return nil }
        var found: ArtifactSighting?
        for c in content where c["type"] as? String == "text" {
            if let link = ArtifactLink.all(in: c["text"] as? String ?? "").last { found = ArtifactSighting(link: link) }
        }
        return found
    }

    /// The Artifact tool's result text, and a Claude Docs result's frame.
    static func textResult(_ text: String) -> ArtifactSighting? {
        let head = text.prefix(600)
        if head.hasPrefix("Published ") || head.hasPrefix("Opened the Artifact at ") || head.hasPrefix("Created ") {
            return ArtifactLink.parse(String(head)).map { ArtifactSighting(link: $0) }
        }
        if head.hasPrefix("Updated the Artifact at ") {
            return ArtifactLink.parse(String(head)).map { ArtifactSighting(link: $0, republished: true) }
        }
        if let r = text.range(of: "\"artifactUrl\":\""), let link = ArtifactLink.parse(String(text[r.upperBound...].prefix(120))) {
            return ArtifactSighting(link: link)
        }
        return nil
    }
}

/// What a settled claude.ai artifact page shows. claude.ai answers 200 for everything and draws its
/// states in the page; the artifact itself renders in an iframe, so the page's own text stays short.
enum ArtifactPage {
    enum Verdict: Equatable { case artifact, signedOut, noAccess, other }

    /// Nil while the page is still drawing.
    static func classify(path: String, title: String, body: String, frames: Int) -> Verdict? {
        let b = body.lowercased()
        if path.hasPrefix("/login") || b.contains("sign in to view this page") || title.hasPrefix("Sign in") { return .signedOut }
        let missing = ["not found", "doesn't exist", "does not exist", "don't have access", "do not have access",
                       "no access", "isn't available", "is not available", "been deleted", "couldn't find", "could not find"]
        if body.count < 400, missing.contains(where: b.contains) { return .noAccess }
        guard path.contains("/artifact/") else { return .other }
        return frames > 0 ? .artifact : nil
    }
}

// MARK: browser per account

/// Where "Open in browser" sends an account's links: a browser, optionally one of its profiles
/// or (Firefox family) containers. Config: `browser = <account> <browser> [profile|container <name>]`.
struct BrowserChoice: Equatable {
    enum Kind: String { case app, profile, container }
    var browser: String
    var kind: Kind = .app
    var name = ""

    static let systemDefault = BrowserChoice(browser: "default")

    /// "zen", "zen profile Work", "zen container Claude Tinkers 2", "chrome profile Profile 1".
    static func parse(_ s: String) -> BrowserChoice? {
        let parts = s.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        guard let b = parts.first?.lowercased(), b == "default" || KnownBrowser.byID[b] != nil else { return nil }
        guard parts.count == 3, let k = Kind(rawValue: parts[1].lowercased()), k != .app else { return BrowserChoice(browser: b) }
        return BrowserChoice(browser: b, kind: k, name: parts[2].trimmingCharacters(in: .whitespaces))
    }

    var line: String { kind == .app ? browser : "\(browser) \(kind.rawValue) \(name)" }

    /// "Zen · Claude Tinkers 2", "Chrome · Robin", "Default browser".
    func title(profileName: (String) -> String = { $0 }) -> String {
        guard let b = KnownBrowser.byID[browser] else { return "Default browser" }
        switch kind {
        case .app: return b.title
        case .profile: return "\(b.title) · \(profileName(name))"
        case .container: return "\(b.title) · \(name) container"
        }
    }
}

/// Browsers Maxwell knows how to open in a profile or container.
struct KnownBrowser {
    enum Family { case firefox, chromium, other }
    let id: String, title: String, bundleID: String, family: Family
    /// Under ~/Library/Application Support: profiles.ini (Firefox family) or Local State (Chromium).
    let support: String?

    static let all: [KnownBrowser] = [
        KnownBrowser(id: "zen", title: "Zen", bundleID: "app.zen-browser.zen", family: .firefox, support: "zen"),
        KnownBrowser(id: "firefox", title: "Firefox", bundleID: "org.mozilla.firefox", family: .firefox, support: "Firefox"),
        KnownBrowser(id: "chrome", title: "Chrome", bundleID: "com.google.Chrome", family: .chromium, support: "Google/Chrome"),
        KnownBrowser(id: "brave", title: "Brave", bundleID: "com.brave.Browser", family: .chromium, support: "BraveSoftware/Brave-Browser"),
        KnownBrowser(id: "edge", title: "Edge", bundleID: "com.microsoft.edgemac", family: .chromium, support: "Microsoft Edge"),
        KnownBrowser(id: "vivaldi", title: "Vivaldi", bundleID: "com.vivaldi.Vivaldi", family: .chromium, support: "Vivaldi"),
        KnownBrowser(id: "arc", title: "Arc", bundleID: "company.thebrowser.Browser", family: .other, support: nil),
        KnownBrowser(id: "safari", title: "Safari", bundleID: "com.apple.Safari", family: .other, support: nil),
    ]
    static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    // Firefox family: profiles.ini and containers.json.

    /// Profile names from profiles.ini, in file order.
    static func firefoxProfiles(ini: String) -> [String] {
        sections(ini).filter { $0.name.hasPrefix("Profile") }.compactMap { $0.values["Name"] }
    }

    /// The folder of the profile the browser opens by default (the Install section's, else Default=1), relative to the ini.
    static func firefoxDefaultProfile(ini: String) -> String? {
        let s = sections(ini)
        if let p = s.first(where: { $0.name.hasPrefix("Install") })?.values["Default"] { return p }
        return s.first { $0.name.hasPrefix("Profile") && $0.values["Default"] == "1" }?.values["Path"]
    }

    /// Container names from containers.json. The four built-in ones have no name (the browser
    /// localises them by id), or an l10n id in older files.
    static func firefoxContainers(json: Data) -> [String] {
        guard let o = try? JSONSerialization.jsonObject(with: json) as? [String: Any], let ids = o["identities"] as? [[String: Any]] else { return [] }
        let byID = [1: "Personal", 2: "Work", 3: "Banking", 4: "Shopping"]
        let byL10n = ["userContextPersonal.label": "Personal", "userContextWork.label": "Work",
                      "userContextBanking.label": "Banking", "userContextShopping.label": "Shopping"]
        return ids.compactMap { i in
            guard i["public"] as? Bool != false else { return nil }
            if let n = i["name"] as? String, !n.isEmpty { return n }
            if let l = i["l10nID"] as? String ?? i["l10nId"] as? String { return byL10n[l] }
            return (i["userContextId"] as? Int).flatMap { byID[$0] }
        }
    }

    /// The URL the "Open external links in a container" add-on handles.
    static func containerURL(_ url: URL, container: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        guard let n = container.addingPercentEncoding(withAllowedCharacters: allowed),
              let u = url.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "ext+container:name=\(n)&url=\(u)")
    }

    /// Chromium: profile folders and their names from Local State, in the browser's own order.
    static func chromiumProfiles(localState: Data) -> [(dir: String, name: String)] {
        guard let o = try? JSONSerialization.jsonObject(with: localState) as? [String: Any],
              let profile = o["profile"] as? [String: Any], let cache = profile["info_cache"] as? [String: Any] else { return [] }
        let order = (profile["profiles_order"] as? [String]) ?? cache.keys.sorted()
        return order.compactMap { dir in ((cache[dir] as? [String: Any])?["name"] as? String).map { (dir, $0) } }
    }

    private static func sections(_ ini: String) -> [(name: String, values: [String: String])] {
        var out: [(String, [String: String])] = []
        for raw in ini.components(separatedBy: .newlines) {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("["), l.hasSuffix("]") { out.append((String(l.dropFirst().dropLast()), [:])); continue }
            guard !out.isEmpty, let eq = l.firstIndex(of: "=") else { continue }
            out[out.count - 1].1[String(l[..<eq])] = String(l[l.index(after: eq)...])
        }
        return out
    }
}

/// Every artifact one transcript published, opened or named, read line by line in order (the viewer's
/// reading, `ArtifactTranscript`). The newest sighting sets `at`; a later one without a title keeps the title.
struct ArtifactLedger: Equatable {
    struct Entry: Equatable { var title: String?; var at: Date }
    private(set) var entries: [String: Entry] = [:]

    mutating func read(_ line: Substring) {
        // Cheap test first: most lines never mention an artifact.
        guard line.contains("artifact/"), line.contains("claude.ai/"), let a = ArtifactTranscript.sighting(inLine: String(line)) else { return }
        let at = Self.time(line) ?? entries[a.link.url.absoluteString]?.at ?? .distantPast
        let url = a.link.url.absoluteString
        entries[url] = Entry(title: a.title ?? entries[url]?.title, at: max(at, entries[url]?.at ?? .distantPast))
    }

    /// The line's `timestamp`, read without parsing the whole line again.
    private static func time(_ line: Substring) -> Date? {
        guard let r = line.range(of: "\"timestamp\":\"") else { return nil }
        let rest = line[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return iso.date(from: String(rest[..<end]))
    }
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
