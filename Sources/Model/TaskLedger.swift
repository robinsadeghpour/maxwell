import Foundation

struct BackgroundTask: Codable, Equatable {
    enum Kind: String, Codable { case agent, shell }
    var id: String
    var kind: Kind
    var label: String?      // the agent's description; nil for shells
    var startedAt: Date
}

extension Array where Element == BackgroundTask {
    var agents: [BackgroundTask] { filter { $0.kind == .agent } }
    /// "3 agents", "1 agent · 2 shells", "1 shell"; empty when nothing runs.
    var summary: String {
        let a = agents.count, sh = count - a
        return [a > 0 ? "\(a) agent\(a == 1 ? "" : "s")" : nil, sh > 0 ? "\(sh) shell\(sh == 1 ? "" : "s")" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
    /// "2 subagents and 1 background shell running", for a check or the Working banner.
    var running: String {
        let a = agents.count, sh = count - a
        let what = [a > 0 ? "\(a) subagent\(a == 1 ? "" : "s")" : nil, sh > 0 ? "\(sh) background shell\(sh == 1 ? "" : "s")" : nil]
        return what.compactMap { $0 }.joined(separator: " and ") + " running"
    }
}

/// Background work a transcript shows: shells started with run_in_background
/// (`toolUseResult.backgroundTaskId`) and async subagents (`toolUseResult.isAsync` + `agentId`),
/// each ended by a `<task-notification>` naming its task id with a status other than running,
/// or by a TaskStop result ("Successfully stopped task", `task_id`).
struct TaskLedger: Codable {
    private(set) var started: [String: BackgroundTask] = [:]
    private(set) var finished = Set<String>()

    mutating func read(_ line: Data) {
        // Byte searches first: most lines (and every multi-megabyte request blob) match neither.
        if line.range(of: Self.taskIdTag) != nil { noteFinished(line) }
        guard line.range(of: Self.startedKey) != nil || line.range(of: Self.asyncKey) != nil || line.range(of: Self.stoppedKey) != nil,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let r = obj["toolUseResult"] as? [String: Any] else { return }
        let at = (obj["timestamp"] as? String).flatMap { Self.iso.date(from: $0) } ?? .distantPast
        if let id = r["backgroundTaskId"] as? String { started[id] = BackgroundTask(id: id, kind: .shell, startedAt: at) }
        if r["isAsync"] as? Bool == true, let id = r["agentId"] as? String {
            started[id] = BackgroundTask(id: id, kind: .agent, label: r["description"] as? String, startedAt: at)
        }
        if (r["message"] as? String)?.hasPrefix("Successfully stopped task") == true, let id = r["task_id"] as? String { finished.insert(id) }
    }

    /// Tasks started at or after `since` (the session's process start: older ones died with
    /// their process) and not reported done.
    func running(since: Date) -> [BackgroundTask] {
        started.values.filter { $0.startedAt >= since && !finished.contains($0.id) }.sorted { $0.startedAt < $1.startedAt }
    }

    /// Each "<task-id>X</task-id>" with a "<status>" before the next task id ends task X,
    /// unless that status is "running". An agent that stopped with background work of its own
    /// is reported "completed" but resumes later under the same id, so it stays running until
    /// a later notice ends it.
    private mutating func noteFinished(_ line: Data) {
        var from = line.startIndex
        while let open = line.range(of: Self.taskIdTag, in: from..<line.endIndex) {
            guard let close = line.range(of: Self.taskIdEnd, in: open.upperBound..<line.endIndex) else { return }
            let id = String(decoding: line[open.upperBound..<close.lowerBound], as: UTF8.self)
            let next = line.range(of: Self.taskIdTag, in: close.upperBound..<line.endIndex)?.lowerBound ?? line.endIndex
            if line.range(of: Self.waitingNote, in: close.upperBound..<next) != nil {
                finished.remove(id)
            } else if let st = line.range(of: Self.statusTag, in: close.upperBound..<next),
               let stEnd = line.range(of: Self.statusEnd, in: st.upperBound..<next),
               String(decoding: line[st.upperBound..<stEnd.lowerBound], as: UTF8.self) != "running" {
                finished.insert(id)
            }
            from = close.upperBound
        }
    }

    private static let taskIdTag = Data("<task-id>".utf8), taskIdEnd = Data("</task-id>".utf8)
    private static let statusTag = Data("<status>".utf8), statusEnd = Data("</status>".utf8)
    private static let startedKey = Data("\"backgroundTaskId\"".utf8), asyncKey = Data("\"isAsync\":true".utf8)
    private static let stoppedKey = Data("Successfully stopped task".utf8)
    private static let waitingNote = Data("stopped with background work of its own still running".utf8)
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
