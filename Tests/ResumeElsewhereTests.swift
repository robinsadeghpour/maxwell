import Foundation

/// Claude Code's answer to `/resume` on a conversation from another folder, as a session's
/// screen shows it (Claude Code 2.1.327).
func resumeElsewhereTests() {
    let id = "1a2b3c4d-0000-4000-8000-123456789abc"
    let screen = """
    ❯ /resume
      ⎿  This session is from a different directory.

         To resume, run:
           cd /Users/ada/code/acme/.claude/worktrees/v0-1 && claude --resume \(id)

         (Command copied to clipboard)

    ❯
    """
    check(ResumeElsewhere.parse(screen: screen) == ResumeElsewhere(sessionId: id, folders: ["/Users/ada/code/acme/.claude/worktrees/v0-1"]),
          "/resume from another folder: the folder and the conversation's id")
    check(ResumeElsewhere.parse(screen: screen.replacingOccurrences(of: "⎿", with: " ")) == nil, "the same words without the command-output mark (typed, or quoted in a reply) are not followed")
    check(ResumeElsewhere.parse(screen: "❯ claude --resume \(id)\n  cd /tmp && claude --resume \(id)") == nil, "the command without Claude Code's notice is not followed")
    check(ResumeElsewhere.parse(screen: "  ⎿  This session is from a different directory.\n\nTo resume, run:") == nil, "the notice before its command is drawn is not followed yet")

    // A narrow pane breaks the line: in the middle of a long path, or at the spaces around &&.
    let midWord = "  ⎿  This session is from a different directory.\n\n   To resume, run:\n     cd /Users/ada/code/acme/.claude/work\n     trees/v0-1 && claude --resume\n     \(id)\n"
    check(ResumeElsewhere.parse(screen: midWord)?.folders.first == "/Users/ada/code/acme/.claude/worktrees/v0-1", "a path broken mid-word reads whole")
    check(ResumeElsewhere.parse(screen: midWord)?.sessionId == id, "an id on its own line is still read")
    let atSpace = "  ⎿  This session is from a different directory.\n\n   To resume, run:\n     cd '/Users/ada/My\n     Code/acme' && claude --resume \(id)\n"
    check(ResumeElsewhere.parse(screen: atSpace)?.folders == ["/Users/ada/MyCode/acme", "/Users/ada/My Code/acme"], "a quoted path broken at a space: both readings, quotes dropped")

    // Asked twice in one session: the newest answer counts.
    let other = "9f8e7d6c-0000-4000-8000-cba987654321"
    let twice = screen + "\n" + screen.replacingOccurrences(of: id, with: other).replacingOccurrences(of: "acme", with: "orbit")
    check(ResumeElsewhere.parse(screen: twice) == ResumeElsewhere(sessionId: other, folders: ["/Users/ada/code/orbit/.claude/worktrees/v0-1"]), "two answers on screen: the last one")
}
