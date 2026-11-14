import Foundation

/// ~/.config/maxwell/config: Ghostty-style `key = value` lines. Repeated keys (account,
/// keybind) accumulate. The Settings window edits the same file line by line, so
/// comments and unknown keys survive.
struct Config: Equatable {
    /// `theme = <name>`: one fixed theme whatever the system does. Unset: the light/dark pair.
    var themeOverride: String?
    var themeLight = "paper"
    var themeDark = "graphite"
    /// "system" follows macOS; "light" and "dark" pin one side of the pair.
    var appearance = "system"
    /// The interface: lists, panels, viewer. The terminal has its own size.
    var fontSize: Double = 13
    var terminalFontSize: Double = 12
    var notify = true
    var autoOpen = true
    var showTree = false
    var appIcon = "auto"
    /// Glass: overrides the theme's background-opacity (0.3 very glassy … 1 opaque).
    var backgroundOpacity: Double?
    /// Frost behind the window in points (0 none … 64 strong); unset uses the system material.
    var backgroundBlur: Double?
    /// Animations: "on", or "off" (also off whenever macOS Reduce Motion is on).
    var motion = "on"
    /// Session rows: "detail" (title, then project · branch · account) or "compact" (one line).
    var rowStyle = "detail"
    /// Project switcher: "rail" (a column of project keys) or "tabs" (chips above the list).
    var projectNav = "rail"
    /// The rail: "auto" hides it until the pointer reaches the left edge, like the Dock; "shown" keeps it.
    var rail = "auto"
    /// How long the pointer rests on the left edge before the rail slides in (the Dock waits longer).
    var railDelay: Double = 0.18
    /// `project-pin = <name>` lines, in rail order. Unpinned projects show on the rail only while they need him.
    var pinned: [String] = []
    /// `project-logo = <name> <path>` overrides the logo found in the repo.
    var logos: [String: String] = [:]
    /// How a logo is drawn: "engraved" (the silhouette in theme ink), "pixel" (square pixels, like the app icon), or "monogram".
    var logoStyle = "engraved"
    /// Markdown in the viewer: "mono" like the rest of the window, or "sans" for long reads.
    var viewerFont = "mono"
    /// "Says done" sessions quiet for longer than this fold into the Idle group.
    var idleAfter: TimeInterval = 24 * 3600
    /// A stopped session must be quiet this long (plus every other check) to be safe to close.
    var safeAfter: TimeInterval = 2 * 3600
    /// The final model read of a candidate's last reply. Off: nothing is ever safe to close.
    var judge = true
    /// `project = <name> <path glob>` lines, checked before the git-derived project.
    var projects: [ProjectRule] = []
    var accounts: [Account] = []
    var keybinds: [String: String] = [:]   // action id -> shortcut, e.g. "new-session" -> "cmd+n"

    static let lightThemes = ["paper", "silver-light"]
    static let darkThemes = ["graphite", "silver"]
    static let themes = lightThemes + darkThemes

    /// The theme to show: the fixed override, else the side of the pair the appearance asks for.
    func theme(systemDark: Bool) -> String {
        if let themeOverride { return themeOverride }
        switch appearance {
        case "light": return themeLight
        case "dark": return themeDark
        default: return systemDark ? themeDark : themeLight
        }
    }

    var rules: GroupRules { GroupRules(idleAfter: idleAfter, safeAfter: safeAfter, judge: judge) }

