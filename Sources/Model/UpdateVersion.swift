/// Which release the updater downloads (Sources/App/Updater.swift does the downloading).
enum UpdateVersion {
    /// Whether the latest release is worth downloading: newer than the running app and than the
    /// update already waiting for "Restart to update". A waiting update never ends the search:
    /// Maxwell stays open for days, and the button has to install the newest release.
    static func wanted(latest: String, running: String, waiting: String?) -> Bool {
        newer(latest, than: running) && waiting.map { newer(latest, than: $0) } != false
    }

    /// Compares dotted version numbers: 0.1.10 is newer than 0.1.9.
    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").compactMap { Int($0) }, y = b.split(separator: ".").compactMap { Int($0) }
        guard !x.isEmpty else { return false }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
