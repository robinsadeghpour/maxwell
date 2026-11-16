import Foundation

/// A file named in terminal output, as Ghostty's link finder hands it over: an absolute or relative
/// path, a `file://` URL, maybe with `:line:col` after it or a full stop picked up from the sentence.
enum FileLink {
    /// The existing file `raw` names, trying each folder in `bases` in turn for a relative path.
    /// `isFile` decides what counts: the viewer shows files only, a plain terminal opens folders too.
    static func resolve(_ raw: String, bases: [String], home: String, isFile: (String) -> Bool) -> URL? {
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") { return nil }
        for path in candidates(raw, home: home) {
            let roots = path.hasPrefix("/") ? [""] : bases
            for root in roots {
                let url = URL(fileURLWithPath: (root as NSString).appendingPathComponent(path)).standardizedFileURL
                if isFile(url.path) { return url }
            }
        }
        return nil
    }

    /// The path as written, then without the punctuation a sentence leaves on it, each without
    /// `:line:col`, with `~` expanded.
    static func candidates(_ raw: String, home: String) -> [String] {
        var path = raw.hasPrefix("file://") ? (URL(string: raw)?.path ?? raw) : raw
        if path.hasPrefix("~/") { path = home + path.dropFirst() }
        var out: [String] = []
        func add(_ p: String) {
            var p = p
            if let r = p.range(of: #":\d+(:\d+)?$"#, options: .regularExpression) { p.removeSubrange(r) }
            if !p.isEmpty, !out.contains(p) { out.append(p) }
        }
        add(path)
        add(withoutTrailingPunctuation(path))
        return out
    }

    /// A link without the punctuation a sentence leaves after it ("notes.md." is "notes.md"):
    /// what opens, so what gets underlined.
    static func withoutTrailingPunctuation(_ s: String) -> String {
        String(s.reversed().drop { ".,;:!?)]}'\"`".contains($0) }.reversed())
    }
}
