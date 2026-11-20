import Foundation
import Testing
@testable import MonitorCore

private let bashTool = "/bin/zsh -c source /Users/x/.claude/shell-snapshots/snapshot-zsh-1.sh && eval 'tail -f log'"
private let days3: TimeInterval = 3 * 86_400

/// A stale session with what it started (a command, a server, an MCP server, a tmux holding the
/// user's editor) beside a live session with a dev server.
private let processes: [ProcessRow] = [
    row(1, parent: 0, path: "/sbin/launchd", mine: false),
    row(500, parent: 1, path: "claude", args: "claude", elapsed: 300_000),
    row(501, parent: 500, path: "/bin/zsh", args: bashTool, session: "old"),
    row(502, parent: 501, path: "/usr/bin/tail", args: "tail -f log", session: "old"),
    row(507, parent: 500, rssMB: 80, path: "node", args: "node /p/node_modules/.bin/mcp-server", session: "old"),
    row(506, parent: 1, path: "node", args: "node server.js", ports: [3000], session: "old"),   // detached server
    row(503, parent: 1, path: "/opt/homebrew/bin/tmux", args: "tmux new -d", session: "old"),
    row(504, parent: 503, path: "/bin/zsh", args: "-zsh", session: "old"),
    row(505, parent: 504, path: "/usr/bin/vim", args: "vim notes.md", session: "old"),
    row(600, parent: 1, path: "claude", args: "claude", elapsed: 9_000),
    row(601, parent: 600, path: "node", args: "node /w/node_modules/.bin/vite --port 5173", ports: [5173], session: "live"),
]

private let records = [
    record(500, id: "old", name: "Old docs", status: .idle, statusAgo: days3),
    record(600, id: "live", name: "Web", status: .busy, statusAgo: 30),
]

private func snapshot(_ rows: [ProcessRow] = processes, _ recs: [SessionRecord] = records) -> Snapshot {
    Snapshot.assemble(system: metrics(), processes: rows, records: recs, launchdJobs: [], now: fixedNow)
}

@Test func staleSessionsTakeWhatTheyStartedButNotTheUsersTmux() throws {
    let plan = CleanupPlan(snapshot: snapshot(), worktrees: [], selfPid: 99_999)
    #expect(plan.staleSessions.map(\.record.name) == ["Old docs"])
    let job = try #require(plan.staleSessionJobs.first)
    #expect(plan.staleSessionJobs.count == 1)
    #expect(job.roots.map(\.pid) == [501, 507])
    #expect(Set(job.members.map(\.pid)) == [501, 502, 507])          // not tmux, its shell or vim
    #expect(job.owner == .session(pid: 500, name: "Old docs"))
    // The detached server is a service; it isn't stopped twice.
    #expect(plan.services.contains { $0.root.pid == 506 })
    #expect(!plan.staleSessionJobs.flatMap(\.members).contains { $0.pid == 506 })
}

@Test func onlyServersSomethingStillRunningUsesAreFlaggedAsInUse() {
    let plan = CleanupPlan(snapshot: snapshot(), worktrees: [], selfPid: 99_999)
    #expect(Set(plan.services.map(\.root.pid)) == [506, 601])
    // vite belongs to the live session; the stale session's server goes with it.
    #expect(plan.servicesInUse.map(\.root.pid) == [601])
}

@Test func jobsAlreadyBeingStoppedAreLeftOut() {
    let plan = CleanupPlan(snapshot: snapshot(), worktrees: [], skipping: [601], selfPid: 99_999)
    #expect(plan.services.map(\.root.pid) == [506])
}

@Test func nothingToCleanUpIsEmpty() {
    let quiet = snapshot([row(1, parent: 0, path: "/sbin/launchd", mine: false),
                          row(600, parent: 1, path: "claude", args: "claude", elapsed: 9_000)],
                         [record(600, id: "live", name: "Web", status: .busy, statusAgo: 30)])
    let plan = CleanupPlan(snapshot: quiet, worktrees: [], selfPid: 99_999)
    #expect(plan.isEmpty)
    #expect(plan.processCount == 0)
}

/// The dialog for the README's demo data: what each line promises, and the totals.
@Test func summaryForTheDemoData() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let plan = CleanupPlan(snapshot: DemoData.snapshot(now: now), worktrees: DemoData.worktreeScan(now: now).reclaimable,
                           selfPid: 99_999)
    let lines = plan.summary
    print(lines.joined(separator: "\n"))
    #expect(lines[0] == "• Stop 3 processes left behind by closed sessions.")
    #expect(lines[1] == "• Stop 3 servers and build daemons. 2 may be in use: vite :5173 (session “Checkout redesign”), "
                       + "postgres :5432 (session “API rate limiting”).")
    #expect(lines[2] == "• End 1 stale Claude session: “Docs cleanup”. Resume later with claude --resume.")
    #expect(lines[3] == "• Delete 3 reclaimable worktrees (2.2 GB).")
    #expect(lines[4].isEmpty)
    #expect(lines[5].hasPrefix("Frees about 2.5 GB of memory and 2.2 GB of disk. "))
    #expect(lines[5].hasSuffix("Branches are kept."))
    #expect(plan.processCount == 6)
}
