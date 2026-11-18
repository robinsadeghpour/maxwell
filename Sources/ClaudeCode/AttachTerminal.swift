import Darwin
import Foundation

/// `claude attach <shortId>` on a pseudo-terminal with no window: what the phone types into and
/// what its Terminal tab shows. Claude Code lets several attaches share one background session, and
/// what one types shows in the others (docs/claude-code-internals.md). Main thread only.
///
/// Started with posix_spawn in a new session that opens the terminal by name, which makes it the
/// controlling terminal, so a resize reaches Claude as SIGWINCH. Closing hangs up the terminal, the
/// way closing a Maxwell pane does; the session keeps running.
final class AttachTerminal {
    let session: SessionID
    private(set) var pid: pid_t = 0
    private var master: Int32 = -1
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var pending = Data()
    static let maxPending = 1 << 20
    private var exitWatch: DispatchSourceProcess?
    var onOutput: ((Data) -> Void)?
    var onExit: (() -> Void)?

    enum StartError: Error, CustomStringConvertible {
        case pty(Int32), spawn(Int32)
        var description: String {
            switch self {
            case .pty(let e): return "couldn't open a terminal (\(String(cString: strerror(e))))"
            case .spawn(let e): return "couldn't start claude attach (\(String(cString: strerror(e))))"
            }
        }
    }

    init(session: SessionID) { self.session = session }

    func start(shortId: String, account: Account, cwd: String, cols: Int, rows: Int) -> StartError? {
        var m: Int32 = -1, s: Int32 = -1
        var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: cols), ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&m, &s, nil, nil, &size) == 0 else { return .pty(errno) }
        let name = String(cString: ptsname(m))
        Darwin.close(s)
        var env = ClaudeCLI.env(for: account)
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        let args = [ClaudeCLI.claudePath, "attach", shortId]
        let dir = FileManager.default.fileExists(atPath: cwd) ? cwd : Paths.home.path
        let err = Self.spawn(args, env: env, tty: name, cwd: dir, pid: &pid)
        guard err == 0 else { Darwin.close(m); return .spawn(err) }
        master = m
        _ = fcntl(m, F_SETFL, fcntl(m, F_GETFL) | O_NONBLOCK)
        watch()
        return nil
    }

    private static func spawn(_ args: [String], env: [String: String], tty: String, cwd: String, pid: inout pid_t) -> Int32 {
        var actions: posix_spawn_file_actions_t?
        var attr: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attr)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attr) }
        posix_spawn_file_actions_addopen(&actions, 0, tty, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)
        posix_spawn_file_actions_addchdir_np(&actions, cwd)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        let argv = args.map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        return posix_spawn(&pid, args[0], &actions, &attr, argv, envp)
    }

    private func watch() {
        let r = DispatchSource.makeReadSource(fileDescriptor: master, queue: .main)
        r.setEventHandler { [weak self] in self?.drain() }
        r.resume()
        reader = r
        let p = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        p.setEventHandler { [weak self] in self?.exited() }
        p.resume()
        exitWatch = p
    }

    private func drain() {
        var buf = [UInt8](repeating: 0, count: 65536)
        var got = Data()
        while true {
            let n = read(master, &buf, buf.count)
            if n > 0 { got.append(contentsOf: buf[0..<n]); if got.count >= 512 * 1024 { break }; continue }
            break
        }
        if !got.isEmpty { onOutput?(got) }
    }

    private func exited() {
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        teardown()
        onExit?()
    }

    var isRunning: Bool { master >= 0 }

    /// Queues bytes for Claude and writes what the terminal takes now; the rest goes out as it drains,
    /// never by waiting on the main thread. False (and nothing queued) past 1 MB waiting.
    @discardableResult
    func write(_ data: Data) -> Bool {
        guard master >= 0 else { return false }
        guard pending.count + data.count <= Self.maxPending else {
            mark("phone: \(data.count) bytes for the terminal dropped, \(pending.count) still waiting")
            return false
        }
        pending.append(data)
        flush()
        return true
    }

    private func flush() {
        while !pending.isEmpty, master >= 0 {
            let n = pending.withUnsafeBytes { p in p.baseAddress.map { Darwin.write(master, $0, p.count) } ?? 0 }
            if n > 0 { pending.removeFirst(n); continue }
            if n < 0, errno == EAGAIN || errno == EINTR { break }
            pending.removeAll()
        }
        if pending.isEmpty || master < 0 {
            writer?.cancel()
            writer = nil
        } else if writer == nil {
            let w = DispatchSource.makeWriteSource(fileDescriptor: master, queue: .main)
            w.setEventHandler { [weak self] in self?.flush() }
            w.resume()
            writer = w
        }
    }

    func resize(cols: Int, rows: Int) {
        guard master >= 0 else { return }
        var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)
    }

    /// Hangs up: `claude attach` exits and the session keeps running in the background.
    func close() {
        guard master >= 0 else { return }
        let p = pid
        teardown()
        guard p > 0 else { return }
        kill(p, SIGHUP)
        // Reaped off the main thread once it has gone, so no zombie is left.
        DispatchQueue.global(qos: .utility).async { var st: Int32 = 0; waitpid(p, &st, 0) }
    }

    private func teardown() {
        reader?.cancel(); reader = nil
        writer?.cancel(); writer = nil
        pending.removeAll()
        exitWatch?.cancel(); exitWatch = nil
        if master >= 0 { Darwin.close(master); master = -1 }
    }

    deinit { close() }
}
