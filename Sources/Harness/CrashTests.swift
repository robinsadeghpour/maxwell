import Foundation
import Sentry

extension CrashReports {
    /// `--crash-test` crashes the app a second after launch and `--hang-test` blocks the main thread
    /// for 5 s, to check that reports reach the dashboard. The crash is sent on the next launch.
    static func runTests() {
        if CommandLine.arguments.contains("--crash-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { SentrySDK.crash() }
        }
        if CommandLine.arguments.contains("--hang-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Thread.sleep(forTimeInterval: 5) }
        }
    }
}
