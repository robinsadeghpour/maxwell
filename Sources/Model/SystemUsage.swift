import Foundation

/// A process on this Mac. Not a session id and not a background session's short id.
struct ProcessID: Hashable {
    var raw: Int32
}

/// One process as `ps` lists it.
struct ProcessSample: Equatable {
    var pid: ProcessID
    var parent: ProcessID
    /// Share of one core, as `ps` reports it: an average over the last few seconds.
    var cpu: Double
    /// Resident memory in bytes.
    var memory: UInt64
    var command: String

    /// The Claude Code binary (`~/.local/share/claude/versions/<v>`), its `claude` launcher, or one of
    /// the processes the background service names for itself (`claude bg-pty-host`, `claude bg-spare`).
    var isClaude: Bool {
        let name = (command as NSString).lastPathComponent
        return name == "claude" || name.hasPrefix("claude ") || command.contains("/claude/versions/")
    }
}

/// What a group of processes uses. CPU is a share of the whole Mac, so loads add up to the machine's.
struct Load: Equatable {
    var cpu = 0.0
    var memory: UInt64 = 0
    var processes = 0

    mutating func add(_ p: ProcessSample, cores: Int) {
        cpu += p.cpu / Double(max(1, cores))
        memory += p.memory
        processes += 1
    }
    static func + (a: Load, b: Load) -> Load { Load(cpu: a.cpu + b.cpu, memory: a.memory + b.memory, processes: a.processes + b.processes) }
}

/// How hard macOS is working to find memory, as Activity Monitor's Memory Pressure graph shows it.
enum MemoryPressure: Equatable {
    case normal, high, critical, unknown

    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.
    init(level: Int32?) {
        switch level {
        case 1: self = .normal
        case 2: self = .high
        case 4: self = .critical
        default: self = .unknown
        }
    }
}

/// One reading of the whole Mac and of Claude Code on it.
struct SystemSample: Equatable {
    var at = Date()
    var cores = ProcessInfo.processInfo.activeProcessorCount
    var memTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    var memUsed: UInt64 = 0
    var pressure = MemoryPressure.unknown
    var machineCPU = 0.0
    var maxwell = Load()
    /// Each running session: its Claude Code process and everything it started.
    var sessions: [SessionID: Load] = [:]
    /// Claude Code processes that belong to no session: spare workers, launchers, the background service.
    var otherClaude = Load()

    var claude: Load { sessions.values.reduce(otherClaude, +) }
}

enum SystemUsage {
    /// `ps -Ao pid=,ppid=,%cpu=,rss=,comm=`. `rss` is in KiB; the command may hold spaces.
    static func parse(ps out: String) -> [ProcessSample] {
        out.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard f.count == 5, let pid = Int32(f[0]), let parent = Int32(f[1]), let cpu = Double(f[2]), let rss = UInt64(f[3]) else { return nil }
            return ProcessSample(pid: ProcessID(raw: pid), parent: ProcessID(raw: parent), cpu: cpu, memory: rss * 1024, command: String(f[4]))
        }
    }

    /// Splits Claude Code's processes by session. A process counts toward the first session found
    /// above it, so a session's shell commands, MCP servers and subagents are its own. The launcher a
    /// session runs under counts toward that session. A session pid counts only while it is still a
    /// Claude Code process, so a reused pid never lends a session someone else's load.
    static func split(_ procs: [ProcessSample], sessions pids: [ProcessID: SessionID], cores: Int) -> (sessions: [SessionID: Load], other: Load) {
        let byPid = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let live = pids.filter { byPid[$0.key]?.isClaude == true }
        var launched: [ProcessID: SessionID] = [:]
        for (pid, id) in live { if let parent = byPid[pid]?.parent, byPid[parent]?.isClaude == true, live[parent] == nil { launched[parent] = id } }
        func owner(_ p: ProcessSample) -> SessionID? {
            var at = p.pid
            for _ in 0..<64 {
                if let id = live[at] ?? launched[at] { return id }
                guard let up = byPid[at]?.parent, up != at, up.raw > 1 else { return nil }
                at = up
            }
            return nil
        }
        var sessions: [SessionID: Load] = [:], other = Load()
        for p in procs {
            if let id = owner(p) { sessions[id, default: Load()].add(p, cores: cores) } else if p.isClaude { other.add(p, cores: cores) }
        }
        return (sessions, other)
    }
}

/// The last five minutes of machine and Claude Code CPU, one point per reading. A gap in the
/// readings (the panel was hidden) stays a gap: points carry their time.
struct SystemHistory: Equatable {
    struct Point: Equatable { var at: Date; var machine: Double; var claude: Double }
    static let span: TimeInterval = 300
    private(set) var points: [Point] = []

    mutating func add(_ s: SystemSample) {
        points.append(Point(at: s.at, machine: s.machineCPU, claude: s.claude.cpu))
        points.removeAll { $0.at < s.at.addingTimeInterval(-Self.span) }
    }
}
