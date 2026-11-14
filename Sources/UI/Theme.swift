import AppKit

/// A theme is a token file (Resources/themes/<name>, or ~/.config/maxwell/themes/<name>).
/// Every colour in the app comes from here; sizes come from `Metrics`.
struct Theme {
    var name: String
    var dark: Bool
    var background: NSColor
    var backgroundOpacity: CGFloat
    /// Frost radius behind the window; nil uses the macOS material.
    var backgroundBlur: CGFloat?
    var plane: NSColor            // rail and sidebar sit on this extra tint, one step off the terminal
    var panel: NSColor
    var fg: NSColor
    var fg2: NSColor
    var fg3: NSColor
    var hair: NSColor
    var hair2: NSColor
    var hover: NSColor
    var sel: NSColor
    var selFg: NSColor
    var rowSel: NSColor           // the selected session row: a raised key, not an inverted block
    var dim: NSColor              // laid over an unfocused pane, like Ghostty's unfocused split
    var on: NSColor        // needs you: the only loud state
    var chk: NSColor       // says done, not verified
    var safe: NSColor      // verified, safe to close
    var cursor: NSColor
    var selection: NSColor
    /// Set only by light themes: Claude Code's dark TUI needs a dark well to stay readable.
    var terminalBackground: NSColor?
    var terminalForeground: NSColor
    var terminalCursor: NSColor
    var terminalSelection: NSColor

    static func load(_ name: String) -> Theme {
        let user = Paths.home.appendingPathComponent(".config/maxwell/themes/\(name)")
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("themes/\(name)")
        let text = [user, bundled].compactMap { $0 }.lazy.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.first
            ?? (try? String(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("themes/graphite"), encoding: .utf8)) ?? ""
        var t: [String: String] = [:]
        for (k, v) in Config.entries(text) { t[k] = v }
        func c(_ k: String, _ d: String) -> NSColor { NSColor(hex: t[k] ?? d) ?? .magenta }
        return Theme(
            name: name, dark: t["appearance"] != "light",
            background: c("background", "#0d0e11"),
            backgroundOpacity: CGFloat(Double(t["background-opacity"] ?? "") ?? 0.86),
            backgroundBlur: t["background-blur"].flatMap(Double.init).map { CGFloat($0) },
            plane: c("plane", "#ffffff06"), panel: c("panel", "#15161a"), fg: c("fg", "#e6e7e9"), fg2: c("fg2", "#a2a6ac"), fg3: c("fg3", "#6b6f76"),
            hair: c("hair", "#ffffff14"), hair2: c("hair2", "#ffffff0b"), hover: c("hover", "#ffffff0d"),
            sel: c("sel", "#d8dbdf"), selFg: c("sel-fg", "#0d0e11"), rowSel: c("row-sel", "#ffffff14"), dim: c("dim", "#0000002e"), on: c("on", "#ffb340"), chk: c("chk", "#c88bff"),
            safe: c("safe", "#4be27f"), cursor: c("cursor", "#d8dbdf"), selection: c("selection", "#3a3d44"),
            terminalBackground: t["terminal-background"].flatMap { NSColor(hex: $0) },
            terminalForeground: c("terminal-foreground", t["fg"] ?? "#e6e7e9"),
            terminalCursor: c("terminal-cursor", t["cursor"] ?? "#d8dbdf"),
            terminalSelection: c("terminal-selection", t["selection"] ?? "#3a3d44"))
    }

    var appearance: NSAppearance? { NSAppearance(named: dark ? .darkAqua : .aqua) }

    func color(for group: PhaseGroup) -> NSColor {
        switch group {
        case .needsYou: return on
        case .yourTurn: return chk
        case .safeToClose: return safe
        case .working, .limited, .idle, .recentlyClosed: return fg3
        }
    }
}

enum Metrics {
    static var fontSize: CGFloat = 12
    static let row: CGFloat = 24
    static let row2: CGFloat = 38        // two-line session row
    static let rail: CGFloat = 40
    static let control: CGFloat = 22
    static let header: CGFloat = 28
    static let titlebar: CGFloat = 38
    static let status: CGFloat = 22
    static let side: CGFloat = 288
    static let viewer: CGFloat = 420
    static let gutter: CGFloat = 12
}

enum Fonts {
    static let family = "JetBrains Mono"

    /// Registers the bundled JetBrains Mono for this process (Ghostty finds it too).
    static func register() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let fonts = files.filter { $0.pathExtension == "ttf" } as CFArray
        CTFontManagerRegisterFontURLs(fonts, .process, true, nil)
    }

    static func mono(_ size: CGFloat = Metrics.fontSize, _ weight: NSFont.Weight = .regular) -> NSFont {
        let name: String
        switch weight {
        case .bold: name = "JetBrainsMono-Bold"
        case .semibold: name = "JetBrainsMono-SemiBold"
        case .medium: name = "JetBrainsMono-Medium"
        default: name = "JetBrainsMono-Regular"
        }
        return NSFont(name: name, size: size) ?? .monospacedSystemFont(ofSize: size, weight: weight)
    }
}

extension NSColor {
    /// #rgb, #rrggbb or #rrggbbaa.
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("#") else { return nil }
        s.removeFirst()
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let a = s.count == 8 ? CGFloat(v & 0xff) / 255 : 1
        let rgb = s.count == 8 ? v >> 8 : v
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255,
                  blue: CGFloat(rgb & 0xff) / 255, alpha: a)
    }

    var hex: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02x%02x%02x", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }

    var cssRGBA: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "rgba(%d,%d,%d,%.3f)", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)), c.alphaComponent)
    }
}
