import AppKit

/// Maxwell's windows. Tells the controller when keyboard focus moves between panes.
final class MXWindow: NSWindow {
    var onFocusChange: (() -> Void)?
    /// Sees each press and release before any view; returns true when it took it (`TitleBar.guardClick`).
    var onClick: ((NSEvent) -> Bool)?
    override func sendEvent(_ e: NSEvent) {
        if e.type == .leftMouseDown || e.type == .leftMouseUp, onClick?(e) == true { return }
        super.sendEvent(e)
    }
    override func makeFirstResponder(_ r: NSResponder?) -> Bool {
        let ok = super.makeFirstResponder(r)
        onFocusChange?()
        return ok
    }
    /// AppKit pulls a titled window back onto a screen; a quiet run's window stays parked.
    override func constrainFrameRect(_ r: NSRect, to s: NSScreen?) -> NSRect {
        quietTest ? r : super.constrainFrameRect(r, to: s)
    }

    /// Shows the window. In a quiet run it goes past the right edge of every screen instead:
    /// ordered in, so it draws and `--snap` can capture it, but never on the user's screens
    /// and never key.
    func present() {
        guard quietTest else { return makeKeyAndOrderFront(nil) }
        let right = NSScreen.screens.map(\.frame.maxX).max() ?? 0
        setFrameOrigin(NSPoint(x: right + 2000, y: 0))
        orderBack(nil)
    }

    /// macOS doesn't clip a see-through window's content to the window's rounded corners, and the
    /// rim it draws then stair-steps around the content's square ones. The views that fill such a
    /// window clip themselves to its radius: 20 pt on macOS 26 for a window with a toolbar, 10 pt
    /// before, square in full screen.
    static func clipCorners(_ views: [NSView], fullScreen: Bool) {
        let radius: CGFloat
        if fullScreen { radius = 0 } else if #available(macOS 26, *) { radius = 20 } else { radius = 10 }
        for v in views {
            v.wantsLayer = true
            v.layer?.cornerRadius = radius
            v.layer?.cornerCurve = .continuous
            v.layer?.masksToBounds = true
        }
    }
}

/// Window frames per screen. Opens on the screen with the mouse when the last screen is gone
/// or on first launch, so Maxwell never appears on a monitor you are not looking at.
enum WindowPlacement {
    private static let lastKey = "Maxwell.frame.last"

    static func key(_ screen: NSScreen) -> String {
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0
        return "Maxwell.frame.\(screen.localizedName).\(id)"
    }

    static func save(_ w: NSWindow) {
        guard let s = w.screen else { return }
        UserDefaults.standard.set(NSStringFromRect(w.frame), forKey: key(s))
        UserDefaults.standard.set(key(s), forKey: lastKey)
    }

    static func restore(_ w: NSWindow) {
        let d = UserDefaults.standard
        let screens = NSScreen.screens
        let last = d.string(forKey: lastKey).flatMap { k in screens.first { key($0) == k } }
        let mouse = screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? screens.first
        guard let screen = last ?? mouse else { return w.center() }
        if let saved = d.string(forKey: key(screen)).map(NSRectFromString), screen.visibleFrame.intersects(saved) {
            w.setFrame(saved, display: false)
        } else {
            let v = screen.visibleFrame
            let size = NSSize(width: min(1440, v.width - 40), height: min(900, v.height - 40))
            w.setFrame(NSRect(x: v.midX - size.width / 2, y: v.midY - size.height / 2, width: size.width, height: size.height), display: false)
        }
    }
}
