import Foundation

struct ProjectRule: Equatable {
    var name: String
    var glob: String   // matched against the session's folder and each folder above it
}

/// Which project a session's folder belongs to. Worktrees and sibling clones map to their
/// parent repo, so ~/projects/orbit-v2-worktrees/x and ~/projects/orbit-v2-accounts are
/// both "Orbit". Reads only the filesystem (.git files), memoised per folder.
final class Projects {
    private var cache: [String: String] = [:]
    let rules: [ProjectRule]

    init(rules: [ProjectRule]) { self.rules = rules }

    func name(for cwd: String) -> String {
        if let n = cache[cwd] { return n }
        let n = resolve(cwd)
        cache[cwd] = n
        return n
    }

    private func resolve(_ cwd: String) -> String {
        guard !cwd.isEmpty else { return "Other" }
        return known(cwd) ?? Self.pretty(cwd)
    }

    /// The project a folder belongs to by a rule or its git repo; nil for a loose folder.
    func known(_ dir: String) -> String? {
        var d = dir
        while d.count > 1 {
            if let r = rules.first(where: { fnmatch(Paths.normalize($0.glob), d, 0) == 0 }) { return r.name }
            d = (d as NSString).deletingLastPathComponent
        }
        return Self.repoRoot(dir).map(Self.pretty)
    }

    /// True when `cwd` is in a linked worktree, whose branch belongs to that session alone.
    func isWorktree(_ cwd: String) -> Bool {
        if let w = worktrees[cwd] { return w }
        var dir = cwd, found = false
        while dir.count > 1 {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dir + "/.git", isDirectory: &isDir) { found = !isDir.boolValue; break }
            dir = (dir as NSString).deletingLastPathComponent
        }
        worktrees[cwd] = found
        return found
    }
    private var worktrees: [String: Bool] = [:]

    /// The main checkout of the repo holding `cwd`, or nil outside git.
    static func repoRoot(_ cwd: String) -> String? {
        let fm = FileManager.default
        var dir = cwd
        while dir.count > 1 {
            let dotGit = (dir as NSString).appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit, isDirectory: &isDir) {
                if isDir.boolValue { return dir }
                // A worktree: "gitdir: /path/repo/.git/worktrees/<name>".
                let text = (try? String(contentsOfFile: dotGit, encoding: .utf8)) ?? ""
                if let r = text.range(of: "gitdir: ") {
                    let gitdir = text[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                    if let w = gitdir.range(of: "/.git/worktrees/") { return String(gitdir[..<w.lowerBound]) }
                }
                return dir
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// Display name for a repo root: a "-workspace" parent wins (acme-workspace/web is
    /// Acme), a "-worktrees" parent or a sibling repo whose name prefixes this one
    /// (orbit-v2-accounts next to orbit-v2) folds in, and "-v2"-style suffixes drop.
    static func pretty(_ root: String) -> String {
        let parent = (root as NSString).deletingLastPathComponent
        let parentName = (parent as NSString).lastPathComponent
        var name = (root as NSString).lastPathComponent
        if parentName.hasSuffix("-workspace") {
            name = parentName
        } else if parentName.hasSuffix("-worktrees") {
            name = String(parentName.dropLast("-worktrees".count))
        } else if let siblings = try? FileManager.default.contentsOfDirectory(atPath: parent) {
            let base = siblings.filter { name.hasPrefix($0 + "-") && FileManager.default.fileExists(atPath: parent + "/" + $0 + "/.git") }
                .max { $0.count < $1.count }
            if let base { name = base }
        }
        for suffix in ["-workspace", "-worktrees"] where name.hasSuffix(suffix) { name = String(name.dropLast(suffix.count)) }
        if let r = name.range(of: #"-v\d+$"#, options: .regularExpression) { name.removeSubrange(r) }
        name = name.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}
