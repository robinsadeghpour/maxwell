import Foundation

/// Plain terminals come back after a restart: folder, name and order.
func savedTerminalsTests() {
    let d = UserDefaults(suiteName: "maxwell-tests-\(UUID().uuidString)")!
    check(SavedTerminals.load(d).terminals.isEmpty, "nothing saved: no terminals come back")

    let saved = SavedTerminals(terminals: [.init(folder: "/p/api", name: "deploy logs"), .init(folder: "/p/web", name: nil)])
    saved.save(d)
    check(SavedTerminals.load(d) == saved, "folders, names and order survive a save and load")
    SavedTerminals().save(d)
    check(d.data(forKey: SavedTerminals.key) == nil, "closing the last terminal clears what's saved")

    let exists: (String) -> Bool = { ["/p", "/p/api"].contains($0) }
    check(SavedTerminals.reopenFolder("/p/api", home: "/h", exists: exists) == "/p/api", "a folder that exists reopens there")
    check(SavedTerminals.reopenFolder("/p/.worktrees/gone/src", home: "/h", exists: exists) == "/p", "a deleted worktree reopens in the nearest folder still there")
    check(SavedTerminals.reopenFolder("/gone", home: "/h", exists: exists) == "/h", "nothing left of the path: home")
}
