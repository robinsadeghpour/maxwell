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

    /// `claude --bg --name <name> [--model <model>] [prompt]` in `cwd`. Returns the short id it prints.
    /// `model` is for test runs (haiku); sessions you start keep your default.
    static func startBackground(account: Account, cwd: String, name: String, model: String? = nil, prompt: String? = nil) -> Swift.Result<String, StartError> {
        var args = ["--bg", "--name", name]
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

    /// The interactive process running `sessionId` in a terminal on this account, from Claude
    /// Code's own pid files (`<config>/sessions/<pid>.json`), with whether it skips permissions.
    static func terminalProcess(sessionId: String, account: Account) -> (pid: pid_t, skipsPermissions: Bool)? {
        let dir = account.configDir.appendingPathComponent("sessions")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for f in files where f.hasSuffix(".json") {
            guard let data = FileManager.default.contents(atPath: dir.appendingPathComponent(f).path),
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  j["sessionId"] as? String == sessionId, j["kind"] as? String == "interactive",
                  let pid = (j["pid"] as? NSNumber)?.int32Value, kill(pid, 0) == 0 else { continue }
            let args = run("/bin/ps", ["-o", "args=", "-p", "\(pid)"]).out
            return (pid, args.contains("--dangerously-skip-permissions") || args.contains("bypassPermissions"))
        }
        return nil
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
