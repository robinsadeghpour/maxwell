import AVFoundation
import Speech

/// Turns the microphone into text on this Mac (Apple's SpeechAnalyzer, macOS 26): nothing you say
/// leaves it. Reports the words as they come, and the whole reply once you stop talking.
@available(macOS 26, *)
final class VoiceEars {
    /// Every change to what was heard so far in this reply. Main thread.
    var onWords: ((String) -> Void)?
    /// You stopped talking: the reply. Main thread.
    var onReply: ((String) -> Void)?
    /// How long a pause ends a reply.
    static let pause: TimeInterval = 1.6

    /// While false the microphone is ignored: Maxwell is speaking, or no session is on the line.
    var listening = false {
        didSet {
            guard listening != oldValue else { return }
            gate.open = listening
            // What was heard before the gate moved belongs to nobody.
            forget()
        }
    }

    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var feed: AsyncStream<AnalyzerInput>.Continuation?
    private var reading: Task<Void, Never>?
    private let gate = Gate()
    private var settled = ""
    private var unsettled = ""
    /// Results that end before this belong to a reply already given, or to time the gate was shut.
    private var heardThrough = CMTime.zero
    private var latest = CMTime.zero
    private lazy var quiet = Debounce(Self.pause) { [weak self] in self?.reply() }
    /// True from the pause until the reply is given: the model is settling the last words.
    private var settling = false
    /// Gives the reply when the model has settled it, or after a second if it never says so.
    private lazy var lastLook = Debounce(1.0) { [weak self] in self?.give() }

