import Foundation

/// What a crash report may say. Crash text can carry a path, a file name or a quoted value from
/// the user's work, so it is cut down to code locations and plain words before it leaves the Mac.
/// The full list of what is sent is on runmaxwell.com/docs/privacy#crash-reports; keep the two in step.
enum CrashScrub {
    /// Quoted text becomes <…>. A path becomes <path>, except a .swift source file, which keeps
    /// its name (it is Maxwell's own code: "Terminal.swift:14"). Emails become <email>.
    static func text(_ s: String) -> String {
        var t = s
        t = replace(#"\"[^\"]*\"|'[^']*'|‘[^’]*’|“[^”]*”"#, in: t) { _ in "<…>" }
        t = replace(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, in: t) { _ in "<email>" }
        t = replace(#"(?<![\w.<])~?/[^\s:'\"(),;]+"#, in: t) { p in
            let name = (p as NSString).lastPathComponent
            return name.hasSuffix(".swift") ? name : "<path>"
        }
        let user = NSUserName()
        if user.count > 2 { t = t.replacingOccurrences(of: user, with: "<user>") }
        return t.count > 300 ? String(t.prefix(300)) + "…" : t
    }

    /// A loaded binary is named by its file name only: ".../Maxwell.app/Contents/MacOS/Maxwell" is
    /// "Maxwell", wherever the user keeps the app.
    static func image(_ path: String) -> String { (path as NSString).lastPathComponent }

    /// The device, OS and app facts a report keeps. Everything else in a context (locale, time zone,
    /// boot time, disk sizes, device hash) and every other context is dropped.
    static let keep: [String: Set<String>] = [
        "os": ["name", "version", "build", "kernel_version"],
        "device": ["family", "model", "model_id", "arch", "memory_size", "processor_count", "simulator"],
        "app": ["app_version", "app_build", "app_identifier", "app_name", "build_type", "in_foreground"],
        "trace": ["trace_id", "span_id", "op"],
    ]

    static func contexts(_ c: [String: [String: Any]]) -> [String: [String: Any]] {
        var out: [String: [String: Any]] = [:]
        for (name, fields) in c {
            guard let allowed = keep[name] else { continue }
            let kept = fields.filter { allowed.contains($0.key) }
            if !kept.isEmpty { out[name] = kept }
        }
        return out
    }

    private static func replace(_ pattern: String, in s: String, with f: (String) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        var out = "", last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += f(ns.substring(with: m.range))
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }
}
