import AppKit

/// A key chord like "cmd+shift+x". Parsed from the config's `keybind` lines.
struct Shortcut: Equatable {
    var key: String               // lowercase character, or "backspace", "up", ...
    var mods: NSEvent.ModifierFlags

    init?(_ spec: String) {
        var mods: NSEvent.ModifierFlags = []
        var key: String?
        for part in spec.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "cmd", "super": mods.insert(.command)
            case "shift": mods.insert(.shift)
            case "ctrl", "control": mods.insert(.control)
            case "alt", "opt", "option": mods.insert(.option)
            default: key = part
            }
        }
        guard let key else { return nil }
        self.key = key
        self.mods = mods
    }

    /// The menu key equivalent for this key.
    var keyEquivalent: String {
        switch key {
        case "backspace": return "\u{8}"
        case "up": return String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case "down": return String(UnicodeScalar(NSDownArrowFunctionKey)!)
        case "enter", "return": return "\r"
        case "plus": return "+"
        default: return key
        }
    }

    var display: String {
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        switch key {
        case "backspace": s += "⌫"
        case "up": s += "↑"
        case "down": s += "↓"
        case "enter", "return": s += "⏎"
        default: s += key.uppercased()
        }
        return s
    }

    func matches(_ e: NSEvent) -> Bool {
        let m = e.modifierFlags.intersection([.command, .shift, .control, .option])
        guard m == mods else { return false }
        let k = (e.charactersIgnoringModifiers ?? "").lowercased()
        if key == "backspace" { return e.keyCode == 51 }
        return k == keyEquivalent.lowercased() || (key == "=" && k == "+")
    }
}

/// Every user action: one registry feeds the menu bar, the ⌘K palette, keybinds and buttons.
struct Action {
    let id: String
    let title: String
    let menu: String
    var shortcut: Shortcut?
    var isEnabled: () -> Bool = { true }
    /// A setting the item turns on and off; the menu shows a check mark while it's on.
    var isChecked: (() -> Bool)? = nil
    let run: () -> Void
}

final class ActionMenuItem: NSMenuItem, NSMenuItemValidation {
    // The item is its own target, so AppKit asks it whether it is enabled and checked.
    func validateMenuItem(_ item: NSMenuItem) -> Bool { MenuValidator.shared.validateMenuItem(item) }
    var handler: (() -> Void)?
    var enabledCheck: (() -> Bool)?
    var checked: (() -> Bool)?
    @objc func fire() { handler?() }
}

final class MenuValidator: NSObject, NSMenuItemValidation {
    static let shared = MenuValidator()
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let a = item as? ActionMenuItem else { return true }
        if let c = a.checked { a.state = c() ? .on : .off }
        return a.enabledCheck?() ?? true
    }
}

enum MenuBuilder {
    static func build(_ actions: [Action]) -> NSMenu {
        let main = NSMenu()
        let app = NSMenu(title: "Maxwell")
        app.addItem(withTitle: "About Maxwell", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        for a in actions where a.menu == "Maxwell" { app.addItem(item(a)) }
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Maxwell", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit Maxwell", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(app, to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(edit, to: main)

        for title in ["Session", "Projects", "View", "Panels"] {
            let m = NSMenu(title: title)
            for a in actions where a.menu == title { m.addItem(item(a)) }
            add(m, to: main)
        }
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        add(window, to: main)
        NSApp.windowsMenu = window
        return main
    }

    private static func add(_ m: NSMenu, to main: NSMenu) {
        let i = NSMenuItem(title: m.title, action: nil, keyEquivalent: "")
        i.submenu = m
        main.addItem(i)
    }

    private static func item(_ a: Action) -> NSMenuItem {
        let i = ActionMenuItem(title: a.title, action: #selector(ActionMenuItem.fire), keyEquivalent: a.shortcut?.keyEquivalent ?? "")
        i.keyEquivalentModifierMask = a.shortcut?.mods ?? []
        i.handler = a.run
        i.enabledCheck = a.isEnabled
        i.checked = a.isChecked
        i.target = i
        return i
    }
}
