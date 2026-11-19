import Foundation

/// Where Maxwell continues a stopped session whose folder was deleted.
func goneFolderTests() {
    let left: Set<String> = ["/Users/ada", "/Users/ada/code", "/Users/ada/code/acme", "/Users/ada/code/acme/.claude/worktrees"]
    let exists = { left.contains($0) }
    check(GoneFolder.fallback(for: "/Users/ada/code/acme/.claude/worktrees/qa-gate", exists: exists) == "/Users/ada/code/acme",
          "a removed worktree continues in its repository, not in the worktrees folder")
    check(GoneFolder.fallback(for: "/Users/ada/code/acme/.claude/worktrees/qa-gate/web", exists: exists) == "/Users/ada/code/acme",
          "a folder inside a removed worktree continues in its repository")
    check(GoneFolder.fallback(for: "/Users/ada/code/scratch/deep", exists: exists) == "/Users/ada/code",
          "any other deleted folder continues in the nearest folder above that exists")
    check(GoneFolder.fallback(for: "/Users/ada/gone/.claude/worktrees/x", exists: exists) == "/Users/ada",
          "a worktree whose repository is gone too: the nearest folder above the repository")
    check(GoneFolder.fallback(for: "/Volumes/usb/work", exists: { _ in false }) == nil, "nothing left below / : no folder")
}
