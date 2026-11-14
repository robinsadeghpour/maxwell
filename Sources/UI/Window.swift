import AppKit

/// The main window. Tells the controller when keyboard focus moves between panes.
final class MXWindow: NSWindow {
    var onFocusChange: (() -> Void)?
    override func makeFirstResponder(_ r: NSResponder?) -> Bool {
        let ok = super.makeFirstResponder(r)
        onFocusChange?()
        return ok
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
