import AppKit
import Darwin

/// The one way usage is drawn: a 2 pt bar on a hairline track, the percent, then when it
/// resets. Grey until 80%, brighter to 95%, amber at the limit.
enum UsageBar {
    static func draw(_ w: UsageWindow?, in r: NSRect, now: Date, theme t: Theme, resetWidth: CGFloat) {
        let font = Fonts.mono(Metrics.fontSize - 2)
        // Past the reset time a sample no longer says anything about the new window.
        let live = w.flatMap { $0.resetsAt > now ? $0 : nil }
        let pct = live?.usedPercent ?? (w == nil ? nil : 0)
        let pctW: CGFloat = 34
        // Narrow: the reset time moves to the tooltip, the bar keeps its room.
        let resetWidth = r.width < 170 ? 0 : resetWidth
        let barW = max(12, r.width - pctW - resetWidth - 12)
        let bar = NSRect(x: r.minX, y: r.midY - 1, width: barW, height: 2)
        Meter.draw(pct, in: bar, theme: t)
        let full = (pct ?? 0) >= 100
        Text.draw(pct.map { "\(Int($0))%" } ?? "–", in: NSRect(x: bar.maxX + 6, y: r.minY, width: pctW, height: r.height),
                  color: full ? t.on : pct.map { $0 >= 80 } == true ? t.fg : t.fg2, font: font, align: .right)
        guard resetWidth > 0 else { return }
        let reset = live.map { "↻" + Format.reset($0.resetsAt, now: now) } ?? (w == nil ? "" : "ready")
        Text.draw(reset, in: NSRect(x: r.maxX - resetWidth, y: r.minY, width: resetWidth, height: r.height),
                  color: full ? t.on : t.fg3, font: font, align: .right)
    }
}

extension UsageBar {
    /// "62% used in the last 5 hours", then when it resets in plain words.
    static func tip(_ w: UsageWindow?, week: Bool, now: Date = Date()) -> Tip {
        let span = week ? "this week" : "in the last 5 hours"
        guard let w else { return Tip("No usage reported yet for \(span)") }
        if w.resetsAt <= now { return Tip("The \(week ? "weekly" : "5 hour") limit has reset").adding("All of it is free again") }
        return Tip("\(Int(w.usedPercent))% used \(span)").adding("Resets \(Format.when(w.resetsAt, now: now))")
    }
}

/// The small header every widget panel uses: a caps label, room for a note on the right.
private func drawWidgetHeader(_ title: String, note: String = "", in v: MXView, theme t: Theme) {
    let head = Fonts.mono(Metrics.fontSize - 2.5, .medium)
    Text.draw(title, in: NSRect(x: 12, y: 0, width: 120, height: Widget.header), color: t.fg3, font: head)
    if !note.isEmpty {
        Text.draw(note, in: NSRect(x: 12, y: 0, width: v.bounds.width - 24, height: Widget.header), color: t.fg3, font: head, align: .right)
    }
}

enum Widget {
    static let header: CGFloat = 24
    static let line: CGFloat = 19
}

/// Usage per account: 5-hour and weekly bars with percent and reset time.
final class UsagePanel: MXView, PanelContent, TipSource {
    var accounts: [Account] = [] { didSet { if accounts != oldValue { needsDisplay = true } } }
    var counts: [AccountID: Int] = [:] { didSet { if counts != oldValue { needsDisplay = true } } }

    var gripRect: NSRect { NSRect(x: 0, y: 0, width: bounds.width, height: Widget.header) }
    func preferredExtent(along d: Dock) -> CGFloat? {
        d == .bottom ? Widget.header + CGFloat(max(3, accounts.count)) * Widget.line + 8 : Widget.header + CGFloat(accounts.count) * Widget.line + 10
    }

    private var columns: (name: CGFloat, c1: NSRect, c2: NSRect) {
        let x0: CGFloat = 12 + 76
        let w = (bounds.width - x0 - 12 - 16) / 2
        return (76, NSRect(x: x0, y: 0, width: w, height: 0), NSRect(x: x0 + w + 16, y: 0, width: w, height: 0))
    }

