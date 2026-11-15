import Foundation

/// The plugin side of Maxwell's wire (docs/plugins.md): newline-delimited JSON-RPC 2.0 on
/// stdin and stdout. Everything runs on the main queue; call `run()` last, it never returns.
///
///     let io = PluginIO()
///     io.onRequest = { method, params, reply in reply(.success([:])) }
///     io.run()
final class PluginIO {
    struct Failure: Error { var code: Int; var message: String }
    typealias Reply = (Result<Any, Failure>) -> Void

    /// A request from Maxwell (`initialize`, `action/run`, `shutdown`). Call `reply` exactly once.
    var onRequest: ((_ method: String, _ params: [String: Any], _ reply: @escaping Reply) -> Void)?
    /// A notification from Maxwell (`sessions/changed`, `settings/changed`, `secrets/changed`).
    var onNotification: ((_ method: String, _ params: [String: Any]) -> Void)?
    /// stdin closed: Maxwell is gone. Default: exit.
    var onClose: () -> Void = { exit(0) }

    private var nextId = 1
    private var pending: [Int: Reply] = [:]
    private let out = FileHandle.standardOutput

    init() { signal(SIGPIPE, SIG_IGN) }

    func notify(_ method: String, _ params: [String: Any]) { write(["jsonrpc": "2.0", "method": method, "params": params]) }

    func request(_ method: String, _ params: [String: Any], reply: @escaping Reply) {
        let id = nextId
        nextId += 1
        pending[id] = reply
        write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    /// `secrets/get`: the secret's value, or nil when it isn't set.
    func secret(_ key: String, _ done: @escaping (String?) -> Void) {
        request("secrets/get", ["key": key]) { r in
            if case .success(let v) = r { done((v as? [String: Any])?["value"] as? String) } else { done(nil) }
        }
    }

    func log(_ message: String) { FileHandle.standardError.write(Data((message + "\n").utf8)) }

    func run() -> Never {
        Thread.detachNewThread { [self] in
            while let line = readLine(strippingNewline: true) {
                DispatchQueue.main.async { self.handle(line) }
            }
            DispatchQueue.main.async { self.onClose() }
        }
        dispatchMain()
    }

    private func handle(_ line: String) {
        guard let m = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return }
        let params = (m["params"] as? [String: Any]) ?? [:]
        if let method = m["method"] as? String {
            if let id = m["id"] {
                if let onRequest {
                    onRequest(method, params) { [weak self] r in
                        switch r {
                        case .success(let v): self?.write(["jsonrpc": "2.0", "id": id, "result": v])
                        case .failure(let e): self?.write(["jsonrpc": "2.0", "id": id, "error": ["code": e.code, "message": e.message]])
                        }
                    }
                } else {
                    write(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "unknown method \(method)"]])
                }
            } else {
                onNotification?(method, params)
            }
        } else if let id = (m["id"] as? NSNumber)?.intValue, let reply = pending.removeValue(forKey: id) {
            if let e = m["error"] as? [String: Any] {
                reply(.failure(Failure(code: (e["code"] as? NSNumber)?.intValue ?? -32603, message: (e["message"] as? String) ?? "failed")))
            } else {
                reply(.success(m["result"] ?? NSNull()))
            }
        }
    }

    private func write(_ m: [String: Any]) {
        guard var d = try? JSONSerialization.data(withJSONObject: m) else { return }
        d.append(0x0A)
        try? out.write(contentsOf: d)
    }
}
