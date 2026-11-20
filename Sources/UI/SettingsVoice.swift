import AppKit

/// Settings › Voice: turning voice mode on, what it calls you, the language, and the ElevenLabs key (docs/voice.md).
extension SettingsView {
    /// A Save button for the field before it. Return and clicking elsewhere save too, but nothing on
    /// screen says so, and a pasted key you can't read back needs something to press.
    private func save(_ field: InputField) -> (NSView, CGFloat) {
        let b = MXButton("Save", small: true) { [weak field] in field?.commit() }
        return (b, b.intrinsicContentSize.width)
    }

    func voice() {
        let c = model.config, v = model.voice
        form.header("Voice mode", note: "Maxwell says which session needs you and what it asks. You answer out loud, and your words are typed into that session, as if you had typed them.")
        form.toggle("Voice mode", c.voice, note: "Off: its shortcuts do nothing and nothing is said.") { [weak self] in self?.onSet?("voice", $0 ? "on" : "off") }
        guard c.voice else { return }
        if !v.canHear {
            form.row("Needs macOS 26", [], note: "Hearing you uses the speech model that comes with macOS 26 or later.", icon: StatusSquare(.warn), warn: true)
        }
        form.text("Turn it on and off", v.toggleKey.isEmpty ? "No shortcut" : v.toggleKey,
                  note: v.keyTaken ? "macOS gave this shortcut to another app. Pick another under Keys." : "Works from any app. The orb's × turns it off too. Change it under Keys.")
        form.text("Answer now", v.answerKey.isEmpty ? "No shortcut" : v.answerKey,
                  note: "After a question the microphone stays open for \(Int(VoiceMode.answerWindow)) seconds. This opens it again; so does a click on the orb.")

        form.header("You", note: "Say “skip” to leave a session for later, “repeat” to hear it again, “cancel” at the end to take back what you said, “goodbye” to turn voice mode off.")
        let name = InputField(value: c.voiceName, placeholder: "Your first name", secure: false)
        name.onCommit = { [weak self] in self?.onSet?("voice-name", $0) }
        form.row("What Maxwell calls you", [(name, 200), save(name)], note: "“Hey Ada. Billing needs you.” Empty: no greeting.")
        form.choice("Language", [("en-US", "English"), ("en-GB", "English (UK)"), ("de-DE", "Deutsch")], current: c.voiceLanguage,
                    note: "The one language Maxwell hears. Hearing happens on this Mac; what you say isn't sent anywhere.") { [weak self] in self?.onSet?("voice-language", $0) }

        form.header("The voice", note: "With an ElevenLabs API key, Maxwell speaks with an ElevenLabs voice, and the words it says are sent to ElevenLabs. Without one it uses this Mac's own voice.")
        let key = InputField(value: "", placeholder: v.hasKey ? "Saved in Keychain" : "Paste your ElevenLabs API key", secure: true)
        key.onCommit = { [weak self] in if !$0.isEmpty { self?.onVoiceKey?($0) } }
        var controls: [(NSView, CGFloat)] = [(key, 240), save(key)]
        if v.hasKey {
            let remove = MXButton("Remove", small: true) { [weak self] in self?.onVoiceKey?(nil) }
            remove.tip = Tip("Delete it from the Keychain")
            controls.append((remove, remove.intrinsicContentSize.width))
        }
        form.row("ElevenLabs API key", controls, note: "Kept in the macOS Keychain. Make one at elevenlabs.io › Developers › API keys; it needs Text to Speech.")
        if v.hasKey {
            let voice = InputField(value: c.voiceId, placeholder: "Maxwell's pick (George)", secure: false)
            voice.onCommit = { [weak self] in self?.onSet?("voice-id", $0) }
            form.row("Voice", [(voice, 240), save(voice)], note: "A voice id from your ElevenLabs voice library. Empty: Maxwell's pick.")
        }
        let test = MXButton("Say a test line", small: true) { [weak self] in self?.onVoiceTest?() }
        form.row("", [(test, test.intrinsicContentSize.width)],
                 note: v.problem.map { "ElevenLabs couldn't say the last line, so this Mac's voice did: \($0)" }, warn: v.problem != nil)
    }
}
