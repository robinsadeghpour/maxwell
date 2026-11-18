import Foundation

/// Scripted phone checks (docs/phone.md, "Checking the bridge"): with MAXWELL_PHONE_PAIR_FILE set in a
/// quiet run, Maxwell makes a pairing code at launch and writes its link there, for a test phone to read.
enum PhoneHarness {
    static func start(_ bridge: PhoneBridge) {
        guard quietTest, let path = ProcessInfo.processInfo.environment["MAXWELL_PHONE_PAIR_FILE"], !path.isEmpty else { return }
        guard let link = bridge.makePairingCode() else { return mark("phone harness: no pair link (is phone-relay set?)") }
        do {
            try link.write(toFile: path, atomically: true, encoding: .utf8)
            mark("phone harness: pair link written")
        } catch {
            mark("phone harness: couldn't write the pair link: \(error.localizedDescription)")
        }
    }
}
