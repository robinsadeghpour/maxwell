import Foundation

/// The bytes the phone writes to type a message into a session's prompt through `claude attach`
/// (docs/claude-code-internals.md, "Typing into an attached session").
enum PromptInput {
    /// One write this long or longer reaches Claude Code as a paste: the control keys in it are dropped.
    static let pasteBytes = 64

    /// Empties the prompt before the phone's text goes in. Claude Code puts the prompt back after an
    /// early Esc, and a draft typed on the Mac sits there too; the phone can't see either, and its
    /// text would be added to it. Ctrl-U deletes to the line start (at a line start it joins the line
    /// above, on an empty prompt it does nothing), so 30 presses empty a prompt of 15 lines.
    static let clear = Data(repeating: 0x15, count: 30)

    /// Several lines go in as one bracketed paste, so a newline doesn't send the first line alone.
    static func text(_ s: String) -> Data {
        Data((s.contains("\n") ? "\u{1b}[200~\(s)\u{1b}[201~" : s).utf8)
    }
}
