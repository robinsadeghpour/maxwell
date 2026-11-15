// Minimal libghostty embed. Modelled on ghostty/macos/Sources/Ghostty (MIT),
// cut down to: one app, many surfaces, keys, text, mouse, scroll, clipboard,
// and the OPEN_URL / PWD actions so terminal paths open in the session's viewer.
import AppKit
import GhosttyKit
import UniformTypeIdentifiers

final class GhosttyRuntime {
    static let shared = GhosttyRuntime()
    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?

    func start(configText: String) {
        if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
            fatalError("ghostty_init failed")
        }
        let cfg = makeConfig(configText)
        var rt = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { _ in
                DispatchQueue.main.async { if let a = GhosttyRuntime.shared.app { ghostty_app_tick(a) } }
            },
            action_cb: { _, target, action in GhosttyRuntime.shared.handle(target: target, action: action) },
            read_clipboard_cb: { ud, _, state, mimes, n, list in readClipboard(ud, state, mimes, n, list) },
            confirm_read_clipboard_cb: { _, _, _, _ in },
            write_clipboard_cb: { _, _, contents, n, _ in
                for i in 0..<n {
                    let c = contents[i]
                    let data = c.data; guard String(cString: c.mime).hasPrefix("text/plain") else { continue }
                    let s = String(decoding: UnsafeRawBufferPointer(start: data, count: c.len), as: UTF8.self)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(s, forType: .string)
                    return
                }
            },
            close_surface_cb: { ud, _ in
                guard let ud else { return }
                let view = Unmanaged<TerminalView>.fromOpaque(ud).takeUnretainedValue()
                DispatchQueue.main.async { view.onExit?() }
            })
        app = ghostty_app_new(&rt, cfg)
        if app == nil { fatalError("ghostty_app_new failed") }
        config = cfg
    }

    /// Our look comes from a config we write, not the user's Ghostty config.
    private func makeConfig(_ text: String) -> ghostty_config_t {
        let cfg = ghostty_config_new()!
        let path = NSTemporaryDirectory() + "maxwell-ghostty-\(getpid()).conf"
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        ghostty_config_load_file(cfg, path)
        ghostty_config_finalize(cfg)
        for i in 0..<ghostty_config_diagnostics_count(cfg) {
            NSLog("ghostty config: %@", String(cString: ghostty_config_get_diagnostic(cfg, i).message))
        }
        try? FileManager.default.removeItem(atPath: path)
        return cfg
    }

    /// Live theme and font changes: every surface picks up the new config.
    func update(configText: String, surfaces: [TerminalView]) {
        guard let app else { return }
        let cfg = makeConfig(configText)
        ghostty_app_update_config(app, cfg)
        for v in surfaces { if let s = v.surface { ghostty_surface_update_config(s, cfg) } }
        if let old = config { ghostty_config_free(old) }
        config = cfg
    }

    private func view(_ target: ghostty_target_s) -> TerminalView? {
        guard target.tag == GHOSTTY_TARGET_SURFACE, let s = target.target.surface, let ud = ghostty_surface_userdata(s) else { return nil }
        return Unmanaged<TerminalView>.fromOpaque(ud).takeUnretainedValue()
    }

    private func handle(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_OPEN_URL:
            let u = action.action.open_url
            let s = String(decoding: UnsafeRawBufferPointer(start: u.url, count: Int(u.len)), as: UTF8.self)
            guard let v = view(target) else { return false }
            DispatchQueue.main.async { v.onOpenURL?(s, v.cwd) }
            return true
        case GHOSTTY_ACTION_PWD:
            let pwd = String(cString: action.action.pwd.pwd)
            guard let v = view(target) else { return true }
            v.cwd = pwd
            DispatchQueue.main.async { v.onCwd?() }
            return true
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            // `claude attach` ended (detached, or the session stopped): the pane shows Reattach.
            guard let v = view(target) else { return false }
            DispatchQueue.main.async { v.onExit?() }
            return true
        case GHOSTTY_ACTION_MOUSE_SHAPE, GHOSTTY_ACTION_MOUSE_OVER_LINK, GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_RING_BELL:
            return true
        default:
            return false
        }
    }
}

