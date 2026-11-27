import AppKit
import Carbon

/// Scripted checks of plain terminals (New Terminal), quiet runs only. Keys go in as real key
/// events through the window, the way a keyboard's do, so the text system and Ghostty's encoder
/// both see them.
/// MAXWELL_TERMINAL_STEPS="<seconds>:<step>[;…]", each step one of:
/// - `new [folder]`: a new terminal, in that folder.
/// - `type <text>`: the text as key presses on the current keyboard layout; `⏎` presses Return.
///   Dead keys (`~` and `` ` `` on German layouts) can't be typed: macOS doesn't compose them
///   from made-up events, not even in a plain text view.
/// - `key <name>[ <name>…]`: return, tab, backspace, esc, up, down, left, right, space, or a
///   letter, with cmd+, ctrl+, alt+, shift+ in front.
/// - `dump <label>`: logs `terminal harness: <label>` with the terminal's row, folder, whether it
///   has the keyboard, and the lines on screen.
/// - `click <what>`, `dblclick <what>`: a click or a double-click on `doc` (the first document tab
///   in the title bar), `session` (the first session tab), or the `folder`, `plus` or `search` button.
/// - `where <label>`: logs which part of the window has the keyboard, whether it is on screen, and
///   what fills the window.
enum TerminalHarness {
    static func start(_ main: MainWindowController) {
        guard quietTest, let spec = ProcessInfo.processInfo.environment["MAXWELL_TERMINAL_STEPS"] else { return }
        for step in spec.split(separator: ";") {
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let at = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { run(parts[1], main) }
        }
    }

    private static func run(_ step: String, _ main: MainWindowController) {
        let words = step.split(separator: " ", maxSplits: 1).map(String.init)
        let rest = words.count > 1 ? words[1] : ""
        switch words.first {
        case "new": main.openShell(in: rest.isEmpty ? nil : rest)
        case "type": for ch in rest { ch == "⏎" ? press("return", main) : type(ch, main) }
        case "key": for k in rest.split(separator: " ") { press(String(k), main) }
        case "dump": dump(rest, main)
        case "click": click(rest, times: 1, main)
        case "dblclick": click(rest, times: 2, main)
        case "where": whereKeyboard(rest, main)
        default: mark("terminal harness: unknown step \(step)")
        }
    }

    private static func dump(_ label: String, _ main: MainWindowController) {
        guard let t = main.shownShell else { return mark("terminal harness: \(label): no terminal on screen") }
        let row = main.shellRows().first { $0.id == main.current }
        let focused = main.window?.firstResponder === t
        var shown = t.viewportText().split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
        while shown.last?.isEmpty == true { shown.removeLast() }
        mark("terminal harness: \(label): row \(row?.title ?? "-") · \(row?.detail ?? "-") · \(focused ? "has" : "lost") keyboard\n" + shown.map { "  | " + $0 }.joined(separator: "\n"))
    }

    private static func whereKeyboard(_ label: String, _ main: MainWindowController) {
        let fr = main.window?.firstResponder as? NSView, root = main.root
        let parts: [(String, NSView)] = [("viewer", root.viewerPane), ("terminal", root.sessionPane), ("session list", root.sidebar)]
        let part = fr.flatMap { v in parts.first { v.isDescendant(of: $0.1) }?.0 } ?? fr.map { "\(Swift.type(of: $0))" } ?? "nowhere"
        let onScreen = fr.map { !$0.isHiddenOrHasHiddenAncestor && $0.window != nil } ?? false
        mark("terminal harness: \(label): keyboard in \(part), \(onScreen ? "on screen" : "hidden"), fill \(root.filling.map { "\($0)" } ?? "none")")
    }

