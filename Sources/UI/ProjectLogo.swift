import AppKit

/// A project's logo turned into Maxwell's language: the silhouette of the repo's own icon,
/// drawn either as square ink pixels (like the pixel-demon app icon) or as an engraved mark,
/// in the theme's ink on a glass key. Never the original colours.
struct LogoMark {
    static let side = 48
    static let faint: Float = 0.4
    let source: String
    /// side × side coverage, 0 … 1, row 0 at the top.
    let mask: [Float]

    /// Square pixels on an `n` × `n` grid: each cell is full ink, faint ink, or off.
    func cells(_ n: Int) -> [[Float]] {
        let s = Self.side
        return (0..<n).map { cy in (0..<n).map { cx in
            let x0 = cx * s / n, x1 = (cx + 1) * s / n, y0 = cy * s / n, y1 = (cy + 1) * s / n
            var dark: Float = 0, any: Float = 0
            for y in y0..<y1 { for x in x0..<x1 {
                let v = mask[y * s + x]
                if v > 0.7 { dark += 1 }
                if v > Self.faint * 0.5 { any += 1 }
            } }
            let area = Float((x1 - x0) * (y1 - y0))
            return dark / area >= 0.45 ? 1 : any / area >= 0.5 ? Self.faint : 0
        } }
    }

