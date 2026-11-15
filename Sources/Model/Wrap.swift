import Foundation

/// The status line a session ends its reply with: "**Safe to close** · v0.1.17 shipped".
struct Wrap: Equatable {
    enum State: String, CaseIterable { case safe = "Safe to close", open = "Not done", needsYou = "Needs you" }
    var state: State
    var note: String

    /// Reads only the last non-empty line; nil unless it starts with one of the three states.
    static func parse(_ message: String) -> Wrap? {
        guard let line = lastLine(message) else { return nil }
        let clean = line.filter { !"*`".contains($0) }.drop { !$0.isLetter }
        for state in State.allCases {
            guard clean.lowercased().hasPrefix(state.rawValue.lowercased()) else { continue }
            let rest = clean.dropFirst(state.rawValue.count)
            if let f = rest.first, f.isLetter || f.isNumber { return nil }
            let note = rest.drop { "·-—:|_".contains($0) || $0.isWhitespace }.trimmingCharacters(in: CharacterSet.whitespaces.union(["_"]))
            return Wrap(state: state, note: String(note.prefix(120)))
        }
        return nil
    }

    /// The message without its status line, so the line never reads as a question or an offer.
    static func stripped(_ message: String) -> String {
        guard parse(message) != nil, let line = lastLine(message), let r = message.range(of: line, options: .backwards) else { return message }
        return String(message[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func lastLine(_ message: String) -> String? {
        message.components(separatedBy: .newlines).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Written to <state dir>/session-context.md; the hook prints it on SessionStart into every session's context.
    static let rule = """
    Maxwell status line. End every reply with one last line in exactly one of these forms, with nothing after it:
    **Safe to close** · <what was done, a few words>
    **Not done** · <what is still open, and what it waits on>
    **Needs you** · <the one thing you need from the user>
    Say Safe to close only when nothing is left: changes merged or not needed, nothing uncommitted or unpushed, no follow-up promised. Examples:
    **Safe to close** · v0.1.17 shipped, worktree removed
    **Not done** · PR #25 waiting on CI
    **Needs you** · pick a name for the setting

    """

    static var contextFile: URL { Paths.stateDir.appendingPathComponent("session-context.md") }

    /// Writes the rule for the hook to hand to new sessions, or removes it when the setting is off.
    static func publish(_ on: Bool) {
        let fm = FileManager.default
        guard on else { try? fm.removeItem(at: contextFile); return }
        try? fm.createDirectory(at: Paths.stateDir, withIntermediateDirectories: true)
        try? rule.write(to: contextFile, atomically: true, encoding: .utf8)
    }
}
