import Foundation

public enum Level: Int, Comparable, Sendable {
    case green = 0, yellow, red
    public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
}

public enum MemoryPressure: Sendable { case normal, warning, critical, unknown }
public enum Thermal: Sendable { case nominal, fair, serious, critical }

/// Raw hardware readings; produced by `SystemSampler`.
public struct SystemMetrics: Sendable {
    public var load: [Double]            // 1, 5, 15 minute load averages
    public var cpuCount: Int
    public var physicalMemoryBytes: UInt64
    public var memoryPressure: MemoryPressure
    public var memoryFreePercent: Int?
    public var swapUsedBytes: UInt64
    public var swapTotalBytes: UInt64
    /// Swap-in plus swap-out traffic since the previous sample; nil on the first sample.
    public var swapBytesPerSecond: Double?
    public var diskFreeBytes: Int64?
    public var thermal: Thermal

    public init(load: [Double], cpuCount: Int, physicalMemoryBytes: UInt64, memoryPressure: MemoryPressure,
                memoryFreePercent: Int?, swapUsedBytes: UInt64, swapTotalBytes: UInt64,
                swapBytesPerSecond: Double?, diskFreeBytes: Int64?, thermal: Thermal) {
        self.load = load
        self.cpuCount = cpuCount
        self.physicalMemoryBytes = physicalMemoryBytes
        self.memoryPressure = memoryPressure
        self.memoryFreePercent = memoryFreePercent
        self.swapUsedBytes = swapUsedBytes
        self.swapTotalBytes = swapTotalBytes
        self.swapBytesPerSecond = swapBytesPerSecond
        self.diskFreeBytes = diskFreeBytes
        self.thermal = thermal
    }

    public var loadPerCore: Double { (load.first ?? 0) / Double(max(cpuCount, 1)) }
}

/// Every threshold in one place. Defaults were tuned against a 16-core / 64 GB machine
/// where a 1-minute load of ~160 (10x cores) and 25 GB of swap was "overloaded".
public struct Thresholds: Sendable {
    public var loadPerCoreYellow = 1.5
    public var loadPerCoreRed = 3.0
    public var swapRateYellowMBps = 5.0
    public var swapRateRedMBps = 50.0
    /// Swap in use as a fraction of physical RAM.
    public var swapUsedYellowFraction = 0.25
    public var diskFreeYellowGB = 20.0
    public var diskFreeRedGB = 5.0
    public var sessionCoresYellow = 2.0
    public var sessionCoresRed = 6.0
    public var sessionMemoryYellowGB = 4.0
    public var sessionMemoryRedGB = 10.0
    public var waitingYellowMinutes = 10.0
    public var staleIdleHours = 24.0

    public init() {}
}

public struct MetricStatus: Equatable, Sendable {
    public let title: String
    public let value: String
    public let level: Level
    /// Why the level is not green; nil when green.
    public let reason: String?
}

public struct SessionReport: Sendable {
    public let usage: SessionUsage
    public let level: Level
    public let reasons: [String]
    /// Idle for longer than `staleIdleHours`: a candidate for closing.
    public let isStale: Bool
    public let statusAge: TimeInterval?
}