    /// The tap runs on an audio thread; this is the one thing it reads.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var open: Bool {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    /// Asks for the microphone, fetches the language's model if it isn't on this Mac yet, and starts.
    /// `ready` gets nil, or why it can't listen. Main thread.
    func start(language: String, progress: @escaping (String) -> Void, ready: @escaping (String?) -> Void) {
        Task { @MainActor in
            do {
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    return ready("Maxwell isn't allowed to use the microphone. Allow it in System Settings › Privacy & Security › Microphone.")
                }
                let (feed, format) = try await self.open(language, progress: progress)
                try self.tap(into: feed, as: format)
                ready(nil)
            } catch {
                self.stop()
                ready("Listening didn't start: \((error as? VoiceSpeaker.Failure)?.message ?? error.localizedDescription)")
            }
        }
    }

    /// The speech model, running and read from; what is fed to `feed` in `format` is heard.
    @MainActor
    private func open(_ language: String, progress: @escaping (String) -> Void) async throws -> (AsyncStream<AnalyzerInput>.Continuation, AVAudioFormat) {
        let transcriber = try await Self.transcriber(language, progress: progress)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw VoiceSpeaker.Failure("this Mac has no audio format the speech model takes")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, feed) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: stream)
        self.analyzer = analyzer
        self.feed = feed
        read(transcriber)
        return (feed, format)
    }

    /// A recording in place of the microphone, through the same conversion, gate and pause as live
    /// sound: how a scripted run checks hearing a reply as it is spoken.
    func start(recording: URL, language: String, ready: @escaping (String?) -> Void) {
        Task { @MainActor in
            do {
                let (feed, format) = try await self.open(language, progress: { mark("voice: \($0)") })
                let file = try AVAudioFile(forReading: recording)
                guard let converter = AVAudioConverter(from: file.processingFormat, to: format) else { throw VoiceSpeaker.Failure("the recording can't be converted") }
                ready(nil)
                self.listening = true
                while file.framePosition < file.length, let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) {
                    try file.read(into: chunk)
                    if self.gate.open, let out = Self.convert(chunk, with: converter, to: format) { feed.yield(AnalyzerInput(buffer: out)) }
                    // As fast as a microphone gives it, so words come in the order and rhythm they would live.
                    try await Task.sleep(for: .milliseconds(Int(Double(chunk.frameLength) / file.processingFormat.sampleRate * 1000)))
                }
                // A second of silence, as after a spoken reply: the model settles its last words on it.
                if let quiet = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)) {
                    quiet.frameLength = quiet.frameCapacity
                    feed.yield(AnalyzerInput(buffer: quiet))
                }
            } catch {
                self.stop()
                ready("Listening didn't start: \((error as? VoiceSpeaker.Failure)?.message ?? error.localizedDescription)")
            }
        }
    }

    func stop() {
        listening = false
        quiet.cancel()
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        feed?.finish(); feed = nil
        reading?.cancel(); reading = nil
        if let a = analyzer { Task { await a.cancelAndFinishNow() } }
        analyzer = nil
    }

    /// The language's on-device model, downloaded once by macOS when it is missing.
    static func transcriber(_ language: String, progress: @escaping (String) -> Void) async throws -> SpeechTranscriber {
        let asked = Locale(identifier: language)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: asked) else {
            throw VoiceSpeaker.Failure("macOS has no speech model for \(language)")
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            progress("Downloading the speech model for \(language)…")
            try await request.downloadAndInstall()
        }
        return transcriber
    }

    private func tap(into feed: AsyncStream<AnalyzerInput>.Continuation, as format: AVAudioFormat) throws {
        let input = engine.inputNode
        let native = input.outputFormat(forBus: 0)
        guard native.sampleRate > 0, let converter = AVAudioConverter(from: native, to: format) else {
            throw VoiceSpeaker.Failure("no microphone was found")
        }
        let gate = self.gate
        input.installTap(onBus: 0, bufferSize: 4096, format: native) { buffer, _ in
            guard gate.open, let out = Self.convert(buffer, with: converter, to: format) else { return }
            feed.yield(AnalyzerInput(buffer: out))
        }
        engine.prepare()
        try engine.start()
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }

    private func read(_ transcriber: SpeechTranscriber) {
        reading = Task { @MainActor [weak self] in
            do {
                for try await result in transcriber.results {
                    self?.heard(String(result.text.characters), through: result.range.end, final: result.isFinal)
                }
            } catch {
                if !Task.isCancelled { mark("voice: listening stopped: \(error.localizedDescription)") }
            }
        }
    }

    /// A final result settles its words; one that isn't replaces the last guess at the words after them.
    private func heard(_ text: String, through end: CMTime, final: Bool) {
        if end > latest { latest = end }
        guard listening, end > heardThrough else { return }
        if final {
            settled += text
            unsettled = ""
        } else {
            unsettled = text
        }
        let words = (settled + unsettled).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        onWords?(words)
        // While the last words settle, a result is the model's second look, not you talking again.
        if !settling { quiet.poke() }
    }

    /// You paused. The words heard last are still the model's first guess ("database 1"); ask it to
    /// settle them ("database first") and give the reply once it has, or shortly after if it doesn't.
    private func reply() {
        guard !unsettled.isEmpty, let analyzer else { return give() }
        settling = true
        lastLook.poke()
        Task { @MainActor [weak self] in
            try? await analyzer.finalize(through: nil)
            // The settled words arrive on the results stream right behind this.
            self?.lastLook.poke(after: 0.15)
        }
    }

    private func give() {
        guard listening else { return forget() }
        let words = (settled + unsettled).trimmingCharacters(in: .whitespacesAndNewlines)
        forget()
        if !words.isEmpty { onReply?(words) }
    }

    private func forget() {
        settling = false
        lastLook.cancel()
        quiet.cancel()
        settled = ""
        unsettled = ""
        heardThrough = latest
    }

    /// What a recording says, through the same model as the microphone: how a scripted run checks hearing.
    static func transcribe(file: URL, language: String) async throws -> String {
        let transcriber = try await transcriber(language, progress: { mark("voice: \($0)") })
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        async let text: String = {
            var all = ""
            for try await result in transcriber.results where result.isFinal { all += String(result.text.characters) }
            return all
        }()
        try await analyzer.start(inputAudioFile: try AVAudioFile(forReading: file), finishAfterFile: true)
        return try await text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
