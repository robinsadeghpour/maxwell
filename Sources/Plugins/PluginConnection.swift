import Foundation

/// One running plugin program: newline-delimited JSON-RPC 2.0 over its stdin and stdout
/// (docs/plugins.md, "The wire"). Reads on a background queue; every callback runs on main.
final class PluginConnection {
    struct RPCError: Error { var code: Int; var message: String }

    let manifest: PluginManifest
    private let process = Process()
    private let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    /// Serial queue that stderr reads and the exit handler share; see `start`.
    private let stderrTurns = DispatchQueue(label: "maxwell.plugin.stderr")
    private var buffer = Data()
    private var nextId = 1
    private var pending: [Int: (Result<Any, RPCError>) -> Void] = [:]
    private let log: FileHandle?
    private(set) var lastErrorLine: String?
    private var exited = false
    private let writes = DispatchQueue(label: "maxwell.plugin.write")
    /// Messages handed to the write queue and not yet written. A plugin that stops reading stdin
    /// blocks that queue; past the limit it is stopped rather than left to pile up.
    private var unwritten = 0
    static let maxUnwritten = 500
    private var logBytes = 0
    static let maxLog = 5 << 20
    /// Messages in the current second, to stop a plugin that floods.
    private var window = (start: Date(), count: 0)
    static let maxLine = 4 << 20
    static let maxPerSecond = 200

    /// A request or notification from the plugin. Answer requests with `respond`.
    var onMessage: ((_ method: String, _ params: [String: Any], _ id: Any?) -> Void)?
    /// The process is gone (or was stopped for misbehaving), with a one-line reason.
    var onExit: ((String) -> Void)?