    /// The silhouette as an image whose alpha is the mask, filled with `color`.
    func image(_ color: NSColor) -> NSImage {
        let s = Self.side
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: s, pixelsHigh: s, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: s * 4, bitsPerPixel: 32)!
        let c = color.usingColorSpace(.deviceRGB) ?? color
        let p = rep.bitmapData!
        for i in 0..<(s * s) {
            let a = mask[i] * Float(c.alphaComponent)
            p[i * 4] = UInt8(Float(c.redComponent) * a * 255)
            p[i * 4 + 1] = UInt8(Float(c.greenComponent) * a * 255)
            p[i * 4 + 2] = UInt8(Float(c.blueComponent) * a * 255)
            p[i * 4 + 3] = UInt8(a * 255)
        }
        let img = NSImage(size: NSSize(width: s, height: s))
        img.addRepresentation(rep)
        return img
    }

    /// Reads any image AppKit opens (PNG, ICO, SVG) and keeps the shape that differs from its
    /// background: the border's colour when the icon is full-bleed, transparency otherwise.
    static func extract(from url: URL) -> LogoMark? {
        guard let img = NSImage(contentsOf: url), img.size.width > 0 else { return nil }
        let n = 96
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let k = min(CGFloat(n) / img.size.width, CGFloat(n) / img.size.height)
        let w = img.size.width * k, h = img.size.height * k
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        img.draw(in: NSRect(x: (CGFloat(n) - w) / 2, y: (CGFloat(n) - h) / 2, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = ctx.data?.bindMemory(to: UInt8.self, capacity: n * n * 4) else { return nil }
        // A bitmap context's memory starts with the top row (only its drawing origin is at the bottom).
        func px(_ x: Int, _ y: Int) -> (Float, Float, Float, Float) {
            let i = (y * n + x) * 4
            let a = Float(data[i + 3]) / 255
            guard a > 0 else { return (0, 0, 0, 0) }
            return (Float(data[i]) / 255 / a, Float(data[i + 1]) / 255 / a, Float(data[i + 2]) / 255 / a, a)
        }
        var ring: [(Float, Float, Float)] = []
        var ringCount = 0
        for i in 0..<n {
            for (x, y) in [(i, 1), (i, n - 2), (1, i), (n - 2, i)] {
                ringCount += 1
                let p = px(x, y)
                if p.3 > 0.5 { ring.append((p.0, p.1, p.2)) }
            }
        }
        let fullBleed = Float(ring.count) / Float(ringCount) > 0.6
        func median(_ v: [Float]) -> Float { v.sorted()[v.count / 2] }
        let bg = fullBleed ? (median(ring.map(\.0)), median(ring.map(\.1)), median(ring.map(\.2))) : (0, 0, 0)
        func diff(_ a: (Float, Float, Float, Float), _ b: (Float, Float, Float)) -> Float { max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2)) }
        // Background = what a magic wand from the border reaches through small steps, so a soft
        // gradient behind the mark goes too. Enclosed areas stay part of the mark unless they are
        // the background colour itself (the hole in an O).
        var isBg = [Bool](repeating: false, count: n * n)
        var stack: [(Int, Int)] = []
        for i in 0..<n { stack += [(i, 0), (i, n - 1), (0, i), (n - 1, i)] }
        while let (x, y) = stack.popLast() {
            guard !isBg[y * n + x] else { continue }
            isBg[y * n + x] = true
            let p = px(x, y)
            for (nx, ny) in [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)] where nx >= 0 && ny >= 0 && nx < n && ny < n && !isBg[ny * n + nx] {
                let q = px(nx, ny)
                let passable = fullBleed
                    ? q.3 <= 0.5 || (diff(q, (p.0, p.1, p.2)) < 0.05 && diff(q, bg) < 0.35)
                    : q.3 <= 0.5
                if passable { stack.append((nx, ny)) }
            }
        }
        var fg = [Float](repeating: 0, count: n * n)
        var minX = n, minY = n, maxX = -1, maxY = -1
        for y in 0..<n {
            for x in 0..<n {
                let p = px(x, y)
                var v: Float = isBg[y * n + x] ? 0 : p.3
                if fullBleed, v > 0, diff(p, bg) < 0.06 { v = 0 }
                fg[y * n + x] = v
                if v > 0.5 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
            }
        }
        // Two inks, so an outlined mark keeps its inside: the darker half of the mark at full
        // strength, the lighter half (a letter's fill, a frame's inside) at a fainter one.
        let lum = (0..<(n * n)).map { i -> Float in let p = px(i % n, i / n); return 0.3 * p.0 + 0.59 * p.1 + 0.11 * p.2 }
        let inMark = (0..<(n * n)).filter { fg[$0] > 0.5 }.map { lum[$0] }.sorted()
        if inMark.count > 20 {
            let lo = inMark[inMark.count / 10], hi = inMark[inMark.count * 9 / 10]
            if hi - lo > 0.3 { for i in 0..<(n * n) where fg[i] > 0 && lum[i] > (lo + hi) / 2 { fg[i] *= Self.faint } }
        }
        guard maxX >= minX else { return nil }
        // Crop to the shape, centred in a square, so every mark fills its key the same way.
        let side = max(maxX - minX, maxY - minY) + 1
        let ox = minX - (side - (maxX - minX + 1)) / 2, oy = minY - (side - (maxY - minY + 1)) / 2
        let s = Self.side
        var mask = [Float](repeating: 0, count: s * s)
        for y in 0..<s {
            for x in 0..<s {
                // Box filter over the source cells this output pixel spans.
                let sx0 = ox + x * side / s, sx1 = max(sx0 + 1, ox + (x + 1) * side / s)
                let sy0 = oy + y * side / s, sy1 = max(sy0 + 1, oy + (y + 1) * side / s)
                var sum: Float = 0, cnt: Float = 0
                for yy in sy0..<sy1 { for xx in sx0..<sx1 {
                    cnt += 1
                    if xx >= 0, yy >= 0, xx < n, yy < n { sum += fg[yy * n + xx] }
                } }
                mask[y * s + x] = sum / cnt
            }
        }
        return LogoMark(source: url.path, mask: mask)
    }
}

/// Finds, converts, caches and draws project logos.
final class ProjectLogos {
    static let shared = ProjectLogos()
    enum Style: String { case pixel, engraved, monogram }

    var style = Style.pixel
    var overrides: [String: String] = [:]
    /// Called on the main thread when a mark finishes loading.
    var onChange: (() -> Void)?
    private var marks: [String: (roots: [String], mark: LogoMark?)] = [:]
    private var pending = Set<String>()
    private var generation = 0
    private let queue = DispatchQueue(label: "maxwell.logos", qos: .utility)

