import Foundation

/// Scripted phone checks (docs/phone.md, "Checking the bridge"), quiet runs only:
/// - MAXWELL_PHONE_PAIR_FILE: Maxwell makes a pairing code at launch and writes its link there, for a test phone.
/// - MAXWELL_PHONE_REMOVE_AFTER=<seconds>: a phone that pairs is removed that long after, as Settings' Remove
///   does, to check that the last phone's removal says `bye` and closes the relay connection.
enum PhoneHarness {
    static func start(_ bridge: PhoneBridge) {
        let env = ProcessInfo.processInfo.environment
        guard quietTest else { return }
        if let after = env["MAXWELL_PHONE_REMOVE_AFTER"].flatMap(Double.init) {
            bridge.onPaired = { [weak bridge] id in
                DispatchQueue.main.asyncAfter(deadline: .now() + after) { bridge?.remove(id) }
            }
        }
        guard let path = env["MAXWELL_PHONE_PAIR_FILE"], !path.isEmpty else { return }
        guard let link = bridge.makePairingCode() else { return mark("phone harness: no pair link (is phone-relay set?)") }
        do {
            try link.write(toFile: path, atomically: true, encoding: .utf8)
            mark("phone harness: pair link written")
        } catch {
            mark("phone harness: couldn't write the pair link: \(error.localizedDescription)")
        }
    }
}