/// Answers Ghostty's clipboard reads the way Ghostty.app does: every requested MIME type the
/// pasteboard can serve (images too, which Claude Code asks for on ⌘V), copied files as escaped
/// paths, and the list of available types when `list` asks for it.
private func readClipboard(_ ud: UnsafeMutableRawPointer?, _ state: UnsafeMutableRawPointer,
                           _ mimes: UnsafePointer<UnsafePointer<CChar>>, _ n: Int, _ list: Bool) -> ghostty_clipboard_read_result_e {
    guard let ud else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
    let view = Unmanaged<TerminalView>.fromOpaque(ud).takeUnretainedValue()
    guard let s = view.surface else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
    let pb = NSPasteboard.general
    var contents: [(mime: String, data: Data)] = []
    for i in 0..<n {
        let mime = String(cString: mimes[i])
        guard !contents.contains(where: { $0.mime == mime }), let data = pb.terminalData(forMime: mime) else { continue }
        contents.append((mime, data))
    }
    let available = list ? pb.terminalMimes() : []
    if contents.isEmpty && !list { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }

    // Everything handed to Ghostty lives in C memory for the duration of the call.
    var owned: [UnsafeMutableRawPointer] = []
    defer { owned.forEach { free($0) } }
    func cString(_ str: String) -> UnsafePointer<CChar> { let p = strdup(str)!; owned.append(p); return UnsafePointer(p) }
    let cContents = contents.map { c -> ghostty_clipboard_content_s in
        let buf = malloc(max(c.data.count, 1))!
        owned.append(buf)
        c.data.withUnsafeBytes { if let b = $0.baseAddress { buf.copyMemory(from: b, byteCount: $0.count) } }
        return ghostty_clipboard_content_s(mime: cString(c.mime), data: buf.assumingMemoryBound(to: CChar.self), len: c.data.count)
    }
    let cAvailable = available.map { Optional(cString($0)) }
    cContents.withUnsafeBufferPointer { cp in
        cAvailable.withUnsafeBufferPointer { ap in
            var done = ghostty_clipboard_complete_s()
            done.contents = cp.baseAddress
            done.contents_len = cp.count
            done.available = ap.isEmpty ? nil : UnsafePointer(OpaquePointer(ap.baseAddress))
            done.available_len = ap.count
            done.confirmed = true
            ghostty_surface_complete_clipboard_request(s, &done, state)
        }
    }
    return GHOSTTY_CLIPBOARD_READ_STARTED
}

