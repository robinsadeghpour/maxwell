import Foundation

/// A stopped background session whose folder was deleted (most often a worktree removed once its
/// work merged). Claude Code wakes a session only in its saved folder and refuses when that folder
/// is gone ("Workspace not trusted. <folder> could not be resolved on disk.", 2.1.328), so
/// `claude attach` can't bring it back. `claude --bg --resume <id> --name <n>` from another folder
/// starts a copy there with the whole conversation: that is how Maxwell continues it.
enum GoneFolder {
    /// The folder to continue in: the repository a removed `.claude/worktrees/<name>` belonged to,
    /// else the nearest folder above that still exists. Nil when nothing below `/` is left.
    static func fallback(for cwd: String, exists: (String) -> Bool) -> String? {
        var dir = cwd
        if let r = cwd.range(of: "/.claude/worktrees/") { dir = String(cwd[..<r.lowerBound]) }
        while !dir.isEmpty, dir != "/" {
            if exists(dir) { return dir }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }
}