    static func load(from url: URL = Paths.configFile) -> Config {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return withDiscoveredAccounts(Config()) }
        return parse(text)
    }

    static func parse(_ text: String) -> Config {
        var c = Config()
        for (key, value) in entries(text) {
            switch key {
            case "theme": if !value.isEmpty { c.themeOverride = value }
            case "theme-light": if !value.isEmpty { c.themeLight = value }
            case "theme-dark": if !value.isEmpty { c.themeDark = value }
            case "appearance": if ["system", "light", "dark"].contains(value) { c.appearance = value }
            case "background-blur": if let v = Double(value), (0...64).contains(v) { c.backgroundBlur = v }
            case "motion": if ["on", "off"].contains(value) { c.motion = value }
            case "font-size": if let v = Double(value), (9...24).contains(v) { c.fontSize = v }
            case "terminal-font-size": if let v = Double(value), (8...28).contains(v) { c.terminalFontSize = v }
            case "notify": c.notify = value != "false"
            case "auto-open": c.autoOpen = value != "false"
            case "file-tree": c.showTree = value == "true"
            case "app-icon": c.appIcon = value
            case "background-opacity": if let v = Double(value), (0.3...1).contains(v) { c.backgroundOpacity = v }
            case "row-style": if ["detail", "compact"].contains(value) { c.rowStyle = value }
            case "project-nav": if ["rail", "tabs"].contains(value) { c.projectNav = value }
            case "rail": if ["auto", "shown"].contains(value) { c.rail = value }
            case "rail-delay": if let v = Double(value.replacingOccurrences(of: "s", with: "")), (0...2).contains(v) { c.railDelay = v }
            case "project-pin": if !value.isEmpty, !c.pinned.contains(value) { c.pinned.append(value) }
            case "project-logo-style": if ["pixel", "engraved", "monogram"].contains(value) { c.logoStyle = value }
            case "project-logo":
                guard let sp = value.lastIndex(of: " ") else { continue }
                let name = value[..<sp].trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { c.logos[name] = Paths.normalize(String(value[value.index(after: sp)...])) }
            case "viewer-font": if ["mono", "sans"].contains(value) { c.viewerFont = value }
            case "idle-after": if let d = duration(value) { c.idleAfter = d }
            case "safe-after": if let d = duration(value) { c.safeAfter = d }
            case "judge": c.judge = !["off", "false"].contains(value)
            case "project":
                // project = <name> <path glob>; the name may contain spaces, the glob is the last word.
                guard let sp = value.lastIndex(of: " ") else { continue }
                let name = value[..<sp].trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { c.projects.append(ProjectRule(name: name, glob: String(value[value.index(after: sp)...]))) }
            case "account":
                // account = <name> <config dir>
                let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let dir = URL(fileURLWithPath: Paths.normalize(parts[1].trimmingCharacters(in: .whitespaces)))
                c.accounts.append(Account(id: parts[0], name: parts[0], configDir: dir))
            case "keybind":
                // keybind = cmd+n=new-session
                guard let eq = value.lastIndex(of: "=") else { continue }
                c.keybinds[String(value[value.index(after: eq)...]).trimmingCharacters(in: .whitespaces)] =
                    String(value[..<eq]).trimmingCharacters(in: .whitespaces)
            default: continue
            }
        }
        return c.accounts.isEmpty ? withDiscoveredAccounts(c) : c
    }

    /// "24h", "90m", "2d", or plain hours ("24").
    static func duration(_ s: String) -> TimeInterval? {
        let units: [Character: Double] = ["m": 60, "h": 3600, "d": 86400]
        if let u = s.last, let mult = units[u], let n = Double(s.dropLast()) { return n * mult }
        return Double(s).map { $0 * 3600 }
    }

    static func entries(_ text: String) -> [(String, String)] {
        text.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { return nil }
            return (line[..<eq].trimmingCharacters(in: .whitespaces), line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces))
        }
    }

    /// ~/.claude plus every ~/.claude-* directory that holds a login (.claude.json).
    static func withDiscoveredAccounts(_ base: Config) -> Config {
        var c = base
        let fm = FileManager.default
        c.accounts = [Account(id: "default", name: "default", configDir: Paths.defaultConfigDir)]
        let names = ((try? fm.contentsOfDirectory(atPath: Paths.home.path)) ?? []).filter { $0.hasPrefix(".claude-") }.sorted()
        for n in names where fm.fileExists(atPath: Paths.home.appendingPathComponent(n).appendingPathComponent(".claude.json").path) {
            let id = String(n.dropFirst(".claude-".count))
            c.accounts.append(Account(id: id, name: id, configDir: Paths.home.appendingPathComponent(n)))
        }
        return c
    }

    /// Rewrites `key = value` in place (first occurrence) or appends it; keeps everything else.
    /// A value with newlines is a list: one `key = item` line each, replacing every earlier one.
    static func setting(_ key: String, to value: String, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let isKey = { (l: String) -> Bool in
            let t = l.trimmingCharacters(in: .whitespaces)
            return !t.hasPrefix("#") && t.split(separator: "=", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } == key
        }
        let items = value.components(separatedBy: "\n").filter { !$0.isEmpty }
        if items.count != 1 || value.contains("\n") {
            let at = lines.firstIndex(where: isKey)
            lines.removeAll(where: isKey)
            let new = items.map { "\(key) = \($0)" }
            if let at { lines.insert(contentsOf: new, at: min(at, lines.count)) } else {
                if lines.last == "" { lines.removeLast() }
                lines += new + [""]
            }
            return lines.joined(separator: "\n")
        }
        if let i = lines.firstIndex(where: isKey) {
            lines[i] = "\(key) = \(value)"
        } else {
            if lines.last == "" { lines.removeLast() }
            lines.append("\(key) = \(value)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static let starter = """
    # Maxwell config. Ghostty style: key = value. Maxwell reloads it when you save.
    # The Settings window (Cmd+,) writes this file too.

    # appearance = system | light | dark       (⇧⌘L switches; View › Appearance)
    theme-light = paper
    theme-dark = graphite
    # theme = silver                         one fixed theme, ignores appearance
    font-size = 13                           # lists, panels and the viewer
    terminal-font-size = 12                  # ⌘− and ⌘= change this one
    notify = true
    auto-open = true
    file-tree = false
    # app-icon = auto | light | dark | paper | graphite | light-eyes | dark-eyes
    app-icon = auto
    # Glass: 0.3 very glassy … 1 opaque. Unset uses the theme's value.
    # background-opacity = 0.8
    # Frost behind the window: 0 none … 64 strong. Unset uses the system's frosted material.
    # background-blur = 20
    # row-style = detail | compact     project-nav = rail | tabs     viewer-font = mono | sans
    # rail = auto (slides in at the left edge, like the Dock) | shown
    # rail-delay = 0.18                seconds at the edge before it slides in (the Dock: about 0.5)
    # project-pin = Acme               one line per project kept on the rail, in order
    # project-logo-style = engraved | pixel | monogram
    # project-logo = Acme ~/projects/acme/apps/web/app/icon.png
    # "Says done" sessions quiet for longer than this fold into a collapsed Idle group.
    idle-after = 24h
    # A stopped session counts as safe to close only after this long without activity.
    safe-after = 2h
    # Last step before Safe to close: one small model read (claude -p, haiku, on the account
    # with the most 5-hour room) of the last reply. off = nothing is ever safe to close.
    judge = on
    # project = <name> <path glob>. Without one, a session's project is its git repo
    # (worktrees count as their parent repo).
    # project = Orbit ~/projects/orbit*

    # account = <name> <CLAUDE_CONFIG_DIR>. The first one is the default for new sessions
    # when usage is equal.

    """
}
