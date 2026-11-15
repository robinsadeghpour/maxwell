import Foundation

/// How the plugin is doing, which decides what the panel shows when the list can't.
enum Health: Equatable {
    case loading
    case setup(String)            // no token, or Slack refused it
    case ok(checked: Date)
    case offline(since: Date)     // the last list stays, marked as old
    case error(String)
}

/// The panel as data (protocol v1 `panel/set` view). Pure, so the tests read what Maxwell would draw.
enum Panel {
    static let id = "waiting"

    /// An item's place in the session loop: its status and the session working on it.
    struct Linked: Equatable { var status: ItemStatus; var session: String?; var group: String? }

    static func view(_ items: [Waiting], health: Health, linked: [String: Linked] = [:], now: Date = Date()) -> [String: Any] {
        switch health {
        case .loading where items.isEmpty:
            return ["type": "loading", "title": "Reading Slack…"]
        case .setup(let why):
            return ["type": "empty", "title": "Connect Slack", "body": why,
                    "action": ["action": "connect", "title": "Create Slack App…"]]
        case .error(let e) where items.isEmpty:
            return ["type": "empty", "title": "Couldn't read Slack", "body": e,
                    "action": ["action": "refresh", "title": "Try Again"]]
        default:
            break
        }
        if items.isEmpty {
            let when: String
            if case .ok(let d) = health { when = "Checked \(clock(d))." } else { when = "" }
            return ["type": "empty", "title": "Nobody is waiting on you", "body": "All answered. \(when)"]
        }
        let status = { (w: Waiting) in linked[w.key]?.status ?? (w.state == .owed ? .owed : .needsYou) }
        let row = { (w: Waiting) in Panel.row(w, linked: linked[w.key], now: now) }
        let ready = items.filter { status($0) == .readyToClose }
        let waiting = items.filter { status($0) == .needsYou }
        let inSession = items.filter { status($0) == .inSession }
        let owed = items.filter { status($0) == .owed }
        let urgent = waiting.filter(isUrgent)
        let rest = waiting.filter { !isUrgent($0) }
        var sections: [[String: Any]] = []
        if !ready.isEmpty { sections.append(["title": "Session done, reply", "rows": ready.map(row)]) }
        if !urgent.isEmpty { sections.append(["title": "Answer first", "rows": urgent.map(row)]) }
        if !rest.isEmpty { sections.append(["title": urgent.isEmpty ? "Waiting on you" : "Questions and requests", "rows": rest.map(row)]) }
        if waiting.isEmpty && ready.isEmpty { sections.append(["title": "Nobody is waiting on a reply", "rows": []]) }
        if !inSession.isEmpty { sections.append(["title": "In a session", "rows": inSession.map(row)]) }
        if !owed.isEmpty { sections.append(["title": "You said you'd do it", "rows": owed.map(row)]) }
        if case .offline(let since) = health {
            sections.insert(["title": "Offline since \(clock(since)): this list may be old", "rows": []], at: 0)
        }
        return ["type": "list", "sections": sections]
    }

    /// How a row reads. `line` ships; the others are the options shown in the PR.
    enum Layout: String { case people, asks, line }
    static var layout = Layout(rawValue: ProcessInfo.processInfo.environment["MAXWELL_SLACK_LAYOUT"] ?? "") ?? .line

    static func isUrgent(_ w: Waiting) -> Bool { w.kind == .bug || w.whoKind == .external || w.bumped }

    /// What the panel's count says: people waiting on a reply, including after a session finished.
    static func count(_ items: [Waiting], linked: [String: Linked]) -> Int {
        items.filter { w in [.needsYou, .readyToClose].contains(linked[w.key]?.status ?? (w.state == .owed ? .owed : .needsYou)) }.count
    }

    static func row(_ w: Waiting, linked: Linked? = nil, now: Date) -> [String: Any] {
        let a = age(w.since, now: now)
        let (title, subtitle): (String, String)
        switch layout {
        case .people: (title, subtitle) = ("\(w.who)\(w.count > 1 ? " +\(w.count - 1)" : "")", "\(a) · \(w.place) · \(w.ask)")
        case .asks: (title, subtitle) = (w.ask, "\(w.who) · \(a) · \(w.place)")
        case .line: (title, subtitle) = ("\(w.who) · \(w.ask)", "\(a) · \(w.place)")
        }
        let st = linked?.status ?? (w.state == .owed ? .owed : .needsYou)
        let sessionNote = st == .inSession ? (linked?.group == "needsYou" ? "session needs you" : "session working")
            : st == .readyToClose ? "session done" : nil
        var r: [String: Any] = [
            "id": w.key,
            "title": title,
            "subtitle": sessionNote.map { subtitle + " · " + $0 } ?? subtitle,
            "status": st.rawValue,
            "url": w.link,
            "trailing": a,
            "tooltip": w.state == .owed
                ? "You told \(w.who) you'd do it \(age(w.since, now: now)) ago (\(w.place)). It leaves the list when you reply with the result."
                : "\(w.who) in \(w.place), waiting \(age(w.since, now: now)). Listed because: \(w.reason).",
            // Clicking the row opens the message (or its session); the buttons are what you do about it.
            "actions": linked?.session != nil ? [
                ["action": "open-message", "title": st == .readyToClose ? "Reply in Slack" : "Open in Slack"],
                ["action": "handled", "title": "Handled"],
                ["action": "snooze", "title": "Snooze 3h"],
                ["action": "not-for-me", "title": "Not for Me"],
            ] : [
                ["action": "start-session", "title": "Start Session"],
                ["action": "handled", "title": "Handled"],
                ["action": "snooze", "title": "Snooze 3h"],
                ["action": "not-for-me", "title": "Not for Me"],
                ["action": "open-message", "title": "Open in Slack"],
            ],
        ]
        if let sid = linked?.session { r["session"] = sid }
        if let b = badge(w) { r["badge"] = b }
        r["tone"] = w.state == .owed ? "neutral" : isUrgent(w) ? "bad" : "warn"
        return r
    }

    static func badge(_ w: Waiting) -> [String: String]? {
        if w.bumped && w.state == .waiting { return ["text": "again", "tone": "bad"] }
        switch (w.kind, w.whoKind) {
        case (.bug, _): return ["text": "bug", "tone": "bad"]
        case (_, .external): return ["text": "customer", "tone": "warn"]
        case (.decision, _): return ["text": "decision", "tone": "info"]
        default: return nil
        }
    }

    /// Compact age, the same steps as Maxwell's session rows: 42s, 7m, 3h, 2d.
    static func age(_ d: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(d)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }

    static func clock(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    /// What a new session is told: the ask, the messages around it, and where to answer.
    static func prompt(_ w: Waiting, context: [String], demo: Bool = false) -> String {
        var p = demo ? "This is a made-up test message from Maxwell's demo data. Don't look it up in Slack or anywhere else; just say you received it.\n\n" : ""
        p += "\(w.who) asked in Slack (\(w.place)):\n\n"
        p += context.map { "> " + $0 }.joined(separator: "\n")
        p += "\n\nLink: \(w.link)\n\nLook into it. Don't post, react or draft anything in Slack yourself. When it's done, tell me what to reply, in two short lines."
        return p
    }
}
