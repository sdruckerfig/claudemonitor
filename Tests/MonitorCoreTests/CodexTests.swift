import Foundation
import Testing
@testable import MonitorCore

// MARK: Loaded threads

@Test func threadIdComesFromAWriterLockPath() {
    #expect(CodexSessions.threadId(fromLockPath: "/Users/x/.codex/thread-writer-locks/01a1-beef.lock") == "01a1-beef")
    #expect(CodexSessions.threadId(fromLockPath: "/custom/home/thread-writer-locks/abc.lock") == "abc")   // CODEX_HOME
    #expect(CodexSessions.threadId(fromLockPath: "/Users/x/.codex/thread-writer-locks/.coordination.lock") == nil)
    #expect(CodexSessions.threadId(fromLockPath: "/Users/x/.codex/thread-writer-locks/sub/abc.lock") == nil)
    #expect(CodexSessions.threadId(fromLockPath: "/Users/x/.codex/thread-writer-locks/abc.json") == nil)
    #expect(CodexSessions.threadId(fromLockPath: "/Users/x/.codex/sessions/abc.lock") == nil)
}

@Test func codexIsRecognizedByItsExecutable() {
    #expect(CodexSessions.isCodex(row(1, parent: 1, path: "/opt/homebrew/Caskroom/codex/0.169.0/bin/codex")))
    #expect(CodexSessions.isCodex(row(1, parent: 1,
        path: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")))
    #expect(!CodexSessions.isCodex(row(1, parent: 1, path: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex-code-mode-host")))
    #expect(!CodexSessions.isCodex(row(1, parent: 1, path: "/usr/local/bin/node", args: "node /usr/local/lib/codex/bin/codex.js")))
}

private func thread(_ id: String, parent: String? = nil, title: String? = nil, cwd: String? = "/Users/x/app",
                    updatedAgo: TimeInterval = 3600) -> CodexThread {
    CodexThread(id: id, cwd: cwd, title: title, parentId: parent, createdAt: fixedNow.addingTimeInterval(-86400),
                updatedAt: fixedNow.addingTimeInterval(-updatedAgo))
}

@Test func subagentsFoldIntoTheThreadThatSpawnedThem() throws {
    let live: [String: Int32] = ["main": 700, "sub1": 700, "sub2": 700, "other": 800, "orphan-sub": 700]
    let threads = [
        "main": thread("main", title: "Build the thing", updatedAgo: 3600),
        "sub1": thread("sub1", parent: "main", updatedAgo: 10),        // a busy subagent makes it busy
        "sub2": thread("sub2", parent: "sub1", updatedAgo: 7200),      // nested
        "other": thread("other", title: nil, cwd: "/Users/x/api", updatedAgo: 3 * 86400),
        "orphan-sub": thread("orphan-sub", parent: "closed-parent", title: "Lone worker"),
    ]
    let records = CodexSessions.records(live: live, threads: threads, now: fixedNow)
    #expect(records.map(\.sessionId) == ["main", "orphan-sub", "other"])

    let main = try #require(records.first { $0.sessionId == "main" })
    #expect(main.agent == .codex)
    #expect(main.pid == 700)
    #expect(main.name == "Build the thing")
    #expect(main.threadIds == ["main", "sub1", "sub2"])
    #expect(main.subagentCount == 2)
    #expect(main.status == .busy)
    #expect(main.statusUpdatedAt == fixedNow.addingTimeInterval(-10))
    #expect(main.resumeCommand == "cd /Users/x/app && codex resume main")
    #expect(main.key == "codex:main")

    let other = try #require(records.first { $0.sessionId == "other" })
    #expect(other.name == "api")            // untitled: named after its folder
    #expect(other.status == .idle)
    #expect(records.first { $0.sessionId == "orphan-sub" }?.threadIds == ["orphan-sub"])
}

@Test func aThreadMissingFromTheDatabaseIsStillListed() {
    let records = CodexSessions.records(live: ["01a1e434-98f4": 700], threads: [:], now: fixedNow)
    #expect(records.count == 1)
    #expect(records[0].name == "Codex thread 01a1e434")
    #expect(records[0].cwd == nil)
    #expect(records[0].status == .idle)
}

@Test func staleCodexThreadsAreNeverEndedByCleanup() {
    let host = row(700, parent: 1, path: "/opt/homebrew/bin/codex")
    let codex = SessionRecord(agent: .codex, pid: 700, sessionId: "t", name: "Old thread", cwd: "/p", status: .idle,
                              statusUpdatedAt: fixedNow.addingTimeInterval(-3 * 86400), startedAt: nil, waitingFor: nil,
                              threadIds: ["t"])
    let snap = Snapshot.assemble(system: metrics(), processes: [host], records: [codex], launchdJobs: [], now: fixedNow)
    #expect(snap.sessions.first?.isStale == true)
    #expect(CleanupPlan(snapshot: snap, worktrees: []).staleSessions.isEmpty)
}

// MARK: Attribution

