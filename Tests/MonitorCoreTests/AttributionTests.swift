import Foundation
import Testing
@testable import MonitorCore

/// A process tree shaped like the real ones: Bash-tool shells under claude, a nested claude,
/// a detached background job, a job left behind by a closed session, and unrelated apps.
private let tree: [ProcessRow] = [
    row(1, parent: 0, path: "/sbin/launchd"),
    row(100, parent: 1, cpu: 5, path: "claude", args: "claude --dangerously-skip-permissions"),
    row(101, parent: 100, path: "/bin/zsh", args: "/bin/zsh -c source /Users/x/.claude/shell-snapshots/s.sh && dotnet test"),
    row(102, parent: 101, cpu: 300, rssMB: 2000, path: "/opt/homebrew/bin/dotnet", args: "dotnet test"),
    row(103, parent: 101, cpu: 2, path: "claude", args: "claude -p hello"),          // its own session
    row(104, parent: 103, cpu: 50, path: "/usr/bin/node", args: "node script.js"),
    row(300, parent: 1, path: "/bin/zsh",
        args: "zsh -c run > /private/tmp/claude-501/-Users-x/aaaa-1111/scratchpad/build.txt"),
    row(301, parent: 300, cpu: 90, path: "/usr/bin/lockf", args: "lockf -k /tmp/x.lock make"),
    row(400, parent: 1, path: "/bin/zsh", args: "/bin/zsh -c source /Users/x/.claude/shell-snapshots/old.sh && vite"),
    row(401, parent: 400, cpu: 10, rssMB: 400, path: "/usr/local/bin/node", args: "node vite --port 5173"),
    row(500, parent: 1, cpu: 40, rssMB: 900, path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
]

private let records = [
    record(100, id: "aaaa-1111", name: "A", status: .busy),
    record(103, id: "bbbb-2222", name: "B", status: .busy),
    record(600, id: "dead-0000", name: "exited"),     // status file outlived its process
    record(500, id: "reused-pid", name: "stale"),     // pid now belongs to Chrome
]

@Test func attributesTreeDetachedJobsAndOrphans() throws {
    let a = Attribution.build(processes: tree, records: records)
    #expect(Set(a.sessions.map(\.process.pid)) == [100, 103])

    let sessionA = try #require(a.sessions.first { $0.process.pid == 100 })
    #expect(Set(sessionA.descendants.map(\.pid)) == [101, 102, 300, 301])
    #expect(sessionA.detachedPids == [300, 301])
    #expect(sessionA.topChild?.pid == 102)
    #expect(abs(sessionA.totalCores - 3.95) < 0.001)

    let sessionB = try #require(a.sessions.first { $0.process.pid == 103 })
    #expect(sessionB.descendants.map(\.pid) == [104])

    #expect(Set(a.orphans.map(\.pid)) == [400, 401])
    #expect(Set(a.other.map(\.pid)) == [1, 500])
}

@Test func recognisesNpmInstalledClaude() {
    #expect(Attribution.isClaude(row(1, parent: 0, path: "/usr/local/bin/node", args: "node /usr/local/bin/claude")))
    #expect(!Attribution.isClaude(row(1, parent: 0, path: "/usr/local/bin/node", args: "node vite")))
}

@Test func groupsProcessesByApp() {
    let chromeHelper = "/Applications/Google Chrome.app/Contents/Frameworks/GC.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
    let rows = [
        row(1, parent: 0, cpu: 10, path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
        row(2, parent: 1, cpu: 20, path: chromeHelper),
        row(3, parent: 0, cpu: 5, path: "/Library/Developer/CoreSimulator/Volumes/iOS/Runtimes/iOS 26.5.simruntime/Contents/Resources/RuntimeRoot/usr/libexec/foo"),
        row(4, parent: 0, cpu: 1, path: "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/VM.xpc/Contents/MacOS/VM"),
        row(5, parent: 0, cpu: 1, path: "/opt/homebrew/bin/dotnet"),
    ]
    let groups = Dictionary(uniqueKeysWithValues: Attribution.groups(rows).map { ($0.name, $0) })
    #expect(groups["Google Chrome"]?.count == 2)
    #expect(abs((groups["Google Chrome"]?.cores ?? 0) - 0.3) < 0.001)
    #expect(groups["Simulators"]?.count == 1)
    #expect(groups["Virtual machines"]?.count == 1)
    #expect(groups["dotnet"]?.count == 1)
}
