import Foundation

/// Crash text keeps code locations and plain words; paths, quoted values and names go.
func crashScrubTests() {
    let me = NSUserName()
    let cases: [(String, String)] = [
        ("/Users/\(me)/projects/maxwell/Sources/UI/Terminal.swift:14: Fatal error: ghostty_init failed",
         "Terminal.swift:14: Fatal error: ghostty_init failed"),
        ("Fatal error: Index out of range", "Fatal error: Index out of range"),
        ("couldn't open /Users/jane/work/acme-plan.md for reading", "couldn't open <path> for reading"),
        ("couldn't open ~/notes/secret.txt", "couldn't open <path>"),
        ("no session named \"fix the login bug\"", "no session named <…>"),
        ("-[NSURL initFileURLWithPath:]: nil string parameter", "-[NSURL initFileURLWithPath:]: nil string parameter"),
        ("account jane@example.com expired", "account <email> expired"),
        ("KERN_INVALID_ADDRESS at 0x0000000000000000", "KERN_INVALID_ADDRESS at 0x0000000000000000"),
        ("loading file:///Users/jane/a.json", "loading file:<path>"),
        ("1/2 done", "1/2 done"),
    ]
    for (raw, want) in cases {
        let got = CrashScrub.text(raw)
        check(got == want, "crash text \(raw.debugDescription) scrubs to \(want.debugDescription), got \(got.debugDescription)")
    }
    check(!CrashScrub.text("user \(me) here").contains(me) || me.count <= 2, "the macOS user name never leaves")
    check(CrashScrub.text(String(repeating: "a", count: 1000)).count <= 301, "crash text is capped")
    check(CrashScrub.image("/Users/jane/Applications/Maxwell.app/Contents/MacOS/Maxwell") == "Maxwell", "an image path keeps only its file name")
    check(CrashScrub.image("/usr/lib/system/libsystem_kernel.dylib") == "libsystem_kernel.dylib", "a system image keeps its file name")

    let ctx = CrashScrub.contexts([
        "os": ["name": "macOS", "version": "15.1", "build": "24B83"],
        "device": ["model": "Mac15,3", "arch": "arm64", "boot_time": "2026-11-01", "storage_size": 1_000_000, "name": "Jane's MacBook"],
        "app": ["app_version": "0.1.27", "device_app_hash": "abc", "app_start_time": "x"],
        "culture": ["locale": "de_DE", "timezone": "Europe/Berlin"],
    ])
    check(Set(ctx.keys) == ["os", "device", "app"], "only the os, device and app contexts are kept, got \(ctx.keys.sorted())")
    check(Set(ctx["device"]?.keys ?? [:].keys) == ["model", "arch"], "device keeps model and arch only, got \(ctx["device"]?.keys.sorted() ?? [])")
    check(Set(ctx["app"]?.keys ?? [:].keys) == ["app_version"], "app keeps the version, not the device hash or start time")
}
