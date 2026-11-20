import Foundation

/// Merges Maxwell's hook into each account's settings.json and a usage tap into the
/// status-line script, or a status line that shows nothing where an account has none.
/// Idempotent, backed up, and reversed exactly by `uninstall`.
enum HookInstaller {
    static let events = ["SessionStart", "UserPromptSubmit", "Stop", "StopFailure", "Notification", "SessionEnd"]
    static let marker = "maxwell-hook"
    static let tapMarker = "# maxwell usage tap"
    static var hookBinary: URL { Paths.home.appendingPathComponent(".local/share/maxwell/maxwell-hook") }
    static let hookCommand = "\"$HOME/.local/share/maxwell/maxwell-hook\" 2>/dev/null || true"
    /// The status line for an account that has none. The hook prints nothing in this mode.
    static let statusLineCommand = "\"$HOME/.local/share/maxwell/maxwell-hook\" --statusline 2>/dev/null || true"

    struct Report: CustomStringConvertible {
        var lines: [String] = []
        mutating func add(_ s: String) { lines.append(s) }
        var description: String { lines.joined(separator: "\n") }
    }

    static func install(accounts: [Account], bundledHook: URL) throws -> Report {
        var r = Report()
        try FileManager.default.createDirectory(at: hookBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
        let updated = try copyBinary(bundledHook)
        r.add("hook binary: \(hookBinary.path) (\(updated ? "updated" : "current"))")
        for file in settingsFiles(accounts) {
            try edit(file, report: &r) { addHooks(&$0); addStatusLine(&$0) }
        }
        for script in statusLineScripts(accounts) {
            try editText(script, report: &r) { addTap($0) }
        }
        return r
    }

    /// After an app update: brings an installed hook up to the bundled one, and gives accounts
    /// that have Maxwell's hooks but no status line the one that reads usage. Never installs
    /// into an account without the hooks.
    static func refresh(accounts: [Account], bundledHook: URL) {
        guard FileManager.default.fileExists(atPath: hookBinary.path) else { return }
        _ = try? copyBinary(bundledHook)
        for file in settingsFiles(accounts) {
            var r = Report()
            do {
                try edit(file, report: &r) { if hasHooks($0) { addStatusLine(&$0) } }
                if r.description.contains("changed (") { NSLog("usage status line added: %@", r.description) }
            } catch { NSLog("usage status line not added to %@: %@", file.path, "\(error)") }
        }
    }

    /// Replaces the installed binary when it differs from the bundled one; true if it did.
    private static func copyBinary(_ bundledHook: URL) throws -> Bool {
        let fm = FileManager.default
        let current = try? Data(contentsOf: hookBinary), bundled = try Data(contentsOf: bundledHook)
        guard current != bundled else { return false }
        let tmp = hookBinary.appendingPathExtension("tmp")
        try bundled.write(to: tmp)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
        _ = try fm.replaceItemAt(hookBinary, withItemAt: tmp)
        return true
    }

    static func uninstall(accounts: [Account]) throws -> Report {
        var r = Report()
        for file in settingsFiles(accounts) {
            try edit(file, report: &r) { removeHooks(&$0); removeStatusLine(&$0) }
        }
        for script in statusLineScripts(accounts) {
            try editText(script, report: &r) { removeTap($0) }
        }
        if FileManager.default.fileExists(atPath: hookBinary.path) {
            try FileManager.default.removeItem(at: hookBinary)
            r.add("removed \(hookBinary.path)")
        }
        return r
    }

    /// The real files behind each account's settings.json; symlinked accounts share one.
    static func settingsFiles(_ accounts: [Account]) -> [URL] {
        var seen = Set<String>(), out: [URL] = []
        for a in accounts {
            let f = a.configDir.appendingPathComponent("settings.json").resolvingSymlinksInPath()
            if FileManager.default.fileExists(atPath: f.path), seen.insert(f.path).inserted { out.append(f) }
        }
        return out
    }

    static func statusLineScripts(_ accounts: [Account]) -> [URL] {
        var seen = Set<String>(), out: [URL] = []
        for f in settingsFiles(accounts) {
            guard let text = try? String(contentsOf: f, encoding: .utf8), let json = try? OJSON.parse(text),
                  let cmd = json["statusLine"]?["command"]?.stringValue else { continue }
            let path = cmd.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "$HOME", with: Paths.home.path)
                .replacingOccurrences(of: "~", with: Paths.home.path)
            guard !path.contains(" "), FileManager.default.isExecutableFile(atPath: path) else { continue }
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            if seen.insert(url.path).inserted { out.append(url) }
        }
        return out
    }

    // MARK: settings.json

