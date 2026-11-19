import Foundation

/// The Live Activity's frames (docs/phone.md, "Live Activity"): plain `{"to", "live"}` frames to the
/// relay, which pushes them to Apple for the phone.
extension PhoneBridge {
    /// Sends each Live Activity phone's picture when it changed, and `null` once to a phone that turned it off.
    func sendLive() {
        guard let relay, relay.status == .connected else { return }
        let phones = registry.phones.values.map { PhoneLive.Phone(id: $0.id, live: $0.live == true, detail: $0.pushDetail ?? .hidden) }
        let frames = PhoneLive.frames(phones, state: store.state, rules: store.config.rules, now: Date(), macName: Self.macName, sent: liveSent)
        for f in frames where relay.send(f.frame) { liveSent[f.phone] = f.key }
    }
}
