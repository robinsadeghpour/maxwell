import Foundation

/// Claude Code's answer when `/resume` picks a conversation from another folder. It can't change
/// folders inside a running session, so it prints the command to run instead:
///
///     This session is from a different directory.
///     To resume, run:
///       cd <folder> && claude --resume <session id>
///
/// Maxwell reads that off the session's screen and resumes the conversation there itself.
struct ResumeElsewhere: Equatable {
    var sessionId: SessionID
    /// The folder as printed. When the screen broke a long path over lines, the ways it can be
    /// read, likeliest first; the caller takes the first that exists.
    var folders: [String]

    /// With the mark Claude Code draws before a command's output: the same words typed into a
    /// prompt or quoted in a reply are not an answer.
    private static let notice = "This session is from a different directory"
    private static let outputMark: Character = "⎿"
    private static let command = try? NSRegularExpression(
        pattern: #"cd\s+(.+?)\s*&&\s*claude\s+--resume\s+([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})"#,
        options: [.dotMatchesLineSeparators])

    /// The newest such answer on a screen of text, or nil.
    static func parse(screen: String) -> ResumeElsewhere? {
        guard let found = screen.range(of: notice, options: .backwards), let command,
              screen[..<found.lowerBound].last(where: { !$0.isWhitespace }) == outputMark else { return nil }
        let start = found.upperBound
        let rest = String(screen[start...])
        guard let m = command.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
              let folder = Range(m.range(at: 1), in: rest), let id = Range(m.range(at: 2), in: rest) else { return nil }
        // A path broken mid-word reads right with the break removed; one broken at a space, with a space.
        let printed = String(rest[folder])
        var folders: [String] = []
        for joint in ["", " "] {
            let path = unquoted(printed.replacingOccurrences(of: #"[ \t]*\n[ \t]*"#, with: joint, options: .regularExpression))
            if !path.isEmpty, !folders.contains(path) { folders.append(path) }
        }
        return folders.isEmpty ? nil : ResumeElsewhere(sessionId: String(rest[id]).lowercased(), folders: folders)
    }

    /// A path the way a shell would read it: without its quotes, or its backslashes before spaces.
    private static func unquoted(_ path: String) -> String {
        let p = path.trimmingCharacters(in: .whitespaces)
        for quote in ["'", "\""] where p.count >= 2 && p.hasPrefix(quote) && p.hasSuffix(quote) {
            return String(p.dropFirst().dropLast())
        }
        return p.replacingOccurrences(of: "\\ ", with: " ")
    }
}