    /// The account (and its running sessions), or one bar: how much is used and when it resets.
    func tip(at p: NSPoint) -> (tip: Tip, rect: NSRect)? {
        let c = columns
        if p.y < Widget.header {
            if p.x >= c.c2.minX { return (Tip("Share of each account's weekly limit used"), NSRect(x: c.c2.minX, y: 0, width: c.c2.width, height: Widget.header)) }
            if p.x >= c.c1.minX { return (Tip("Share of each account's 5 hour limit used"), NSRect(x: c.c1.minX, y: 0, width: c.c1.width, height: Widget.header)) }
            return nil
        }
        let i = Int((p.y - Widget.header) / Widget.line)
        guard accounts.indices.contains(i) else { return nil }
        let a = accounts[i], y = Widget.header + CGFloat(i) * Widget.line
        if p.x < c.c1.minX {
            let n = counts[a.id] ?? 0
            return (Tip(a.name).adding(n == 0 ? "No sessions running" : n == 1 ? "1 session running" : "\(n) sessions running"), NSRect(x: 0, y: y, width: c.c1.minX - 4, height: Widget.line))
        }
        let week = p.x >= c.c2.minX
        let col = week ? c.c2 : c.c1
        return (UsageBar.tip(week ? a.week : a.fiveHour, week: week), NSRect(x: col.minX, y: y, width: col.width, height: Widget.line))
    }

    override func draw(_ r: NSRect) {
        let c = columns
        drawWidgetHeader("USAGE", in: self, theme: t)
        let head = Fonts.mono(Metrics.fontSize - 2.5, .medium)
        Text.draw("5 HOURS", in: NSRect(x: c.c1.minX, y: 0, width: c.c1.width, height: Widget.header), color: t.fg3, font: head)
        Text.draw("WEEK", in: NSRect(x: c.c2.minX, y: 0, width: c.c2.width, height: Widget.header), color: t.fg3, font: head)
        let now = Date()
        let small = Fonts.mono(Metrics.fontSize - 2)
        for (i, a) in accounts.enumerated() {
            let y = Widget.header + CGFloat(i) * Widget.line
            let nameW = Text.draw(a.name, in: NSRect(x: 12, y: y, width: c.name - 20, height: Widget.line), color: t.fg2, font: Fonts.mono(Metrics.fontSize - 1))
            if let n = counts[a.id], n > 0 {
                Text.draw("\(n)", in: NSRect(x: 12 + nameW + 5, y: y, width: 24, height: Widget.line), color: t.fg3, font: small)
            }
            let rw = Text.width("↻Sat 00:00", font: small)
            UsageBar.draw(a.fiveHour, in: NSRect(x: c.c1.minX, y: y, width: c.c1.width, height: Widget.line), now: now, theme: t, resetWidth: rw)
            UsageBar.draw(a.week, in: NSRect(x: c.c2.minX, y: y, width: c.c2.width, height: Widget.line), now: now, theme: t, resetWidth: rw)
        }
        if accounts.isEmpty {
            Text.draw("No account has reported usage yet.", in: NSRect(x: 12, y: Widget.header, width: bounds.width - 24, height: Widget.line), color: t.fg3, font: small)
        }
    }
}

/// What Claude Code and the machine use right now: CPU and memory, sampled every 2 s while shown.
final class SystemPanel: MXView, PanelContent, TipSource {
    private var sample: SystemSample?
    private var timer: Timer?
    private let sampler = SystemSampler()

    var gripRect: NSRect { NSRect(x: 0, y: 0, width: bounds.width, height: Widget.header) }
    func preferredExtent(along d: Dock) -> CGFloat? { Widget.header + 3 * Widget.line + 8 }

    override func viewDidMoveToWindow() { updateTimer() }
    override func viewDidHide() { updateTimer() }
    override func viewDidUnhide() { updateTimer() }

    private func updateTimer() {
        let live = window != nil && !isHiddenOrHasHiddenAncestor
        if live, timer == nil {
            tick()
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        } else if !live {
            timer?.invalidate(); timer = nil
        }
    }

    private func tick() {
        sampler.take { [weak self] s in self?.sample = s; self?.needsDisplay = true }
    }

