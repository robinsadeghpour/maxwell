import Foundation

/// Follows one session's transcript for the phone: its last lines once, then each whole line as
/// Claude Code appends it. Reads happen off the main thread; lines arrive on main, in order.
final class TranscriptTail {
    let path: String
    private let queue = DispatchQueue(label: "maxwell.phone.transcript")
    private var offset: UInt64 = 0
    private var inode: UInt64 = 0
    private var carry = Data()
    private var watch: DispatchSourceFileSystemObject?
    private var stopped = false
    /// New whole lines since the last call (main thread).
    var onLines: (([Substring]) -> Void)?

    init(path: String) { self.path = path }

    /// The whole lines in the last `window` bytes, then follows the file from there. `done` runs on main.
    func start(window: UInt64 = 4 << 20, done: @escaping ([Substring]) -> Void) {
        queue.async { [self] in
            var lines: [Substring] = []
            if let h = FileHandle(forReadingAtPath: path) {
                defer { try? h.close() }
                let size = (try? h.seekToEnd()) ?? 0
                let from = size > window ? size - window : 0
                try? h.seek(toOffset: from)
                let data = (try? h.readToEnd()) ?? Data()
                if let lastNL = data.lastIndex(of: 0x0A) {
                    let text = String(decoding: data[data.startIndex...lastNL], as: UTF8.self)
                    lines = text.split(separator: "\n")
                    // A window that starts mid-line drops that first part.
                    if from > 0, !lines.isEmpty { lines.removeFirst() }
                    offset = from + UInt64(lastNL - data.startIndex + 1)
                } else {
                    offset = from
                }
                inode = Self.inode(path)
            }
            DispatchQueue.main.async {
                done(lines)
                self.follow()
            }
        }
    }

    /// Watches the file for writes. A file that isn't there yet, or was replaced, is picked up by `check()`.
    private func follow() {
        guard !stopped, watch == nil else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let w = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        w.setEventHandler { [weak self, weak w] in
            guard let self, let w else { return }
            if !w.data.intersection([.delete, .rename]).isEmpty { self.watch?.cancel(); self.watch = nil }
            self.check()
        }
        w.setCancelHandler { close(fd) }
        w.resume()
        watch = w
    }

    /// Reads what was added since the last read. Also called on every state change, which covers a
    /// transcript created after the phone focused and any write the watch missed.
    func check() {
        guard !stopped else { return }
        follow()
        queue.async { [self] in
            guard let h = FileHandle(forReadingAtPath: path) else { return }
            defer { try? h.close() }
            let size = (try? h.seekToEnd()) ?? 0
            let ino = Self.inode(path)
            if ino != inode || size < offset { inode = ino; offset = 0; carry = Data() }
            guard size > offset else { return }
            try? h.seek(toOffset: offset)
            let data = (try? h.read(upToCount: Int(min(size - offset, 16 << 20)))) ?? Data()
            offset += UInt64(data.count)
            let buf = carry + data
            guard let lastNL = buf.lastIndex(of: 0x0A) else { carry = buf; return }
            carry = Data(buf[(lastNL + 1)...])
            let lines = String(decoding: buf[buf.startIndex...lastNL], as: UTF8.self).split(separator: "\n")
            guard !lines.isEmpty else { return }
            DispatchQueue.main.async { if !self.stopped { self.onLines?(lines) } }
        }
    }

    func stop() {
        stopped = true
        watch?.cancel()
        watch = nil
    }

    private static func inode(_ path: String) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }

    deinit { watch?.cancel() }
}
