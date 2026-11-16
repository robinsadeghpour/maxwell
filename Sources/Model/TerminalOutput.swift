import Foundation

/// What a terminal showed, kept so it comes back after a restart or an Undo: its screen and
/// scrollback with their colours (Ghostty's VT dump), the last `keepLines` lines, in a file of
/// its own. On the way back the new shell prints it, then a dim line saying when it is from.
enum TerminalOutput {
    static let keepLines = 5000

    /// One folder per app, so Maxwell and Maxwell Dev (which share the state folder) keep theirs apart.
    static func folder(app: String) -> URL {
        Paths.stateDir.appendingPathComponent("terminals").appendingPathComponent(app)
    }

    static func file(_ key: String, app: String) -> URL { folder(app: app).appendingPathComponent(key + ".vt") }

    /// The last `lines` lines, starting from plain colours: a cut can fall inside a coloured run.
    /// Ghostty's dump opens by setting the terminal's colours (OSC 10, 11); those go, or a replay
    /// would pin the old theme's colours after a theme change. So do "Last login" lines, one per
    /// launch, and a restore nobody typed after: restarting twice leaves one divider, not two.
    static func tail(_ vt: String, lines: Int = keepLines) -> String {
        let body = vt.replacingOccurrences(of: "\u{1b}\\][^\u{07}\u{1b}]*(\u{07}|\u{1b}\\\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "\n")
        var all = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !plain($0).hasPrefix("Last login:") }
        dropBlankEnd(&all)
        if let d = all.lastIndex(where: { plain($0).contains(dividerMark) }), all[(d + 1)...].filter({ !isBlank($0) }).count <= 1 {
            all.removeSubrange(d...)
            dropBlankEnd(&all)
        }
        return "\u{1b}[0m" + all.suffix(lines).joined(separator: "\n") + "\u{1b}[0m"
    }

    static let dividerMark = "── restored · "

    /// A line without its colour and cursor sequences.
    private static func plain(_ line: String) -> String {
        line.replacingOccurrences(of: "\u{1b}\\[[0-9;:?]*[A-Za-z]", with: "", options: .regularExpression)
    }

    private static func isBlank(_ line: String) -> Bool { plain(line).trimmingCharacters(in: .whitespaces).isEmpty }

    private static func dropBlankEnd(_ lines: inout [String]) {
        while let l = lines.last, isBlank(l) { lines.removeLast() }
    }

    /// The divider under the old output: "── restored · Mon 16 Nov, 14:02 ──", dim.
    static func divider(savedAt: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = calendar.timeZone
        f.dateFormat = calendar.isDate(savedAt, inSameDayAs: now) ? "HH:mm" : "EEE d MMM, HH:mm"
        return "\u{1b}[2m" + dividerMark + f.string(from: savedAt) + " ──\u{1b}[0m"
    }

    /// The command a reopened terminal runs first: the old output, then the divider. It starts by
    /// clearing what the new shell printed on the way up (login's "Last login" line), so the old
    /// output starts at the top.
    static func replay(_ file: URL, savedAt: Date) -> String {
        "printf '\\033[H\\033[J'; cat " + quote(file.path) + "; printf '\\n%s\\n\\n' " + quote(divider(savedAt: savedAt))
    }

    private static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
