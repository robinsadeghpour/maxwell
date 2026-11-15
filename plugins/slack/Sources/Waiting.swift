import Foundation

/// Someone waiting on me in Slack: the answer to "have I replied to everyone?".
struct Waiting: Codable, Equatable {
    enum State: String, Codable {
        /// They asked and I haven't answered.
        case waiting
        /// I said "on it" (or 👀) and the work isn't delivered yet. Nobody waits on a reply, but it's open.
        case owed
    }
    var state: State
    /// The conversation and thread it lives in; stable while new messages arrive there.
    var key: String
    /// The newest message the item covers (handled and snooze are kept up to it).
    var lastTs: String
    var whoId: String
    var who: String
    var whoKind: Person.Kind
    /// What they asked, one line, Slack markup turned into plain text, secrets hidden.
    var ask: String
    var kind: Ask
    /// Waiting: when their first unanswered message arrived. Owed: when I said I'd do it.
    var since: Date
    /// "DM", "group DM", "#support" or "#support thread".
    var place: String
    /// Opens the exact message in Slack.
    var link: String
    /// Why the rules list it, for the tooltip and for tuning.
    var reason: String
    /// Unanswered messages in the burst (a burst of three counts three).
    var count: Int
    /// They asked again after I said I'd look ("any update?").
    var bumped: Bool
    /// Asked of me by name: a DM or an @mention. Only these bring back an item marked Not for me.
    var direct: Bool
    /// The rules could not tell for sure.
    var unclear: Bool
}

/// What kind of message it is, from its words. Bugs and customers sort first; triage (issue #3) builds on this.
enum Ask: String, Codable, CaseIterable {
    case bug, request, question, decision, mention, fyi, thanks, social

    var waits: Bool { [.bug, .request, .question, .decision].contains(self) }
}

/// The rules (docs/slack-reply-debt.md). Pure: the same snapshot, marks and time give the same list.
enum Rules {
    /// Messages from one sender this close together are one burst (one ask).
    static let burstGap: TimeInterval = 60 * 60

    static func waiting(_ s: Snapshot, marks: Marks = Marks(), now: Date = Date()) -> [Waiting] {
        var out: [Waiting] = []
        for c in s.conversations {
            let us = units(c)
            let top = us.first { !$0.thread }
            for u in us {
                guard var w = judge(u, in: c, snapshot: s) else { continue }
                if u.thread, c.kind != .channel, let top, closedLater(w, top: top) { continue }
                if marks.hides(w, now: now) { continue }
                w.place = place(c, thread: u.thread)
                out.append(w)
            }
        }
        return out.sorted { a, b in
            for rank in [{ (w: Waiting) in w.state == .waiting }, { $0.whoKind == .external }, { $0.bumped }, { $0.kind == .bug }] where rank(a) != rank(b) {
                return rank(a)
            }
            return a.since < b.since
        }
    }

    /// A conversation splits into its top level and each of its threads.
    struct Unit {
        var root: String?          // the thread's parent ts; nil for the top level
        var messages: [Message]
        var thread: Bool { root != nil }
    }

    static func units(_ c: Conversation) -> [Unit] {
        let sorted = c.messages.sorted { $0.ts < $1.ts }
        let parents = Set(sorted.compactMap { $0.isReply ? $0.threadTs : nil })
        var top: [Message] = [], threads: [String: [Message]] = [:]
        for m in sorted {
            if m.isReply { threads[m.threadTs!, default: []].append(m); continue }
            top.append(m)
            // A parent is both the top-level message and the thread's opening ask.
            if parents.contains(m.ts) { threads[m.ts, default: []].append(m) }
        }
        var out: [Unit] = []
        if !top.isEmpty { out.append(Unit(root: nil, messages: top)) }
        for t in parents.sorted() { out.append(Unit(root: t, messages: threads[t] ?? [])) }
        return out
    }