public enum Health {
    public static func hardware(_ m: SystemMetrics, _ t: Thresholds = Thresholds()) -> [MetricStatus] {
        var out: [MetricStatus] = []

        let ratio = m.loadPerCore
        let loadLevel: Level = ratio >= t.loadPerCoreRed ? .red : ratio >= t.loadPerCoreYellow ? .yellow : .green
        let loads = m.load.prefix(3).map { String(format: "%.0f", $0) }.joined(separator: " / ")
        out.append(MetricStatus(
            title: "CPU",
            value: String(format: "%.1f× cores", ratio) + " · load \(loads) on \(m.cpuCount)",
            level: loadLevel,
            reason: loadLevel == .green ? nil
                : String(format: "CPU oversubscribed %.1f× (load %.0f on %d cores)", ratio, m.load.first ?? 0, m.cpuCount)))

        let memLevel: Level = switch m.memoryPressure {
        case .critical: .red
        case .warning: .yellow
        default: .green
        }
        let pressureName = switch m.memoryPressure {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        case .unknown: "Unknown"
        }
        out.append(MetricStatus(
            title: "Memory",
            value: pressureName + (m.memoryFreePercent.map { " · \($0)% free" } ?? ""),
            level: memLevel,
            reason: memLevel == .green ? nil : "Memory pressure \(pressureName.lowercased())"))

        let rateMB = (m.swapBytesPerSecond ?? 0) / 1_048_576
        let usedFraction = Double(m.swapUsedBytes) / Double(max(m.physicalMemoryBytes, 1))
        var swapLevel: Level = .green
        var swapReason: String?
        if rateMB >= t.swapRateRedMBps {
            swapLevel = .red
            swapReason = String(format: "Thrashing: swapping %.0f MB/s", rateMB)
        } else if rateMB >= t.swapRateYellowMBps {
            swapLevel = .yellow
            swapReason = String(format: "Swapping %.0f MB/s", rateMB)
        } else if usedFraction >= t.swapUsedYellowFraction {
            swapLevel = .yellow
            swapReason = "\(Format.bytes(m.swapUsedBytes)) swap in use. Quit idle apps or reboot to reclaim it"
        }
        out.append(MetricStatus(
            title: "Swap",
            value: "\(Format.bytes(m.swapUsedBytes)) used" + (m.swapBytesPerSecond.map { " · " + String(format: "%.1f MB/s", $0 / 1_048_576) } ?? ""),
            level: swapLevel, reason: swapReason))

        if let free = m.diskFreeBytes {
            let gb = Double(free) / 1_073_741_824
            let level: Level = gb < t.diskFreeRedGB ? .red : gb < t.diskFreeYellowGB ? .yellow : .green
            out.append(MetricStatus(title: "Disk", value: "\(Format.bytes(free)) free", level: level,
                                    reason: level == .green ? nil : "Low disk: \(Format.bytes(free)) free"))
        }

        let (thermalLevel, thermalName): (Level, String) = switch m.thermal {
        case .nominal: (.green, "Nominal")
        case .fair: (.green, "Fair")
        case .serious: (.yellow, "Serious")
        case .critical: (.red, "Critical")
        }
        out.append(MetricStatus(title: "Thermal", value: thermalName, level: thermalLevel,
                                reason: thermalLevel == .green ? nil : "Thermal state \(thermalName.lowercased()): CPU is being throttled"))
        return out
    }

    public static func rollup(_ statuses: [MetricStatus]) -> Level {
        statuses.map(\.level).max() ?? .green
    }

    public static func session(_ u: SessionUsage, now: Date, _ t: Thresholds = Thresholds()) -> SessionReport {
        var level: Level = .green
        var reasons: [String] = []
        func flag(_ l: Level, _ why: String) {
            level = max(level, l)
            reasons.append(why)
        }

        let cores = u.totalCores
        if cores >= t.sessionCoresRed {
            flag(.red, "Using \(Format.cores(cores))" + (u.topChild.map { ", mostly \($0.name)" } ?? ""))
        } else if cores >= t.sessionCoresYellow {
            flag(.yellow, "Using \(Format.cores(cores))" + (u.topChild.map { ", mostly \($0.name)" } ?? ""))
        }

        let gb = Double(u.totalRSSBytes) / 1_073_741_824
        if gb >= t.sessionMemoryRedGB {
            flag(.red, "Holding \(Format.bytes(u.totalRSSBytes)) of memory")
        } else if gb >= t.sessionMemoryYellowGB {
            flag(.yellow, "Holding \(Format.bytes(u.totalRSSBytes)) of memory")
        }

        let state = u.process.state
        if state.hasPrefix("T") { flag(.red, "Process is stopped (suspended)") }
        if state.hasPrefix("Z") { flag(.red, "Process is a zombie") }

        let age = u.record.statusUpdatedAt.map { now.timeIntervalSince($0) }
        if u.record.status == .waiting, let age, age >= t.waitingYellowMinutes * 60 {
            let what = u.record.waitingFor.map { " (\($0))" } ?? ""
            flag(.yellow, "Waiting on you for \(Format.duration(age))\(what)")
        }

        let stale = u.record.status == .idle && (age ?? 0) >= t.staleIdleHours * 3600
        return SessionReport(usage: u, level: level, reasons: reasons, isStale: stale, statusAge: age)
    }
}
