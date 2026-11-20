import Foundation

/// Scripted voice checks (docs/voice.md, "Checking it"), quiet runs only. A quiet run has no
/// microphone and plays no sound: the mode runs without ears, and replies come from here.
/// - MAXWELL_VOICE_ONLY=<title prefix>: the only sessions the run announces and answers ("mxtest").
///   Without it a scripted run talks to no session at all, so it can never type into yours.
/// - MAXWELL_VOICE_ON=<seconds>: voice mode turns on that long after launch, as its shortcut would.
/// - MAXWELL_VOICE_HEAR="<seconds>:<words>[;…]": at each time, a reply as if you had said it.
/// - MAXWELL_VOICE_FILE=<audio file>: what the speech model hears in a recording, logged as
///   `voice harness: heard in file: …`. MAXWELL_VOICE_LANGUAGE picks the language (en-US).
/// - MAXWELL_ELEVENLABS_KEY: the key, in place of the Keychain (read by VoiceKey).
enum VoiceHarness {
    static func start(_ main: MainWindowController) {
        let env = ProcessInfo.processInfo.environment
        guard quietTest else { return }
        main.voiceOnly = env["MAXWELL_VOICE_ONLY"]
        if let after = env["MAXWELL_VOICE_ON"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { main.toggleVoice() }
        }
        for step in (env["MAXWELL_VOICE_HEAR"] ?? "").split(separator: ";") {
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let at = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { main.voice.heard(parts[1]) }
        }
        if let path = env["MAXWELL_VOICE_FILE"], !path.isEmpty { hear(path, language: env["MAXWELL_VOICE_LANGUAGE"] ?? "en-US") }
        if let path = env["MAXWELL_VOICE_STREAM"], !path.isEmpty { hearLive(path, language: env["MAXWELL_VOICE_LANGUAGE"] ?? "en-US") }
        if let path = env["MAXWELL_VOICE_SNAP"], !path.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + (env["MAXWELL_VOICE_SNAP_AFTER"].flatMap(Double.init) ?? 6)) { snap(main.voiceOrb, to: path) }
        }
    }

    private static var ears: AnyObject?

    /// MAXWELL_VOICE_STREAM=<audio file>: the recording played into the live hearing path in real time.
    /// Logs the words as they come (`voice harness: words: …`) and the reply once it pauses.
    private static func hearLive(_ path: String, language: String) {
        guard #available(macOS 26, *) else { return mark("voice harness: hearing needs macOS 26") }
        let e = VoiceEars()
        ears = e
        e.onWords = { mark("voice harness: words: \($0)") }
        e.onReply = { mark("voice harness: reply: \($0)") }
        e.start(recording: URL(fileURLWithPath: path), language: language) { why in
            mark(why.map { "voice harness: \($0)" } ?? "voice harness: hearing the recording")
        }
    }

    /// MAXWELL_VOICE_SNAP=<png>: the orb as it is drawn MAXWELL_VOICE_SNAP_AFTER seconds in (6).
    private static func snap(_ orb: VoiceOrb, to path: String) {
        guard let png = orb.picture() else { return mark("voice harness: no orb to capture") }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            mark("voice harness: orb captured")
        } catch {
            mark("voice harness: couldn't write the orb: \(error.localizedDescription)")
        }
    }

    private static func hear(_ path: String, language: String) {
        guard #available(macOS 26, *) else { return mark("voice harness: hearing needs macOS 26") }
        Task {
            do {
                let text = try await VoiceEars.transcribe(file: URL(fileURLWithPath: path), language: language)
                mark("voice harness: heard in file: \(text)")
            } catch {
                mark("voice harness: couldn't hear the file: \(error)")
            }
        }
    }
}