extension NSPasteboard {
    /// Pasted or dropped content as terminal text: copied files become escaped absolute paths
    /// (Claude Code attaches image paths as images), anything else its plain string.
    var terminalText: String? {
        let parts = (pasteboardItems ?? []).compactMap { item -> String? in
            if let plist = item.propertyList(forType: .fileURL),
               let url = NSURL(pasteboardPropertyList: plist, ofType: .fileURL) as URL?, url.isFileURL {
                return Self.shellEscape(url.path)
            }
            return item.string(forType: .string)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private var fileURLs: [URL] {
        (pasteboardItems ?? []).compactMap { item in
            guard let plist = item.propertyList(forType: .fileURL),
                  let url = NSURL(pasteboardPropertyList: plist, ofType: .fileURL) as URL?, url.isFileURL else { return nil }
            return url
        }
    }

    /// An image (a screenshot, a copied picture) with no text or files to paste instead.
    var holdsOnlyImage: Bool {
        terminalText == nil && (types ?? []).contains { UTType($0.rawValue)?.conforms(to: .image) == true }
    }

    func terminalData(forMime mime: String) -> Data? {
        if mime == "text/plain" || mime.hasPrefix("text/plain;") { return terminalText.map { Data($0.utf8) } }
        if mime == "text/uri-list" {
            let urls = fileURLs
            return urls.isEmpty ? nil : Data(urls.map { $0.absoluteString + "\r\n" }.joined().utf8)
        }
        let type = UTType(mimeType: mime).map { PasteboardType($0.identifier) } ?? PasteboardType(mime)
        return data(forType: type)
    }

    /// Declared types only, never the data: the listing must stay cheap.
    func terminalMimes() -> [String] {
        let declared = types ?? []
        func mime(_ t: PasteboardType) -> String? {
            guard let m = UTType(t.rawValue)?.preferredMIMEType else { return nil }
            return m == "text/plain;charset=utf-8" ? "text/plain" : m
        }
        var result: [String] = []
        let hasFiles = declared.contains(.fileURL)
        if hasFiles || declared.contains(where: { mime($0) == "text/plain" }) { result.append("text/plain") }
        if hasFiles { result.append("text/uri-list") }
        for t in declared { if let m = mime(t), !result.contains(m) { result.append(m) } }
        return result
    }

    static func shellEscape(_ s: String) -> String {
        var out = ""
        for ch in s { if "\\ ()[]{}<>\"'`!#$&;|*?\t".contains(ch) { out.append("\\") }; out.append(ch) }
        return out
    }
}

final class TerminalView: NSView, NSTextInputClient {
    private(set) var surface: ghostty_surface_t?
    private var keyText: [String]? = nil
    private var tracking: NSTrackingArea?
    /// Pasteboard change count at the last click, to tell whether the drag since then copied.
    private var clipboardAtClick = NSPasteboard.general.changeCount
    var cwd: String?
    var onOpenURL: ((String, String?) -> Void)?
    var onExit: (() -> Void)?
    /// The shell reported a new working folder.
    var onCwd: (() -> Void)?
    /// App shortcuts win over Ghostty's own bindings (cmd+k, cmd+n ...).
    static var isAppShortcut: ((NSEvent) -> Bool)?

    /// `command` runs directly (no shell); `env` is added to Maxwell's own environment.
    init(frame: NSRect, workingDirectory: String, command: String? = nil, env: [String: String] = [:]) {
        super.init(frame: frame)
        wantsLayer = true
        cwd = workingDirectory
        var sc = ghostty_surface_config_new()
        sc.platform_tag = GHOSTTY_PLATFORM_MACOS
        sc.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        sc.userdata = Unmanaged.passUnretained(self).toOpaque()
        sc.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        sc.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        // C strings must outlive ghostty_surface_new; strdup them and free after.
        var owned: [UnsafeMutablePointer<CChar>] = []
        func c(_ s: String) -> UnsafeMutablePointer<CChar> { let p = strdup(s)!; owned.append(p); return p }
        var vars = env.map { ghostty_env_var_s(key: c($0.key), value: c($0.value)) }
        sc.working_directory = UnsafePointer(c(workingDirectory))
        if let command { sc.command = UnsafePointer(c(command)) }
        surface = vars.withUnsafeMutableBufferPointer { buf in
            sc.env_vars = buf.baseAddress
            sc.env_var_count = buf.count
            return ghostty_surface_new(GhosttyRuntime.shared.app!, &sc)
        }
        owned.forEach { free($0) }
        if surface == nil { NSLog("ghostty_surface_new failed") }
        registerForDraggedTypes([.fileURL, .string])
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { if let surface { ghostty_surface_free(surface) } }

    /// Hidden surfaces stop rendering but keep their process and scrollback.
    func setVisible(_ visible: Bool) {
        if let surface { ghostty_surface_set_occlusion(surface, visible) }
    }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        if let surface { ghostty_surface_set_focus(surface, true) }
        return true
    }
    override func resignFirstResponder() -> Bool {
        if let surface { ghostty_surface_set_focus(surface, false) }
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateScale()
        sendSize()
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        sendSize()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale()
        sendSize()
    }
    private func updateScale() {
        guard let surface, let window else { return }
        layer?.contentsScale = window.backingScaleFactor
        ghostty_surface_set_content_scale(surface, window.backingScaleFactor, window.backingScaleFactor)
    }
    private func sendSize() {
        guard let surface else { return }
        let px = convertToBacking(bounds.size)
        guard px.width > 0, px.height > 0 else { return }
        ghostty_surface_set_size(surface, UInt32(px.width), UInt32(px.height))
    }

    // MARK: keyboard
    /// Claude Code turns on mouse reporting, and then Ghostty only looks for links under the
    /// pointer while shift is held. ⌘ adds shift, so ⌘-click opens a path in the viewer.
    static func mouseMods(_ f: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        mods(f.contains(.command) ? f.union(.shift) : f)
    }

    static func mods(_ f: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var m = GHOSTTY_MODS_NONE.rawValue
        if f.contains(.shift) { m |= GHOSTTY_MODS_SHIFT.rawValue }
        if f.contains(.control) { m |= GHOSTTY_MODS_CTRL.rawValue }
        if f.contains(.option) { m |= GHOSTTY_MODS_ALT.rawValue }
        if f.contains(.command) { m |= GHOSTTY_MODS_SUPER.rawValue }
        if f.contains(.capsLock) { m |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(m)
    }

    private func keyEvent(_ action: ghostty_input_action_e, _ e: NSEvent) -> ghostty_input_key_s {
        var k = ghostty_input_key_s()
        k.action = action
        k.keycode = UInt32(e.keyCode)
        k.mods = Self.mods(e.modifierFlags)
        k.consumed_mods = Self.mods(e.modifierFlags.subtracting([.control, .command]))
        if e.type == .keyDown || e.type == .keyUp,
           let c = e.characters(byApplyingModifiers: [])?.unicodeScalars.first {
            k.unshifted_codepoint = c.value
        }
        return k
    }

    private func send(_ k: ghostty_input_key_s, text: String?) {
        guard let surface else { return }
        var k = k
        if let text, !text.isEmpty, let first = text.unicodeScalars.first,
           first.value >= 0x20, first.value != 0x7F, !(0xF700...0xF8FF).contains(first.value) {
            text.withCString { p in k.text = p; _ = ghostty_surface_key(surface, k) }
        } else {
            _ = ghostty_surface_key(surface, k)
        }
    }

    /// Claude Code reads images off the clipboard itself, but only on Ctrl+V: a terminal's ⌘V has
    /// no text to paste for an image, so it sends nothing. With only an image on the clipboard,
    /// ⌘V presses Ctrl+V instead.
    private static func imagePasteAsCtrlV(_ e: NSEvent) -> [NSEvent]? {
        guard e.modifierFlags.intersection([.command, .shift, .control, .option]) == .command,
              e.charactersIgnoringModifiers?.lowercased() == "v", NSPasteboard.general.holdsOnlyImage else { return nil }
        return [NSEvent.EventType.keyDown, .keyUp].compactMap {
            NSEvent.keyEvent(with: $0, location: .zero, modifierFlags: .control, timestamp: e.timestamp,
                             windowNumber: e.windowNumber, context: nil, characters: "\u{16}",
                             charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)
        }
    }

    override func keyDown(with e: NSEvent) {
        if let ctrlV = Self.imagePasteAsCtrlV(e) {
            for c in ctrlV { c.type == .keyDown ? keyDown(with: c) : keyUp(with: c) }
            return
        }
        let action = e.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        // Let AppKit's text system turn the key into text (dead keys, option chars).
        keyText = []
        interpretKeyEvents([e])
        let texts = keyText ?? []
        keyText = nil
        if texts.isEmpty {
            // Control chars and special keys: Ghostty encodes them itself.
            var text = e.characters
            if e.modifierFlags.contains(.control) { text = e.characters(byApplyingModifiers: e.modifierFlags.subtracting(.control)) }
            send(keyEvent(action, e), text: text)
        } else {
            for t in texts { send(keyEvent(action, e), text: t) }
        }
    }
    override func keyUp(with e: NSEvent) { send(keyEvent(GHOSTTY_ACTION_RELEASE, e), text: nil) }
    override func flagsChanged(with e: NSEvent) {
        // Good enough for the spike: report modifier as press/release by current state.
        let pressed = e.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue != 0
        send(keyEvent(pressed ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE, e), text: nil)
    }
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard window?.firstResponder === self, let surface else { return false }
        if Self.isAppShortcut?(e) == true { return false }
        // Claude Code draws its own mouse selection and copies it on release. ⌘C would reach it
        // as a key and clear that highlight, so once the drag has copied, ⌘C stops here.
        if e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           e.charactersIgnoringModifiers == "c", !ghostty_surface_has_selection(surface),
           NSPasteboard.general.changeCount != clipboardAtClick { return true }
        // Let Ghostty handle its own bindings (cmd+c, cmd+v, cmd+k ...); the app menu gets the rest.
        var k = keyEvent(GHOSTTY_ACTION_PRESS, e)
        var flags = ghostty_binding_flags_e(0)
        let isBinding = (e.characters ?? "").withCString { p -> Bool in
            k.text = p
            return ghostty_surface_key_is_binding(surface, k, &flags)
        }
        if isBinding { keyDown(with: e); return true }
        return false
    }

    // NSTextInputClient (no IME preedit support in the spike)
    func insertText(_ string: Any, replacementRange: NSRange) {
        let s = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        if keyText != nil { keyText!.append(s) } else if let surface { ghostty_surface_text(surface, s, UInt(s.utf8.count)) }
    }
    override func doCommand(by selector: Selector) {}
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {}
    func unmarkText() {}
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { false }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        window?.convertToScreen(convert(bounds, to: nil)) ?? .zero
    }
    func characterIndex(for point: NSPoint) -> Int { 0 }

    // MARK: drag and drop
    /// Dropped files paste as escaped paths, like Ghostty.app; Claude Code attaches images by path.
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.terminalText == nil ? [] : .copy
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let surface, let text = sender.draggingPasteboard.terminalText, !text.isEmpty else { return false }
        text.withCString { ghostty_surface_paste_text(surface, $0, UInt(strlen($0))) }
        window?.makeFirstResponder(self)
        return true
    }

