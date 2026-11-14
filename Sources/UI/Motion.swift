import AppKit

/// One timing for every slide and fade: short, ease-out, and a plain cut under Reduce Motion.
enum Motion {
    /// MAXWELL_SLOW_MOTION=10 stretches every animation, to capture and check one frame by frame.
    static let duration: TimeInterval = 0.16 * (Double(ProcessInfo.processInfo.environment["MAXWELL_SLOW_MOTION"] ?? "") ?? 1)
    /// `motion = off` in the config; Reduce Motion turns it off too.
    static var off = false
    static var reduced: Bool { off || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static func easeOut(_ p: Double) -> Double { 1 - pow(1 - p, 3) }

    /// Fades a freshly added overlay in from 6 pt above, or does nothing under Reduce Motion.
    static func appear(_ v: NSView) {
        guard !reduced, let layer = v.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1
        let slide = CABasicAnimation(keyPath: "transform.translation.y")
        slide.fromValue = v.isFlipped ? -6 : 6; slide.toValue = 0
        let g = CAAnimationGroup()
        g.animations = [fade, slide]
        g.duration = 0.14
        g.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(g, forKey: "appear")
    }
}

/// Drives a value from where it is to `target` over `Motion.duration`, calling `step` each frame.
/// Retargeting mid-flight starts from the current value, so nothing jumps.
final class Tween {
    private(set) var value: CGFloat
    private(set) var target: CGFloat
    private var from: CGFloat = 0
    private var start = Date()
    private var timer: Timer?
    var duration = Motion.duration
    var step: ((CGFloat) -> Void)?
    var done: (() -> Void)?

    init(_ v: CGFloat) { value = v; target = v }

    var isRunning: Bool { timer != nil }

    func set(_ t: CGFloat, animated: Bool = true) {
        guard t != target || timer != nil && !animated else { return }
        target = t
        timer?.invalidate(); timer = nil
        if !animated || Motion.reduced {
            value = t; step?(t); done?(); return
        }
        from = value; start = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 120, repeats: true) { [weak self] tm in
            guard let self else { return tm.invalidate() }
            let p = min(1, Date().timeIntervalSince(self.start) / self.duration)
            self.value = self.from + (self.target - self.from) * CGFloat(Motion.easeOut(p))
            self.step?(self.value)
            if p >= 1 { tm.invalidate(); self.timer = nil; self.done?() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
}

/// Overlay scroller drawn from the theme: a square-ended knob, 5 pt wide at rest, 8 pt while hovered.
final class ThinScroller: NSScroller {
    private var hot = false
    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat { 12 }
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { hot = true; needsDisplay = true }
    override func mouseExited(with e: NSEvent) { hot = false; needsDisplay = true }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        guard hot else { return }
        Look.theme.hair2.setFill()
        NSRect(x: bounds.maxX - 10, y: 0, width: 9, height: bounds.height).fill()
    }

    override func drawKnob() {
        let k = rect(for: .knob)
        let w: CGFloat = hot ? 8 : 5
        let r = NSRect(x: bounds.maxX - w - 2, y: k.minY + 2, width: w, height: max(0, k.height - 4))
        (hot ? Look.theme.fg3 : Look.theme.fg3.withAlphaComponent(0.6)).setFill()
        NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5).fill()
    }
}

extension NSScrollView {
    /// Every scroll view in Maxwell: overlay, themed, no background.
    func useThinScroller() {
        drawsBackground = false
        contentView.drawsBackground = false
        hasVerticalScroller = true
        scrollerStyle = .overlay
        autohidesScrollers = true
        verticalScroller = ThinScroller()
    }
}

/// The window's own background blur (what Ghostty's `background-blur` uses), radius in points.
enum WindowBlur {
    private typealias Connection = UInt32
    @_silgen_name("CGSDefaultConnectionForThread") private static func defaultConnection() -> Connection
    @_silgen_name("CGSSetWindowBackgroundBlurRadius") private static func setRadius(_ c: Connection, _ window: Int, _ radius: Int) -> Int32

    static func set(_ w: NSWindow, radius: Int) {
        _ = setRadius(defaultConnection(), w.windowNumber, max(0, radius))
    }
}

/// Whether macOS is in dark mode, and a callback when that changes.
enum SystemAppearance {
    static var isDark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}
