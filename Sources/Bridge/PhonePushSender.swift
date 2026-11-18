import CoreGraphics
import Foundation

/// Pushes go from the Mac straight to Expo's push service (docs/phone.md, "Pushes"); not through the relay.
enum PhonePushSender {
    static let endpoint = URL(string: "https://exp.host/--/api/v2/push/send")!

    /// Someone is at the Mac: input in the last 2 minutes and the screen unlocked. Then no pushes.
    static func macInUse() -> Bool {
        let any = CGEventType(rawValue: ~0) ?? .mouseMoved
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
        return idle < 120 && !locked
    }

    /// Sends the messages; `gone` gets the tokens Expo says no longer reach a phone.
    static func send(_ messages: [[String: Any]], gone: @escaping (Set<String>) -> Void) {
        guard !messages.isEmpty, let body = try? JSONSerialization.data(withJSONObject: messages) else { return }
        if quietTest { return mark("phone: \(messages.count) push(es) not sent (quiet run)") }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error { return mark("phone: push failed: \(error.localizedDescription)") }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let data, let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let tickets = o["data"] as? [[String: Any]] else { return mark("phone: push answered \(code)") }
            var dead = Set<String>()
            for (i, t) in tickets.enumerated() where t["status"] as? String == "error" {
                let reason = (t["details"] as? [String: Any])?["error"] as? String ?? t["message"] as? String ?? "?"
                mark("phone: push refused: \(reason)")
                if reason == "DeviceNotRegistered", i < messages.count, let token = messages[i]["to"] as? String { dead.insert(token) }
            }
            mark("phone: sent \(tickets.count - dead.count) push(es)")
            if !dead.isEmpty { DispatchQueue.main.async { gone(dead) } }
        }.resume()
    }
}