    init(manifest: PluginManifest, env: [String: String], logURL: URL) {
        self.manifest = manifest
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        log = try? FileHandle(forWritingTo: logURL)
        _ = try? log?.seekToEnd()
        var cmd = manifest.run
        if cmd[0].hasPrefix("./") || !cmd[0].contains("/") && FileManager.default.fileExists(atPath: manifest.dir.appendingPathComponent(cmd[0]).path) {
            cmd[0] = manifest.dir.appendingPathComponent(cmd[0]).standardizedFileURL.path
        }
        if cmd[0].hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: cmd[0])
            process.arguments = Array(cmd.dropFirst())
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = cmd
        }
        process.currentDirectoryURL = manifest.dir
        process.environment = env
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
    }

    func start() throws {
        writeLog("--- start \(ISO8601DateFormatter().string(from: Date())) \(manifest.id) \(manifest.version)")
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            // End of file: stop asking, or the handler spins on a closed stdout.
            if d.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.received(d) }
        }
        // Reading stderr and handling the exit take turns on one queue, so the last lines a plugin
        // wrote before it died always reach `stderrData` before `finish` reports why it stopped.
        let errors = stderr.fileHandleForReading, turns = stderrTurns
        errors.readabilityHandler = { [weak self] h in
            turns.sync {
                let d = h.availableData
                guard !d.isEmpty else { h.readabilityHandler = nil; return }
                DispatchQueue.main.async { self?.stderrData(d) }
            }
        }
        process.terminationHandler = { [weak self] p in
            let why = p.terminationReason == .uncaughtSignal ? "killed by signal \(p.terminationStatus)" : "exited with status \(p.terminationStatus)"
            turns.sync {
                errors.readabilityHandler = nil
                let rest = Self.readWaiting(errors)
                DispatchQueue.main.async {
                    if !rest.isEmpty { self?.stderrData(rest) }
                    self?.finish(why)
                }
            }
        }
        try process.run()
    }

    var pid: Int32 { process.processIdentifier }

    func notify(_ method: String, _ params: [String: Any]) { write(["jsonrpc": "2.0", "method": method, "params": params]) }

    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval = 10, reply: @escaping (Result<Any, RPCError>) -> Void) {
        let id = nextId
        nextId += 1
        pending[id] = reply
        write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let r = self?.pending.removeValue(forKey: id) else { return }
            r(.failure(RPCError(code: -32000, message: "\(method) timed out after \(Int(timeout)) s")))
        }
    }

    func respond(_ id: Any, result: Any) { write(["jsonrpc": "2.0", "id": id, "result": result]) }
    func respond(_ id: Any, error: RPCError) { write(["jsonrpc": "2.0", "id": id, "error": ["code": error.code, "message": error.message]]) }

    /// `shutdown`, then close stdin; SIGTERM after 2 s if it is still there.
    func stop() {
        guard !exited else { return }
        request("shutdown", [:], timeout: 2) { [weak self] _ in
            try? self?.stdin.fileHandleForWriting.close()
        }
        // Strong on purpose: the host has already let go, and this must still run.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard !self.exited else { return }
            self.process.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if !self.exited { Darwin.kill(self.process.processIdentifier, SIGKILL) }
            }
        }
    }

    /// Stops it now, for a plugin that misbehaves.
    func kill(_ why: String) {
        guard !exited else { return }
        writeLog("--- stopped by Maxwell: \(why)")
        lastErrorLine = why
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if self.map({ !$0.exited }) ?? true { Darwin.kill(pid, SIGKILL) }
        }
    }

    // MARK: -

    private func write(_ message: [String: Any]) {
        guard !exited, process.isRunning, var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        // A plugin that stopped reading must not block Maxwell: write off the main thread.
        let h = stdin.fileHandleForWriting
        unwritten += 1
        if unwritten > Self.maxUnwritten { return kill("stopped reading what Maxwell sends") }
        writes.async { [weak self] in
            try? h.write(contentsOf: data)
            DispatchQueue.main.async { self?.unwritten -= 1 }
        }
    }

    private func received(_ d: Data) {
        guard !d.isEmpty else { return }
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            handle(line)
        }
        if buffer.count > Self.maxLine { buffer.removeAll(); writeLog("--- dropped a line over 4 MB") }
    }

    private func handle(_ line: Data) {
        guard !line.isEmpty, !exited else { return }
        let now = Date()
        if now.timeIntervalSince(window.start) >= 1 { window = (now, 0) }
        window.count += 1
        if window.count > Self.maxPerSecond { return kill("sent over \(Self.maxPerSecond) messages a second") }
        guard let m = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            writeLog("--- not JSON on stdout: \(String(decoding: line.prefix(200), as: UTF8.self))")
            return
        }
        if let method = m["method"] as? String {
            onMessage?(method, (m["params"] as? [String: Any]) ?? [:], m["id"])
        } else if let id = (m["id"] as? NSNumber)?.intValue, let reply = pending.removeValue(forKey: id) {
            if let e = m["error"] as? [String: Any] {
                reply(.failure(RPCError(code: (e["code"] as? NSNumber)?.intValue ?? -32603, message: (e["message"] as? String) ?? "failed")))
            } else {
                reply(.success(m["result"] ?? NSNull()))
            }
        }
    }

    /// What the pipe holds right now, without waiting for more: a process that exited has written everything.
    private static func readWaiting(_ h: FileHandle) -> Data {
        let fd = h.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var out = Data(), buf = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = read(fd, &buf, buf.count)
            guard n > 0 else { return out }
            out.append(buf, count: n)
        }
    }

    private func stderrData(_ d: Data) {
        guard !exited else { return }
        // The log keeps the first 5 MB of a run; a plugin that floods stderr can't fill the disk.
        if logBytes < Self.maxLog { logBytes += d.count; log.map { try? $0.write(contentsOf: d) } }
        if let last = String(decoding: d, as: UTF8.self).split(whereSeparator: \.isNewline).last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            lastErrorLine = String(last.prefix(160))
        }
    }

    private func finish(_ why: String) {
        guard !exited else { return }
        exited = true
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        for (_, r) in pending { r(.failure(RPCError(code: -32000, message: "plugin stopped"))) }
        pending.removeAll()
        writeLog("--- \(why)")
        try? log?.close()
        logClosed = true
        onExit?(lastErrorLine.map { "\(why): \($0)" } ?? why)
    }

    private func writeLog(_ s: String) {
        guard !logClosed else { return }
        log.map { try? $0.write(contentsOf: Data((s + "\n").utf8)) }
    }
    private var logClosed = false
}
