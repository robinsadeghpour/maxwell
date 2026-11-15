import Foundation

/// Which of Maxwell's own terminals a terminal session runs in. Each terminal Maxwell opens
/// carries a tag in its environment; a `claude` started there inherits it, so reading the tag
/// from the session's process says which terminal it lives in. That session's row then takes
/// the terminal's place instead of showing up twice.
final class TerminalHosts {
    static let envKey = "MAXWELL_TERMINAL"
    /// Process id → terminal tag (nil: none). A process keeps its environment, so one read is enough.
    private var tags: [Int: String?] = [:]

    /// The value a terminal's environment carries. The app's pid keeps tags from an earlier launch apart.
    static func tag(_ terminalId: String) -> String { "\(getpid()):\(terminalId)" }

    /// Session → terminal id, for terminal sessions whose process runs in one of `terminalIds`.
    func hosts(_ sessions: [Session], terminalIds: [String]) -> [SessionID: String] {
        guard !terminalIds.isEmpty else { return [:] }
        let byTag = Dictionary(uniqueKeysWithValues: terminalIds.map { (Self.tag($0), $0) })
        var out: [SessionID: String] = [:]
        for s in sessions where s.phase != .ended {
            guard case .elsewhere(let pid?) = s.reach else { continue }
            if tags[pid] == nil { tags[pid] = .some(Self.environment(of: pid_t(pid))[Self.envKey]) }
            if let tag = tags[pid] ?? nil, let id = byTag[tag] { out[s.id] = id }
        }
        return out
    }

    /// Another process's environment, read with sysctl (the same user's processes only).
    /// Layout of KERN_PROCARGS2: argc, the executable path, argv, then the environment, NUL-separated.
    static func environment(of pid: pid_t) -> [String: String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [:] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [:] }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        let parts = buf[4..<size].split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
        // parts: the executable path, argc arguments, then KEY=value pairs.
        var env: [String: String] = [:]
        for p in parts.dropFirst(1 + Int(argc)) {
            guard let eq = p.firstIndex(of: "=") else { continue }
            env[String(p[..<eq])] = String(p[p.index(after: eq)...])
        }
        return env
    }
}
