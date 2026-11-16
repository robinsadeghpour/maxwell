import Foundation
import Sentry

/// Crash and hang reports from the released Maxwell to Sentry, so a crash is known without anyone
/// writing in. Every report goes through `scrub` first: no transcripts, prompts, paths, session
/// names or account details, and no breadcrumbs. Maxwell Dev and scripted test runs never report.
/// `crash-reports = off` (Settings › General) turns it off at once.
enum CrashReports {
    /// Sentry DSNs are public by design: they only let a client send events to this project.
    static let dsn = "https://0cfab0ec37a4c029d0d460d3a7c82da6@o4512158045569024.ingest.de.sentry.io/4512442577387600"

    static func apply(enabled: Bool) {
        let want = enabled && Updater.isRelease && !quietTest
        if want == SentrySDK.isEnabled { return }
        guard want else { SentrySDK.close(); return }
        SentrySDK.start { o in
            o.dsn = dsn
            o.releaseName = "maxwell@\(Updater.current)"
            o.environment = "production"
            o.sendDefaultPii = false
            o.maxBreadcrumbs = 0
            o.enableAutoBreadcrumbTracking = false
            o.enableNetworkBreadcrumbs = false
            o.enableSwizzling = false
            o.enableDataSwizzling = false
            o.enableMetrics = false
            o.enableLogs = false
            o.enableAutoPerformanceTracing = false
            o.enableNetworkTracking = false
            o.enableCaptureFailedRequests = false
            o.enableFileIOTracing = false
            o.enableCoreDataTracing = false
            o.enableUncaughtNSExceptionReporting = true
            o.enableAppHangTracking = true
            o.appHangTimeoutInterval = 3
            o.beforeSend = scrub
        }
    }

    static func scrub(_ e: Sentry.Event) -> Sentry.Event? {
        e.user = e.user?.userId.map { User(userId: $0) }   // the SDK's random install ID, to count Macs
        e.serverName = nil
        e.breadcrumbs = nil
        e.extra = nil
        e.tags = nil
        e.request = nil
        e.modules = nil
        e.error = nil
        e.context = e.context.map(CrashScrub.contexts)
        if let m = e.message { e.message = SentryMessage(formatted: CrashScrub.text(m.formatted)) }
        for x in e.exceptions ?? [] {
            x.value = x.value.map(CrashScrub.text)
            x.mechanism?.desc = x.mechanism?.desc.map(CrashScrub.text)
            x.mechanism?.data = nil
            scrub(x.stacktrace)
        }
        for t in e.threads ?? [] {
            t.name = t.name.map(CrashScrub.text)
            scrub(t.stacktrace)
        }
        scrub(e.stacktrace)
        for d in e.debugMeta ?? [] { d.codeFile = d.codeFile.map(CrashScrub.image) }
        return e
    }

    private static func scrub(_ s: SentryStacktrace?) {
        for f in s?.frames ?? [] {
            f.package = f.package.map(CrashScrub.image)
            f.fileName = f.fileName.map(CrashScrub.image)
            f.vars = nil
            f.contextLine = nil; f.preContext = nil; f.postContext = nil
        }
    }
}
