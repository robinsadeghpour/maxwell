import AppKit

/// What the orb shows: one state, who is on the line, and the words being said or heard.
struct VoiceOrbLook: Equatable {
    enum State { case starting, idle, speaking, listening, waiting, failed }
    var state = State.idle
    /// "Listening · Billing"
    var caption = ""
    var words = ""
}

/// Voice mode's presence on screen: a small panel that floats over every app, with an orb that
/// breathes while it rests, swells while Maxwell speaks and pulses while it listens.
final class VoiceOrb {
    var onClose: (() -> Void)?
    /// A click on the panel while a session waits: answer now.
    var onClick: (() -> Void)?
    private var window: NSWindow?
    private let view = VoiceOrbView(frame: NSRect(x: 0, y: 0, width: 380, height: 88))

    func show(_ look: VoiceOrbLook) {
        view.onClose = { [weak self] in self?.onClose?() }
        view.onClick = { [weak self] in self?.onClick?() }
        view.look = look
        if window == nil { window = makeWindow() }
        window?.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }

    /// The orb as it is drawn now, as PNG; nil while it is hidden. For scripted checks.
    func picture() -> Data? {
        guard window != nil, let layer = view.layer else { return nil }
        let scale: CGFloat = 2
        let size = view.bounds.size
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // The view is flipped; a bitmap context is not.
        ctx.translateBy(x: 0, y: size.height * scale)
        ctx.scaleBy(x: scale, y: -scale)
        view.displayIfNeeded()
        (layer.presentation() ?? layer).render(in: ctx)
        return ctx.makeImage().flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.level = .floating
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.contentView = view
        // A scripted run's windows stay past the right edge of every screen.
        if quietTest {
            w.setFrameOrigin(NSPoint(x: (NSScreen.screens.map(\.frame.maxX).max() ?? 0) + 2000, y: 0))
        } else if let s = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main {
            w.setFrameOrigin(NSPoint(x: s.visibleFrame.midX - view.frame.width / 2, y: s.visibleFrame.minY + 56))
        }
        return w
    }
}

final class VoiceOrbView: MXView {
    var look = VoiceOrbLook() { didSet { if look != oldValue { needsDisplay = true; animate() } } }
    var onClose: (() -> Void)?
    var onClick: (() -> Void)?
    private let halo = CALayer()
    private let core = CAGradientLayer()
    private lazy var close = IconButton(.close, tip: Tip("Turn voice mode off", action: "voice-mode")) { [weak self] in self?.onClose?() }
    private static let orbSize: CGFloat = 44

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        let box = NSRect(x: 22, y: (frame.height - Self.orbSize) / 2, width: Self.orbSize, height: Self.orbSize)
        halo.frame = box
        halo.cornerRadius = Self.orbSize / 2
        core.frame = box
        core.cornerRadius = Self.orbSize / 2
        core.type = .radial
        core.startPoint = CGPoint(x: 0.35, y: 0.35)
        core.endPoint = CGPoint(x: 1, y: 1)
        layer?.addSublayer(halo)
        layer?.addSublayer(core)
        addSubview(close)
        animate()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        close.frame.origin = NSPoint(x: bounds.width - close.frame.width - 6, y: 6)
    }

    override func lookChanged() { super.lookChanged(); animate() }
    override func mouseDown(with e: NSEvent) { onClick?() }

    private var tint: NSColor {
        switch look.state {
        case .listening: return t.on
        case .speaking: return t.chk
        case .failed: return t.on
        case .starting, .idle, .waiting: return t.fg3
        }
    }

    /// One slow breath at rest, a deeper one while speaking, a quick pulse while the microphone is open.
    private func animate() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        core.colors = [tint.blended(withFraction: 0.45, of: .white)?.cgColor ?? tint.cgColor, tint.cgColor]
        halo.backgroundColor = tint.withAlphaComponent(0.28).cgColor
        CATransaction.commit()
        core.removeAllAnimations()
        halo.removeAllAnimations()
        guard !Motion.reduced, look.state != .failed else { return }
        let (period, swell, reach): (Double, Double, Double)
        switch look.state {
        case .listening: (period, swell, reach) = (0.55, 1.08, 1.55)
        case .speaking: (period, swell, reach) = (0.9, 1.14, 1.4)
        default: (period, swell, reach) = (2.4, 1.04, 1.18)
        }
        core.add(Self.pulse("transform.scale", to: swell, period: period), forKey: "swell")
        halo.add(Self.pulse("transform.scale", to: reach, period: period), forKey: "reach")
        halo.add(Self.pulse("opacity", to: 0.15, period: period), forKey: "fade")
    }

    private static func pulse(_ key: String, to: Double, period: Double) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: key)
        a.fromValue = 1
        a.toValue = to
        a.duration = period
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return a
    }

    override func draw(_ r: NSRect) {
        t.panel.setFill()
        bounds.fill()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
        t.hair.setStroke()
        border.stroke()
        let x: CGFloat = 22 + Self.orbSize + 18
        let width = bounds.width - x - 36
        let small = Fonts.mono(Metrics.fontSize - 2)
        Text.draw(look.caption.uppercased(), in: NSRect(x: x, y: 12, width: width, height: 16), color: look.state == .failed ? t.on : t.fg3, font: small)
        // Two lines of words; the end of a long sentence is what was said last, so that end is kept.
        let font = Fonts.mono(Metrics.fontSize)
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byWordWrapping
        let words = NSAttributedString(string: Self.tail(look.words, fitting: width, lines: 2, font: font),
                                       attributes: [.font: font, .foregroundColor: t.fg, .paragraphStyle: p])
        words.draw(with: NSRect(x: x, y: 32, width: width, height: 40), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// The last words that fit in `lines` lines, with an ellipsis in front when some were dropped.
    static func tail(_ s: String, fitting width: CGFloat, lines: Int, font: NSFont) -> String {
        let room = Int(width / max(1, Text.width("m", font: font))) * lines - 2
        guard s.count > room, room > 8 else { return s }
        let cut = s.suffix(room)
        return "…" + (cut.firstIndex(of: " ").map { String(cut[cut.index(after: $0)...]) } ?? String(cut))
    }
}
