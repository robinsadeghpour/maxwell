import AppKit

/// Where a request sends the keyboard: the session's terminal (the session list when it has
/// none), a panel, or a view it was in before.
enum KeyboardTarget {
    case terminal
    case panel(PanelID)
    case view(NSView)
}

/// The one way the keyboard moves on a request: a shortcut (⌥⌘1–3, a panel's ⌥⌘ number), a
/// fill starting or ending, an overlay closing. A view AppKit can't see (hidden, or inside an area
/// still sliding or shrinking back) refuses the keyboard and drops it, so the request waits until
/// the target is on screen and laid out.
/// `pendingKeyboard` holds a request still waiting, and what had the keyboard when it was made.
extension MainWindowController {
    /// Ends a fill that hides the target, then gives it the keyboard as soon as it is on screen.
    /// Until then the request waits for the areas to settle (`root.onSettled`); anything that takes
    /// the keyboard meanwhile, like a click, cancels it.
    func giveKeyboard(_ target: KeyboardTarget) {
        switch target {
        case .terminal: if root.fillHides(nil) { root.filling = nil }
        case .panel(let p): if root.fillHides(p) { root.filling = nil }
        case .view: break
        }
        pendingKeyboard = (target, window?.firstResponder)
        applyPendingKeyboard()
    }

    func applyPendingKeyboard() {
        guard let (target, from) = pendingKeyboard else { return }
        guard window?.firstResponder === from else { pendingKeyboard = nil; return }
        root.layoutSubtreeIfNeeded()
        guard let v = view(for: target) else { pendingKeyboard = nil; return }
        guard !v.isHiddenOrHasHiddenAncestor else { return }
        pendingKeyboard = nil
        window?.makeFirstResponder(v)
        updateDim()
    }

    private func view(for target: KeyboardTarget) -> NSView? {
        switch target {
        case .view(let v): return v.window != nil ? v : view(for: .terminal)
        case .terminal:
            if let id = current, let t = terminal(for: id) ?? shell(id), !detached.contains(id) { return t }
            return root.sidebar.list
        case .panel(.sessions): return root.sidebar.list
        case .panel(.viewer):
            let hasPage = root.viewerPane.viewer.current != nil || root.viewerPane.viewer.currentArtifact != nil
            // An empty viewer takes the keyboard itself, so ⇧⌘↩ and Esc then act on it.
            return hasPage ? root.viewerPane.viewer.page ?? root.viewerPane : root.viewerPane
        case .panel(let p): return root.content(p) as? PluginPanel
        }
    }

    /// AppKit takes the keyboard from a view that hides and leaves it with the window, where typing
    /// goes nowhere: the viewer swapping its page for a PDF or an artifact, the last doc closed, a
    /// side hidden, a terminal ended. It goes back where `KeyboardHome.afterLosing` says: the panel
    /// it was in while that is still on screen, otherwise the terminal, the session pane or the
    /// session list. Called after anything that can hide or empty a view.
    func keepKeyboardVisible() {
        defer { updateDim() }
        guard let w = window, pendingKeyboard == nil else { return }
        root.layoutSubtreeIfNeeded()
        let fr = w.firstResponder
        let lost = fr == nil || fr === w || (fr as? NSView).map { $0.isHiddenOrHasHiddenAncestor || $0.window == nil } ?? false
        guard lost else { return }
        let attached = current.map { id in !detached.contains(id) && (terminal(for: id) ?? shell(id)) != nil } ?? false
        let home = KeyboardHome.afterLosing(root.keyboardHome, panelOnScreen: { [root] in root.isShown($0) && !root.fillHides($0) },
                                            hasTerminal: attached, hasSession: current != nil)
        switch home {
        case .panel(let p): focusPanel(p)
        case .terminal: giveKeyboard(.terminal)
        case .sessionPane: giveKeyboard(.view(root.sessionPane))
        case .sessionList: giveKeyboard(.panel(.sessions))
        }
    }

    /// Back to the session's terminal (the session list when there is none), as after an overlay
    /// closes. While a panel fills the window the terminal is hidden, so the keyboard stays in it.
    func focusMain() {
        if root.fillHides(nil), let p = root.filling?.dock.flatMap({ root.shown($0).first(where: \.canFill) }) { return focusPanel(p) }
        giveKeyboard(.terminal)
    }

    /// ⌥⌘1, ⌥⌘2, ⌥⌘3: the session list, the terminal, the viewer.
    func focus(_ pane: Int) {
        giveKeyboard(pane == 1 ? .panel(.sessions) : pane == 2 ? .terminal : .panel(.viewer))
    }

    func focusPanel(_ p: PanelID) { giveKeyboard(.panel(p)) }

    /// The keyboard follows: into what fills the window (what it covers is hidden and must not
    /// keep the keyboard), and back to where it was afterwards.
    func fillingChanged(_ f: WindowFill?) {
        let fr = window?.firstResponder as? NSView
        switch f {
        case nil:
            giveKeyboard(focusBeforeFill.map(KeyboardTarget.view) ?? .terminal)
            focusBeforeFill = nil
        case .session?:
            if focusBeforeFill == nil { focusBeforeFill = fr }
            guard fr?.isDescendant(of: root.sessionPane) != true else { break }
            if let id = current, let t = terminal(for: id) ?? shell(id), !detached.contains(id) { giveKeyboard(.view(t)) } else { window?.makeFirstResponder(nil) }
        case .panel(let d)?:
            if focusBeforeFill == nil { focusBeforeFill = fr }
            let inside = root.shown(d).contains { p in root.content(p).map { fr?.isDescendant(of: $0) == true } ?? false }
            if !inside { focusPanel(root.shown(d).first(where: \.canFill) ?? .viewer) }
        }
        updateDim()
        updateBadges()
    }
}
