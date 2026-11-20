import Foundation

/// The lines voice mode speaks and what a spoken reply means. Pure: Sources/Voice hears and speaks.
enum VoiceLine {
    /// "Hey Ada. Billing needs you. Should I migrate first?"
    static func announcement(title: String, question: String, name: String) -> String {
        let hey = name.isEmpty ? "" : "Hey \(name). "
        return "\(hey)\(title) needs you. \(spoken(question))"
    }

    /// A second session asking while another is on the line: named, not read out.
    static func also(title: String) -> String { "\(title) also needs you." }

    /// A permission prompt is a menu in the terminal, not a question a sentence answers.
    static func permission(title: String, question: String) -> String {
        "\(title) asks for a permission. \(spoken(question)) Answer that one in Maxwell."
    }

    static func greeting(waiting: Int) -> String {
        switch waiting {
        case 0: return "Voice mode is on. Nothing needs you."
        case 1: return "Voice mode is on. One session needs you."
        default: return "Voice mode is on. \(waiting) sessions need you."
        }
    }

    /// Text as a voice should read it: no markdown marks, code blocks or raw links, and not the whole reply.
    static func spoken(_ text: String, limit: Int = 420) -> String {
        var s = text
        for (pattern, with) in [("```[\\s\\S]*?```", " a code block "), ("\\[([^\\]]+)\\]\\([^)]*\\)", "$1"), ("https?://\\S+", "a link"),
                                ("[*_`#>]+", ""), ("\\s+", " ")] {
            s = s.replacingOccurrences(of: pattern, with: with, options: .regularExpression)
        }
        s = s.trimmingCharacters(in: .whitespaces)
        guard s.count > limit else { return s }
        let head = String(s.prefix(limit))
        // End on a sentence when one ends in the second half; a cut mid-word sounds broken.
        if let end = head.lastIndex(where: { ".?!".contains($0) }), head.distance(from: head.startIndex, to: end) > limit / 2 {
            return String(head[...end]) + " There is more in Maxwell."
        }
        return head + "… There is more in Maxwell."
    }

    enum Heard: Equatable {
        case answer(String)
        /// Leave this session for later and go to the next.
        case skip
        case again
        /// Throw away what was just said; the session stays on the line.
        case cancel
        case hangUp
    }

    private static let skips: Set<String> = ["skip", "later", "next", "not now", "überspringen", "später", "weiter", "nicht jetzt"]
    private static let agains: Set<String> = ["repeat", "again", "say that again", "repeat that", "nochmal", "noch mal", "wiederholen"]
    private static let hangUps: Set<String> = ["goodbye", "stop listening", "end call", "hang up", "voice mode off", "tschüss", "auflegen"]
    private static let cancels = ["cancel", "never mind", "scratch that", "abbrechen", "vergiss es"]

    /// Only a reply that is nothing but a command counts as one, so "skip the tests" is still an answer.
    static func heard(_ text: String) -> Heard {
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let plain = said.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        if plain.isEmpty { return .cancel }
        if skips.contains(plain) { return .skip }
        if agains.contains(plain) { return .again }
        if hangUps.contains(plain) { return .hangUp }
        // "…deploy it. No wait, cancel": the last words take the whole reply back.
        if cancels.contains(where: { plain == $0 || plain.hasSuffix(" " + $0) }) { return .cancel }
        return .answer(said)
    }
}

/// Whose turn it is to be asked: one session on the line, the rest waiting in the order they asked.
struct VoiceCall: Equatable {
    struct Asking: Equatable {
        var id: SessionID
        var question: String
        /// False for a permission prompt: it is said, but a spoken reply can't answer it.
        var answerable = true
    }

    enum Step: Equatable {
        /// Read the question out; the session is on the line now.
        case announce(SessionID, String)
        /// Name a session that started waiting while another is on the line.
        case mention(SessionID)
        /// Say it and move on: nothing spoken can answer it.
        case tell(SessionID, String)
    }

    private(set) var onLine: SessionID?
    private(set) var waiting: [SessionID] = []
    /// The question each session was last queued or announced with. The same question again is not news.
    private(set) var asked: [SessionID: String] = [:]

    /// `asking`: every session that needs you now, oldest first. Returns what to say, in order.
    mutating func update(_ asking: [Asking]) -> [Step] {
        var steps: [Step] = []
        let now = Dictionary(asking.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        waiting.removeAll { now[$0] == nil }
        // Answered some other way (typed in Maxwell, on the phone): the line is free.
        if let id = onLine, now[id] == nil { onLine = nil }
        for a in asking where asked[a.id] != a.question {
            asked[a.id] = a.question
            if !a.answerable { steps.append(.tell(a.id, a.question)); continue }
            if a.id == onLine { steps.append(.announce(a.id, a.question)); continue }
            if !waiting.contains(a.id) { waiting.append(a.id) }
            if onLine != nil { steps.append(.mention(a.id)) }
        }
        if onLine == nil, let next = waiting.first, let q = now[next]?.question {
            waiting.removeFirst()
            onLine = next
            steps.append(.announce(next, q))
        }
        return steps
    }

    /// The session on the line was answered or skipped. It isn't asked again until its question changes.
    mutating func release() { onLine = nil }
}
