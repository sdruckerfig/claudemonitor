import Darwin
import Foundation

/// Reads live hardware metrics. Not thread-safe: call from one serial queue,
/// because swap throughput is measured as a delta between consecutive samples.
public final class SystemSampler {
    private var lastSwap: (pages: UInt64, at: Date)?
    private let diskPath: String

    public init(diskPath: String = NSHomeDirectory()) {
        self.diskPath = diskPath
    }

    public func sample(now: Date = Date()) -> SystemMetrics {
        var load = [Double](repeating: 0, count: 3)
        _ = getloadavg(&load, 3)

        let swap = swapUsage()
        var swapRate: Double?
        if let pages = swapPages() {
            if let last = lastSwap, now > last.at, pages >= last.pages {
                swapRate = Double(pages - last.pages) * Double(vm_kernel_page_size) / now.timeIntervalSince(last.at)
            }
            lastSwap = (pages, now)
        }

        return SystemMetrics(
            load: load,
            cpuCount: ProcessInfo.processInfo.activeProcessorCount,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            memoryPressure: memoryPressure(),
            memoryFreePercent: sysctlInt32("kern.memorystatus_level").map(Int.init),
            swapUsedBytes: swap?.used ?? 0,
            swapTotalBytes: swap?.total ?? 0,
            swapBytesPerSecond: swapRate,
            diskFreeBytes: diskFree(),
            thermal: thermal())
    }

    private func memoryPressure() -> MemoryPressure {
        switch sysctlInt32("kern.memorystatus_vm_pressure_level") {
        case 1: return .normal
        case 2: return .warning
        case 4: return .critical
        default: return .unknown
        }
    }

    private func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }

    private func swapUsage() -> (used: UInt64, total: UInt64)? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return (usage.xsu_used, usage.xsu_total)
    }

    /// Cumulative pages swapped in + out since boot.
    private func swapPages() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return stats.swapins + stats.swapouts
    }

    private func diskFree() -> Int64? {
        var fs = statfs()
        guard statfs(diskPath, &fs) == 0 else { return nil }
        return Int64(fs.f_bavail) * Int64(fs.f_bsize)
    }

    private func thermal() -> Thermal {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }
}
