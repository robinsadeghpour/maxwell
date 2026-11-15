import Foundation

/// Slack Web API calls this plugin may make. Every one of them only reads; a method that is
/// not listed throws before anything goes over the network, so the plugin can't post, react,
/// draft or schedule even by mistake.
enum ReadOnly {
    static let methods: Set<String> = [
        "auth.test",
        "conversations.history",
        "conversations.replies",
        "search.messages",
        "users.info",
    ]
}

struct SlackError: Error, Equatable, CustomStringConvertible {
    var code: String
    var description: String { code }
    static let notReadOnly = SlackError(code: "not_read_only")
}

/// Sends one Web API call and returns the raw JSON body. Tests swap in recorded responses.
typealias Transport = (_ method: String, _ params: [String: String]) throws -> Data

enum SlackHTTP {
    static func transport(token: String) -> Transport {
        return { method, params in
            var c = URLComponents(string: "https://slack.com/api/\(method)")!
            c.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            var req = URLRequest(url: c.url!, timeoutInterval: 20)
            req.httpMethod = "GET"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            for attempt in 0..<3 {
                let (data, resp) = try fetch(req)
                if resp.statusCode == 429, attempt < 2 {
                    let wait = Double(resp.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 5
                    Thread.sleep(forTimeInterval: min(wait, 30))
                    continue
                }
                return data
            }
            throw SlackError(code: "ratelimited")
        }
    }

    private static func fetch(_ req: URLRequest) throws -> (Data, HTTPURLResponse) {
        let sem = DispatchSemaphore(value: 0)
        var out: Result<(Data, HTTPURLResponse), Error> = .failure(SlackError(code: "no_response"))
        URLSession.shared.dataTask(with: req) { d, r, e in
            if let e { out = .failure(e) } else if let d, let r = r as? HTTPURLResponse { out = .success((d, r)) }
            sem.signal()
        }.resume()
        sem.wait()
        return try out.get()
    }
}

/// The read-only client: checks the method against `ReadOnly`, sends it, unwraps `ok`.
struct SlackAPI {
    var transport: Transport

    func call(_ method: String, _ params: [String: String] = [:]) throws -> [String: Any] {
        guard ReadOnly.methods.contains(method) else { throw SlackError.notReadOnly }
        let data = try transport(method, params)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SlackError(code: "bad_json") }
        guard obj["ok"] as? Bool == true else { throw SlackError(code: obj["error"] as? String ?? "unknown_error") }
        return obj
    }

    /// Follows `response_metadata.next_cursor` up to `pages` pages and concatenates `key`.
    func paged(_ method: String, _ params: [String: String], key: String, pages: Int = 5) throws -> [[String: Any]] {
        var out: [[String: Any]] = [], cursor: String?
        for _ in 0..<pages {
            var p = params
            if let cursor { p["cursor"] = cursor }
            let r = try call(method, p)
            out += r[key] as? [[String: Any]] ?? []
            cursor = (r["response_metadata"] as? [String: Any])?["next_cursor"] as? String
            if cursor?.isEmpty ?? true { break }
        }
        return out
    }
}
