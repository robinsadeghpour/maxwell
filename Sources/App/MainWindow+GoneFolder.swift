import AppKit

/// Resume on a stopped session whose folder was deleted (see `GoneFolder`): `claude attach` would
/// only print "Couldn't wake", so Maxwell continues the conversation as a copy in the repository
/// (or the nearest folder that is left), opens the copy and closes the old record.
extension MainWindowController {
    func continueFromGoneFolder(_ s: Session, account: Account) {
        let gone = (s.cwd as NSString).abbreviatingWithTildeInPath
        guard let folder = GoneFolder.fallback(for: s.cwd, exists: { FileManager.default.fileExists(atPath: $0) }) else {
            return toast("Can't resume “\(s.title)”: \(gone) and every folder above it are gone. The conversation is kept: claude --resume \(s.id)")
        }
        let path = (folder as NSString).abbreviatingWithTildeInPath
        toast("\(gone) is gone. Continuing “\(s.title)” in \(path)…")
        store.resume(s.id, in: folder, account: account, name: s.title) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let copy):
                mark("gone folder: \(s.id.prefix(8)) continued as \(copy.prefix(8)) in \(path)")
                self.open(copy)
                self.toast("\(gone) was deleted, so “\(s.title)” continues in \(path) with its whole conversation.")
                self.store.closeNow(s.id) { [weak self] outcome in
                    if case .closed = outcome { self?.forget(s.id) }
                }
            case .failure(.untrusted):
                self.askToTrust(folder, account: account, retry: { self.continueFromGoneFolder(s, account: account) }, cancelled: {})
            case .failure(let error):
                self.toast("Couldn't continue “\(s.title)” in \(path): \(error)")
            }
        }
    }
}
