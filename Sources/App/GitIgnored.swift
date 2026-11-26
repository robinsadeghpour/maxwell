import Foundation

/// What git ignores in a folder: `git ls-files --others --ignored --exclude-standard --directory`.
struct GitIgnored: Equatable {
    var paths: Set<String> = []
    static func read(_ root: String) -> GitIgnored {
        let r = ClaudeCLI.run("/usr/bin/git", ["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"], cwd: root, timeout: 5)
        guard r.status == 0 else { return GitIgnored() }
        return GitIgnored(paths: Set(r.out.split(separator: "\0").map { String($0).hasSuffix("/") ? String($0.dropLast()) : String($0) }))
    }
    /// The path, or a folder it is in, is ignored.
    func contains(_ url: URL, under root: URL) -> Bool {
        guard !paths.isEmpty, url.path.hasPrefix(root.path + "/") else { return false }
        var rel = String(url.path.dropFirst(root.path.count + 1))
        while !rel.isEmpty {
            if paths.contains(rel) { return true }
            guard let slash = rel.lastIndex(of: "/") else { return false }
            rel = String(rel[..<slash])
        }
        return false
    }
}