/// A Codex app server hosting two threads (one with a subagent), its own MCP helper, a command a
/// thread ran, a server a thread started, and leftovers from a thread that has closed.
private let codexTree: [ProcessRow] = [
    row(1, parent: 0, path: "/sbin/launchd"),
    row(700, parent: 1, cpu: 30, rssMB: 600, path: "/Applications/Codex.app/Contents/Resources/codex",
        args: "/Applications/Codex.app/Contents/Resources/codex app-server"),
    row(701, parent: 700, cpu: 1, path: "/opt/homebrew/bin/node", args: "node mcp-server.js"),       // shared helper
    row(710, parent: 700, path: "/bin/zsh", args: "/bin/zsh -lc npm test", codexThread: "sub-a"),   // subagent's command
    row(711, parent: 710, cpu: 200, rssMB: 1500, path: "/opt/homebrew/bin/node", args: "node node_modules/.bin/vitest run",
        codexThread: "sub-a"),
    row(720, parent: 700, path: "/opt/homebrew/bin/node", args: "node node_modules/vite/bin/vite.js --port 5196",
        ports: [5196], cwd: "/Users/x/web", codexThread: "thread-b"),
    row(730, parent: 1, path: "/bin/zsh",
        args: "/bin/zsh -c source /Users/x/.codex/shell_snapshots/thread-b.123.sh && nohup make watch"),  // detached
    // A closed thread's server, re-parented to launchd: a leftover.
    row(740, parent: 1, path: "/usr/bin/python3", args: "python3 -m http.server 8000", ports: [8000], codexThread: "closed"),
    // A closed thread's command still under the running app server: the server may still own it.
    row(750, parent: 700, path: "/usr/bin/tail", args: "tail -f log", codexThread: "closed"),
    // A Claude session that was started from a Codex thread keeps its own tree.
    row(800, parent: 700, cpu: 5, path: "claude", args: "claude", codexThread: "thread-a"),
    row(801, parent: 800, cpu: 50, path: "/bin/zsh", args: "/bin/zsh -c swift build", codexThread: "thread-a"),
]

private let codexRecords = [
    SessionRecord(agent: .codex, pid: 700, sessionId: "thread-a", name: "A", cwd: "/Users/x/app", status: .busy,
                  statusUpdatedAt: fixedNow, startedAt: nil, waitingFor: nil, threadIds: ["thread-a", "sub-a"]),
    SessionRecord(agent: .codex, pid: 700, sessionId: "thread-b", name: "B", cwd: "/Users/x/web", status: .idle,
                  statusUpdatedAt: fixedNow, startedAt: nil, waitingFor: nil, threadIds: ["thread-b"]),
    record(800, id: "claude-1", name: "Nested claude", status: .busy),
]

@Test func codexThreadsAreChargedForTheirOwnProcessesOnly() throws {
    let a = Attribution.build(processes: codexTree, records: codexRecords)
    #expect(a.sessions.count == 3)

    let threadA = try #require(a.sessions.first { $0.key == "codex:thread-a" })
    #expect(threadA.process.pid == 700)
    #expect(Set(threadA.descendants.map(\.pid)) == [710, 711])     // its subagent's work, not the helper or claude
    #expect(threadA.detachedPids.isEmpty)
    #expect(abs(threadA.totalCores - 2.0) < 0.001)                // the shared host isn't counted
    #expect(threadA.totalRSSBytes == (10 + 1500) * 1_048_576)

    let threadB = try #require(a.sessions.first { $0.key == "codex:thread-b" })
    #expect(Set(threadB.descendants.map(\.pid)) == [720, 730])
    #expect(threadB.detachedPids == [730])

    let claude = try #require(a.sessions.first { $0.record.agent == .claude })
    #expect(claude.descendants.map(\.pid) == [801])

    #expect(a.orphanTrees.map(\.root) == [740])                    // not 750: its codex is still running
    #expect(Set(a.other.map(\.pid)) == [1, 700, 701, 750])
}

@Test func codexJobsNameTheirThreadAndNeverIncludeCodex() throws {
    let a = Attribution.build(processes: codexTree, records: codexRecords)
    let (leftovers, services) = Jobs.build(a, processes: codexTree, launchdJobs: [], selfPid: 99_999)
    #expect(leftovers.map(\.root.pid) == [740])
    let vite = try #require(services.first { $0.root.pid == 720 })
    #expect(vite.owner == .session(pid: 700, name: "B", agent: .codex))
    #expect(vite.ownerText == "Codex thread “B”")
    #expect(!Jobs.isStoppable(codexTree[1]))                       // the app server
    #expect(!Jobs.isStoppable(row(5, parent: 1, path: "/opt/homebrew/bin/codex")))
}

// MARK: State database

/// A throwaway database with the columns Codex uses (and a missing one, `preview`), so the reader
/// is exercised against the real shape without touching ~/.codex.
private func makeStateDB(_ dir: URL, columns: String = "id TEXT PRIMARY KEY, cwd TEXT NOT NULL, title TEXT NOT NULL, name TEXT, source TEXT NOT NULL, created_at INTEGER, updated_at INTEGER, updated_at_ms INTEGER, archived INTEGER NOT NULL DEFAULT 0",
                         rows: [String]) throws {
    let sql = (["CREATE TABLE threads (\(columns));"] + rows).joined(separator: "\n")
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    task.arguments = [dir.appendingPathComponent("state_5.sqlite").path, sql]
    try task.run()
    task.waitUntilExit()
    #expect(task.terminationStatus == 0)
}

