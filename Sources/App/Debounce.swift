import Foundation

/// The one way Maxwell waits out a burst (docs/engineering-standard.md, rule 12). Main thread only.
///
/// - `.trailing`: runs once the pokes have stopped for `delay` (output has gone quiet).
/// - `.atMost`: runs `delay` after the first poke of a burst, so a steady stream still runs every
///   `delay` and never starves (state sent at most every 300 ms).
///
/// Poked once, either is a one-shot timeout; `poke(after:)` sets that one wait's length.
final class Debounce {
    enum Mode { case trailing, atMost }
    let mode: Mode
    var delay: TimeInterval
    private let action: () -> Void
    private var timer: Timer?

    init(_ delay: TimeInterval, _ mode: Mode = .trailing, action: @escaping () -> Void) {
        self.delay = delay
        self.mode = mode
        self.action = action
    }

    var isPending: Bool { timer != nil }

    func poke(after wait: TimeInterval? = nil) {
        if mode == .atMost, timer != nil { return }
        timer?.invalidate()
        let t = Timer(timeInterval: wait ?? delay, repeats: false) { [weak self] _ in
            self?.timer = nil
            self?.action()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Runs now if something is waiting.
    func flush() {
        guard timer != nil else { return }
        cancel()
        action()
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }

    deinit { timer?.invalidate() }
}
