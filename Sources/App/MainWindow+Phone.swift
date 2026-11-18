import AppKit

extension MainWindowController {
    /// Settings › Phone › Remove; with `signOut`, also signs out of claude.ai the accounts whose sign-in
    /// the phone was given, which ends those sessions on claude.ai's side, the phone's copy with them.
    func removePhone(_ id: String, signOut: Bool) {
        let shared = phone?.status.phones.first { $0.id == id }?.shares.keys.map { $0 } ?? []
        phone?.remove(id)
        guard signOut else { return }
        for name in shared {
            guard let a = store.state.accounts.first(where: { $0.name == name }) else { continue }
            ClaudeWeb.shared.signOut(a) { mark("phone: signed \(name) out of claude.ai after removing a phone") }
        }
    }
}