    private static func click(_ what: String, times: Int, _ main: MainWindowController) {
        let root = main.root, strip = root.viewerPane.header.strip
        // Where each target is: the first document tab, the first session tab, the folder button.
        let spots: [String: (NSView, NSPoint)] = [
            "doc": (strip, NSPoint(x: 30, y: strip.bounds.midY)),
            "session": (root.titleBar, NSPoint(x: root.titleBar.fullScreen ? 60 : 150, y: root.titleBar.bounds.midY)),
            "folder": (root.viewerPane.header.treeButton, NSPoint(x: 14, y: 11)),
            "plus": (root.titleBar.plus, NSPoint(x: 13, y: 11)),
            "search": (root.titleBar.palette, NSPoint(x: 13, y: 11)),
        ]
        guard let (v, at) = spots[what], let w = main.window, v.window != nil, !v.isHiddenOrHasHiddenAncestor else {
            return mark("terminal harness: no \(what) to click")
        }
        let p = v.convert(at, to: nil)
        func event(_ type: NSEvent.EventType, _ count: Int) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1)
        }
        // Sent straight to the window: a posted event's point is moved onto a screen, and a quiet
        // run's window is past every screen's edge. The release waits in the queue for a view that
        // follows the mouse until the button comes up; one that doesn't gets it sent after.
        for count in 1...times {
            guard let down = event(.leftMouseDown, count), let up = event(.leftMouseUp, count) else { continue }
            NSApp.postEvent(up, atStart: true)
            w.sendEvent(down)
            if NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) != nil { w.sendEvent(up) }
        }
        mark("terminal harness: \(times == 2 ? "double-clicked" : "clicked") the \(what)")
    }

    private static func type(_ ch: Character, _ main: MainWindowController) {
        let s = String(ch)
        guard let k = layout[s] else { return mark("terminal harness: no key for \(s)") }
        send(chars: s, plain: unshifted[k.code] ?? s, code: k.code, mods: k.mods, main)
    }

    private static let named: [String: (String, UInt16)] = [
        "return": ("\r", 36), "tab": ("\t", 48), "backspace": ("\u{7f}", 51), "esc": ("\u{1b}", 53), "space": (" ", 49),
        "up": ("\u{F700}", 126), "down": ("\u{F701}", 125), "left": ("\u{F702}", 123), "right": ("\u{F703}", 124),
    ]

    private static func press(_ spec: String, _ main: MainWindowController) {
        var mods: NSEvent.ModifierFlags = []
        var key = spec
        for (name, flag) in [("cmd+", NSEvent.ModifierFlags.command), ("ctrl+", .control), ("alt+", .option), ("shift+", .shift)] where key.contains(name) {
            mods.insert(flag); key = key.replacingOccurrences(of: name, with: "")
        }
        if ["up", "down", "left", "right"].contains(key) { mods.insert([.numericPad, .function]) }
        let (plain, code) = named[key] ?? (key, layout[key]?.code ?? 0)
        var chars = plain
        if mods.contains(.control), let c = plain.unicodeScalars.first, ("a"..."z").contains(c), let ctrl = UnicodeScalar(c.value - 0x60) {
            chars = String(ctrl)
        }
        send(chars: chars, plain: plain, code: code, mods: mods, main)
    }

    private static func send(chars: String, plain: String, code: UInt16, mods: NSEvent.ModifierFlags, _ main: MainWindowController) {
        guard let w = main.window else { return }
        for t in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: w.windowNumber, context: nil, characters: chars,
                                           charactersIgnoringModifiers: plain, isARepeat: false, keyCode: code) else { continue }
            if t == .keyDown, mods.contains(.command), NSApp.mainMenu?.performKeyEquivalent(with: e) == true { continue }
            w.sendEvent(e)
        }
    }

    /// Characters to the key (and modifiers) that types them on the current keyboard layout.
    private static let layout: [String: (code: UInt16, mods: NSEvent.ModifierFlags)] = {
        var out: [String: (UInt16, NSEvent.ModifierFlags)] = [:]
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return out }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        let combos: [(NSEvent.ModifierFlags, Int)] = [([], 0), (.shift, shiftKey), (.option, optionKey), ([.option, .shift], optionKey | shiftKey)]
        data.withUnsafeBytes { raw in
            guard let kl = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return }
            func translate(_ code: UInt16, _ carbon: Int, _ dead: inout UInt32) -> String {
                var len = 0
                var buf = [UniChar](repeating: 0, count: 4)
                UCKeyTranslate(kl, code, UInt16(kUCKeyActionDown), UInt32(carbon >> 8) & 0xff, UInt32(LMGetKbdType()), 0, &dead, 4, &len, &buf)
                return String(utf16CodeUnits: buf, count: len)
            }
            for (mods, carbon) in combos {
                for code in UInt16(0)..<64 {
                    var dead: UInt32 = 0
                    let s = translate(code, carbon, &dead)
                    if dead == 0, !s.isEmpty, out[s] == nil { out[s] = (code, mods) }
                }
            }
        }
        return out
    }()
    private static let unshifted: [UInt16: String] = Dictionary(layout.filter { $0.value.mods.isEmpty }.map { ($0.value.code, $0.key) }, uniquingKeysWith: { a, _ in a })
}
