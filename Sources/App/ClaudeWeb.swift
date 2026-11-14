import AppKit
import WebKit
import CryptoKit

/// claude.ai inside Maxwell. Each account has its own website data store (cookies, storage), named
/// by a UUID derived from its config folder, so logins never mix and survive restarts.
/// Signing in always happens on claude.ai's own page; Maxwell never sees or stores a password.
final class ClaudeWeb {
    static let shared = ClaudeWeb()

    static let home = URL(string: "https://claude.ai")!
    static let login = URL(string: "https://claude.ai/login")!

    enum Status: Equatable { case unknown, signedOut, signedIn }

    private var stores: [String: WKWebsiteDataStore] = [:]
    private var observers: [String: CookieWatch] = [:]
    private(set) var status: [String: Status] = [:]
    /// Posted on the main thread when an account's status changes; the object is the account name.
    static let changed = Notification.Name("maxwell.claude-web.changed")

    /// A stable UUID per config folder: SHA-256 of the path, shaped as a version-5-style UUID.
    static func storeID(configDir: URL) -> UUID {
        var b = Array(SHA256.hash(data: Data(("maxwell.claude-web:" + Paths.normalize(configDir.path)).utf8)).prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    func store(_ a: Account) -> WKWebsiteDataStore {
        if let s = stores[a.name] { return s }
        let s = WKWebsiteDataStore(forIdentifier: Self.storeID(configDir: a.configDir))
        stores[a.name] = s
        let w = CookieWatch { [weak self] in self?.refresh(a) }
        s.httpCookieStore.add(w)
        observers[a.name] = w
        return s
    }

    func configuration(_ a: Account) -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = store(a)
        // Safari's agent: with WebKit's default one Google serves a reduced sign-in flow.
        c.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        return c
    }

    /// Signed in = claude.ai's session cookie is there and not expired. Only the cookie's name and
    /// expiry are looked at.
    func refresh(_ a: Account, done: ((Status) -> Void)? = nil) {
        store(a).httpCookieStore.getAllCookies { [weak self] cookies in
            let now = Date()
            let on = cookies.contains { $0.name == "sessionKey" && $0.domain.hasSuffix("claude.ai") && ($0.expiresDate.map { $0 > now } ?? true) }
            let s: Status = on ? .signedIn : .signedOut
            DispatchQueue.main.async {
                guard let self else { return }
                let changed = self.status[a.name] != s
                self.status[a.name] = s
                if changed { NotificationCenter.default.post(name: Self.changed, object: a.name) }
                done?(s)
            }
        }
    }

    /// Removes everything claude.ai (and the sign-in providers) stored for this account.
    func signOut(_ a: Account, done: @escaping () -> Void) {
        let s = store(a)
        s.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in
            self?.refresh(a) { _ in done() }
        }
    }

    /// The email this account's Claude Code login uses (oauthAccount in .claude.json), to say who to sign in as.
    static func expectedEmail(_ a: Account) -> String? {
        if CommandLine.arguments.contains("--demo-emails") { return "\(a.name)@example.com" }   // screenshots for docs
        let file = a.configDirEnv == nil ? Paths.home.appendingPathComponent(".claude.json") : a.configDir.appendingPathComponent(".claude.json")
        guard let d = try? Data(contentsOf: file), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let acct = o["oauthAccount"] as? [String: Any] else { return nil }
        return acct["emailAddress"] as? String
    }

    private final class CookieWatch: NSObject, WKHTTPCookieStoreObserver {
        let changed: () -> Void
        private var pending = false
        init(_ changed: @escaping () -> Void) { self.changed = changed }
        func cookiesDidChange(in store: WKHTTPCookieStore) {
            // Sign-in sets a burst of cookies; look once after it settles.
            guard !pending else { return }
            pending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.pending = false; self.changed() }
        }
    }
}
