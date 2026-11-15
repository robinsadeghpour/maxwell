import AppKit

/// Keeps the released Maxwell current without ever closing it on its own. It asks GitHub for the
/// latest public release, downloads and checks the new app in the background, and swaps it in
/// only when you click "Restart to update".
/// Maxwell Dev never updates itself.
final class Updater {
    static let repo = "robinsadeghpour/maxwell"
    static let releaseID = "dev.maxwell.app"
    static var isRelease: Bool { Bundle.main.bundleIdentifier == releaseID }
    static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    enum Check { case upToDate, ready(String), failed(String) }

    private(set) var ready: (version: String, app: URL)?
    var onReady: ((String) -> Void)?
    private var timer: Timer?
    private var busy = false

    func start() {
        guard Self.isRelease else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.check() }
        timer = Timer.scheduledTimer(withTimeInterval: 4 * 3600, repeats: true) { [weak self] _ in self?.check() }
    }

    func check(done: ((Check) -> Void)? = nil) {
        if let r = ready { done?(.ready(r.version)); return }
        guard !busy else { return }
        busy = true
        DispatchQueue.global(qos: .utility).async {
            let result = Self.fetch()
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let r?):
                    self.ready = r
                    self.onReady?(r.version)
                    done?(.ready(r.version))
                case .success(nil): done?(.upToDate)
                case .failure(let e): done?(.failed(e.message))
                }
            }
        }
    }

    /// Replaces this app with the downloaded one after it quits, then opens it again.
    /// Sessions keep running: they are Claude Code background sessions.
    /// A copy run straight from the DMG, or one macOS translocated, sits on a read-only volume:
    /// its update goes to Applications instead, or the swap would fail and reopen the old version.
    func install() {
        guard let r = ready else { return }
        guard let dest = Self.installTarget() else {
            onInstallFailed?("Maxwell can't write to Applications. Drag it there from the DMG and open it from Applications.")
            return
        }
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        if [ -e "$1" ]; then
          rm -rf "$1.old" && mv "$1" "$1.old" && /usr/bin/ditto "$2" "$1" && rm -rf "$1.old" || { rm -rf "$1"; mv "$1.old" "$1"; }
        else
          /usr/bin/ditto "$2" "$1"
        fi
        /usr/bin/open "$1"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "sh", dest.path, r.app.path]
        guard (try? p.run()) != nil else { return }
        NSApp.terminate(nil)
    }

    var onInstallFailed: ((String) -> Void)?

    /// This app's own path when it can be replaced there, else Maxwell.app in the first
    /// Applications folder this user can write to.
    static func installTarget(bundle: URL = Bundle.main.bundleURL, home: URL = Paths.home) -> URL? {
        let fm = FileManager.default
        if !bundle.path.contains("/AppTranslocation/"), fm.isWritableFile(atPath: bundle.deletingLastPathComponent().path) { return bundle }
        let user = home.appendingPathComponent("Applications")
        if !fm.fileExists(atPath: user.path) { try? fm.createDirectory(at: user, withIntermediateDirectories: true) }
        return [URL(fileURLWithPath: "/Applications"), user]
            .first { fm.isWritableFile(atPath: $0.path) }?
            .appendingPathComponent("Maxwell.app")
    }

    // MARK: fetching

    private struct Failure: Error { let message: String }

    private static let curl = "/usr/bin/curl"

    /// The latest public release and its zip, from GitHub's API. No login needed.
    private static func fetch() -> Result<(version: String, app: URL)?, Failure> {
        guard let out = run(curl, ["-fsSL", "--max-time", "20", "-H", "Accept: application/vnd.github+json", "https://api.github.com/repos/\(repo)/releases/latest"]),
              let json = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let tag = json["tag_name"] as? String else { return .failure(Failure(message: "Couldn't reach GitHub.")) }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard newer(version, than: current) else { return .success(nil) }
        let assets = json["assets"] as? [[String: Any]] ?? []
        guard let asset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
              let name = asset["name"] as? String, let url = asset["browser_download_url"] as? String else {
            return .failure(Failure(message: "\(tag) has no app to download."))
        }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(releaseID)/updates/\(version)")
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let zip = dir.appendingPathComponent(name)
        guard run(curl, ["-fsSL", "--max-time", "300", "-o", zip.path, url]) != nil,
              run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path]) != nil else {
            return .failure(Failure(message: "Couldn't download \(tag)."))
        }
        let app = dir.appendingPathComponent("Maxwell.app")
        // Only ever swap in a released Maxwell of exactly the version GitHub announced.
        guard let info = Bundle(url: app)?.infoDictionary, info["CFBundleIdentifier"] as? String == releaseID,
              info["CFBundleShortVersionString"] as? String == version else {
            return .failure(Failure(message: "The download for \(tag) isn't a Maxwell release."))
        }
        return .success((version, app))
    }

    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").compactMap { Int($0) }, y = b.split(separator: ".").compactMap { Int($0) }
        guard !x.isEmpty else { return false }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
