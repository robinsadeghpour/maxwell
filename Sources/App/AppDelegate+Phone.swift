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
        main.phone = bridge
        bridge.reload(store.config)
        PhoneHarness.start(bridge)
    }
}
