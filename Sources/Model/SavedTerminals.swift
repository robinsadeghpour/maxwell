import Foundation

/// The plain terminals open in Maxwell, in sidebar order, so they come back after a restart:
/// each one's folder and the name you gave it. The shell itself doesn't survive; it starts fresh
/// in that folder, the way Terminal and Warp bring back their windows.
struct SavedTerminals: Codable, Equatable {
    struct Terminal: Codable, Equatable {
        var folder: String
        var name: String?
    }
    var terminals: [Terminal] = []
    static let key = "Maxwell.terminals"

    static func load(_ d: UserDefaults = .standard) -> SavedTerminals {
        d.data(forKey: key).flatMap { try? JSONDecoder().decode(SavedTerminals.self, from: $0) } ?? SavedTerminals()
    }

    func save(_ d: UserDefaults = .standard) {
        if terminals.isEmpty { return d.removeObject(forKey: Self.key) }
        if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.key) }
    }

    /// Where a saved terminal reopens: its folder, or the nearest folder above it that still
    /// exists (a deleted worktree reopens in its repository), or home.
    static func reopenFolder(_ folder: String, home: String, exists: (String) -> Bool) -> String {
        var f = folder
        while f != "/" && !f.isEmpty {
            if exists(f) { return f }
            f = (f as NSString).deletingLastPathComponent
        }
        return home
    }
}
