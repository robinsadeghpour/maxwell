import Darwin
import Foundation

/// Reads `ps` for every process and the kernel for the machine, off the main thread.
/// `/bin/ps` runs as root, so it sees processes of every user: the machine's share stays whole.
final class SystemSampler {
    private let queue = DispatchQueue(label: "maxwell.system", qos: .utility)
    private var lastTicks: (busy: UInt64, total: UInt64)?

    /// `sessions`: the running sessions' Claude Code processes, read on the main thread by the caller.
    func take(sessions: [ProcessID: SessionID], _ done: @escaping (SystemSample) -> Void) {
        queue.async {
            var s = SystemSample()
            let procs = SystemUsage.parse(ps: ClaudeCLI.run("/bin/ps", ["-Ao", "pid=,ppid=,%cpu=,rss=,comm="], timeout: 5).out)
            (s.sessions, s.otherClaude) = SystemUsage.split(procs, sessions: sessions, cores: s.cores)
            if let me = procs.first(where: { $0.pid.raw == getpid() }) { s.maxwell.add(me, cores: s.cores) }
            s.maxwell.memory = Self.footprint()
            s.memUsed = Self.memoryUsed()
            s.pressure = MemoryPressure(level: Self.pressureLevel())
            let ticks = Self.cpuTicks()
            if let last = self.lastTicks, ticks.total > last.total {
                s.machineCPU = Double(ticks.busy - last.busy) / Double(ticks.total - last.total) * 100
            }
            self.lastTicks = ticks
            DispatchQueue.main.async { done(s) }
        }
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

    private static func pressureLevel() -> Int32? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 ? level : nil
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
