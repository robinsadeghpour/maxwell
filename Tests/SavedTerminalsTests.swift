import Foundation

/// Plain terminals come back after a restart: folder, name and order.
func savedTerminalsTests() {
    let d = UserDefaults(suiteName: "maxwell-tests-\(UUID().uuidString)")!
    check(SavedTerminals.load(d).terminals.isEmpty, "nothing saved: no terminals come back")

    let saved = SavedTerminals(terminals: [.init(folder: "/p/api", name: "deploy logs"), .init(folder: "/p/web", name: nil)])
    saved.save(d)
    check(SavedTerminals.load(d) == saved, "folders, names and order survive a save and load")
    SavedTerminals().save(d)
    check(d.data(forKey: SavedTerminals.key) == nil, "closing the last terminal clears what's saved")

    let exists: (String) -> Bool = { ["/p", "/p/api"].contains($0) }
    check(SavedTerminals.reopenFolder("/p/api", home: "/h", exists: exists) == "/p/api", "a folder that exists reopens there")
    check(SavedTerminals.reopenFolder("/p/.worktrees/gone/src", home: "/h", exists: exists) == "/p", "a deleted worktree reopens in the nearest folder still there")
    check(SavedTerminals.reopenFolder("/gone", home: "/h", exists: exists) == "/h", "nothing left of the path: home")
}

/// A reopened terminal shows what it showed before, cut to the last lines, under a divider.
func terminalOutputTests() {
    let vt = "\u{1b}]10;rgb:ec/ee/f1\u{1b}\\\u{1b}]11;rgb:14/16/1a\u{07}" + (1...10).map { "line \($0)" }.joined(separator: "\r\n") + "\r\n\r\n   \r\n"
    let kept = TerminalOutput.tail(vt, lines: 3)
    check(kept == "\u{1b}[0mline 8\nline 9\nline 10\u{1b}[0m", "keeps the last lines, drops the blank prompt area, starts and ends in plain colours")
    check(!TerminalOutput.tail(vt).contains("]10;") && !TerminalOutput.tail(vt).contains("]11;"), "the dump's own colour settings don't come back")

    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    let saved = Date(timeIntervalSince1970: 1_794_837_720)  // Mon 16 Nov 2026, 14:02 UTC
    check(TerminalOutput.divider(savedAt: saved, now: saved.addingTimeInterval(3600), calendar: cal) == "\u{1b}[2m── restored · 14:02 ──\u{1b}[0m", "today: just the time")
    check(TerminalOutput.divider(savedAt: saved, now: saved.addingTimeInterval(86400 * 2), calendar: cal).contains("Mon 16 Nov, 14:02"), "another day: the day too")
    let cmd = TerminalOutput.replay(URL(fileURLWithPath: "/s/it's.vt"), savedAt: saved)
    check(cmd.contains("cat '/s/it'\\''s.vt'; printf"), "the file path is quoted for the shell")

    let restored = "Last login: Mon\nwork\nme % \n\n\u{1b}[2m── restored · 14:02 ──\u{1b}[0m\n\nme % \n"
    check(TerminalOutput.tail(restored) == "\u{1b}[0mwork\nme % \u{1b}[0m", "nothing typed since the restore: its divider goes, as does the Last login line")
    let used = restored + "me % ls\nfile\nme % "
    check(TerminalOutput.tail(used).contains("restored · 14:02"), "something typed since: the divider stays")
}