    /// One unit: does the latest thing someone said there wait on me, or do I owe it?
    static func judge(_ u: Unit, in c: Conversation, snapshot s: Snapshot) -> Waiting? {
        let me = s.me
        let parents = Set(c.messages.compactMap { $0.isReply ? $0.threadTs : nil })
        func isBot(_ m: Message) -> Bool { s.users[m.user]?.kind == .bot }
        // A bot counts only when it names me with an explicit ask (decision cards, "Needs you" digests).
        func counts(_ m: Message) -> Bool { m.user != me && (!isBot(m) || Words.botAsks(m, me: me)) }

        // My last real reply. "what" or "uhmm haha" doesn't answer anything.
        let lastReply = u.messages.lastIndex { $0.user == me && !Words.nonAnswer($0.text) }
        let after = u.messages[(lastReply.map { $0 + 1 } ?? 0)...].filter(counts)
        let iAcked = lastReply.map { Words.isAck(u.messages[$0].text) } ?? false

        guard let last = after.last else {
            // Nothing after my reply. If that reply was "on it", I owe the work.
            guard let i = lastReply, iAcked, let ask = u.messages[..<i].last(where: counts) else { return nil }
            let run = burst(ending: ask, in: Array(u.messages[..<i].filter(counts)))
            guard c.kind == .dm || run.contains(where: { $0.mentions.contains(me) }) || u.thread else { return nil }
            return item(.owed, u, c, s, run: run, kind: strongest(run.map { kind($0, me: me) }), last: u.messages[i], since: u.messages[i].date,
                        reason: "you said \"\(Rules.oneLine(u.messages[i].text, users: s.users))\"", bumped: false, unclear: false)
        }
        // Outside DMs the ask is the newest message that names me, even when others talked after it.
        let anchor = c.kind == .dm ? last : (after.last { $0.mentions.contains(me) } ?? last)
        // A top-level message that opened a thread is judged as that thread.
        if !u.thread, parents.contains(anchor.ts) { return nil }
        let run = burst(ending: anchor, in: after)
        let k = strongest(run.map { kind($0, me: me) })
        let mentioned = run.contains { $0.mentions.contains(me) }
        let bumped = iAcked || run.contains { Words.bump($0.text) }

        // My reaction on their last message: ✅ answers it, 👀 means I'm on it.
        let mine = anchor.reactions.filter { $0.users.contains(me) }.map(\.name)
        if mine.contains(where: Words.answerReactions.contains) { return nil }
        if mine.contains(where: Words.seenReactions.contains), k.waits {
            return item(.owed, u, c, s, run: run, kind: k, last: last, since: anchor.date, reason: "you reacted 👀", bumped: false, unclear: false)
        }
        // After my "on it", a plain "thanks" leaves the work owed; "figured it out" closes it.
        if k == .thanks {
            guard iAcked, let i = lastReply, !run.contains(where: { Words.closes($0.text) }),
                  let ask = u.messages[..<i].last(where: counts) else { return nil }
            return item(.owed, u, c, s, run: burst(ending: ask, in: Array(u.messages[..<i].filter(counts))), kind: kind(ask, me: me),
                        last: last, since: u.messages[i].date, reason: "you said \"\(Rules.oneLine(u.messages[i].text, users: s.users))\"",
                        bumped: false, unclear: false)
        }
        // Someone else answered after the ask, and the asker said thanks: closed.
        let later = after.filter { $0.ts > anchor.ts }
        if later.contains(where: { $0.user != anchor.user }), let close = later.last(where: { $0.user == anchor.user }), kind(close, me: me) == .thanks { return nil }

        var reason: String
        var unclear = false
        switch c.kind {
        case .dm:
            guard k.waits || bumped else { return nil }
            reason = "DM, \(k.rawValue)"
        case .group, .channel:
            if mentioned {
                guard k.waits || bumped else { return nil }
                reason = isBot(anchor) ? "a bot asks you to decide" : "mentions you, \(k.rawValue)"
            } else if lastReply != nil, u.thread, k.waits, answersMe(u, run: run, me: me) {
                reason = "answers you in a thread, \(k.rawValue)"
                unclear = k != .question
            } else if c.kind == .group, k.waits, run.allSatisfy({ $0.mentions.isEmpty }), Set(u.messages.map(\.user)).subtracting([me]).count <= 1 {
                reason = "group DM, \(k.rawValue), nobody else answered"
                unclear = true
            } else {
                return nil
            }
        }
        if bumped { reason += ", asked again" }
        return item(.waiting, u, c, s, run: run, kind: bumped && !k.waits ? .request : k, last: last, since: run[0].date,
                    reason: reason, bumped: bumped, unclear: unclear)
    }

