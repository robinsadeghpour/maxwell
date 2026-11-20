import AVFoundation
import Security

/// Your ElevenLabs API key, in the Keychain. MAXWELL_ELEVENLABS_KEY stands in for it in scripted runs,
/// where a rebuilt Maxwell Dev would otherwise ask for Keychain access.
enum VoiceKey {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "Maxwell voice \(Bundle.main.bundleIdentifier ?? "dev.maxwell.app")",
         kSecAttrAccount as String: "elevenlabs"]
    }

    static func read() -> String? {
        if let env = ProcessInfo.processInfo.environment["MAXWELL_ELEVENLABS_KEY"], !env.isEmpty { return env }
        if quietTest { return nil }
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status != errSecSuccess && status != errSecItemNotFound { mark("voice: keychain read failed (\(status))") }
        return (out as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// nil removes the key.
    static func write(_ key: String?) {
        guard let key, !key.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound { mark("voice: keychain delete failed (\(status))") }
            return
        }
        let value = Data(key.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = value
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        }
        if status != errSecSuccess { mark("voice: keychain write failed (\(status))") }
    }
}

/// Says one line at a time: with ElevenLabs when there is a key, else with the Mac's own voice.
/// A line ElevenLabs can't say is said by the Mac's voice, and `problem` says why.
final class VoiceSpeaker: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    /// docs.elevenlabs.io, read 2026-11-20: Flash v2.5 is the low-latency model that speaks English and
    /// German, and "George" is the voice its own quickstart uses.
    static let defaultVoice = "JBFqnCBsd6RMkjVDRZzb"
    static let model = "eleven_flash_v2_5"

    var voiceId = VoiceSpeaker.defaultVoice
    var language = "en-US"
    /// Why the last line fell back to the Mac's voice; nil when ElevenLabs said it, or there is no key.
    private(set) var problem: String?
    /// A scripted run fetches the audio but plays nothing.
    var silent = quietTest

    private let mac = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var fetch: URLSessionDataTask?
    private var done: (() -> Void)?
    /// Counts lines, so a fetch that answers after `stop()` or a newer line is dropped.
    private var line = 0

    override init() {
        super.init()
        mac.delegate = self
    }

    /// Says `text`, then calls `done` on the main thread. A newer line or `stop()` ends this one without calling it.
    func say(_ text: String, done: @escaping () -> Void) {
        stop()
        line += 1
        self.done = done
        mark("voice: says \(text.prefix(120))")
        guard let key = VoiceKey.read() else { return sayWithMac(text) }
        let mine = line
        fetch = Self.request(text, key: key, voice: voiceId) { [weak self] result in
            guard let self, self.line == mine else { return }
            switch result {
            case .success(let audio):
                self.problem = nil
                self.play(audio, fallback: text)
            case .failure(let why):
                self.problem = why.message
                mark("voice: ElevenLabs couldn't say it (\(why.message)); the Mac's voice says it")
                self.sayWithMac(text)
            }
        }
    }

    func stop() {
        line += 1
        done = nil
        fetch?.cancel(); fetch = nil
        player?.stop(); player = nil
        if mac.isSpeaking { mac.stopSpeaking(at: .immediate) }
    }

    private func finish() {
        let d = done
        done = nil
        d?()
    }

    private func play(_ audio: Data, fallback text: String) {
        if silent { mark("voice: ElevenLabs sent \(audio.count) bytes of audio"); return finish() }
        do {
            let p = try AVAudioPlayer(data: audio)
            p.delegate = self
            player = p
            if !p.play() { throw Failure("the audio wouldn't play") }
        } catch {
            problem = "ElevenLabs' audio wouldn't play: \(error.localizedDescription)"
            sayWithMac(text)
        }
    }

    private func sayWithMac(_ text: String) {
        if silent { return finish() }
        let u = AVSpeechUtterance(string: text)
        u.voice = Self.macVoice(language)
        mac.speak(u)
    }

    /// The best voice installed for the language: Premium, then Enhanced, then the plain one.
    static func macVoice(_ language: String) -> AVSpeechSynthesisVoice? {
        let prefix = String(language.prefix(2))
        let fits = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(prefix) }
        return fits.filter { $0.language == language }.max { $0.quality.rawValue < $1.quality.rawValue }
            ?? fits.max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: language)
    }

    func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully ok: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.player === p else { return }
            self.player = nil
            self.finish()
        }
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in self?.finish() }
    }

    struct Failure: Error {
        let message: String
        init(_ m: String) { message = m }
    }

    /// One line as MP3 from ElevenLabs. Answers on the main thread.
    static func request(_ text: String, key: String, voice: String, done: @escaping (Result<Data, Failure>) -> Void) -> URLSessionDataTask? {
        guard let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voice)/stream?output_format=mp3_44100_128") else {
            done(.failure(Failure("the voice id \(voice) isn't one")))
            return nil
        }
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.httpMethod = "POST"
        r.setValue(key, forHTTPHeaderField: "xi-api-key")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text, "model_id": model])
        let task = URLSession.shared.dataTask(with: r) { data, response, error in
            let result: Result<Data, Failure>
            if let error {
                result = .failure(Failure((error as NSError).code == NSURLErrorCancelled ? "cancelled" : error.localizedDescription))
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                result = .failure(Failure(explain(http.statusCode, data)))
            } else if let data, !data.isEmpty {
                result = .success(data)
            } else {
                result = .failure(Failure("no audio came back"))
            }
            DispatchQueue.main.async { done(result) }
        }
        task.resume()
        return task
    }

    /// ElevenLabs' errors carry `detail`: a message, an object with one, or a list of them.
    static func explain(_ status: Int, _ body: Data?) -> String {
        let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        var said: String?
        if let d = json?["detail"] as? String { said = d }
        if let d = json?["detail"] as? [String: Any] { said = d["message"] as? String ?? d["status"] as? String }
        if let d = json?["detail"] as? [[String: Any]] { said = d.first?["msg"] as? String }
        let what = status == 401 ? "the key was refused" : "status \(status)"
        return said.map { "\(what): \($0)" } ?? what
    }
}
