import AppKit

/// What Settings › Voice shows.
struct VoiceStatus: Equatable {
    var hasKey = false
    var isOn = false
    /// Why the last line was said by the Mac's voice, not ElevenLabs.
    var problem: String?
    /// The shortcuts as they are bound now.
    var toggleKey = ""
    var answerKey = ""
    /// False when macOS gave the toggle shortcut to another app.
    var keyTaken = false
    var canHear = true
}

/// Voice mode in the window: its two shortcuts (they work from any app), the orb, which sessions
/// it asks about, and typing a spoken reply into a session (docs/voice.md).
extension MainWindowController {
    func setUpVoice() {
        voice.onChange = { [weak self] in self?.showOrb() }
        voice.askers = { [weak self] in self?.voiceAskers() ?? [] }
        voice.send = { [weak self] id, text, done in
            guard let self else { return done("Maxwell's window is gone.") }
            self.voiceSend(text, to: id, done: done)
        }
        voiceOrb.onClose = { [weak self] in self?.voice.stop() }
        voiceOrb.onClick = { [weak self] in self?.voice.answerNow() }
        voiceConfigChanged()
        VoiceHarness.start(self)
    }

    /// The config or a key binding changed: the shortcuts follow, and turning the setting off ends the mode.
    func voiceConfigChanged() {
        let c = store.config
        voice.name = c.voiceName
        voice.language = c.voiceLanguage
        voice.speaker.voiceId = c.voiceId.isEmpty ? VoiceSpeaker.defaultVoice : c.voiceId
        if !c.voice { voice.stop() }
        let toggle = c.voice ? voiceShortcut("voice-mode") : nil
        let answer = c.voice ? voiceShortcut("voice-answer") : nil
        voiceKeyTaken = !voiceToggleKey.set(toggle) { [weak self] in self?.toggleVoice() }
        voiceAnswerKey.set(answer) { [weak self] in self?.voice.answerNow() }
    }

    /// The action's shortcut as the config has it now: a new `keybind` line counts before the menu is rebuilt.
    private func voiceShortcut(_ id: String) -> Shortcut? {
        if let spec = store.config.keybinds[id] { return spec == "none" ? nil : Shortcut(spec) }
        return voiceActions.first { $0.id == id }?.shortcut
    }

    var voiceActions: [Action] {
        let enabled: () -> Bool = { [weak self] in self?.store.config.voice ?? false }
        return [
            Action(id: "voice-mode", title: "Voice Mode On or Off", menu: "Session", shortcut: Shortcut("ctrl+alt+m"),
                   isEnabled: enabled, isChecked: { [weak self] in self?.voice.isOn ?? false }) { [weak self] in self?.toggleVoice() },
            Action(id: "voice-answer", title: "Answer by Voice Now", menu: "Session", shortcut: Shortcut("ctrl+alt+a"),
                   isEnabled: { [weak self] in self?.voice.isOn ?? false }) { [weak self] in self?.voice.answerNow() },
        ]
    }

    func toggleVoice() {
        guard store.config.voice else { return toast("Voice mode is off. Turn it on in Settings › Voice.") }
        if quietTest, !voice.isOn { voice.startWithoutEars() } else { voice.toggle() }
    }

    var voiceStatus: VoiceStatus {
        var canHear = false
        if #available(macOS 26, *) { canHear = true }
        return VoiceStatus(hasKey: VoiceKey.read() != nil, isOn: voice.isOn, problem: voice.problem,
                           toggleKey: actions.first { $0.id == "voice-mode" }?.shortcut?.display ?? "",
                           answerKey: actions.first { $0.id == "voice-answer" }?.shortcut?.display ?? "",
                           keyTaken: voiceKeyTaken, canHear: canHear)
    }

    func setVoiceKey(_ key: String?) {
        VoiceKey.write(key?.trimmingCharacters(in: .whitespacesAndNewlines))
        refreshSettings()
    }

    /// Settings › Voice › Test: one line in the voice you'd hear, whether or not the mode is on.
    func testVoice() {
        let name = store.config.voiceName
        voice.speaker.say(VoiceLine.announcement(title: "Billing", question: "Should I migrate the database first, then deploy?", name: name)) { [weak self] in
            self?.refreshSettings()
        }
    }

