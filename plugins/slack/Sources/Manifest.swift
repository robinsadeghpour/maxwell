import Foundation

/// The Slack app Robin creates once: user-token scopes that only read, no bot, no events.
enum Manifest {
    static let app: [String: Any] = [
        "display_information": [
            "name": "Maxwell",
            "description": "Shows who is waiting on a reply from you. Reads only; never posts.",
        ],
        "oauth_config": [
            "redirect_urls": ["https://localhost/maxwell"],
            "scopes": ["user": userScopes],
        ],
        "settings": ["org_deploy_enabled": false, "socket_mode_enabled": false, "token_rotation_enabled": false],
    ]

    /// Each scope only reads: search for where things happened, history for the order, users for names.
    static let userScopes = ["search:read", "im:history", "mpim:history", "channels:history", "groups:history", "users:read"]

    /// api.slack.com prefills "Create app from manifest" from this link.
    static var createAppURL: String {
        let json = try! JSONSerialization.data(withJSONObject: app, options: [.sortedKeys, .withoutEscapingSlashes])
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let q = String(data: json, encoding: .utf8)!.addingPercentEncoding(withAllowedCharacters: allowed)!
        return "https://api.slack.com/apps?new_app=1&manifest_json=\(q)"
    }
}
