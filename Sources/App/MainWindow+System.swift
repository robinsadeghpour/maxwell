import AppKit

/// The System panel's readings and its details card (`SystemDetail`).
extension MainWindowController {
    func wireSystem() {
        root.system.measure = { [weak self] done in
            guard let self else { return }
            self.systemSampler.take(sessions: self.runningProcesses(), done)
        }
        root.system.onSample = { [weak self] in
            guard let self else { return }
            if self.systemDetailWanted { self.systemDetailWanted = false; self.showSystemDetail() } else { self.refreshSystemDetail() }
        }
        root.system.onOpen = { [weak self] in self?.toggleSystemDetail() }
        systemDetail.onOpenSession = { [weak self] id in
            self?.systemDetail.dismiss()
            self?.open(id)
        }
        systemDetail.onActivityMonitor = { [weak self] in
            self?.systemDetail.dismiss()
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        }
        systemDetail.onClose = { [weak self] in self?.focusMain() }
    }

    var systemActions: [Action] {
        [Action(id: "system-details", title: "System Details", menu: "Panels") { [weak self] in self?.showSystemDetail() }]
    }

    /// Each running session's Claude Code process. Cloud sessions run on Anthropic's machines.
    private func runningProcesses() -> [ProcessID: SessionID] {
        var pids: [ProcessID: SessionID] = [:]
        for s in store.state.sessions.values where s.phase != .ended && !s.isCloud && s.parkedAt == nil {
            if let pid = s.pid { pids[pid] = s.id }
        }
        return pids
    }

    /// A click on the System panel while its card is open closes the card there, not here.
    func clickTogglesSystemDetail(_ e: NSEvent, _ top: NSView) -> Bool {
        top === systemDetail && root.system.bounds.contains(root.system.convert(e.locationInWindow, from: nil))
    }

    private func toggleSystemDetail() {
        if systemDetail.superview != nil { systemDetail.dismiss() } else { showSystemDetail() }
    }

    /// Opens the card over the System panel. A hidden panel is shown first, and the card opens
    /// with its first reading.
    func showSystemDetail() {
        if !root.isShown(.system) || root.system.sample == nil {
            systemDetailWanted = true
            return root.setHidden(.system, false)
        }
        refreshSystemDetail()
        systemDetail.present(in: root, anchor: root.system.convert(root.system.bounds, to: root))
    }

    func refreshSystemDetail() {
        guard let sample = root.system.sample else { return }
        let state = store.state
        let rows = sample.sessions.compactMap { id, load in state.sessions[id].map { SystemDetail.Row(id: id, title: $0.title, load: load) } }
        systemDetail.update(sample: sample, history: root.system.history, rows: rows)
    }
}
