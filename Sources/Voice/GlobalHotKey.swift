import AppKit
import Carbon.HIToolbox

/// A shortcut that works while another app is in front: voice mode has to be reachable from the
/// editor or the browser, where the session's question finds you. Needs no Accessibility permission.
final class GlobalHotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?
    private var registered: Shortcut?
    /// Tells this shortcut from Maxwell's other global ones.
    private let id: UInt32
    init(id: UInt32) { self.id = id }

    /// Layout-independent key codes for the keys a shortcut can name.
    static let keyCodes: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G,
        "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N,
        "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U,
        "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6,
        "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9, "space": kVK_Space, "enter": kVK_Return, "return": kVK_Return,
    ]

    /// Registers `shortcut` (nil: none). Returns false when macOS refuses it, usually because another app has it.
    @discardableResult
    func set(_ shortcut: Shortcut?, action: @escaping () -> Void) -> Bool {
        self.action = action
        if shortcut == registered, ref != nil || shortcut == nil { return true }
        clear()
        guard let shortcut else { return true }
        // A global shortcut without a modifier would take the key from every app.
        guard let code = Self.keyCodes[shortcut.key], !shortcut.mods.isEmpty else { return false }
        installHandler()
        var mods: UInt32 = 0
        if shortcut.mods.contains(.command) { mods |= UInt32(cmdKey) }
        if shortcut.mods.contains(.option) { mods |= UInt32(optionKey) }
        if shortcut.mods.contains(.control) { mods |= UInt32(controlKey) }
        if shortcut.mods.contains(.shift) { mods |= UInt32(shiftKey) }
        let hotKey = EventHotKeyID(signature: OSType(0x4D58_5643), id: id)   // "MXVC"
        let status = RegisterEventHotKey(UInt32(code), mods, hotKey, GetApplicationEventTarget(), 0, &ref)
        registered = status == noErr ? shortcut : nil
        if status != noErr { mark("voice: macOS refused the shortcut \(shortcut.display) (\(status))") }
        return status == noErr
    }

    func clear() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        registered = nil
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, me in
            guard let me else { return noErr }
            let key = Unmanaged<GlobalHotKey>.fromOpaque(me).takeUnretainedValue()
            DispatchQueue.main.async { key.action?() }
            return noErr
        }, 1, &spec, me, &handler)
    }

    deinit {
        clear()
        if let handler { RemoveEventHandler(handler) }
    }
}
