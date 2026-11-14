import AppKit

/// The "Pixel demon" app icon, drawn in code: square ink pixels on a flat material,
/// no gradients. Variants match artifacts/maxwell-icons.html; `app-icon` picks one.
enum IconArt {
    static let demon = ["1000001", "1100011", "0111110", "0101010", "0111110", "0011100", "0010100"]
    static let demonEyes = ["1000001", "1100011", "0111110", "01a1a10", "0111110", "0011100", "0010100"]

    struct Variant { var body: String; var brush: CGFloat; var edge: NSColor; var ink: String; var off: NSColor; var eyes: Bool }
    static let variants: [String: Variant] = [
        "light": .init(body: "#c3c6cb", brush: 0.22, edge: NSColor(white: 0, alpha: 0.25), ink: "#1c1d20", off: NSColor(white: 0, alpha: 0.06), eyes: false),
        "dark": .init(body: "#2b2d31", brush: 0.05, edge: NSColor(white: 0, alpha: 0.6), ink: "#d6d9dd", off: NSColor(white: 1, alpha: 0.05), eyes: false),
        "paper": .init(body: "#e7e8eb", brush: 0, edge: NSColor(white: 0, alpha: 0.15), ink: "#1c1d20", off: NSColor(white: 0, alpha: 0.06), eyes: false),
        "graphite": .init(body: "#141518", brush: 0, edge: NSColor(white: 0, alpha: 0.7), ink: "#e3e5e8", off: NSColor(white: 1, alpha: 0.045), eyes: false),
        "light-eyes": .init(body: "#c3c6cb", brush: 0.22, edge: NSColor(white: 0, alpha: 0.25), ink: "#1c1d20", off: NSColor(white: 0, alpha: 0.06), eyes: true),
        "dark-eyes": .init(body: "#2b2d31", brush: 0.05, edge: NSColor(white: 0, alpha: 0.6), ink: "#d6d9dd", off: NSColor(white: 1, alpha: 0.05), eyes: true),
    ]

    /// What Settings › Appearance offers, in order. Titles name the material; "eyes" adds the amber eyes.
    static let choices: [(value: String, title: String, tip: String)] = [
        ("auto", "Auto", "Silver in light mode, Gunmetal in dark"),
        ("light", "Silver", "Brushed silver, black pixels"),
        ("dark", "Gunmetal", "Dark metal, light pixels. The built-in icon"),
        ("paper", "Paper", "Flat paper grey, black pixels"),
        ("graphite", "Graphite", "Near black, light pixels"),
        ("light-eyes", "Silver eyes", "Silver with amber eyes"),
        ("dark-eyes", "Gunmetal eyes", "Gunmetal with amber eyes"),
    ]

    static var choice = "auto"

    static func apply(dark: Bool) {
        let name = choice == "auto" ? (dark ? "dark" : "light") : choice
        NSApp.applicationIconImage = image(name, size: 512)
        persist(name)
    }

    /// While Maxwell is closed, the Dock, Finder and Launchpad show the bundle's icon. The built-in
    /// one is Gunmetal; any other pick is written onto the bundle as a custom icon (codesign ignores
    /// it). An update replaces the bundle and drops it, so the next launch writes it again.
    private static func persist(_ name: String) {
        guard !CommandLine.arguments.contains("--quit-after") else { return }  // test runs leave the bundle alone
        let path = Bundle.main.bundlePath, key = "bundleIcon"
        let has = FileManager.default.fileExists(atPath: path + "/Icon\r")
        if variants[name] == nil || name == "dark" {
            if has { NSWorkspace.shared.setIcon(nil, forFile: path, options: []) }
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        if has && UserDefaults.standard.string(forKey: key) == name { return }
        if NSWorkspace.shared.setIcon(image(name, size: 1024), forFile: path, options: []) {
            UserDefaults.standard.set(name, forKey: key)
        }
    }

    /// The tile for a choice in Settings: "auto" is Silver on the left half, Gunmetal on the right.
    static func preview(_ value: String, size: CGFloat) -> NSImage {
        guard value == "auto" else { return image(value, size: size) }
        let light = image("light", size: size), dark = image("dark", size: size)
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            light.draw(in: r)
            NSGraphicsContext.saveGraphicsState()
            NSRect(x: r.midX, y: r.minY, width: r.width / 2, height: r.height).clip()
            dark.draw(in: r)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
    }

    static func image(_ name: String, size: CGFloat) -> NSImage {
        let v = variants[name] ?? variants["dark"]!
        return NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            let s = size / 100
            // macOS icon grid: the squircle sits inside a 10% margin.
            let inset: CGFloat = 10 * s, side = size - 2 * inset
            let shape = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: side, height: side), xRadius: side * 0.225, yRadius: side * 0.225)
            NSColor(hex: v.body)!.setFill()
            shape.fill()
            if v.brush > 0 {
                NSGraphicsContext.saveGraphicsState()
                shape.addClip()
                NSColor(white: 1, alpha: v.brush).setFill()
                var y = inset
                while y < inset + side { NSRect(x: inset, y: y, width: side, height: 0.55 * s * 0.8).fill(); y += 1.6 * s * 0.8 }
                NSGraphicsContext.restoreGraphicsState()
            }
            v.edge.setStroke()
            shape.lineWidth = max(1, s * 0.8)
            shape.stroke()
            let rows = v.eyes ? demonEyes : demon
            let step = side * 8 / 90, px = step * 0.8
            let x0 = size / 2 - (7 * step - (step - px)) / 2
            for (y, row) in rows.enumerated() {
                for (x, c) in row.enumerated() {
                    let color: NSColor = c == "1" ? NSColor(hex: v.ink)! : c == "a" ? NSColor(hex: "#d98324")! : v.off
                    color.setFill()
                    NSRect(x: x0 + CGFloat(x) * step, y: x0 + CGFloat(y) * step, width: px, height: px).fill()
                }
            }
            return true
        }
    }

    /// Writes an .iconset for iconutil (used by build.sh for the bundle icon).
    static func writeIconset(_ name: String, to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = base * scale
                let img = image(name, size: CGFloat(px))
                guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
                NSGraphicsContext.restoreGraphicsState()
                let file = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                try rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(file))
            }
        }
    }
}
