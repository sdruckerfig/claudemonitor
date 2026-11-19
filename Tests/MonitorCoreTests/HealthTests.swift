import Foundation
import Testing
@testable import MonitorCore

private func level(_ title: String, _ m: SystemMetrics) -> Level? {
    Health.hardware(m).first { $0.title == title }?.level
}

@Test func healthyMachineIsGreen() {
    let statuses = Health.hardware(metrics())
    #expect(Health.rollup(statuses) == .green)
    #expect(statuses.allSatisfy { $0.reason == nil })
}

/// The three states observed on 2026-11-19: load 157, 37 and 4 on 16 cores.
@Test func cpuLoadBands() {
    #expect(level("CPU", metrics(load: 157)) == .red)
    #expect(level("CPU", metrics(load: 37)) == .yellow)
    #expect(level("CPU", metrics(load: 4)) == .green)
}

@Test func memoryPressureMapsToLevels() {
    #expect(level("Memory", metrics(pressure: .warning)) == .yellow)
    #expect(level("Memory", metrics(pressure: .critical)) == .red)
    #expect(level("Memory", metrics(pressure: .unknown)) == .green)
}

@Test func swapActivityOutranksSwapSize() {
    #expect(level("Swap", metrics(swapUsedGB: 1, swapMBps: 80)) == .red)
    #expect(level("Swap", metrics(swapUsedGB: 1, swapMBps: 10)) == .yellow)
    #expect(level("Swap", metrics(swapUsedGB: 19, swapMBps: 0)) == .yellow)   // 19 GB on 64 GB RAM
    #expect(level("Swap", metrics(swapUsedGB: 4, swapMBps: nil)) == .green)
}

@Test func diskAndThermal() {
    #expect(level("Disk", metrics(diskFreeGB: 3)) == .red)
    #expect(level("Disk", metrics(diskFreeGB: 15)) == .yellow)
    #expect(level("Thermal", metrics(thermal: .serious)) == .yellow)
    #expect(level("Thermal", metrics(thermal: .critical)) == .red)
}

@Test func rollupIsWorstMetricWithReasons() {
    let statuses = Health.hardware(metrics(load: 160, pressure: .warning))
    #expect(Health.rollup(statuses) == .red)
    let reasons = statuses.compactMap(\.reason)
    #expect(reasons.count == 2)
    #expect(reasons[0].contains("10.0×"))
}

@Test func heavySessionIsRedAndNamesTheCulprit() {
    let csc = row(9716, parent: 100, cpu: 900, rssMB: 4800, path: "/opt/dotnet/csc")
    let r = Health.session(usage(cores: 0.3, children: [csc]), now: fixedNow)
    #expect(r.level == .red)
    #expect(r.reasons.first?.contains("mostly csc") == true)
    #expect(r.reasons.count == 2)   // 9 cores (red) and 5.1 GB (yellow) are both reported
}

@Test func memoryHeavySessionIsYellow() {
    let r = Health.session(usage(rssMB: 5000), now: fixedNow)
    #expect(r.level == .yellow)
}

@Test func waitingSessionNeedsAttentionAfterThreshold() {
    let fresh = Health.session(usage(record: record(100, status: .waiting, statusAgo: 120)), now: fixedNow)
    #expect(fresh.level == .green)
    let old = Health.session(usage(record: record(100, status: .waiting, statusAgo: 3600, waitingFor: "dialog open")), now: fixedNow)
    #expect(old.level == .yellow)
    #expect(old.reasons == ["Waiting on you for 1h (dialog open)"])
}

@Test func longIdleSessionIsStaleButHealthy() {
    let r = Health.session(usage(record: record(100, status: .idle, statusAgo: 3 * 86400)), now: fixedNow)
    #expect(r.isStale)
    #expect(r.level == .green)
}

@Test func stoppedProcessIsRed() {
    #expect(Health.session(usage(state: "T"), now: fixedNow).level == .red)
}

@Test func snapshotOrdersMostUrgentFirst() {
    let processes = [
        row(1, parent: 0, path: "/sbin/launchd"),
        row(10, parent: 1, path: "claude"),
        row(20, parent: 1, path: "claude"),
        row(30, parent: 1, path: "claude"),
        row(31, parent: 30, cpu: 800, path: "csc"),
        row(40, parent: 1, path: "claude"),
    ]
    let records = [
        record(10, name: "stale", status: .idle, statusAgo: 5 * 86400),
        record(20, name: "busy", status: .busy),
        record(30, name: "hog", status: .busy),
        record(40, name: "waiting", status: .waiting, statusAgo: 60),
    ]
    let s = Snapshot.assemble(system: metrics(), processes: processes, records: records, now: fixedNow)
    #expect(s.sessions.map(\.usage.record.name) == ["hog", "waiting", "busy", "stale"])
}
