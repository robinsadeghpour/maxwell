import Foundation

/// The plugin's view of Maxwell's wire, on top of the shared SDK (`plugins/sdk/MaxwellPlugin.swift`).
/// The SDK delivers everything on the main queue; handlers here run on a work queue instead, so
/// the plugin can wait for Maxwell's answer (`call`) without blocking the line reader.
final class Wire {
    typealias Handler = (_ params: [String: Any]) throws -> Any?
    struct WireError: Error { var code: Int; var message: String }

    private let io = PluginIO()
    private var requests: [String: Handler] = [:]
    private var notes: [String: ([String: Any]) -> Void] = [:]
    private let work = DispatchQueue(label: "slack.work", attributes: .concurrent)

    func onRequest(_ method: String, _ h: @escaping Handler) { requests[method] = h }
    func onNotification(_ method: String, _ h: @escaping ([String: Any]) -> Void) { notes[method] = h }

    func notify(_ method: String, _ params: [String: Any]) {
        DispatchQueue.main.async { self.io.notify(method, params) }
    }

    /// Request and wait. Never call this on the main queue.
    func call(_ method: String, _ params: [String: Any], timeout: TimeInterval = 10) -> Result<Any?, WireError> {
        let sem = DispatchSemaphore(value: 0)
        var r: Result<Any?, WireError> = .failure(WireError(code: -1, message: "timeout"))
        DispatchQueue.main.async {
            self.io.request(method, params) { reply in
                r = reply.map { $0 }.mapError { WireError(code: $0.code, message: $0.message) }
                sem.signal()
            }
        }
        _ = sem.wait(timeout: .now() + timeout)
        return r
    }

    func run() -> Never {
        io.onRequest = { [unowned self] method, params, reply in
            guard let h = requests[method] else { return reply(.failure(.init(code: -32601, message: "unknown method \(method)"))) }
            work.async {
                let r: Result<Any, PluginIO.Failure>
                do { r = .success(try h(params) ?? NSNull()) }
                catch let e as WireError { r = .failure(.init(code: e.code, message: e.message)) }
                catch { r = .failure(.init(code: -32000, message: "\(error)")) }
                DispatchQueue.main.async { reply(r) }
            }
        }
        io.onNotification = { [unowned self] method, params in
            if let h = notes[method] { work.async { h(params) } }
        }
        io.run()
    }
}