    private static func item(_ state: Waiting.State, _ u: Unit, _ c: Conversation, _ s: Snapshot, run: [Message], kind k: Ask,
                             last: Message, since: Date, reason: String, bumped: Bool, unclear: Bool) -> Waiting {
        let who = run.last!.user
        let external = c.external && s.users[who]?.kind != .bot || s.users[who]?.kind == .external
        // "Any news?" says little; after a bump, show what they first asked.
        let first = bumped ? u.messages.first { $0.user == who && !Words.bump($0.text) && ![.thanks, .social].contains(classify($0.text)) }
            ?? u.messages.first { $0.user == who && !Words.bump($0.text) } : nil
        let ask = first ?? run.last { kind($0, me: s.me) == k } ?? run.last!
        return Waiting(state: state, key: c.id + ":" + (u.root ?? "top"), lastTs: last.ts, whoId: who, who: s.users[who]?.name ?? who,
                       whoKind: external ? .external : (s.users[who]?.kind ?? .member),
                       ask: oneLine(Words.dropLeadingMentions(Words.askLine(ask, me: s.me), me: s.me), users: s.users), kind: k, since: since, place: "",
                       link: link(s, c, ask), reason: reason + (external ? ", outside your company" : ""), count: run.count,
                       bumped: bumped, direct: c.kind == .dm || run.contains { $0.mentions.contains(s.me) }, unclear: unclear)
    }

    /// The sender's messages leading up to `end`, while they keep talking and the gaps stay short.
    static func burst(ending end: Message, in ms: [Message]) -> [Message] {
        var run: [Message] = []
        for m in ms.reversed() where m.ts <= end.ts {
            if m.user != end.user { break }
            if let first = run.first, first.date.timeIntervalSince(m.date) > burstGap { break }
            run.insert(m, at: 0)
        }
        return run
    }

    /// A DM thread that waits is closed by a later top-level "figured it out" or thanks from the same person.
    static func closedLater(_ w: Waiting, top: Unit) -> Bool {
        top.messages.contains { $0.user == w.whoId && $0.ts > w.lastTs && classify($0.text) == .thanks }
    }

    /// The message right before the run is mine: they are answering me, so the ball is with me.
    static func answersMe(_ u: Unit, run: [Message], me: String) -> Bool {
        guard let first = run.first, let i = u.messages.firstIndex(of: first), i > 0 else { return false }
        return u.messages[i - 1].user == me
    }

    static func strongest(_ kinds: [Ask]) -> Ask {
        let order: [Ask] = [.bug, .request, .decision, .question, .mention, .fyi, .thanks, .social]
        return order.first { kinds.contains($0) } ?? .social
    }

    /// A digest is judged by the line that names me.
    static func kind(_ m: Message, me: String) -> Ask {
        let k = classify(Words.askLine(m, me: me))
        // A file with no other words in a DM is something to look at ("check mal bitte" + PDF).
        if m.files > 0, k == .social || k == .mention { return .request }
        return k
    }

    static func place(_ c: Conversation, thread: Bool) -> String {
        switch c.kind {
        case .dm: return thread ? "DM thread" : "DM"
        case .group: return thread ? "group DM thread" : "group DM"
        case .channel: return thread ? "\(c.name) thread" : c.name
        }
    }

    static func link(_ s: Snapshot, _ c: Conversation, _ m: Message) -> String {
        let p = "p" + m.ts.replacingOccurrences(of: ".", with: "")
        if let w = s.workspace, !w.isEmpty {
            var url = (w.hasSuffix("/") ? w : w + "/") + "archives/\(c.id)/\(p)"
            if m.isReply, let t = m.threadTs { url += "?thread_ts=\(t)&cid=\(c.id)" }
            return url
        }
        return "slack://channel?team=\(s.team ?? "")&id=\(c.id)&message=\(m.ts)"
    }

    // MARK: words

    /// The kind of one message from its words, English and German.
    static func classify(_ raw: String) -> Ask {
        let text = plain(raw).lowercased()
        let words = Words.split(text)
        if words.isEmpty { return raw.contains("<@") ? .mention : .social }
        if Lexicon.closing.contains(where: { Words.has(text, $0) }) && !Lexicon.request.contains(where: { Words.has(text, $0) }) { return .thanks }
        if words.count <= 6, !text.contains("?"), words.allSatisfy({ Lexicon.ack.contains($0) || Lexicon.filler.contains($0) }) { return .thanks }
        if Lexicon.bug.contains(where: { Words.has(text, $0) }) { return .bug }
        if Lexicon.decision.contains(where: { Words.has(text, $0) }) { return .decision }
        if Lexicon.request.contains(where: { Words.has(text, $0) }) || Words.bump(raw) { return .request }
        if text.contains("?") || Lexicon.questionStart.contains(words[0]) { return .question }
        if Lexicon.fyi.contains(where: { Words.has(text, $0) }) { return .fyi }
        if words.count <= 3 && (raw.contains("<http") || raw.contains("http")) { return .fyi }
        if raw.contains("<@") { return .mention }
        return .social
    }