@Test func readsThreadsFromTheNewestStateDatabase() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-state-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    FileManager.default.createFile(atPath: dir.appendingPathComponent("state_4.sqlite").path, contents: Data("old".utf8))
    let spawn = #"{"subagent":{"thread_spawn":{"parent_thread_id":"t1","depth":1,"agent_role":"worker"}}}"#
    try makeStateDB(dir, rows: [
        "INSERT INTO threads VALUES ('t1', '/Users/x/app', 'Continue building', NULL, 'vscode', 1800000000, 1800000100, 1800000100500, 0);",
        "INSERT INTO threads VALUES ('t2', '/Users/x/app', '', NULL, '\(spawn)', 1800000000, 1800000200, NULL, 0);",
        "INSERT INTO threads VALUES ('t3', '/Users/x/wt', 'First line\nsecond line', 'Named', 'cli', 1, 2, NULL, 0);",
        "INSERT INTO threads VALUES ('t4', '/Users/x/old', 'Archived', NULL, 'cli', 1, 2, NULL, 1);",
    ])
    #expect(CodexState.databaseURL(home: dir)?.lastPathComponent == "state_5.sqlite")

    let byId = try CodexState.threads(home: dir, ids: ["t1", "t2"]).get()
    #expect(Set(byId.keys) == ["t1", "t2"])
    #expect(byId["t1"]?.title == "Continue building")
    #expect(byId["t1"]?.updatedAt == Date(timeIntervalSince1970: 1_800_000_100.5))   // ms preferred
    #expect(byId["t2"]?.title == nil)
    #expect(byId["t2"]?.parentId == "t1")
    #expect(byId["t2"]?.updatedAt == Date(timeIntervalSince1970: 1_800_000_200))

    let open = try CodexState.threads(home: dir, ids: [], unarchived: true).get()
    #expect(Set(open.keys) == ["t1", "t2", "t3"])
    #expect(open["t3"]?.title == "Named")
    let withArchivedLoaded = try CodexState.threads(home: dir, ids: ["t4"], unarchived: true).get()
    #expect(withArchivedLoaded["t4"]?.archived == true)
}

@Test func anOlderSchemaStillYieldsFoldersAndAMissingDatabaseIsReported() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-state-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(CodexState.threads(home: dir, ids: ["a"]) == .failure(.missing))
    try makeStateDB(dir, columns: "id TEXT PRIMARY KEY, cwd TEXT", rows: ["INSERT INTO threads VALUES ('a', '/p');"])
    let t = try CodexState.threads(home: dir, ids: [], unarchived: true).get()   // no archived column: all count
    #expect(t["a"]?.cwd == "/p")
    #expect(t["a"]?.title == nil)
}

@Test func worktreesCodexThreadsWorkInAreKeptAndUnknownFoldersFailClosed() throws {
    let wt = "/Users/x/.codex/worktrees/8790/app"
    let t = CodexThread(id: "t", cwd: wt + "/web", title: "Port the API", parentId: nil, createdAt: nil, updatedAt: nil)
    #expect(Worktrees.usage(of: wt, processes: [], cwds: [:], sessions: [], codexThreads: [t]) == "Codex thread “Port the API” works here")
    #expect(Worktrees.usage(of: "/Users/x/other", processes: [], cwds: [:], sessions: [], codexThreads: [t]) == nil)

    let codexSession = SessionRecord(agent: .codex, pid: 7, sessionId: "t", name: "Port the API", cwd: wt, status: .idle,
                                     statusUpdatedAt: nil, startedAt: nil, waitingFor: nil, threadIds: ["t"])
    #expect(Worktrees.usage(of: wt, processes: [], cwds: [:], sessions: [codexSession]) == "Codex thread “Port the API” is open here")

    // No state database and nothing loaded (no codex processes): nothing to protect.
    let empty = FileManager.default.temporaryDirectory.appendingPathComponent("no-codex-\(UUID().uuidString)")
    #expect(try LiveContext.codexThreads(processes: [], home: empty).isEmpty)
}

@Test func codexEnvironmentAndSnapshotsMarkLeftovers() {
    #expect(Attribution.looksCodexLaunched(row(1, parent: 1, path: "/usr/bin/make", codexThread: "x")))
    #expect(Attribution.looksCodexLaunched(row(1, parent: 1, path: "/bin/zsh",
        args: "/bin/zsh -c source /Users/x/.codex/shell_snapshots/abc.1.sh && make")))
    #expect(!Attribution.looksCodexLaunched(row(1, parent: 1, path: "/Applications/Docker.app/Contents/MacOS/Docker",
                                                codexThread: "x")))
    #expect(!Attribution.looksCodexLaunched(row(1, parent: 1, path: "/usr/bin/make")))
}
