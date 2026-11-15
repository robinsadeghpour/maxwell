import Foundation

/// Runs the `claude`, `git` and `gh` processes Maxwell needs. Children get a clean
/// environment: no CLAUDE_CODE_* markers (they turn off transcript saving) and the
/// account's CLAUDE_CONFIG_DIR only when it is not the default account.
enum ClaudeCLI {
    static let claudePath: String = {
        let candidates = [Paths.home.appendingPathComponent(".local/bin/claude").path, "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "claude"
    }()

    static let ghPath: String = [Paths.home.appendingPathComponent(".local/bin/gh").path, "/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
        .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/false"

    /// Removes Claude Code session markers from Maxwell's own environment once at
    /// launch, so every child (terminal surfaces included) starts clean.
    static func scrubOwnEnvironment() {
        for key in ProcessInfo.processInfo.environment.keys where isSessionMarker(key) { unsetenv(key) }
        // Finder launches get a minimal PATH; claude, git and gh live in these.
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let extra = [Paths.home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin"]
        setenv("PATH", (extra.filter { !path.contains($0) } + [path]).joined(separator: ":"), 1)
    }

    static func isSessionMarker(_ key: String) -> Bool {
        key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") || key == "CLAUDE_PID" || key == "CLAUDE_EFFORT"
            || key == "ANTHROPIC_PROFILE" || key == "ANTHROPIC_CONFIG_DIR" || key == "CLAUDE_CONFIG_DIR"
    }

    static func env(for account: Account) -> [String: String] {
        var e = ProcessInfo.processInfo.environment.filter { !isSessionMarker($0.key) }
        if let dir = account.configDirEnv { e["CLAUDE_CONFIG_DIR"] = dir }
        return e
    }

    struct Result { var status: Int32; var out: String; var err: String }

    /// Runs a process to completion off the main thread's critical path (call from a background queue).
    @discardableResult
    static func run(_ exe: String, _ args: [String], cwd: String? = nil, env: [String: String]? = nil, timeout: TimeInterval = 20) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        p.environment = env ?? ProcessInfo.processInfo.environment.filter { !isSessionMarker($0.key) }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return Result(status: -1, out: "", err: "\(error)") }
        let deadline = DispatchTime.now() + timeout
        let group = DispatchGroup()
        var outData = Data(), errData = Data()
        group.enter(); DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        if group.wait(timeout: deadline) == .timedOut { p.terminate() }
        p.waitUntilExit()
        return Result(status: p.terminationStatus, out: String(decoding: outData, as: UTF8.self), err: String(decoding: errData, as: UTF8.self))
    }

    static func agents(_ account: Account) -> Data? {
        // Test hook: a recorded listing, for screenshot runs on demo sessions.
        if let f = ProcessInfo.processInfo.environment["MAXWELL_AGENTS_FIXTURE"], !f.isEmpty { return try? Data(contentsOf: URL(fileURLWithPath: f)) }
        let r = run(claudePath, ["agents", "--json"], env: env(for: account), timeout: 10)
        return r.status == 0 ? Data(r.out.utf8) : nil
    }

    enum StartError: Error, CustomStringConvertible {
        case untrusted(String)
        case failed(String)
        var description: String {
            switch self {
            case .untrusted(let dir): return "\((dir as NSString).abbreviatingWithTildeInPath) is not trusted on this account yet."
            case .failed(let msg): return msg
            }
        }
    }

    /// `claude --bg --name <name> [--dangerously-skip-permissions] [--model <model>] [prompt]` in `cwd`.
    /// Returns the short id it prints. `model` is for test runs (haiku); sessions you start keep your default.
    static func startBackground(account: Account, cwd: String, name: String, skipPermissions: Bool, model: String? = nil, prompt: String? = nil) -> Swift.Result<String, StartError> {
        var args = ["--bg", "--name", name]
        if skipPermissions { args.append("--dangerously-skip-permissions") }
        if let model { args += ["--model", model] }
        if let prompt { args.append(prompt) }
        let r = run(claudePath, args, cwd: cwd, env: env(for: account), timeout: 30)
        let text = r.out + r.err
        if text.contains("Workspace not trusted") { return .failure(.untrusted(cwd)) }
        // "backgrounded · d2f54676 · name (idle — send a prompt to start)"
        guard r.status == 0, let line = text.components(separatedBy: "\n").first(where: { $0.contains("backgrounded") }) else {
            return .failure(.failed(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        let parts = line.components(separatedBy: " · ")
        guard parts.count >= 2 else { return .failure(.failed(line)) }
        return .success(parts[1].trimmingCharacters(in: .whitespaces))
    }

    /// Where a session that runs in another terminal is running.
    enum TerminalProcess: Equatable {
        case none                                           // no process: resuming is safe
        case found(pid: pid_t, skipsPermissions: Bool)
        case unsure(count: Int)                             // several in its folder, none known to be it
    }

    /// The interactive process running `s` in a terminal on `account`: the process Maxwell's hook
    /// recorded, Claude Code's own pid file (versions that write one for interactive sessions), or
    /// the one interactive `claude` in the session's folder (hooks from before the pid). That last
    /// guess is only made for the folder's newest session (`newestInFolder`): an older one that
    /// ended without saying so would otherwise be matched to someone else's live terminal.
    static func terminalProcess(_ s: Session, account: Account, newestInFolder: Bool) -> TerminalProcess {
        if case .elsewhere(let pid?) = s.reach, let args = interactiveArgs(pid_t(pid)) {
            return .found(pid: pid_t(pid), skipsPermissions: skipsPermissions(args))
        }
        let dir = account.configDir.appendingPathComponent("sessions")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for f in files where f.hasSuffix(".json") {
            guard let data = FileManager.default.contents(atPath: dir.appendingPathComponent(f).path),
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  j["sessionId"] as? String == s.id, j["kind"] as? String == "interactive",
                  let pid = (j["pid"] as? NSNumber)?.int32Value, let args = interactiveArgs(pid) else { continue }
            return .found(pid: pid, skipsPermissions: skipsPermissions(args))
        }
        let here = interactiveClaudes().filter { $0.cwd == s.cwd }
        if let p = here.first(where: { $0.args.contains(s.id) }) ?? (here.count == 1 && newestInFolder ? here.first : nil) {
            return .found(pid: p.pid, skipsPermissions: skipsPermissions(p.args))
        }
        return here.isEmpty || !newestInFolder ? .none : .unsure(count: here.count)
    }

    private static func skipsPermissions(_ args: String) -> Bool {
        args.contains("--dangerously-skip-permissions") || args.contains("bypassPermissions")
    }

    /// A `claude` someone runs in a terminal, not Claude Code's background machinery
    /// (`bg-spare`, `bg-pty-host`, `daemon`) or a one-off command (`attach`, `-p`, ...).
    static func isInteractiveClaude(_ args: String) -> Bool {
        let words = args.split(separator: " ").map(String.init)
        // `claude ...`, `/path/to/claude ...`, or `node /path/to/claude ...` (npm installs).
        guard words.prefix(2).contains(where: { ($0 as NSString).lastPathComponent == "claude" }) else { return false }
        let notInteractive: Set<String> = ["daemon", "attach", "agents", "logs", "stop", "mcp", "doctor", "update", "-p", "--print"]
        return !words.contains { notInteractive.contains($0) || $0.hasPrefix("--bg") || $0.hasPrefix("bg-") }
    }

    /// The process's arguments when it is alive and an interactive `claude`.
    private static func interactiveArgs(_ pid: pid_t) -> String? {
        guard pid > 1, kill(pid, 0) == 0 else { return nil }
        let args = run("/bin/ps", ["-o", "args=", "-p", "\(pid)"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        return isInteractiveClaude(args) ? args : nil
    }

    /// Every interactive `claude` on this Mac with its working folder.
    private static func interactiveClaudes() -> [(pid: pid_t, cwd: String, args: String)] {
        let procs: [(pid: pid_t, args: String)] = run("/bin/ps", ["-axo", "pid=,args="]).out.split(separator: "\n").compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let sp = t.firstIndex(of: " "), let pid = pid_t(t[..<sp]) else { return nil }
            let args = t[sp...].trimmingCharacters(in: .whitespaces)
            return isInteractiveClaude(args) ? (pid, args) : nil
        }
        guard !procs.isEmpty else { return [] }
        // `lsof -Fn` prints "p<pid>" and then "n<path>" for each process's working folder.
        var cwd: [pid_t: String] = [:], current: pid_t?
        for line in run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fn", "-p", procs.map { "\($0.pid)" }.joined(separator: ",")]).out.split(separator: "\n") {
            if line.hasPrefix("p") { current = pid_t(line.dropFirst()) }
            else if line.hasPrefix("n"), let p = current { cwd[p] = String(line.dropFirst()) }
        }
        return procs.compactMap { p in cwd[p.pid].map { (p.pid, $0, p.args) } }
    }

    // MARK: folder trust

    /// Claude Code's record of the folders it may work in: `projects[path].hasTrustDialogAccepted`
    /// in the account's `.claude.json` (`~/.claude.json` for the default account).
    static func trustFile(_ account: Account) -> URL {
        account.configDirEnv == nil ? Paths.home.appendingPathComponent(".claude.json") : account.configDir.appendingPathComponent(".claude.json")
    }

    /// True when `folder` or a folder above it is trusted on `account`.
    static func isTrusted(_ folder: String, account: Account) -> Bool {
        guard let data = FileManager.default.contents(atPath: trustFile(account).path),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = j["projects"] as? [String: Any] else { return false }
        var dir = folder
        while true {
            if (projects[dir] as? [String: Any])?["hasTrustDialogAccepted"] as? Bool == true { return true }
            let up = (dir as NSString).deletingLastPathComponent
            if up == dir || up.isEmpty { return false }
            dir = up
        }
    }

    /// Says yes to Claude Code's "Do you trust the files in this folder?" for `folder`, writing
    /// the same record its own prompt writes. Claude Code writes this file too, so it checks
    /// that the answer stuck and tries again if not.
    @discardableResult
    static func trust(_ folder: String, account: Account) -> Bool {
        let url = trustFile(account)
        for _ in 0..<3 {
            if isTrusted(folder, account: account) { return true }
            var j: [String: Any] = [:]
            if let data = FileManager.default.contents(atPath: url.path) {
                guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
                j = parsed
            }
            var projects = j["projects"] as? [String: Any] ?? [:]
            var entry = projects[folder] as? [String: Any] ?? [:]
            entry["hasTrustDialogAccepted"] = true
            projects[folder] = entry
            j["projects"] = projects
            guard let out = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted]) else { return false }
            try? out.write(to: url, options: .atomic)
            usleep(100_000)
        }
        return isTrusted(folder, account: account)
    }

    /// `claude --bg --resume <id>`: the same conversation, under the same id, as a background
    /// session. Claude starts a copy instead while it still sees the old process; that is reported.
    static func resumeBackground(account: Account, cwd: String, sessionId: String, name: String, skipPermissions: Bool) -> Swift.Result<(short: String, copy: Bool), StartError> {
        var args = ["--bg", "--resume", sessionId, "--name", name]
        if skipPermissions { args.append("--dangerously-skip-permissions") }
        let r = run(claudePath, args, cwd: cwd, env: env(for: account), timeout: 30)
        let text = r.out + r.err
        if text.contains("Workspace not trusted") { return .failure(.untrusted(cwd)) }
        guard r.status == 0, let line = text.components(separatedBy: "\n").first(where: { $0.contains("backgrounded") }) else {
            return .failure(.failed(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        let parts = line.components(separatedBy: " · ")
        guard parts.count >= 2 else { return .failure(.failed(line)) }
        return .success((parts[1].trimmingCharacters(in: .whitespaces), text.contains("started a copy")))
    }

    /// `claude stop <id>`: ends the process and keeps the conversation; `claude attach <id>`
    /// starts it again. Maxwell never deletes a session (no `claude rm`).
    static func stop(account: Account, shortId: String) -> Result {
        run(claudePath, ["stop", shortId], env: env(for: account))
    }
}
