import Foundation

/// The artifacts each session's transcript holds, for the phone's list. Each transcript is read once
/// and then only the bytes added since (keyed by path and inode), off the main thread. Transcripts run
/// to gigabytes, so the bytes are searched for `claude.ai/` and only the lines that hold it are parsed.
final class ArtifactScanner {
    private struct Scan { var inode: UInt64; var offset: UInt64 = 0; var ledger = ArtifactLedger() }
    private let queue = DispatchQueue(label: "maxwell.phone.artifacts", qos: .utility)
    private var scans: [String: Scan] = [:]
    private var running = false
    private static let needle = Array("claude.ai/".utf8)

    /// Reads what is new in these transcripts, in the order given (newest sessions first). `found` gets
    /// every artifact read so far, on main, after each few transcripts and at the end, so a first read of
    /// many large transcripts fills the list as it goes. A scan still running drops this call.
    func scan(_ sessions: [(id: SessionID, account: AccountID, transcript: String)], found: @escaping ([PhoneArtifact]) -> Void) {
        guard !running else { return }
        running = true
        queue.async { [self] in
            let started = Date(), first = scans.isEmpty
            var out: [PhoneArtifact] = []
            for (i, s) in sessions.enumerated() {
                let ledger = autoreleasepool { read(s.transcript) }
                for (url, e) in ledger.entries {
                    out.append(PhoneArtifact(url: url, title: e.title, session: s.id, account: s.account, at: e.at))
                }
                if first, i % 20 == 19 { let so = out; DispatchQueue.main.async { found(so) } }
            }
            if first { mark("phone: read \(sessions.count) transcripts for artifacts in \(Int(Date().timeIntervalSince(started) * 1000)) ms, \(out.count) found") }
            DispatchQueue.main.async {
                self.running = false
                found(out)
            }
        }
    }

    private func read(_ path: String) -> ArtifactLedger {
        let inode = ((try? FileManager.default.attributesOfItem(atPath: path))?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        var scan = scans[path] ?? Scan(inode: inode)
        guard let h = FileHandle(forReadingAtPath: path) else { return scan.ledger }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        if scan.inode != inode || size < scan.offset { scan = Scan(inode: inode) }
        guard size > scan.offset else { scans[path] = scan; return scan.ledger }
        try? h.seek(toOffset: scan.offset)
        var carry = Data()
        while let chunk = try? h.read(upToCount: 8 << 20), !chunk.isEmpty {
            let buf = carry + chunk
            guard let lastNL = buf.lastIndex(of: 0x0A) else { carry = buf; continue }
            Self.lines(mentioning: Self.needle, in: buf[buf.startIndex...lastNL]) { scan.ledger.read(Substring($0)) }
            scan.offset += UInt64(lastNL - buf.startIndex + 1)
            carry = Data(buf[(lastNL + 1)...])
        }
        scans[path] = scan
        return scan.ledger
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
