import Foundation

/// Linear's GraphQL API, behind a transport so tests run on recorded fixtures.
protocol LinearTransport {
    func send(_ query: String, _ variables: [String: Any], _ done: @escaping (Result<[String: Any], LinearError>) -> Void)
}

enum LinearError: Error, Equatable, CustomStringConvertible {
    case unauthorized, offline(String), http(Int), graphql(String), decode
    var description: String {
        switch self {
        case .unauthorized: return "the API key was refused"
        case .offline(let why): return "offline (\(why))"
        case .http(let code): return "Linear answered HTTP \(code)"
        case .graphql(let m): return m
        case .decode: return "unexpected answer from Linear"
        }
    }
}

/// api.linear.app with a personal API key (`Authorization: <key>`).
struct HTTPTransport: LinearTransport {
    var key: String
    var endpoint = URL(string: "https://api.linear.app/graphql")!

    func send(_ query: String, _ variables: [String: Any], _ done: @escaping (Result<[String: Any], LinearError>) -> Void) {
        var r = URLRequest(url: endpoint, timeoutInterval: 15)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(key, forHTTPHeaderField: "Authorization")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        URLSession.shared.dataTask(with: r) { data, resp, err in
            let result: Result<[String: Any], LinearError>
            if let err { result = .failure(.offline(err.localizedDescription)) }
            else if let h = resp as? HTTPURLResponse, h.statusCode == 401 || h.statusCode == 403 { result = .failure(.unauthorized) }
            else if let h = resp as? HTTPURLResponse, h.statusCode >= 300, h.statusCode != 400 { result = .failure(.http(h.statusCode)) }
            else { result = Self.decode(data) }
            DispatchQueue.main.async { done(result) }
        }.resume()
    }

    static func decode(_ data: Data?) -> Result<[String: Any], LinearError> {
        guard let data, let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .failure(.decode) }
        if let errs = d["errors"] as? [[String: Any]], let first = errs.first {
            let m = (first["message"] as? String) ?? "GraphQL error"
            let code = (first["extensions"] as? [String: Any])?["code"] as? String
            return .failure(code == "AUTHENTICATION_ERROR" ? .unauthorized : .graphql(m))
        }
        guard let out = d["data"] as? [String: Any] else { return .failure(.decode) }
        return .success(out)
    }
}

/// Answers from a folder of recorded responses: `viewer.json`, and one `<IDENT>.json` per issue.
/// Unknown issues come back as null, like the API does.
struct FixtureTransport: LinearTransport {
    var dir: URL
    func send(_ query: String, _ variables: [String: Any], _ done: @escaping (Result<[String: Any], LinearError>) -> Void) {
        let load = { (name: String) in (try? Data(contentsOf: dir.appendingPathComponent("\(name).json"))).flatMap { (try? JSONSerialization.jsonObject(with: $0)) } }
        var out: [String: Any] = [:]
        if query.contains("assignedIssues") { out = (load("mine") as? [String: Any]) ?? [:] }
        else if query.contains("viewer") { out = (load("viewer") as? [String: Any]) ?? [:] }
        for (k, v) in variables { if k.hasPrefix("i"), let id = v as? String { out[k] = load(id) ?? NSNull() } }
        DispatchQueue.main.async { done(.success(out)) }
    }
}

/// Reads and writes. In a dry run every write is logged to a file and nothing is sent.
final class LinearClient {
    let transport: LinearTransport
    let dryRunLog: URL?

    init(transport: LinearTransport, dryRunLog: URL?) {
        self.transport = transport
        self.dryRunLog = dryRunLog
    }

    static let issueFields = "id identifier title url state { id name type position } team { key states { nodes { id name type position } } }"

    /// The signed-in user's name and every team key the key can see.
    func viewer(_ done: @escaping (Result<(name: String, teams: Set<String>), LinearError>) -> Void) {
        transport.send("query { viewer { name } teams(first: 100) { nodes { key } } }", [:]) { r in
            done(r.flatMap { d in
                guard let name = (d["viewer"] as? [String: Any])?["name"] as? String else { return .failure(.decode) }
                let keys = ((d["teams"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []).compactMap { $0["key"] as? String }
                return .success((name, Set(keys)))
            })
        }
    }

    /// Tickets assigned to the signed-in user: everything not finished, and what finished this week.
    func mine(_ done: @escaping (Result<[LinearIssue], LinearError>) -> Void) {
        let f = Self.issueFields
        let q = """
        query Mine { viewer {
          open: assignedIssues(first: 100, orderBy: updatedAt, filter: { state: { type: { in: ["triage", "backlog", "unstarted", "started"] } } }) { nodes { \(f) } }
          done: assignedIssues(first: 30, orderBy: updatedAt, filter: { completedAt: { gt: "-P7D" } }) { nodes { \(f) } }
        } }
        """
        transport.send(q, [:]) { r in
            done(r.map { d in
                let v = d["viewer"] as? [String: Any]
                return ["open", "done"].flatMap { k in ((v?[k] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []).compactMap(LinearIssue.parse) }
            })
        }
    }

    /// Several issues in one request, by identifier. Missing ones are left out.
    func issues(_ ids: [String], _ done: @escaping (Result<[String: LinearIssue], LinearError>) -> Void) {
        guard !ids.isEmpty else { return done(.success([:])) }
        let vars = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ("i\($0.offset)", $0.element as Any) })
        let decl = ids.indices.map { "$i\($0): String!" }.joined(separator: ", ")
        let body = ids.indices.map { "i\($0): issue(id: $i\($0)) { \(Self.issueFields) }" }.joined(separator: " ")
        transport.send("query Issues(\(decl)) { \(body) }", vars) { r in
            done(r.map { d in
                var out: [String: LinearIssue] = [:]
                for (i, id) in ids.enumerated() { if let x = (d["i\(i)"] as? [String: Any]).flatMap(LinearIssue.parse) { out[id] = x } }
                return out
            })
        }
    }

    func move(_ issue: LinearIssue, to state: LinearIssue.State, _ done: @escaping (Result<String, LinearError>) -> Void) {
        let q = "mutation Move($id: String!, $state: String!) { issueUpdate(id: $id, input: { stateId: $state }) { success } }"
        write(q, ["id": issue.uuid, "state": state.id], describe: "move \(issue.identifier) to \(state.name)", done)
    }

    func comment(_ issue: LinearIssue, body: String, _ done: @escaping (Result<String, LinearError>) -> Void) {
        let q = "mutation Comment($id: String!, $body: String!) { commentCreate(input: { issueId: $id, body: $body }) { success } }"
        write(q, ["id": issue.uuid, "body": body], describe: "comment on \(issue.identifier): \(body)", done)
    }

    private func write(_ q: String, _ vars: [String: Any], describe: String, _ done: @escaping (Result<String, LinearError>) -> Void) {
        if let log = dryRunLog {
            let line = (try? JSONSerialization.data(withJSONObject: ["at": ISO8601DateFormatter().string(from: Date()), "query": q, "variables": vars], options: [.sortedKeys])) ?? Data()
            if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
            if let h = try? FileHandle(forWritingTo: log) { _ = try? h.seekToEnd(); try? h.write(contentsOf: line + Data("\n".utf8)); try? h.close() }
            return DispatchQueue.main.async { done(.success("Dry run: would \(describe)")) }
        }
        transport.send(q, vars) { r in
            done(r.flatMap { d in
                let ok = d.values.contains { (($0 as? [String: Any])?["success"] as? Bool) == true }
                return ok ? .success(describe.prefix(1).uppercased() + describe.dropFirst()) : .failure(.graphql("Linear didn't accept it"))
            })
        }
    }
}
