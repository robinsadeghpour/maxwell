import Foundation
import CryptoKit

/// Claude Code's cloud sessions. Listing and archiving go through the Sessions API that Claude Code
/// itself uses (`claude --teleport`, claude.ai/code), signed in with the account's own Claude Code
/// login from the Keychain. Maxwell reads the access token Claude Code keeps fresh; it never refreshes,
/// stores or logs it. Starting and messaging use Claude Code's own commands.
enum CloudSessions {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case noLogin                 // no Claude Code login for this account in the Keychain
        case loginExpired            // Claude Code renews it the next time it runs on this account
        case http(Int)
        case network(String)
        case format                  // the API answered something Maxwell can't read
        case refused(String)         // Claude Code's own words, when a command didn't do it
        var description: String {
            switch self {
            case .noLogin: return "no Claude Code login for this account"
            case .loginExpired: return "the account's Claude Code login expired; it renews the next time Claude Code runs"
            case .http(let code): return code == 401 || code == 403 ? "the Sessions API refused the login (\(code))" : "the Sessions API answered \(code)"
            case .network(let why): return "couldn't reach the Sessions API: \(why)"
            case .format: return "the Sessions API answered in a shape Maxwell doesn't know"
            case .refused(let said): return said
            }
        }
    }

    private static let api = URL(string: "https://api.anthropic.com/v1/sessions")!

    /// The Keychain item with the account's login: "Claude Code-credentials" for ~/.claude, and
    /// "Claude Code-credentials-" plus the first 8 hex digits of SHA-256 of the config folder otherwise.
    static func keychainService(_ a: Account) -> String {
        guard a.configDirEnv != nil else { return "Claude Code-credentials" }
        let hash = SHA256.hash(data: Data(Paths.normalize(a.configDir.path).utf8)).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-" + hash.prefix(8)
    }

    private static func token(_ a: Account) -> Result<String, Failure> {
        let r = ClaudeCLI.run("/usr/bin/security", ["find-generic-password", "-s", keychainService(a), "-w"], timeout: 10)
        guard r.status == 0, let o = try? JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any],
              let oauth = o["claudeAiOauth"] as? [String: Any], let t = oauth["accessToken"] as? String else { return .failure(.noLogin) }
        if let ms = (oauth["expiresAt"] as? NSNumber)?.doubleValue, Date(timeIntervalSince1970: ms / 1000) < Date() { return .failure(.loginExpired) }
        return .success(t)
    }

    /// Call from a background queue: it waits for the answer.
    private static func call(_ a: Account, path: String, post: Bool = false) -> Result<Data, Failure> {
        let t: String
        switch token(a) { case .success(let v): t = v; case .failure(let f): return .failure(f) }
        var req = URLRequest(url: URL(string: api.absoluteString + path) ?? api, timeoutInterval: 20)
        req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("ccr-byoc-2025-07-29", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if post { req.httpMethod = "POST"; req.httpBody = Data("{}".utf8) }
        var out: Result<Data, Failure> = .failure(.network("no answer"))
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, response, error in
            defer { done.signal() }
            if let error { out = .failure(.network(error.localizedDescription)); return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            out = (200..<300).contains(code) ? .success(data ?? Data()) : .failure(.http(code))
        }.resume()
        done.wait()
        return out
    }

    /// The account's sessions, newest first; cloud ones only.
    static func list(_ a: Account) -> Result<CloudSnapshot, Failure> {
        let at = Date()
        return call(a, path: "?beta=true&limit=100").flatMap { data in
            CloudParser.parse(data, accountId: a.id, at: at).map { .success($0) } ?? .failure(.format)
        }
    }

    /// Ends the cloud session for good; its conversation stays readable on claude.ai.
    static func archive(_ id: SessionID, account a: Account) -> Result<Void, Failure> {
        call(a, path: "/\(id)/archive?beta=true", post: true).map { _ in () }
    }

    /// `claude --cloud "<task>"` in `cwd`: a new cloud session from the branch's last push. It only
    /// runs with a terminal, so it gets one from `script`. Returns what it printed about the session.
    static func start(_ task: String, cwd: String, account a: Account) -> Result<(id: SessionID, title: String, url: String), Failure> {
        // A folder Claude Code doesn't trust yet stops at its trust dialog: the caller asks first.
        let r = ClaudeCLI.run("/usr/bin/script", ["-q", "/dev/null", ClaudeCLI.claudePath, "--cloud", task], cwd: cwd, env: ClaudeCLI.env(for: a), timeout: 120)
        if let made = CloudParser.created(r.out + r.err) { return .success(made) }
        let said = (r.out + r.err).replacingOccurrences(of: #"\u{1B}\[[0-9;?<>]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
            .components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.first { $0.hasPrefix("Error") } ?? "claude --cloud didn't start a session"
        return .failure(.refused(said))
    }

    /// `claude -p "<text>" --cloud <id>`: queues a message for the session and returns.
    static func send(_ text: String, to id: SessionID, account a: Account) -> Bool {
        ClaudeCLI.run(ClaudeCLI.claudePath, ["-p", text, "--cloud", id], env: ClaudeCLI.env(for: a), timeout: 60).status == 0
    }

    /// The shell command that brings a cloud session onto this Mac, run in a terminal inside the
    /// project's checkout. `claude --teleport` checks out the session's branch and wants a clean
    /// worktree, so it runs in a new one under .claude/worktrees and your checkout stays as it is.
    static func teleportCommand(_ id: SessionID, account a: Account) -> String {
        let env = a.configDirEnv.map { "CLAUDE_CONFIG_DIR=\(shellQuote($0)) " } ?? ""
        let name = "cloud-" + id.suffix(8).lowercased()
        return "top=$(git rev-parse --show-toplevel) && dir=\"$top/.claude/worktrees/\(name)\" && "
            + "{ [ -d \"$dir\" ] || git -C \"$top\" worktree add --detach \"$dir\"; } && cd \"$dir\" && "
            + "\(env)\(shellQuote(ClaudeCLI.claudePath)) --teleport \(shellQuote(id))"
    }

    private static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
