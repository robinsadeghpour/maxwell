import AppKit

/// A logo drawn from a known asymmetric source: a bar along the top and a block at the bottom
/// left. Goes through the real path (file, `LogoMark.extract`, `drawKey` in a flipped view)
/// and checks the bar lands on top and the block on the left, in every logo style.
func logoTests() {
    let s = 64
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: s, pixelsHigh: s, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: s * 4, bitsPerPixel: 32)!
    for y in 0..<s { for x in 0..<s {
        let on = y < 12 || (x < 16 && y >= 44)
        let i = (y * s + x) * 4
        rep.bitmapData![i + 3] = on ? 255 : 0
    } }
    let src = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mx-logo-\(getpid()).png")
    try? rep.representation(using: .png, properties: [:])!.write(to: src)
    defer { try? FileManager.default.removeItem(at: src) }
    guard let mark = LogoMark.extract(from: src) else { return check(false, "the test logo extracts") }

    let n = 96
    for style in [ProjectLogos.Style.engraved, .pixel] {
        let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(n)); ctx.scaleBy(x: 1, y: -1)   // like MXView: y = 0 at the top
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        let logos = ProjectLogos()
        logos.style = style
        logos.set("Test", mark: mark, roots: [])
        logos.drawKey("Test", monogram: "TE", roots: [], in: NSRect(x: 0, y: 0, width: n, height: n), ink: .black, theme: Theme.load("graphite"))
        NSGraphicsContext.restoreGraphicsState()
        let px = ctx.data!.bindMemory(to: UInt8.self, capacity: n * n * 4)
        // Memory row 0 is the top of the picture.
        func ink(_ xs: Range<Int>, _ ys: Range<Int>) -> Int { ys.reduce(0) { a, y in xs.reduce(a) { $0 + Int(px[(y * n + $1) * 4 + 3]) } } }
        let top = ink(0..<n, 0..<n / 2), bottom = ink(0..<n, n / 2..<n)
        let lowLeft = ink(0..<n / 2, n * 2 / 3..<n), lowRight = ink(n / 2..<n, n * 2 / 3..<n)
        check(top > bottom * 2, "\(style) logo keeps the bar on top (top \(top), bottom \(bottom))")
        check(lowLeft > lowRight * 2, "\(style) logo keeps the block on the left (left \(lowLeft), right \(lowRight))")
    }
}
