import Foundation

/// What ⌘N offers: folders sessions used first, then repos found in the usual code folders.
func projectFoldersTests() {
    let fm = FileManager.default
    let home = NSTemporaryDirectory() + "mx-home-\(getpid())"
    defer { try? fm.removeItem(atPath: home) }
    for repo in ["projects/orbit", "projects/acme-workspace/web", "Documents/GitHub/zephyr", "projects/orbit-worktrees/x"] {
        try? fm.createDirectory(atPath: "\(home)/\(repo)/.git", withIntermediateDirectories: true)
    }
    try? fm.createDirectory(atPath: "\(home)/projects/notes", withIntermediateDirectories: true)
    let projects = Projects(rules: [])
    try? fm.createDirectory(atPath: "\(home)/projects/zeta/.git", withIntermediateDirectories: true)
    let used = [(path: "\(home)/projects/zeta", at: Date(timeIntervalSince1970: 10)), (path: "\(home)/projects/orbit", at: Date(timeIntervalSince1970: 20)),
                (path: "\(home)/projects", at: Date(timeIntervalSince1970: 30)), (path: "\(home)/.claude-x/jobs/1/tmp", at: Date(timeIntervalSince1970: 40))]
    let all = ProjectFolders.all(used: used, projects: projects, home: home)
    let paths = all.map { String($0.path.dropFirst(home.count + 1)) }
    check(paths.prefix(2) == ["projects/orbit", "projects/zeta"], "folders sessions used come first, latest first")
    check(paths[2] == "projects", "a loose folder someone used comes after the projects")
    check(!paths.contains { $0.hasPrefix(".") }, "hidden folders tools ran in are left out")
    check(paths.contains("projects/acme-workspace/web") && paths.contains("Documents/GitHub/zephyr"), "repos on disk are offered, one level into a non-repo folder too")
    check(!paths.contains("projects/notes") && !paths.contains { $0.contains("worktrees") }, "loose folders and worktree folders are not offered")
    check(paths.filter { $0 == "projects/orbit" }.count == 1, "a used repo is offered once")
    check(all.first { $0.path.hasSuffix("/web") }?.project == "Acme", "a found repo is named by its project")
    check(!ProjectFolders.isProject(home, projects: projects, home: home), "home is never a project")
    check(ProjectFolders.isProject("\(home)/projects/orbit", projects: projects, home: home), "a repo is a project")
    check(!ProjectFolders.isProject("\(home)/projects/notes", projects: projects, home: home), "a loose folder is not")
}