    static var cacheDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("dev.maxwell.app/logos")
    }

    /// The mark for a project, or nil while it first loads or when the repo has none.
    /// `roots` are the folders its sessions run in; when they change the search runs again,
    /// and the old mark stays up until the new one is ready.
    func mark(_ project: String, roots: [String]) -> LogoMark? {
        let known = marks[project]
        if known?.roots == roots || pending.contains(project) { return known?.mark }
        pending.insert(project)
        let override = overrides[project], generation = generation
        queue.async {
            let m = autoreleasepool { () -> LogoMark? in
                let url = override.map { URL(fileURLWithPath: $0) } ?? Self.findCached(roots: roots)
                return url.flatMap { Self.cached($0) }
            }
            DispatchQueue.main.async {
                guard generation == self.generation else { return }   // style or overrides changed meanwhile
                self.marks[project] = (roots, m)
                self.pending.remove(project)
                self.onChange?()
            }
        }
        return known?.mark
    }

    /// Sets a project's mark directly, for the contact sheet and tests.
    func set(_ project: String, mark: LogoMark?, roots: [String]) { marks[project] = (roots, mark) }

    func reset() { marks = [:]; pending = []; generation += 1 }

    /// Bump when `extract` changes, so masks converted by older code are never read again.
    static let maskVersion = 2

    /// Converted masks are cached by source path, modification time and `maskVersion`.
    static func cached(_ url: URL) -> LogoMark? {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0
        let key = stableHash(url.path + "\(Int(mtime))v\(maskVersion)")
        let file = cacheDir.appendingPathComponent("\(key)-\(url.deletingPathExtension().lastPathComponent).mask")
        let s = LogoMark.side
        if let d = try? Data(contentsOf: file), d.count == s * s {
            return LogoMark(source: url.path, mask: d.map { Float($0) / 255 })
        }
        guard let m = LogoMark.extract(from: url) else { return nil }
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try? Data(m.mask.map { UInt8(min(255, max(0, $0 * 255))) }).write(to: file)
        return m
    }

    /// FNV-1a: Swift's own hashValue changes every launch, which would defeat the disk cache.
    static func stableHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(format: "%016llx", h)
    }

    /// `find`, remembered for a day per set of roots: walking a big repo costs a second of disk.
    static func findCached(roots: [String]) -> URL? {
        let key = stableHash(roots.sorted().joined(separator: "|"))
        let file = cacheDir.appendingPathComponent("find-\(key).txt")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path), let d = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(d) < 86400, let text = try? String(contentsOf: file, encoding: .utf8) {
            return text.isEmpty ? nil : URL(fileURLWithPath: text)
        }
        let url = find(roots: roots)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try? (url?.path ?? "").write(to: file, atomically: true, encoding: .utf8)
        return url
    }

    /// Best logo file in a repo: an app icon set, then a touch icon, then icon/logo files,
    /// then a favicon. Shallower wins inside a tier. Skips dependencies and build output.
    static func find(roots: [String]) -> URL? {
        let skip: Set<String> = ["node_modules", ".git", "build", "dist", ".next", "Pods", "vendor", "DerivedData", ".turbo", "out", "coverage", "footage", "tmp"]
        func tier(_ path: String) -> Int? {
            let name = (path as NSString).lastPathComponent.lowercased()
            let ext = (name as NSString).pathExtension
            guard ["png", "svg", "icns", "ico", "jpg"].contains(ext) else { return nil }
            if path.contains("AppIcon.appiconset/") { return 0 }
            if name.hasPrefix("apple-touch-icon") { return 1 }
            if name == "icon.png" || name == "icon.svg" || name.hasPrefix("app-icon") { return 2 }
            if name.hasPrefix("logo") && !name.contains("navbar") { return 3 }
            if name.hasPrefix("favicon") && ext != "ico" { return 4 }
            return nil
        }
        var best: (tier: Int, depth: Int, size: Int, url: URL)?
        let fm = FileManager.default
        for root in Set(roots) {
            let base = URL(fileURLWithPath: root)
            guard let e = fm.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { continue }
            while let next = autoreleasepool(invoking: { e.nextObject() as? URL }) {
                let url = next
                let depth = url.pathComponents.count - base.pathComponents.count
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    if skip.contains(url.lastPathComponent) || url.lastPathComponent.hasSuffix("-worktrees") || depth >= 6 { e.skipDescendants() }
                    continue
                }
                guard let t = tier(url.path) else { continue }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let cand = (t, depth, size, url)
                if best.map({ (cand.0, cand.1, -cand.2) < ($0.tier, $0.depth, -$0.size) }) ?? true { best = cand }
            }
        }
        // .github/logo.svg sits in a hidden folder the enumerator skips; it is a common brand mark.
        if best == nil || best!.tier > 3 {
            for root in roots {
                let u = URL(fileURLWithPath: root).appendingPathComponent(".github/logo.svg")
                if fm.fileExists(atPath: u.path) { return u }
            }
        }
        return best?.url
    }

    // MARK: drawing

    /// Draws the project's key: glass tile, hairline edge, then the mark (or a pixel monogram).
    func drawKey(_ project: String?, monogram: String, roots: [String], in r: NSRect, ink: NSColor, theme t: Theme) {
        let inner = r.insetBy(dx: r.width * 0.2, dy: r.height * 0.2)
        if project == nil { return Self.drawPixels(Self.allMark, in: inner, ink: ink, off: nil) }
        // Maxwell's own mark is the app icon's demon.
        if project == "Maxwell", overrides["Maxwell"] == nil {
            return Self.drawPixels(IconArt.demon.map { $0.map { $0 == "1" ? 1 : 0 } }, in: inner, ink: ink, off: nil)
        }
        let m = style == .monogram ? nil : mark(project!, roots: roots)
        switch (m, style) {
        case (let m?, .engraved):
            let sink = t.dark ? NSColor.black.withAlphaComponent(0.55) : NSColor.white.withAlphaComponent(0.9)
            m.image(sink).draw(in: inner.offsetBy(dx: 0, dy: 0.75), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            m.image(ink).draw(in: inner, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        case (let m?, _):
            Self.drawPixels(m.cells(13), in: inner.insetBy(dx: -1, dy: -1), ink: ink, off: r.width >= 40 ? t.hair2 : nil)
        case (nil, _):
            Self.drawPixels(Self.monogramCells(monogram), in: inner, ink: ink, off: nil)
        }
    }

    static func drawPixels(_ cells: [[Float]], in r: NSRect, ink: NSColor, off: NSColor?) {
        let rows = cells.count, cols = cells.first?.count ?? 0
        guard rows > 0, cols > 0 else { return }
        let step = min(r.width / CGFloat(cols), r.height / CGFloat(rows))
        let px = step * 0.84
        let x0 = r.midX - step * CGFloat(cols) / 2, y0 = r.midY - step * CGFloat(rows) / 2
        for (y, row) in cells.enumerated() {
            for (x, level) in row.enumerated() {
                guard level > 0 || off != nil else { continue }
                (level > 0 ? ink.withAlphaComponent(ink.alphaComponent * CGFloat(level)) : off!).setFill()
                NSRect(x: x0 + CGFloat(x) * step, y: y0 + CGFloat(y) * step, width: px, height: px).fill()
            }
        }
    }

    /// "All": four squares, the same pixel grammar as the marks.
    static let allMark: [[Float]] = ["11011", "11011", "00000", "11011", "11011"].map { $0.map { $0 == "1" ? 1 : 0 } }

    /// Two letters of a 3 × 5 pixel face, side by side.
    static func monogramCells(_ s: String) -> [[Float]] {
        let letters = Array(s.uppercased().prefix(2))
        return (0..<5).map { y in
            letters.enumerated().flatMap { i, ch -> [Float] in
                let rows = font[ch] ?? font["?"]!
                return (i > 0 ? [0] : []) + rows[y].map { $0 == "1" ? 1 : 0 }
            }
        }
    }

    static let font: [Character: [String]] = [
        "A": ["010", "101", "111", "101", "101"], "B": ["110", "101", "110", "101", "110"], "C": ["011", "100", "100", "100", "011"],
        "D": ["110", "101", "101", "101", "110"], "E": ["111", "100", "110", "100", "111"], "F": ["111", "100", "110", "100", "100"],
        "G": ["011", "100", "101", "101", "011"], "H": ["101", "101", "111", "101", "101"], "I": ["111", "010", "010", "010", "111"],
        "J": ["001", "001", "001", "101", "010"], "K": ["101", "101", "110", "101", "101"], "L": ["100", "100", "100", "100", "111"],
        "M": ["101", "111", "111", "101", "101"], "N": ["110", "101", "101", "101", "101"], "O": ["010", "101", "101", "101", "010"],
        "P": ["110", "101", "110", "100", "100"], "Q": ["010", "101", "101", "110", "011"], "R": ["110", "101", "110", "101", "101"],
        "S": ["011", "100", "010", "001", "110"], "T": ["111", "010", "010", "010", "010"], "U": ["101", "101", "101", "101", "111"],
        "V": ["101", "101", "101", "101", "010"], "W": ["101", "101", "111", "111", "101"], "X": ["101", "101", "010", "101", "101"],
        "Y": ["101", "101", "010", "010", "010"], "Z": ["111", "001", "010", "100", "111"], "?": ["111", "001", "010", "000", "010"],
        "0": ["111", "101", "101", "101", "111"], "1": ["010", "110", "010", "010", "111"], "2": ["110", "001", "010", "100", "111"],
    ]
}

extension ProjectLogos {
    /// A contact sheet for review: per project the source, then pixel and engraved keys in
    /// Graphite and Paper at rail size and at 4×.
    static func writeSheet(_ projects: [(String, String)], overrides: [String: String], to out: URL) throws {
        let themes = [Theme.load("graphite"), Theme.load("paper")]
        let cell: CGFloat = 132, rowH: CGFloat = 150
        let size = NSSize(width: 160 + cell * 4, height: 40 + rowH * CGFloat(projects.count))
        let logos = ProjectLogos()
        logos.overrides = overrides
        var marks: [String: LogoMark] = [:]
        for (name, root) in projects {
            if let u = overrides[name].map({ URL(fileURLWithPath: $0) }) ?? find(roots: [root]), let m = cached(u) { marks[name] = m }
        }
        let img = NSImage(size: size, flipped: true) { _ in
            NSColor(white: 0.5, alpha: 1).setFill(); NSRect(origin: .zero, size: size).fill()
            let label: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.white]
            for (i, h) in ["source", "pixel · graphite", "engraved · graphite", "pixel · paper", "engraved · paper"].enumerated() {
                (h as NSString).draw(at: NSPoint(x: i == 0 ? 12 : 160 + cell * CGFloat(i - 1) + 8, y: 12), withAttributes: label)
            }
            for (row, (name, _)) in projects.enumerated() {
                let y = 40 + rowH * CGFloat(row)
                (name as NSString).draw(at: NSPoint(x: 12, y: y + rowH - 22), withAttributes: label)
                if let m = marks[name], let src = NSImage(contentsOfFile: m.source) {
                    src.draw(in: NSRect(x: 12, y: y + 4, width: 110, height: 110), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
                for (i, (t, style)) in [(themes[0], Style.pixel), (themes[0], .engraved), (themes[1], .pixel), (themes[1], .engraved)].enumerated() {
                    let x = 160 + cell * CGFloat(i)
                    let bg = NSRect(x: x, y: y, width: cell - 4, height: rowH - 4)
                    (t.dark ? NSColor(hex: "#1b1c21")! : NSColor(hex: "#e9eaee")!).setFill(); bg.fill()
                    logos.style = style
                    logos.set(name, mark: marks[name], roots: [])
                    for (k, s) in [(0, CGFloat(26)), (1, CGFloat(96))] {
                        let r = k == 0 ? NSRect(x: x + 10, y: y + 10, width: s, height: s) : NSRect(x: x + 24, y: y + 42, width: s, height: s)
                        let path = NSBezierPath(roundedRect: r, xRadius: s * 0.16, yRadius: s * 0.16)
                        t.hair2.setFill(); path.fill(); t.hair.setStroke(); path.lineWidth = 1; path.stroke()
                        logos.drawKey(name, monogram: String(name.prefix(2)), roots: [], in: r, ink: t.fg, theme: t)
                    }
                }
            }
            return true
        }
        let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
        try rep.representation(using: .png, properties: [:])!.write(to: out)
    }
}
