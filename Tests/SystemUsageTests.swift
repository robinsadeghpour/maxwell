import Foundation

/// The System panel's split of Claude Code by session, on the process tree Claude Code 2.1.332 makes.
func systemUsageTests() {
    // pid ppid %cpu rss(KiB) command
    let ps = """
      100     1   0.5  40000 /Users/me/.local/bin/claude
      200   100   0.0  50000 claude bg-pty-host
      201   200  40.0 400000 claude bg-spare
      202   201   0.0   2000 /bin/zsh
      203   202  60.0 100000 /usr/local/bin/node
      300   100   0.0  50000 claude bg-pty-host
      301   300   1.0 300000 claude bg-spare
      400     1   0.0  45000 /Users/me/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude
      401   400  20.0 500000 /Users/me/.local/share/claude/versions/2.1.332
      402   401  10.0  80000 /opt/homebrew/bin/node mcp-server
      500     1  80.0 900000 /Applications/Some Editor.app/Contents/MacOS/Some Editor
      600     1  50.0  10000 /usr/bin/yes
    """
    let procs = SystemUsage.parse(ps: ps)
    check(procs.count == 12 && procs.first { $0.pid.raw == 500 }?.command == "/Applications/Some Editor.app/Contents/MacOS/Some Editor", "ps lines parse, commands with spaces kept whole")
    let pids = [ProcessID(raw: 201): "bg", ProcessID(raw: 401): "term", ProcessID(raw: 600): "gone"]
    let (sessions, other) = SystemUsage.split(procs, sessions: pids, cores: 10)
    check(sessions["bg"]?.processes == 4 && abs((sessions["bg"]?.cpu ?? 0) - 10.0) < 0.001, "a background session counts its shell, the command it runs and its pty host")
    check(sessions["term"]?.processes == 3 && abs((sessions["term"]?.cpu ?? 0) - 3.0) < 0.001, "a terminal session counts its MCP server and its launcher")
    check(sessions["gone"] == nil, "a session pid now used by another program lends it nothing")
    check(other.processes == 3 && abs(other.cpu - 0.15) < 0.001, "the background service and a spare worker count as other Claude Code")
    check(sessions.values.allSatisfy { $0.memory > 0 } && sessions["bg"]?.memory == (50000 + 400000 + 2000 + 100000) * 1024, "memory adds up per session")

    var h = SystemHistory()
    let t = Date(timeIntervalSince1970: 1_800_000_000)
    for i in 0..<200 { var s = SystemSample(); s.at = t.addingTimeInterval(Double(i) * 2); s.machineCPU = 50; h.add(s) }
    check(h.points.count == 151 && h.points.first?.at == t.addingTimeInterval(398 - 300), "history keeps five minutes of readings")
}
