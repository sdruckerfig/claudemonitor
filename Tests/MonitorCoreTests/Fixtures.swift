import Foundation
@testable import MonitorCore

/// A process row. Unless `mine` is false it belongs to the current user, as the inspector would report.
func row(_ pid: Int32, parent: Int32, cpu: Double = 0, rssMB: Int64 = 10, path: String, args: String? = nil,
         state: String = "S", elapsed: Int = 60, ports: [UInt16] = [], cwd: String? = nil,
         session: String? = nil, claudePid: Int32? = nil, codexThread: String? = nil, mine: Bool = true) -> ProcessRow {
    ProcessRow(pid: pid, ppid: parent, cpuPercent: cpu, rssKB: rssMB * 1024, elapsedSeconds: elapsed,
               state: state, executablePath: path, args: args ?? path,
               details: ProcessDetails(ownedByUser: mine, cwd: cwd, listeningPorts: ports,
                                       claudeSessionId: session, claudePid: claudePid, codexThreadId: codexThread))
}

func record(_ pid: Int32, id: String? = nil, name: String = "s", status: SessionStatus = .idle,
            statusAgo: TimeInterval = 60, now: Date = fixedNow, waitingFor: String? = nil) -> SessionRecord {
    SessionRecord(pid: pid, sessionId: id, name: name, cwd: "/Users/x/proj", status: status,
                  statusUpdatedAt: now.addingTimeInterval(-statusAgo), startedAt: nil, waitingFor: waitingFor)
}

let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
let gib: UInt64 = 1_073_741_824

func metrics(load: Double = 4, cpus: Int = 16, pressure: MemoryPressure = .normal, swapUsedGB: Double = 1,
             swapMBps: Double? = 0, diskFreeGB: Double = 200, thermal: Thermal = .nominal) -> SystemMetrics {
    SystemMetrics(load: [load, load, load], cpuCount: cpus, physicalMemoryBytes: 64 * gib,
                  memoryPressure: pressure, memoryFreePercent: 60,
                  swapUsedBytes: UInt64(swapUsedGB * Double(gib)), swapTotalBytes: 32 * gib,
                  swapBytesPerSecond: swapMBps.map { $0 * 1_048_576 },
                  diskFreeBytes: Int64(diskFreeGB * Double(gib)), thermal: thermal)
}

func usage(cores: Double = 0, rssMB: Int64 = 300, state: String = "S", record r: SessionRecord = record(100),
           children: [ProcessRow] = []) -> SessionUsage {
    SessionUsage(record: r, process: row(r.pid, parent: 1, cpu: cores * 100, rssMB: rssMB, path: "claude", state: state),
                 descendants: children, detachedPids: [])
}