    /// Slack markup to plain text: <@U1> → @Name, <url|label> → label, <url> → host.
    static func plain(_ s: String, users: [String: Person] = [:]) -> String {
        var out = "", i = s.startIndex
        while i < s.endIndex {
            if s[i] == "<", let close = s[i...].firstIndex(of: ">") {
                let inner = s[s.index(after: i)..<close]
                if inner.hasPrefix("@") {
                    let id = String(inner.dropFirst().prefix { $0 != "|" })
                    out += "@" + (users[id]?.name ?? "someone")
                } else if inner.hasPrefix("#") {
                    out += "#" + (inner.split(separator: "|").last.map(String.init) ?? "channel")
                } else if let bar = inner.firstIndex(of: "|") {
                    out += inner[inner.index(after: bar)...]
                } else if inner.hasPrefix("!") {
                    out += "@" + inner.dropFirst().prefix { $0 != "^" && $0 != "|" }
                } else {
                    out += URL(string: String(inner))?.host ?? String(inner)
                }
                i = s.index(after: close)
            } else {
                out.append(s[i]); i = s.index(after: i)
            }
        }
        return out.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
    }

    /// One line for the list: plain text, secrets hidden, whitespace folded, at most 140 characters.
    static func oneLine(_ s: String, users: [String: Person]) -> String {
        let flat = Words.dropEmoji(plain(s, users: users)).split(whereSeparator: \.isWhitespace).map { Words.secret(String($0)) ? "•••" : String($0) }.joined(separator: " ")
        return flat.count > 140 ? String(flat.prefix(139)) + "…" : flat
    }
}

/// Small judgments about words, shared by the rules.
enum Words {
    static func split(_ text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
    }

    /// `phrase` in `text` on word boundaries.
    static func has(_ text: String, _ phrase: String) -> Bool {
        var from = text.startIndex
        while let r = text.range(of: phrase, range: from..<text.endIndex) {
            let before = r.lowerBound == text.startIndex ? " " : text[text.index(before: r.lowerBound)]
            let after = r.upperBound == text.endIndex ? " " : text[r.upperBound]
            if !before.isLetter && !after.isLetter { return true }
            from = r.upperBound
        }
        return false
    }

    /// My reply that only promises: "on it", "lemme check", "ich guck mal".
    static func isAck(_ raw: String) -> Bool {
        let text = Rules.plain(raw).lowercased()
        return split(text).count <= 8 && Lexicon.myAck.contains { has(text, $0) }
    }

    /// My reply that answers nothing: "what", "uhmm haha".
    static func nonAnswer(_ raw: String) -> Bool {
        let w = split(Rules.plain(raw).lowercased())
        return !w.isEmpty && w.allSatisfy(Lexicon.nonAnswer.contains)
    }

    /// They closed it themselves: "figured it out", "never mind", "I'll ask X".
    static func closes(_ raw: String) -> Bool {
        let text = Rules.plain(raw).lowercased()
        return Lexicon.closing.contains { has(text, $0) }
    }

    /// They ask again: "any update?", "were you able to check", "asap".
    static func bump(_ raw: String) -> Bool {
        let text = Rules.plain(raw).lowercased()
        return Lexicon.bump.contains { has(text, $0) }
    }

    /// A bot that names me with a decision or a "Needs you" line.
    static func botAsks(_ m: Message, me: String) -> Bool {
        guard m.mentions.contains(me) else { return false }
        let text = m.text.lowercased()
        return text.contains(":raising_hand:") || text.contains("needs you") || text.contains("please") || (has(text, "should") && text.contains("?"))
    }

    /// "@Me can you…" reads as "can you…": the list is already mine. Leading bullets go too.
    static func dropLeadingMentions(_ text: String, me: String) -> String {
        var t = Substring(dropEmoji(text)).drop { $0 == "•" || $0 == " " || $0 == "-" }
        let tag = "<@\(me)>"
        while t.hasPrefix(tag) { t = t.dropFirst(tag.count).drop { $0 == " " || $0 == "," || $0 == ":" } }
        return t.isEmpty ? text : String(t)
    }

    /// The line that concerns me: in a digest, the bullet that names me.
    static func askLine(_ m: Message, me: String) -> String {
        let lines = m.text.split(separator: "\n").map(String.init)
        return lines.first { $0.contains("<@\(me)>") && lines.count > 1 } ?? m.text
    }

