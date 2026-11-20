import Foundation

/// Voice mode: says which session needs you and what it asks, hears your reply, and types it into
/// that session, word for word. The session carries on as if you had typed it.
///
/// The microphone is only open right after a question, for `answerWindow`: an open microphone would
/// type a meeting or a phone call into a session.
final class VoiceMode {
    enum Phase: Equatable {
        case off
        /// Getting the microphone and the speech model.
        case starting(String)
        /// On, nobody on the line.
        case idle
        case speaking(String)
        /// Waiting for you to answer; `words` is what was heard so far.
        case listening(words: String)
        /// The question was asked and the answer window closed; the shortcut for "answer" opens it again.
        case waiting
        /// Your reply is being typed into the session.
        case sending(String)
        case failed(String)
    }

    /// A session that needs you, as the window knows it.
    struct Asker {
        var id: SessionID
        var title: String
        var question: String
        var answerable: Bool
    }

    private(set) var phase = Phase.off { didSet { if phase != oldValue { onChange?() } } }
    var isOn: Bool { phase != .off }
    /// The session on the line, for the orb.
    var onLineTitle: String? { call.onLine.flatMap { id in askers().first { $0.id == id }?.title } }
    var problem: String? { speaker.problem }

    var onChange: (() -> Void)?
    /// Every session that needs you now, oldest first.
    var askers: () -> [Asker] = { [] }
    /// Types the reply into the session, then says how it went: nil, or why it couldn't.
    var send: (SessionID, String, @escaping (String?) -> Void) -> Void = { _, _, done in done("There is nothing to send to.") }
    var name = ""
    var language = "en-US" { didSet { speaker.language = language } }

    static let answerWindow: TimeInterval = 25

    let speaker = VoiceSpeaker()
    private var call = VoiceCall()
    private var lines: [String] = []
    private var speaking = false
    /// The microphone is ready and the greeting is queued: sessions are announced from here on.
    private var ready = false
    private var ears: AnyObject?
    private lazy var window = Debounce(Self.answerWindow) { [weak self] in self?.windowClosed() }

    func toggle() { isOn ? stop() : start() }

    func start() {
        guard !isOn else { return }
        call = VoiceCall()
        guard #available(macOS 26, *) else {
            phase = .failed("Voice mode needs macOS 26 or later to hear you.")
            return
        }
        phase = .starting("Starting…")
        let ears = VoiceEars()
        self.ears = ears
        ears.onWords = { [weak self] words in
            guard let self, case .listening = self.phase else { return }
            self.phase = .listening(words: words)
            self.window.poke()
        }
        ears.onReply = { [weak self] in self?.heard($0) }
        ears.start(language: language, progress: { [weak self] in self?.phase = .starting($0) }) { [weak self] why in
            guard let self, self.isOn else { return }
            if let why { return self.fail(why) }
            self.begin()
        }
    }

    /// Scripted runs have no microphone: the mode runs, and `heard` is called for you.
    func startWithoutEars() {
        guard !isOn else { return }
        call = VoiceCall()
        phase = .starting("Starting…")
        begin()
    }

    private func begin() {
        mark("voice: on")
        ready = true
        say(VoiceLine.greeting(waiting: askers().filter(\.answerable).count))
        sessionsChanged()
    }

    func stop() {
        guard isOn else { return }
        mark("voice: off")
        window.cancel()
        speaker.stop()
        stopEars()
        lines = []
        speaking = false
        ready = false
        call = VoiceCall()
        phase = .off
    }

    private func fail(_ why: String) {
        mark("voice: \(why)")
        stopEars()
        phase = .failed(why)
    }

    private func stopEars() {
        if #available(macOS 26, *) { (ears as? VoiceEars)?.stop() }
        ears = nil
    }

    private func listen(_ on: Bool) {
        if #available(macOS 26, *) { (ears as? VoiceEars)?.listening = on }
    }

    /// The store changed: someone new may need you, or the session on the line was answered elsewhere.
    func sessionsChanged() {
        guard isOn, ready else { return }
        if case .failed = phase { return }
        let now = askers()
        let titles = Dictionary(now.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        let hadLine = call.onLine
        let steps = call.update(now.map { VoiceCall.Asking(id: $0.id, question: $0.question, answerable: $0.answerable) })
        for step in steps {
            switch step {
            case .announce(let id, let q): say(VoiceLine.announcement(title: titles[id] ?? "A session", question: q, name: name))
            case .mention(let id): say(VoiceLine.also(title: titles[id] ?? "Another session"))
            case .tell(let id, let q): say(VoiceLine.permission(title: titles[id] ?? "A session", question: q))
            }
        }
        // The line emptied without a word from here: stop waiting for an answer nobody owes.
        if hadLine != nil, call.onLine == nil, !speaking { settle() }
    }

    /// Opens the answer window again for the session on the line.
    func answerNow() {
        guard isOn, call.onLine != nil, !speaking else { return }
        openWindow()
    }

    /// A whole reply, from the microphone or a scripted run.
    func heard(_ text: String) {
        guard isOn, let id = call.onLine else { return }
        if case .sending = phase { return }
        mark("voice: heard \(text.prefix(120))")
        window.cancel()
        listen(false)
        switch VoiceLine.heard(text) {
        case .answer(let reply):
            phase = .sending(reply)
            return send(id, reply) { [weak self] why in
                guard let self, self.isOn, self.phase == .sending(reply) else { return }
                if let why {
                    mark("voice: not sent: \(why)")
                    self.say("I couldn't send that. \(why)")
                } else {
                    mark("voice: sent to \(id.prefix(8))")
                    self.call.release()
                    self.say("Sent.")
                }
                self.sessionsChanged()
            }
        case .skip:
            call.release()
            say("Okay, later.")
        case .again:
            if let a = askers().first(where: { $0.id == id }) { say(VoiceLine.announcement(title: a.title, question: a.question, name: "")) }
        case .cancel:
            say("Cancelled. Go ahead.")
        case .hangUp:
            return stop()
        }
        sessionsChanged()
    }

    private func say(_ text: String) {
        lines.append(text)
        if !speaking { sayNext() }
    }

    private func sayNext() {
        guard isOn, !lines.isEmpty else {
            speaking = false
            return settle()
        }
        speaking = true
        window.cancel()
        listen(false)
        let text = lines.removeFirst()
        phase = .speaking(text)
        speaker.say(text) { [weak self] in self?.sayNext() }
    }

    /// Nothing left to say: listen if a session is on the line, else rest.
    private func settle() {
        guard isOn else { return }
        if case .failed = phase { return }
        if case .sending = phase { return }
        if call.onLine != nil { openWindow() } else { window.cancel(); listen(false); phase = .idle }
    }

    private func openWindow() {
        phase = .listening(words: "")
        listen(true)
        window.poke()
    }

    private func windowClosed() {
        guard case .listening = phase else { return }
        listen(false)
        phase = .waiting
    }
}
