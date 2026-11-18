import Foundation

/// The artifacts each session's transcript holds, for the phone's list, off the main thread at utility QoS.
///
/// Transcripts run to gigabytes, so: a transcript seen for the first time is read from its last 16 MB;
/// after that only the bytes added since (keyed by path and inode). The bytes are searched for
/// `claude.ai/` and only the lines that hold it are parsed. Where each scan stopped, and what it found,
/// is kept in `<state dir>/phone-artifact-scans-1.json`, so a launch reads only what was written since.
/// A cache: deleting it costs one tail read per transcript.
final class ArtifactScanner {
    private struct Scan: Codable { var inode: UInt64; var offset: UInt64; var ledger = ArtifactLedger() }
    private let queue = DispatchQueue(label: "maxwell.phone.artifacts", qos: .utility)
    private var scans: [String: Scan]
    private var dirty = false
    private var running = false
    private let file = Paths.stateDir.appendingPathComponent("phone-artifact-scans-1.json")
    private static let needle = Array("claude.ai/".utf8)
    static let firstRead: UInt64 = 16 << 20
    static let chunk = 4 << 20

    init() {
        scans = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: Scan].self, from: $0) } ?? [:]
    }

    /// Reads what is new in these transcripts, in the order given (newest sessions first). `found` gets
    /// every artifact read so far, on main, after each 20 transcripts and at the end. A scan still running
    /// drops this call: the next state change asks again.
    func scan(_ sessions: [(id: SessionID, account: AccountID, transcript: String)], found: @escaping ([PhoneArtifact]) -> Void) {
        guard !running else { return }
        running = true
        queue.async { [self] in
            let started = Date()
            var out: [PhoneArtifact] = [], read: UInt64 = 0
            for (i, s) in sessions.enumerated() {
                let ledger = autoreleasepool { self.read(s.transcript, bytes: &read) }
                for (url, e) in ledger.entries {
                    out.append(PhoneArtifact(url: url, title: e.title, session: s.id, account: s.account, at: e.at))
                }
                if i % 20 == 19, read > 0 { let so = out; DispatchQueue.main.async { found(so) } }
            }
            if read > 32 << 20 {
                mark("phone: read \(read >> 20) MB of \(sessions.count) transcripts for artifacts in \(Int(Date().timeIntervalSince(started) * 1000)) ms, \(out.count) found")
            }
            save()
            DispatchQueue.main.async {
                self.running = false
                found(out)
            }
        }
    }

    private func read(_ path: String, bytes: inout UInt64) -> ArtifactLedger {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return scans[path]?.ledger ?? ArtifactLedger() }
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        var scan = scans[path] ?? Scan(inode: inode, offset: size > Self.firstRead ? size - Self.firstRead : 0)
        if scan.inode != inode || size < scan.offset { scan = Scan(inode: inode, offset: size > Self.firstRead ? size - Self.firstRead : 0) }
        guard size > scan.offset, let h = FileHandle(forReadingAtPath: path) else { return scan.ledger }
        defer { try? h.close() }
        // Each read starts at the last whole line: a line cut at a chunk's end is read again with the next.
        while scan.offset < size {
            let more: Bool = autoreleasepool {
                try? h.seek(toOffset: scan.offset)
                guard let data = try? h.read(upToCount: Self.chunk), !data.isEmpty else { return false }
                bytes += UInt64(data.count)
                guard let lastNL = data.lastIndex(of: 0x0A) else {
                    // A line longer than a chunk (a huge tool result) is skipped; a half-written last line waits.
                    if data.count == Self.chunk { scan.offset += UInt64(data.count); return true }
                    return false
                }
                Self.lines(mentioning: Self.needle, in: data[data.startIndex...lastNL]) { scan.ledger.read(Substring($0)) }
                scan.offset += UInt64(lastNL - data.startIndex + 1)
                return true
            }
            if !more { break }
        }
        scans[path] = scan
        dirty = true
        return scan.ledger
    }

    private func save() {
        guard dirty, let data = try? JSONEncoder().encode(scans) else { return }
        do { try data.write(to: file, options: .atomic) } catch { mark("phone: couldn't save the artifact scans: \(error.localizedDescription)") }
        dirty = false
    }

    /// Each whole line of `data` that contains `needle`, found with memmem.
    static func lines(mentioning needle: [UInt8], in data: Data, _ each: (String) -> Void) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var at = 0
            while at < raw.count, let hit = memmem(base + at, raw.count - at, needle, needle.count) {
                let h = base.distance(to: hit)
                var start = h
                while start > 0, raw[start - 1] != 0x0A { start -= 1 }
                var end = h
                while end < raw.count, raw[end] != 0x0A { end += 1 }
                each(String(decoding: UnsafeRawBufferPointer(rebasing: raw[start..<end]), as: UTF8.self))
                at = end + 1
            }
        }
    }
}