    static let answerReactions: Set<String> = ["white_check_mark", "heavy_check_mark", "ballot_box_with_check", "+1", "thumbsup", "ok_hand", "ok", "done"]
    static let seenReactions: Set<String> = ["eyes", "eyes_mx", "looking"]

    /// ":sweat_smile:" and friends read as noise in a one-line preview.
    static func dropEmoji(_ s: String) -> String {
        s.replacingOccurrences(of: ":[a-z][a-z0-9_+\\-]*:", with: "", options: .regularExpression)
    }

    /// Tokens, keys and long opaque strings never show in a preview.
    static func secret(_ word: String) -> Bool {
        let w = word.trimmingCharacters(in: .punctuationCharacters)
        if ["xox", "sk-", "ghp_", "gho_", "github_pat_", "AKIA", "AIza", "lin_api_", "eyJ"].contains(where: w.hasPrefix) && w.count >= 16 { return true }
        let letters = w.filter(\.isLetter).count, digits = w.filter(\.isNumber).count
        return w.count >= 28 && letters > 0 && digits > 0 && !w.contains("/") && !w.contains(".")
    }
}

/// Words that decide a message's kind. Each matches on word boundaries.
enum Lexicon {
    static let ack: Set<String> = ["thanks", "thank", "thx", "ty", "danke", "dankeschön", "tausend", "dank", "merci", "ok", "okay", "k", "kk",
                                   "cool", "nice", "great", "perfect", "perfekt", "super", "top", "passt", "gut", "sehr", "alles", "klar", "got",
                                   "it", "sounds", "good", "lol", "haha", "hahaha", "awesome", "geil", "mega", "yes", "ja", "jo", "yep", "jep",
                                   "done", "erledigt", "noted", "worked", "works", "ofc", "smile", "slightly", "smiling", "face", "pray", "raised",
                                   "hands", "joy", "will", "check", "tomorrow", "have", "weekend", "is"]
    static let filler: Set<String> = ["you", "u", "dir", "dich", "so", "much", "a", "lot", "very", "vielen", "for", "that", "das", "the", "and"]
    /// They close it themselves: a sign-off, a redirect, or "figured it out".
    static let closing = ["figured out", "figured it out", "never mind", "nevermind", "i'll ask", "ill ask", "ich frag", "hat sich erledigt",
                          "got it working", "no worries", "nicht mehr nötig", "have a nice weekend", "schönes wochenende"]
    static let bug = ["bug", "broken", "kaputt", "error", "fehler", "crash", "crashes", "geht nicht", "funktioniert nicht", "doesn't work",
                      "does not work", "not working", "isn't working", "won't load", "lädt nicht", "500", "exception", "failing", "failed",
                      "fails", "down", "wrong", "falsch"]
    static let decision = ["approve", "approval", "freigabe", "sign off", "go or no", "should we", "sollen wir", "which one", "welche nehmen",
                           ":raising_hand:", "needs you"]
    static let request = ["can you", "could you", "would you", "kannst du", "könntest du", "könnt ihr", "please", "pls", "bitte",
                          "need you", "brauche", "schau mal", "check mal", "can we", "could we", "take a look", "look into", "review",
                          "mach mal", "help me", "let me know"]
    static let bump = ["any update", "any updates", "any news", "anything new", "were you able", "did you get a chance", "still waiting",
                       "asap", "gibt's was neues", "gibts was neues", "schon geschaut", "hast du schon", "still trying"]
    static let questionStart: Set<String> = ["what", "why", "how", "when", "where", "who", "which", "is", "are", "do", "does", "did", "can",
                                             "could", "would", "should", "any", "was", "wie", "warum", "wann", "wo", "wer", "welche", "hast",
                                             "habt", "bist", "ist", "kannst", "gibt", "weißt", "könnte"]
    static let fyi = ["fyi", "heads up", "zur info", "just so you know", "note for later", "released", "shipped", "just a thought"]
    /// My replies that promise work instead of answering.
    static let myAck = ["on it", "will check", "will do", "lemme check", "let me check", "i'll check", "i'll look", "ill check", "will look",
                        "ich guck", "ich schau", "schau ich", "guck ich", "mach ich", "will start", "looking", "checking", "muss gucken",
                        "must check", "on my list", "i'm on it", "im on it"]
    static let nonAnswer: Set<String> = ["what", "was", "hm", "hmm", "hmmm", "uhm", "uhmm", "uh", "haha", "hahaha", "lol", "huh", "wtf", "wait", "äh"]
}