    /// What each row measures. CPU is always a share of the whole Mac, so the rows add up.
    func tip(at p: NSPoint) -> (tip: Tip, rect: NSRect)? {
        guard let s = sample else { return nil }
        let x0: CGFloat = 12 + 76, w = (bounds.width - x0 - 12 - 16) / 2
        if p.y < Widget.header {
            if p.x >= x0 + w + 16 { return (Tip("Memory in use"), NSRect(x: x0 + w + 16, y: 0, width: w, height: Widget.header)) }
            if p.x >= x0 { return (Tip("Share of the whole Mac's processing power").adding("\(s.cores) cores together are 100%"), NSRect(x: x0, y: 0, width: w, height: Widget.header)) }
            return nil
        }
        let i = Int((p.y - Widget.header) / Widget.line)
        let tips = [
            Tip("Claude Code, every account").adding(s.claudeCount == 1 ? "1 process, sessions and their tools together" : "\(s.claudeCount) processes, sessions and their tools together"),
            Tip("Maxwell itself"),
            Tip("The whole Mac").adding("\(s.cores) cores, \(Self.gb(s.memTotal)) GB memory"),
        ]
        guard tips.indices.contains(i) else { return nil }
        return (tips[i], NSRect(x: 0, y: Widget.header + CGFloat(i) * Widget.line, width: bounds.width, height: Widget.line))
    }

    override func draw(_ r: NSRect) {
        drawWidgetHeader("SYSTEM", in: self, theme: t)
        guard let s = sample else {
            Text.draw("Measuring…", in: NSRect(x: 12, y: Widget.header, width: 200, height: Widget.line), color: t.fg3, font: Fonts.mono(Metrics.fontSize - 2))
            return
        }
        let rows: [(String, String, Double, UInt64)] = [
            ("claude", "\(s.claudeCount)", s.claudeCPU, s.claudeMem),
            ("maxwell", "", s.selfCPU, s.selfMem),
            ("machine", "", s.machineCPU, s.memUsed),
        ]
        let x0: CGFloat = 12 + 76
        let w = (bounds.width - x0 - 12 - 16) / 2
        let small = Fonts.mono(Metrics.fontSize - 2)
        let head = Fonts.mono(Metrics.fontSize - 2.5, .medium)
        Text.draw("CPU", in: NSRect(x: x0, y: 0, width: w, height: Widget.header), color: t.fg3, font: head)
        // The header's right end holds the panel buttons (… — ^ ×); the label never runs under them.
        let memX = x0 + w + 16, memRoom = bounds.width - 100 - memX
        let memLabel = memRoom >= Text.width("MEMORY", font: head) ? "MEMORY" : "MEM"
        if memRoom >= Text.width(memLabel, font: head) {
            Text.draw(memLabel, in: NSRect(x: memX, y: 0, width: memRoom, height: Widget.header), color: t.fg3, font: head)
        }
        for (i, (name, count, cpu, mem)) in rows.enumerated() {
            let y = Widget.header + CGFloat(i) * Widget.line
            let nw = Text.draw(name, in: NSRect(x: 12, y: y, width: 70, height: Widget.line), color: t.fg2, font: Fonts.mono(Metrics.fontSize - 1))
            if !count.isEmpty { Text.draw(count, in: NSRect(x: 12 + nw + 5, y: y, width: 30, height: Widget.line), color: t.fg3, font: small) }
            bar(cpu, label: String(format: cpu < 10 ? "%.1f%%" : "%.0f%%", cpu), labelWidth: Text.width("100.0%", font: small), in: NSRect(x: x0, y: y, width: w, height: Widget.line))
            let memPct = Double(mem) / Double(max(1, s.memTotal)) * 100
            let label = i == 2 ? "\(Self.gb(mem))/\(Self.gb(s.memTotal)) GB" : mem > 1 << 30 ? "\(Self.gb(mem)) GB" : "\(mem >> 20) MB"
            bar(memPct, label: label, labelWidth: Text.width("88.8/88.8 GB", font: small), in: NSRect(x: x0 + w + 16, y: y, width: w, height: Widget.line))
        }
    }

