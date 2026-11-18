import Foundation

/// The phone's way into background sessions: one windowless `claude attach` per session it types
/// into or watches, alongside any terminal the Mac has open on it. Main thread only.
///
/// Typing waits for Claude to draw before writing, and for the text to echo before pressing Return:
/// text and Return in one write reach Claude as a paste and are not sent.
final class PhoneTerminals {
    private final class Entry {
        let term: AttachTerminal
        var ready = false
        var sawOutput = false
        var jobs: [Job] = []
        var busy = false
        /// Waiting for the typed text to echo: the next output pokes `echoQuiet`.
        var echoing = false
        var readyQuiet: Debounce?
        var readyMax: Debounce?
        var echoQuiet: Debounce?
        var echoMax: Debounce?
        init(_ t: AttachTerminal) { term = t }
    }
    enum Job { case type(String, done: (String?) -> Void), keys(Data, done: (String?) -> Void) }

    private var open: [SessionID: Entry] = [:]
    var onOutput: ((SessionID, Data) -> Void)?
    /// Claude draws within this after attaching; a session it stopped while idle takes a few seconds to resume.
    static let attachTimeout: TimeInterval = 25

    var sessions: Set<SessionID> { Set(open.keys) }

    /// Starts `claude attach` for the session unless it runs. Nil when it runs, else why it couldn't start.
    func ensure(_ sid: SessionID, shortId: String, account: Account, cwd: String, cols: Int, rows: Int) -> String? {
        if open[sid]?.term.isRunning == true { return nil }
        let t = AttachTerminal(session: sid)
        if let e = t.start(shortId: shortId, account: account, cwd: cwd, cols: cols, rows: rows) { return "\(e)" }
        let e = Entry(t)
        open[sid] = e
        // Ready once Claude has drawn and gone quiet for a moment, or a few seconds after it first drew
        // (a working session's spinner never goes quiet).
        e.readyQuiet = Debounce(0.6) { [weak self] in self?.becameReady(sid) }
        e.readyMax = Debounce(Self.attachTimeout) { [weak self] in self?.attachTimedOut(sid) }
        e.readyMax?.poke()
        e.echoQuiet = Debounce(0.15) { [weak self] in self?.echoed(sid) }
        e.echoMax = Debounce(1.5) { [weak self] in self?.echoed(sid) }
        t.onOutput = { [weak self] data in self?.output(sid, data) }
        t.onExit = { [weak self] in self?.exited(sid) }
        mark("phone: attached a terminal (\(shortId))")
        return nil
    }

    func resize(_ sid: SessionID, cols: Int, rows: Int) { open[sid]?.term.resize(cols: cols, rows: rows) }

    func write(_ bytes: Data, to sid: SessionID) { open[sid]?.term.write(bytes) }

    func release(_ sid: SessionID) {
        guard let e = open.removeValue(forKey: sid) else { return }
        fail(e, "the terminal was closed")
        e.term.close()
        mark("phone: let go of a terminal")
    }

    /// Types text and presses Return, once Claude is ready for it. `done` gets nil, or what went wrong.
    func type(_ text: String, into sid: SessionID, done: @escaping (String?) -> Void) {
        enqueue(.type(text, done: done), sid)
    }

    /// Presses keys as they are (`1`, `2`, Esc), once Claude is ready.
    func press(_ keys: Data, into sid: SessionID, done: @escaping (String?) -> Void) {
        enqueue(.keys(keys, done: done), sid)
    }

    // MARK: running jobs

    private func enqueue(_ job: Job, _ sid: SessionID) {
        guard let e = open[sid] else {
            switch job { case .type(_, let done), .keys(_, let done): done("no terminal for this session") }
            return
        }
        e.jobs.append(job)
        next(sid)
    }

    private func next(_ sid: SessionID) {
        guard let e = open[sid], e.ready, !e.busy, !e.jobs.isEmpty else { return }
        let job = e.jobs.removeFirst()
        switch job {
        case .keys(let bytes, let done):
            e.term.write(bytes)
            done(nil)
            next(sid)
        case .type(let text, _):
            e.busy = true
            // Several lines go in as one bracketed paste, so a newline doesn't send the first line alone.
            let body = text.contains("\n") ? "\u{1b}[200~\(text)\u{1b}[201~" : text
            e.echoing = true
            e.term.write(Data(body.utf8))
            e.echoMax?.poke()
            e.jobs.insert(job, at: 0)
        }
    }

    /// The typed text has drawn (or 1.5 s passed): press Return and finish the job.
    private func echoed(_ sid: SessionID) {
        guard let e = open[sid], e.echoing else { return }
        e.echoing = false
        e.echoQuiet?.cancel()
        e.echoMax?.cancel()
        e.term.write(Data("\r".utf8))
        e.busy = false
        if case .type(_, let done)? = e.jobs.first { e.jobs.removeFirst(); done(nil) }
        next(sid)
    }

    private func output(_ sid: SessionID, _ data: Data) {
        guard let e = open[sid] else { return }
        if !e.ready {
            if !e.sawOutput {
                e.sawOutput = true
                e.readyMax?.poke(after: 4)
            }
            e.readyQuiet?.poke()
        }
        if e.echoing { e.echoQuiet?.poke() }
        onOutput?(sid, data)
    }

    private func becameReady(_ sid: SessionID) {
        guard let e = open[sid], !e.ready else { return }
        e.ready = true
        e.readyMax?.cancel()
        next(sid)
    }

    private func attachTimedOut(_ sid: SessionID) {
        guard let e = open[sid], !e.ready else { return }
        if e.sawOutput { return becameReady(sid) }
        mark("phone: claude attach drew nothing in \(Int(Self.attachTimeout)) s")
        release(sid)
    }

    private func exited(_ sid: SessionID) {
        guard let e = open.removeValue(forKey: sid) else { return }
        fail(e, "claude attach exited")
        mark("phone: claude attach exited")
    }

    private func fail(_ e: Entry, _ why: String) {
        for job in e.jobs {
            switch job { case .type(_, let done), .keys(_, let done): done(why) }
        }
        e.jobs = []
        [e.readyQuiet, e.readyMax, e.echoQuiet, e.echoMax].forEach { $0?.cancel() }
    }
}