    // MARK: mouse
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .inVisibleRect, .activeAlways], owner: self)
        addTrackingArea(tracking!)
        super.updateTrackingAreas()
    }
    private func pos(_ e: NSEvent) {
        guard let surface else { return }
        let p = convert(e.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, p.x, bounds.height - p.y, Self.mouseMods(e.modifierFlags))
    }
    override func mouseMoved(with e: NSEvent) { pos(e) }
    override func mouseDragged(with e: NSEvent) { pos(e) }
    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        clipboardAtClick = NSPasteboard.general.changeCount
        pos(e)
        if let surface { _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, Self.mouseMods(e.modifierFlags)) }
    }
    override func mouseUp(with e: NSEvent) {
        if let surface { _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, Self.mouseMods(e.modifierFlags)) }
    }
    override func scrollWheel(with e: NSEvent) {
        guard let surface else { return }
        var x = e.scrollingDeltaX, y = e.scrollingDeltaY
        var mods: Int32 = 0
        if e.hasPreciseScrollingDeltas { x *= 2; y *= 2; mods |= 1 }
        let momentum: Int32
        switch e.momentumPhase {
        case .began: momentum = 1
        case .stationary: momentum = 2
        case .changed: momentum = 3
        case .ended: momentum = 4
        case .cancelled: momentum = 5
        case .mayBegin: momentum = 6
        default: momentum = 0
        }
        mods |= momentum << 1
        ghostty_surface_mouse_scroll(surface, x, y, mods)
    }

    func viewportText() -> String {
        guard let surface else { return "" }
        var text = ghostty_text_s()
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(surface, sel, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(cString: text.text)
    }

    /// Test hook: Cmd+click the first on-screen occurrence of `needle` (as a user would).
    func cmdClick(on needle: String) -> Bool {
        guard let surface, let scale = window?.backingScaleFactor else { return false }
        let sz = ghostty_surface_size(surface)
        let cols = Int(sz.columns)
        // viewportText joins soft-wrapped rows, so map logical lines back to grid rows.
        var rowOf: [Int] = [], r0 = 0
        let lines = viewportText().components(separatedBy: "\n")
        for l in lines { rowOf.append(r0); r0 += max(1, (l.count + cols - 1) / cols) }
        guard let li = lines.lastIndex(where: { $0.contains(needle) }),
              let r = lines[li].range(of: needle) else { return false }
        let off = lines[li].distance(from: lines[li].startIndex, to: r.lowerBound) + 1
        let row = rowOf[li] + off / cols, col = off % cols
        let cw = Double(sz.cell_width_px) / scale, ch = Double(sz.cell_height_px) / scale
        let padX = (Double(sz.width_px) / scale - Double(sz.columns) * cw) / 2
        let padY = (Double(sz.height_px) / scale - Double(sz.rows) * ch) / 2
        let x = padX + (Double(col) + 0.5) * cw, y = padY + (Double(row) + 0.5) * ch
        let m = Self.mouseMods(.command)
        ghostty_surface_mouse_pos(surface, x, y, m)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, m)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, m)
        return true
    }

    /// Sends Ctrl+<letter> as a real key event (test hook: Ctrl+Z detaches `claude attach`).
    func sendControl(_ letter: Character, keyCode: UInt16) {
        guard let surface else { return }
        var k = ghostty_input_key_s()
        k.action = GHOSTTY_ACTION_PRESS
        k.keycode = UInt32(keyCode)
        k.mods = GHOSTTY_MODS_CTRL
        k.consumed_mods = GHOSTTY_MODS_NONE
        k.unshifted_codepoint = letter.unicodeScalars.first!.value
        _ = ghostty_surface_key(surface, k)
        k.action = GHOSTTY_ACTION_RELEASE
        _ = ghostty_surface_key(surface, k)
    }

    /// Presses Down through keyDown, the path a real press takes: a bare ghostty key with no
    /// characters never reaches the program.
    func pressDown() {
        let down = "\u{F701}"
        for (t, handle) in [(NSEvent.EventType.keyDown, keyDown(with:)), (.keyUp, keyUp(with:))] {
            guard let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: .numericPad, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window?.windowNumber ?? 0, context: nil, characters: down,
                                           charactersIgnoringModifiers: down, isARepeat: false, keyCode: 125) else { continue }
            handle(e)
        }
    }

    /// Types a line and presses Return (Return as a real key, so the shell runs it).
    func sendLine(_ s: String) {
        guard let surface else { return }
        ghostty_surface_text(surface, s, UInt(s.utf8.count))
        var k = ghostty_input_key_s()
        k.action = GHOSTTY_ACTION_PRESS
        k.keycode = 36 // kVK_Return
        k.mods = GHOSTTY_MODS_NONE
        k.consumed_mods = GHOSTTY_MODS_NONE
        k.unshifted_codepoint = 13
        "\r".withCString { p in k.text = p; _ = ghostty_surface_key(surface, k) }
        k.action = GHOSTTY_ACTION_RELEASE
        k.text = nil
        _ = ghostty_surface_key(surface, k)
    }
}