    private func bar(_ pct: Double, label: String, labelWidth lw: CGFloat, in r: NSRect) {
        let b = NSRect(x: r.minX, y: r.midY - 1, width: max(12, r.width - lw - 6), height: 2)
        Meter.draw(pct, in: b, theme: t)
        Text.draw(label, in: NSRect(x: r.maxX - lw, y: r.minY, width: lw, height: r.height), color: pct >= 80 ? t.fg : t.fg2, font: Fonts.mono(Metrics.fontSize - 2), align: .right)
    }

    static func gb(_ b: UInt64) -> String { String(format: "%.1f", Double(b) / Double(1 << 30)) }
}

struct SystemSample {
    var claudeCount = 0
    var claudeCPU = 0.0      // % of the whole machine
    var claudeMem: UInt64 = 0
    var selfCPU = 0.0
    var selfMem: UInt64 = 0
    var machineCPU = 0.0
    var memUsed: UInt64 = 0
    var memTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    var cores = ProcessInfo.processInfo.activeProcessorCount
}

/// Reads `ps` for the Claude processes and the kernel for the machine, off the main thread.
final class SystemSampler {
    private let queue = DispatchQueue(label: "maxwell.system", qos: .utility)
    private var lastTicks: (busy: UInt64, total: UInt64)?

    func take(_ done: @escaping (SystemSample) -> Void) {
        queue.async {
            var s = SystemSample()
            let me = getpid()
            for line in Self.ps().split(separator: "\n") {
                let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
                guard f.count == 4, let pid = Int32(f[0]), let cpu = Double(f[1]), let rss = UInt64(f[2]) else { continue }
                let comm = String(f[3])
                if pid == me { s.selfCPU = cpu / Double(s.cores) }
                if (comm as NSString).lastPathComponent == "claude" || comm.contains("/claude/versions/") {
                    s.claudeCount += 1
                    s.claudeCPU += cpu / Double(s.cores)
                    s.claudeMem += rss * 1024
                }
            }
            s.selfMem = Self.footprint()
            s.memUsed = Self.memoryUsed()
            let ticks = Self.cpuTicks()
            if let last = self.lastTicks, ticks.total > last.total {
                s.machineCPU = Double(ticks.busy - last.busy) / Double(ticks.total - last.total) * 100
            }
            self.lastTicks = ticks
            DispatchQueue.main.async { done(s) }
        }
    }

    private static func ps() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-Ao", "pid=,%cpu=,rss=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// What Activity Monitor calls Memory Used: app memory + wired + compressed.
    private static func memoryUsed() -> UInt64 {
        var vm = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vm) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) } }
        guard kr == KERN_SUCCESS else { return 0 }
        let page = UInt64(vm_kernel_page_size)
        let app = UInt64(vm.internal_page_count) - UInt64(vm.purgeable_count)
        return (app + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * page
    }

    private static func cpuTicks() -> (busy: UInt64, total: UInt64) {
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        var cpus: natural_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpus, &info, &count) == KERN_SUCCESS, let info else { return (0, 0) }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.size)) }
        var busy: UInt64 = 0, total: UInt64 = 0
        for c in 0..<Int(cpus) {
            let base = c * Int(CPU_STATE_MAX)
            let user = UInt64(info[base + Int(CPU_STATE_USER)]), sys = UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(info[base + Int(CPU_STATE_NICE)]), idle = UInt64(info[base + Int(CPU_STATE_IDLE)])
            busy += user + sys + nice
            total += user + sys + nice + idle
        }
        return (busy, total)
    }
}

extension ViewerPane: PanelContent {
    var gripRect: NSRect { NSRect(x: 0, y: 0, width: max(0, bounds.width - headerButtonsWidth - 6), height: Metrics.header) }
    var controlsInset: CGFloat { headerButtonsWidth }
    func preferredExtent(along d: Dock) -> CGFloat? { nil }
}

extension Sidebar: PanelContent {
    var gripRect: NSRect { NSRect(x: 0, y: headerTop, width: max(0, bounds.width - 64), height: Metrics.header) }
    func preferredExtent(along d: Dock) -> CGFloat? { nil }
}
