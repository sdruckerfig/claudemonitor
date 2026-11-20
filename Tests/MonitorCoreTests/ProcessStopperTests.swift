import Darwin
import Foundation
import Testing
@testable import MonitorCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let t1 = t0.addingTimeInterval(30)   // the fresh table is 30 s newer

@Test func planRechecksIdentityAndStaysInsideTheJob() {
    let job = [
        row(10, parent: 1, path: "/bin/zsh", args: "zsh -c npm run dev", elapsed: 100),
        row(11, parent: 10, path: "npm", args: "npm run dev", elapsed: 99),
        row(20, parent: 1, path: "/usr/bin/tail", args: "tail -f log", elapsed: 500),
    ]
    let fresh = [
        row(10, parent: 1, path: "/bin/zsh", args: "zsh -c npm run dev", elapsed: 130),   // same process
        // 11 exited; 12 is new since the snapshot and is stopped with its parent.
        row(12, parent: 10, path: "node", args: "node vite", elapsed: 5),
        row(13, parent: 12, path: "/bin/zsh", args: "-zsh", elapsed: 4),                  // an interactive shell...
        row(14, parent: 13, path: "/usr/bin/vim", args: "vim", elapsed: 3),               // ...and what's in it
        row(15, parent: 12, path: "claude", args: "claude -p hi", elapsed: 3),            // never claude
        row(16, parent: 12, path: "/usr/bin/sleep", args: "sleep 9", elapsed: 2, mine: false),
        row(20, parent: 1, path: "/usr/bin/tail", args: "tail -f log", elapsed: 5),       // pid reused
        row(30, parent: 1, path: "/usr/bin/yes", elapsed: 1000),                           // not in the job
    ]
    let plan = ProcessStopper.plan(members: job, takenAt: t0, fresh: fresh, freshTakenAt: t1, selfPid: 99_999)
    #expect(plan.map(\.pid) == [10, 12])
}

@Test func planNeverIncludesThisProcess() {
    let me = getpid()
    let job = [row(me, parent: 1, path: "/usr/bin/swift", elapsed: 10)]
    let fresh = [row(me, parent: 1, path: "/usr/bin/swift", elapsed: 40)]
    #expect(ProcessStopper.plan(members: job, takenAt: t0, fresh: fresh, freshTakenAt: t1).isEmpty)
}

@Test func samenessAllowsForPsResolution() {
    let a = row(5, parent: 1, path: "x", elapsed: 100)
    #expect(ProcessStopper.isSame(a, takenAt: t0, as: row(5, parent: 1, path: "x", elapsed: 131), takenAt: t1))
    #expect(!ProcessStopper.isSame(a, takenAt: t0, as: row(5, parent: 1, path: "x", elapsed: 140), takenAt: t1))
    #expect(!ProcessStopper.isSame(a, takenAt: t0, as: row(6, parent: 1, path: "x", elapsed: 130), takenAt: t1))
}

/// Starts `sh` running two sleeps, plans against the live process table, and stops it.
@Test func stopsALiveProcessTreeAndNothingElse() throws {
    let sh = Process()
    sh.executableURL = URL(fileURLWithPath: "/bin/sh")
    sh.arguments = ["-c", "/bin/sleep 300 & /bin/sleep 300 & wait"]
    try sh.run()
    defer { if sh.isRunning { kill(sh.processIdentifier, SIGKILL) } }
    let pid = sh.processIdentifier

    let monitor = Monitor()
    var takenAt = Date()
    var table = try monitor.processTable(takenAt: takenAt)
    for _ in 0..<50 where table.filter({ $0.ppid == pid }).count < 2 {   // let both sleeps start
        usleep(100_000)
        takenAt = Date()
        table = try monitor.processTable(takenAt: takenAt)
    }
    let root = try #require(table.first { $0.pid == pid })
    let sleeps = table.filter { $0.ppid == pid }
    #expect(sleeps.count == 2)

    let plan = ProcessStopper.plan(members: [root], takenAt: takenAt, fresh: table, freshTakenAt: takenAt)
    #expect(Set(plan.map(\.pid)) == Set([pid] + sleeps.map(\.pid)))

    let outcome = ProcessStopper.send(SIGTERM, to: plan, takenAt: takenAt)
    #expect(outcome.signalled.count == 3)
    #expect(outcome.failed.isEmpty)
    sh.waitUntilExit()
    var left = plan
    for _ in 0..<50 where !left.isEmpty {
        usleep(100_000)
        left = ProcessStopper.stillRunning(plan, takenAt: takenAt)
    }
    #expect(left.isEmpty)
}

@Test func doesNotSignalAPidThatIsNoLongerTheSameProcess() throws {
    let sleeper = Process()
    sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
    sleeper.arguments = ["300"]
    try sleeper.run()
    defer { sleeper.terminate(); sleeper.waitUntilExit() }
    // A row claiming this pid started an hour ago: by now that pid would be another process.
    let stale = row(sleeper.processIdentifier, parent: getpid(), path: "/bin/sleep", args: "sleep 300", elapsed: 3600)
    let outcome = ProcessStopper.send(SIGTERM, to: [stale], takenAt: Date())
    #expect(outcome.signalled.isEmpty)
    #expect(outcome.gone.map(\.pid) == [sleeper.processIdentifier])
    #expect(sleeper.isRunning)
}
