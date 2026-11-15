import Foundation

/// A folder a new session can start in: the main checkout of a repo, named by its project.
struct ProjectFolder: Equatable {
    var project: String
    var path: String
    /// When a session last ran here; nil for a repo found on disk that no session has used.
    var lastUsed: Date?
}

/// Every place ⌘N can offer: the folders sessions ran in, plus the git repos in the usual
/// code folders, so a project nobody has opened in Maxwell yet is still one search away.
enum ProjectFolders {
    /// Folders people keep repos in, relative to home. Children are checked, and the children
    /// of a child that is not a repo itself (~/projects/acme-workspace/web).
    static let roots = ["projects", "Projects", "code", "Code", "src", "dev", "Developer", "repos", "git", "GitHub",
                        "Documents/GitHub", "Documents/Projects", "Documents/Code", "workspace", "Sites"]

    /// Sessions' folders first (most recent first), then repos found on disk by name.
    static func all(used: [(path: String, at: Date)], projects: Projects, home: String = Paths.home.path) -> [ProjectFolder] {
        var seen = Set<String>(), out: [ProjectFolder] = []
        // Hidden folders (a Claude config dir, a job's temp folder) are where tools ran, not work.
        let visible = used.filter { !$0.path.split(separator: "/").contains { $0.hasPrefix(".") } }
        let recent = visible.sorted { $0.at > $1.at }
        // Projects first; a loose folder someone used (~/projects itself) stays reachable below them.
        for u in recent.filter({ isProject($0.path, projects: projects, home: home) }) + recent.filter({ !isProject($0.path, projects: projects, home: home) })
        where seen.insert(u.path).inserted {
            out.append(ProjectFolder(project: projects.name(for: u.path), path: u.path, lastUsed: u.at))
        }
        let found = repos(under: roots.map { (home as NSString).appendingPathComponent($0) })
        for path in found.sorted(by: { ($0 as NSString).lastPathComponent.lowercased() < ($1 as NSString).lastPathComponent.lowercased() })
        where seen.insert(path).inserted {
            out.append(ProjectFolder(project: projects.name(for: path), path: path, lastUsed: nil))
        }
        return out
    }

    /// True when a folder holds a project: inside a git repo or matched by a project rule.
    /// Home itself never does, even with a repo there (dotfiles), because a session in ~ sees everything.
    static func isProject(_ path: String, projects: Projects, home: String = Paths.home.path) -> Bool {
        Paths.normalize(path) != Paths.normalize(home) && projects.known(path) != nil
    }

    private static func repos(under roots: [String]) -> [String] {
        let fm = FileManager.default
        var out: [String] = [], realSeen = Set<String>()
        func isRepo(_ p: String) -> Bool { fm.fileExists(atPath: p + "/.git") }
        func children(_ p: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: p)) ?? [])
                .filter { !$0.hasPrefix(".") && !$0.hasSuffix("-worktrees") }
                .map { (p as NSString).appendingPathComponent($0) }
                .filter { var d: ObjCBool = false; return fm.fileExists(atPath: $0, isDirectory: &d) && d.boolValue }
        }
        func add(_ p: String) {
            // ~/Projects and ~/projects are the same folder on a case-insensitive disk.
            let real = (p as NSString).resolvingSymlinksInPath.lowercased()
            if realSeen.insert(real).inserted { out.append(p) }
        }
        for root in roots {
            for child in children(root) {
                if isRepo(child) { add(child); continue }
                children(child).filter(isRepo).forEach(add)
            }
        }
        return out
    }
}
