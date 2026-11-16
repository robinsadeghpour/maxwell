import Foundation

/// A `claude` started in a Maxwell terminal is matched to that terminal through the tag it inherits.
func terminalHostsTests() {
    let p = Process()
    // This test binary, asked to wait: macOS hides the environment of its own system tools like /bin/sleep.
    p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    p.environment = ["PATH": "/bin", "MX_TEST_WAIT": "1", TerminalHosts.envKey: TerminalHosts.tag("shell-2")]
    guard (try? p.run()) != nil else { return check(false, "could not start a process to read") }
    defer { p.terminate() }
    check(TerminalHosts.runningCommand(foreground: p.processIdentifier) == URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent, "a command in the foreground is named")
    check(TerminalHosts.runningCommand(foreground: nil) == nil, "nothing in the foreground: nothing running")
    check(TerminalHosts.isShell("-zsh") && TerminalHosts.isShell("bash") && !TerminalHosts.isShell("npm"), "the shell at its prompt is not a running command")
    let env = TerminalHosts.environment(of: p.processIdentifier)
    check(env[TerminalHosts.envKey] == TerminalHosts.tag("shell-2") && env["PATH"] == "/bin", "another process's environment is read")

    func session(_ id: String, _ reach: Reach) -> Session {
        Session(id: id, name: id, accountId: "a", cwd: "/p", at: Date(), origin: .external, reach: reach)
    }
    let inShell = session("s1", .elsewhere(pid: Int(p.processIdentifier)))
    let outside = session("s2", .elsewhere(pid: Int(getpid())))
    let hosts = TerminalHosts()
    check(hosts.hosts([inShell, outside], terminalIds: ["shell-1", "shell-2"]) == ["s1": "shell-2"], "only the session started in a Maxwell terminal is hosted, by that terminal")
    check(hosts.hosts([inShell], terminalIds: ["shell-1"]).isEmpty, "a closed terminal hosts nothing")
    check(hosts.hosts([inShell], terminalIds: []).isEmpty, "no terminals, nothing to match")
}