    static func addHooks(_ json: inout OJSON) {
        var hooks = json["hooks"] ?? .object([])
        for event in events {
            guard case .array(var groups) = hooks[event] ?? .array([]) else { continue }
            if groups.contains(where: isOurs) { continue }
            groups.append(.object([("hooks", .array([.object([
                ("type", .string("command")),
                ("command", .string(hookCommand)),
                ("timeout", .number(5)),
            ])]))]))
            hooks.set(event, .array(groups))
        }
        json.set("hooks", hooks)
    }

    static func removeHooks(_ json: inout OJSON) {
        guard var hooks = json["hooks"] else { return }
        for event in events {
            guard case .array(let groups) = hooks[event] ?? .array([]) else { continue }
            let kept = groups.filter { !isOurs($0) }
            if kept.count != groups.count { hooks.set(event, kept.isEmpty ? nil : .array(kept)) }
        }
        if case .object(let kv) = hooks, kv.isEmpty { json.set("hooks", nil) } else { json.set("hooks", hooks) }
    }

    static func isOurs(_ group: OJSON) -> Bool {
        guard case .array(let hs) = group["hooks"] ?? .array([]), hs.count == 1 else { return false }
        return hs[0]["command"]?.stringValue?.contains(marker) == true
    }

    static func hasHooks(_ json: OJSON) -> Bool {
        events.contains { event in
            guard case .array(let groups) = json["hooks"]?[event] ?? .array([]) else { return false }
            return groups.contains(where: isOurs)
        }
    }

    // MARK: status line

    /// Claude Code reports usage only to a status-line command, so an account with none gets
    /// Maxwell's, which prints nothing. An account's own status line is never replaced.
    static func addStatusLine(_ json: inout OJSON) {
        guard json["statusLine"] == nil else { return }
        json.set("statusLine", .object([("type", .string("command")), ("command", .string(statusLineCommand))]))
    }

    static func removeStatusLine(_ json: inout OJSON) {
        if json["statusLine"]?["command"]?.stringValue == statusLineCommand { json.set("statusLine", nil) }
    }

    /// Inserts the tap after the line that reads stdin into a variable (`IN=$(cat)`).
    static func addTap(_ text: String) -> String {
        if text.contains(tapMarker) { return text }
        var lines = text.components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: { $0.range(of: #"^\s*[A-Za-z_][A-Za-z0-9_]*=\$\(cat\)\s*$"#, options: .regularExpression) != nil })
        else { return text }
        let name = lines[i].trimmingCharacters(in: .whitespaces).components(separatedBy: "=")[0]
        lines.insert("printf '%s' \"$\(name)\" | \"$HOME/.local/share/maxwell/maxwell-hook\" --statusline >/dev/null 2>&1 &  \(tapMarker) (maxwell uninstall-hooks removes this line)", at: i + 1)
        return lines.joined(separator: "\n")
    }

    static func removeTap(_ text: String) -> String {
        text.components(separatedBy: "\n").filter { !$0.contains(tapMarker) }.joined(separator: "\n")
    }

    // MARK: file edits

    static func edit(_ file: URL, report: inout Report, _ change: (inout OJSON) -> Void) throws {
        let text = try String(contentsOf: file, encoding: .utf8)
        var json = try OJSON.parse(text)
        let before = json
        change(&json)
        if json == before { report.add("\(file.path): unchanged"); return }
        try write(json.serialized() + (text.hasSuffix("\n") ? "\n" : ""), to: file, original: text, report: &report)
    }

    static func editText(_ file: URL, report: inout Report, _ change: (String) -> String) throws {
        let text = try String(contentsOf: file, encoding: .utf8)
        let next = change(text)
        if next == text { report.add("\(file.path): unchanged"); return }
        try write(next, to: file, original: text, report: &report)
    }

    /// Backs up, then replaces the file's contents in place (keeps its mode and any symlink to it).
    static func write(_ text: String, to file: URL, original: String, report: inout Report) throws {
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withYear, .withMonth, .withDay, .withTime])
            .replacingOccurrences(of: ":", with: "")
        var backup = URL(fileURLWithPath: file.path + ".maxwell-backup-" + stamp)
        var n = 1
        while FileManager.default.fileExists(atPath: backup.path) {
            backup = URL(fileURLWithPath: file.path + ".maxwell-backup-\(stamp)-\(n)")
            n += 1
        }
        try original.write(to: backup, atomically: true, encoding: .utf8)
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        let tmp = URL(fileURLWithPath: file.path + ".maxwell-tmp")
        try text.write(to: tmp, atomically: false, encoding: .utf8)
        if let mode = attrs[.posixPermissions] { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: tmp.path) }
        guard rename(tmp.path, file.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        report.add("\(file.path): changed (backup \(backup.lastPathComponent))")
    }
}