    /// The sessions voice mode asks about: the ones that need you and that Maxwell can type into.
    func voiceAskers() -> [VoiceMode.Asker] {
        store.state.sessions.values.sorted { $0.lastEventAt < $1.lastEventAt }.compactMap { s in
            guard case .needsYou(let question) = s.phase, voiceReach(s) == nil else { return nil }
            // A scripted run only ever talks to the sessions it names, never to yours.
            if quietTest, !(voiceOnly.map { !$0.isEmpty && (s.name.hasPrefix($0) || s.title.hasPrefix($0)) } ?? false) { return nil }
            return VoiceMode.Asker(id: s.id, title: s.title, question: question, answerable: !question.hasPrefix("Claude needs your permission"))
        }
    }

    /// Why a spoken reply can't be typed into the session; nil when it can.
    private func voiceReach(_ s: Session) -> String? {
        if s.isCloud { return "\(s.title) runs in the cloud." }
        if terminal(for: s.id) != nil { return nil }
        if case .background = s.reach { return nil }
        return "\(s.title) runs in another terminal."
    }

    /// Types `text` and Return into the session, as the keyboard would, and says how it went.
    /// A background session is typed into the way the phone does it (`PhoneTerminals`): that waits
    /// until Claude is ready, resumes a session Claude Code stopped, and knows whether the text arrived.
    /// A session running in one of Maxwell's own terminals has only that terminal.
    func voiceSend(_ text: String, to id: SessionID, done: @escaping (String?) -> Void) {
        guard let s = store.state.sessions[id], s.phase != .ended else { return done("That session has ended.") }
        if let why = voiceReach(s) { return done(why) }
        guard case .background(let short) = s.reach else {
            guard let t = terminal(for: id) else { return done("\(s.title) has no terminal in Maxwell.") }
            t.sendLine(text)
            return done(nil)
        }
        guard let a = store.state.account(s.accountId) else { return done("Its account isn't set up in Maxwell.") }
        if let why = voiceTerminals.ensure(id, shortId: short, account: a, cwd: s.cwd, cols: 100, rows: 30) { return done("It didn't attach: \(why).") }
        voiceTerminals.type(text, into: id) { why in done(why.map { "It wasn't sent: \($0)." }) }
    }

    /// Lets go of the windowless terminals voice mode typed through, once their sessions carry on
    /// (Claude Code never stops a session with a terminal attached) or the mode is off.
    func releaseVoiceTerminals() {
        for id in voiceTerminals.sessions {
            if voice.isOn, case .needsYou = store.state.sessions[id]?.phase { continue }
            voiceTerminals.release(id)
        }
    }

    private func showOrb() {
        var look = VoiceOrbLook()
        let who = voice.onLineTitle
        switch voice.phase {
        case .off:
            voiceOrb.hide()
            releaseVoiceTerminals()
            return refreshSettings()
        case .sending(let text): look = VoiceOrbLook(state: .speaking, caption: who.map { "Sending · \($0)" } ?? "Sending", words: text)
        case .starting(let what): look = VoiceOrbLook(state: .starting, caption: "Voice mode", words: what)
        case .idle: look = VoiceOrbLook(state: .idle, caption: "Voice mode", words: "Nothing needs you.")
        case .speaking(let text): look = VoiceOrbLook(state: .speaking, caption: who.map { "Speaking · \($0)" } ?? "Speaking", words: text)
        case .listening(let words):
            look = VoiceOrbLook(state: .listening, caption: who.map { "Listening · \($0)" } ?? "Listening", words: words.isEmpty ? "Answer when you're ready." : words)
        case .waiting:
            let key = actions.first { $0.id == "voice-answer" }?.shortcut?.display
            look = VoiceOrbLook(state: .waiting, caption: who.map { "Waiting · \($0)" } ?? "Waiting", words: "Click here\(key.map { " or press \($0)" } ?? "") to answer.")
        case .failed(let why): look = VoiceOrbLook(state: .failed, caption: "Voice mode can't start", words: why)
        }
        voiceOrb.show(look)
    }
}
