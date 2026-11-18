import AppKit
import Network

/// The Mac's WebSocket to the relay (docs/phone.md, "The relay"): `{"ping":1}` every 25 s, closed and
/// opened again when no pong comes within 10 s, and reconnected with backoff (0.5 s doubling to 15 s,
/// ±20% jitter), at once when the Mac wakes or the network comes back. Main thread only.
final class RelayConnection: NSObject, URLSessionWebSocketDelegate {
    enum Status: Equatable {
        case connecting
        case connected
        /// Why the last try failed, in words for Settings.
        case cantReach(String)
    }

    let url: URL
    private(set) var status: Status = .connecting { didSet { if status != oldValue { onStatus?(status) } } }
    var onFrame: (([String: Any]) -> Void)?
    var onStatus: ((Status) -> Void)?
    /// The socket is open: send what the room should know first.
    var onOpen: (() -> Void)?

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var generation = 0
    private var backoff: TimeInterval = 0.5
    private var stopped = false
    private var pinger: Timer?
    private lazy var pongWait = Debounce(10) { [weak self] in self?.dropped("it stopped answering pings") }
    private lazy var retry = Debounce(0.5) { [weak self] in self?.open() }
    private let path = NWPathMonitor()
    private var wake: NSObjectProtocol?

    static let pingText = #"{"ping":1}"#
    static let pongText = #"{"pong":1}"#

    init(url: URL) {
        self.url = url
        super.init()
    }

    func start() {
        stopped = false
        // Frames are read and parsed on this queue; only the parsed frame comes to the main thread.
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        session = URLSession(configuration: .default, delegate: self, delegateQueue: q)
        var first = true
        path.pathUpdateHandler = { [weak self] p in
            // The first update is the network as it is now, not a change.
            defer { first = false }
            guard !first, p.status == .satisfied else { return }
            self?.reconnectNow("network changed")
        }
        path.start(queue: .main)
        wake = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reconnectNow("Mac woke")
        }
        open()
    }

    func stop() {
        stopped = true
        retry.cancel()
        pongWait.cancel()
        pinger?.invalidate()
        path.cancel()
        if let wake { NSWorkspace.shared.notificationCenter.removeObserver(wake) }
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
    }

    @discardableResult
    func send(_ frame: [String: Any], then sent: (() -> Void)? = nil) -> Bool {
        guard status == .connected, let task, let data = try? JSONSerialization.data(withJSONObject: frame, options: [.withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return false }
        guard text.utf8.count <= 1_000_000 else {
            mark("phone relay: a \(text.utf8.count)-byte frame is over the relay's 1 MB; not sent")
            return false
        }
        task.send(.string(text)) { [weak self] e in
            DispatchQueue.main.async {
                if let e { self?.dropped("send failed: \(e.localizedDescription)") }
                sent?()
            }
        }
        return true
    }

    // MARK: lifecycle

    private func open() {
        guard !stopped, let session else { return }
        generation += 1
        let g = generation
        task?.cancel(with: .goingAway, reason: nil)
        // While retrying after a failure, Settings keeps saying why it failed.
        if case .cantReach = status {} else { status = .connecting }
        let t = session.webSocketTask(with: url)
        t.maximumMessageSize = 4 << 20
        task = t
        t.resume()
        receive(t, g)
    }

    /// The network or the Mac came back: don't sit out the backoff.
    private func reconnectNow(_ why: String) {
        guard !stopped, status != .connected else { return }
        mark("phone relay: reconnecting now (\(why))")
        backoff = 0.5
        retry.cancel()
        open()
    }

    private enum Received { case pong, frame([String: Any]), other }

    private func receive(_ t: URLSessionWebSocketTask, _ g: Int) {
        t.receive { [weak self] r in
            // Off the main thread: parse here, hand over only the result.
            var got = Received.other
            if case .success(.string(let text)) = r {
                if text == Self.pongText { got = .pong } else if let f = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] { got = .frame(f) }
            }
            DispatchQueue.main.async {
                guard let self, g == self.generation else { return }
                if case .failure(let e) = r { return self.dropped(self.describe(e, t)) }
                switch got {
                case .pong: self.pongWait.cancel()
                case .frame(let f): self.onFrame?(f)
                case .other: break
                }
                self.receive(t, g)
            }
        }
    }

    func urlSession(_ s: URLSession, webSocketTask t: URLSessionWebSocketTask, didOpenWithProtocol p: String?) {
        DispatchQueue.main.async { self.opened(t) }
    }

    private func opened(_ t: URLSessionWebSocketTask) {
        guard t === task else { return }
        backoff = 0.5
        status = .connected
        mark("phone relay: connected to \(url.host ?? "?")")
        pinger?.invalidate()
        let timer = Timer(timeInterval: 25, repeats: true) { [weak self] _ in self?.ping() }
        RunLoop.main.add(timer, forMode: .common)
        pinger = timer
        onOpen?()
    }

    func urlSession(_ s: URLSession, webSocketTask t: URLSessionWebSocketTask, didCloseWith code: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        DispatchQueue.main.async { self.closed(t, code, reason) }
    }

    private func closed(_ t: URLSessionWebSocketTask, _ code: URLSessionWebSocketTask.CloseCode, _ reason: Data?) {
        guard t === task else { return }
        dropped("closed by the relay (\(code.rawValue)\(reason.flatMap { String(data: $0, encoding: .utf8) }.map { ": \($0)" } ?? ""))")
    }

    private func ping() {
        guard status == .connected, let task else { return }
        task.send(.string(Self.pingText)) { _ in }
        pongWait.poke()
    }

    /// The connection is gone: say why, then try again after the backoff.
    private func dropped(_ why: String) {
        guard !stopped else { return }
        pinger?.invalidate()
        pongWait.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        generation += 1
        status = .cantReach(why)
        mark("phone relay: \(url.host ?? "?"): \(why); retrying in \(String(format: "%.1f", backoff)) s")
        retry.poke(after: backoff * Double.random(in: 0.8...1.2))
        backoff = min(backoff * 2, 15)
    }

    /// Failures by kind, in words: the relay refused the room, the host isn't there, or the network is down.
    private func describe(_ e: Error, _ t: URLSessionWebSocketTask) -> String {
        if let http = t.response as? HTTPURLResponse, http.statusCode != 101 {
            switch http.statusCode {
            case 403: return "the relay says this room belongs to another Mac (403)"
            case 400: return "the relay refused this Mac's id or token (400)"
            case 404: return "there is no relay at that address (404)"
            default: return "the relay answered \(http.statusCode)"
            }
        }
        let ns = e as NSError
        guard ns.domain == NSURLErrorDomain else { return ns.localizedDescription }
        switch ns.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost: return "this Mac is offline"
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "that address can't be found"
        case NSURLErrorCannotConnectToHost: return "nothing is answering there"
        case NSURLErrorTimedOut: return "it took too long to answer"
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted: return "the secure connection failed"
        default: return ns.localizedDescription
        }
    }
}
