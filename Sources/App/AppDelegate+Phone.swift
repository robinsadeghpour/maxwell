import AppKit

extension AppDelegate {
    /// The phone bridge (docs/phone.md) listens to the Store beside the window, and is off until
    /// `phone-relay` is set. Quiet runs keep its keys in memory, like plugin secrets.
    func startPhone() {
        let bridge = PhoneBridge(store: store, vault: quietTest ? MemoryVault() : KeychainVault())
        let render = store.onChange
        store.onChange = { [weak bridge] st in
            render?(st)
            bridge?.stateChanged()
        }
        let seen = store.onViewerItem
        store.onViewerItem = { [weak bridge] id, item, reload in
            seen?(id, item, reload)
            bridge?.artifactSeen(id, item)
        }
        bridge.onStatus = { [weak self] in self?.main.refreshSettings() }
        bridge.onClosed = { [weak self] id in self?.main.forget(id) }
        bridge.onConfirmPair = { [weak self] name, decide in self?.confirmPair(name, decide) }
        main.phone = bridge
        bridge.reload(store.config)
        PhoneHarness.start(bridge)
    }

    /// "Pair <name>?" before a phone sees anything: in front of Settings when it is open, else the window.
    private func confirmPair(_ name: String, _ decide: @escaping (Bool) -> Void) {
        let a = NSAlert()
        a.messageText = "Pair “\(name)”?"
        a.informativeText = "It will be able to read and control your sessions."
        a.addButton(withTitle: "Allow")
        a.addButton(withTitle: "Deny")
        let w = NSApp.windows.first { $0.title == "Maxwell Settings" && $0.isVisible } ?? main.window
        guard let w else { return decide(a.runModal() == .alertFirstButtonReturn) }
        a.beginSheetModal(for: w) { decide($0 == .alertFirstButtonReturn) }
    }
}
