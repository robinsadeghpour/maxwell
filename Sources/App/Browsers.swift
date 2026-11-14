import AppKit

/// The browsers on this Mac with their profiles and containers, and opening a link in one of them.
/// Only names are read (profiles.ini, containers.json, Chromium's Local State), never cookies or logins.
enum Browsers {
    struct Installed {
        let browser: KnownBrowser
        let app: URL
        /// Firefox family: profile names (the id is the name). Chromium: folder and display name.
        let profiles: [(id: String, name: String)]
        let containers: [String]
        /// Firefox family: the "Open external links in a container" add-on, which handles ext+container: links.
        let containerAddon: Bool
    }

    static func installed() -> [Installed] {
        let support = Paths.home.appendingPathComponent("Library/Application Support")
        return KnownBrowser.all.compactMap { b in
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b.bundleID) else { return nil }
            var profiles: [(String, String)] = [], containers: [String] = [], addon = false
            if let dir = b.support.map({ support.appendingPathComponent($0) }) {
                switch b.family {
                case .firefox:
                    let ini = (try? String(contentsOf: dir.appendingPathComponent("profiles.ini"), encoding: .utf8)) ?? ""
                    profiles = KnownBrowser.firefoxProfiles(ini: ini).map { ($0, $0) }
                    if let p = KnownBrowser.firefoxDefaultProfile(ini: ini) {
                        let pdir = p.hasPrefix("/") ? URL(fileURLWithPath: p) : dir.appendingPathComponent(p)
                        containers = (try? Data(contentsOf: pdir.appendingPathComponent("containers.json"))).map(KnownBrowser.firefoxContainers) ?? []
                        addon = hasContainerAddon(pdir.appendingPathComponent("extensions.json"))
                    }
                case .chromium:
                    profiles = (try? Data(contentsOf: dir.appendingPathComponent("Local State"))).map(KnownBrowser.chromiumProfiles)?.map { ($0.dir, $0.name) } ?? []
                case .other: break
                }
            }
            return Installed(browser: b, app: app, profiles: profiles, containers: containers, containerAddon: addon)
        }
    }

    static let containerAddonPage = URL(string: "https://addons.mozilla.org/firefox/addon/open-url-in-container/")!

    private static func hasContainerAddon(_ url: URL) -> Bool {
        guard let d = try? Data(contentsOf: url), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let addons = o["addons"] as? [[String: Any]] else { return false }
        return addons.contains { a in
            let name = ((a["defaultLocale"] as? [String: Any])?["name"] as? String ?? "").lowercased()
            return a["active"] as? Bool != false && name.contains("in a container") && name.contains("open")
        }
    }

    /// The profile's display name for a choice (Chromium stores folders like "Profile 1").
    static func profileName(_ choice: BrowserChoice, in list: [Installed]) -> String {
        list.first { $0.browser.id == choice.browser }?.profiles.first { $0.id == choice.name }?.name ?? choice.name
    }

    /// Opens `url` the way `choice` says. Returns a short reason when it could not.
    @discardableResult
    static func open(_ url: URL, with choice: BrowserChoice) -> String? {
        guard let b = KnownBrowser.byID[choice.browser] else { NSWorkspace.shared.open(url); return nil }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b.bundleID) else {
            NSWorkspace.shared.open(url)
            return "\(b.title) isn't installed. Opened in the default browser."
        }
        switch (choice.kind, b.family) {
        case (.container, .firefox):
            guard let u = KnownBrowser.containerURL(url, container: choice.name) else { return "Bad container name." }
            NSWorkspace.shared.open([u], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        case (.profile, .firefox):
            return run(app, ["-P", choice.name, url.absoluteString])
        case (.profile, .chromium):
            return run(app, ["--profile-directory=\(choice.name)", url.absoluteString])
        default:
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
        return nil
    }

    /// Starts the browser's own binary with arguments; a running instance takes the link over and the new process exits.
    private static func run(_ app: URL, _ args: [String]) -> String? {
        guard let exe = Bundle(url: app)?.executableURL else { return "Can't start \(app.lastPathComponent)." }
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "Can't start \(app.lastPathComponent): \(error.localizedDescription)" }
        return nil
    }
}
