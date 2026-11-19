import Foundation
import Testing
@testable import MonitorCore

@Test func parsesWorktreePorcelain() {
    let text = """
    worktree /r/main
    HEAD aaaa
    branch refs/heads/main

    worktree /r/wt-feature
    HEAD bbbb
    branch refs/heads/feature/x

    worktree /r/wt-detached
    HEAD cccc
    detached

    worktree /r/wt-locked
    HEAD dddd
    branch refs/heads/l
    locked claude agent

    worktree /r/wt-gone
    HEAD eeee
    branch refs/heads/g
    prunable gitdir file points to non-existent location

    """
    let list = Worktrees.parsePorcelain(text)
    #expect(list.map(\.path) == ["/r/main", "/r/wt-feature", "/r/wt-detached", "/r/wt-locked", "/r/wt-gone"])
    #expect(list[0].isMain && !list[1].isMain)
    #expect(list[1].branch == "feature/x")
    #expect(list[2].branch == nil)
    #expect(list[3].isLocked)
    #expect(list[4].isPrunable)
}

@Test func findsMainRepoFromGitFile() {
    #expect(Worktrees.mainRepo(fromGitFile: "gitdir: /Users/x/code/webapp/.git/worktrees/feature-x\n")
        == "/Users/x/code/webapp")
    #expect(Worktrees.mainRepo(fromGitFile: "gitdir: /Users/x/sub/.git/modules/lib") == nil)
    // `git worktree add --relative-paths` writes a path relative to the worktree.
    #expect(Worktrees.gitdir(fromGitFile: "gitdir: ../app/.git/worktrees/wt\n", worktree: "/s/wt") == "/s/app/.git/worktrees/wt")
    #expect(Worktrees.mainRepo(fromGitFile: "gitdir: ../app/.git/worktrees/wt", worktree: "/s/wt") == "/s/app")
}

@Test func pathContainmentDoesNotMatchSiblingPrefixes() {
    #expect(Worktrees.contains("/g/webapp", "/g/webapp"))
    #expect(Worktrees.contains("/g/webapp", "/g/webapp/web"))
    #expect(!Worktrees.contains("/g/webapp", "/g/webapp-feature"))
    #expect(Worktrees.contains("/g/CaseWT", "/g/casewt/src"))   // macOS volumes are case-insensitive
}

@Test func usageDetectsSessionsCwdsAndCommandLines() {
    let wt = "/g/webapp-feature"
    let procs = [
        row(10, parent: 1, path: "/bin/node", args: "node /g/webapp/web/vite --port 5174"),   // sibling: no
        row(11, parent: 1, path: "/opt/dotnet", args: "dotnet run --project /g/webapp-feature/api/Server"),
        row(12, parent: 1, path: "/bin/zsh"),
    ]
    #expect(Worktrees.usage(of: wt, processes: [procs[0]], cwds: [:], sessions: []) == nil)
    #expect(Worktrees.usage(of: wt, processes: procs, cwds: [:], sessions: [])?.contains("dotnet (pid 11)") == true)
    #expect(Worktrees.usage(of: wt, processes: [procs[2]], cwds: [12: wt + "/web"], sessions: [])
        == "zsh (pid 12) is running here")
    let session = SessionRecord(pid: 99, sessionId: "s", name: "Feature work", cwd: wt, status: .idle,
                                statusUpdatedAt: nil, startedAt: nil, waitingFor: nil)
    #expect(Worktrees.usage(of: wt, processes: [], cwds: [:], sessions: [session]) == "Claude session “Feature work” is open here")
}

@Test func usageProtectsWorktreesInALiveSessionsScratchpad() {
    let session = SessionRecord(pid: 1, sessionId: "0b1c2d3e-4f50", name: "Upload flow", cwd: "/code/app", status: .busy,
                                statusUpdatedAt: nil, startedAt: nil, waitingFor: nil)
    let wt = "/private/tmp/claude-501/-code-app/0b1c2d3e-4f50/scratchpad/wt-main"
    #expect(Worktrees.usage(of: wt, processes: [], cwds: [:], sessions: [session]) == "Belongs to Claude session “Upload flow”")
    #expect(Worktrees.usage(of: "/code/app-slides", processes: [], cwds: [:], sessions: [session]) == nil)
}

@Test func parsesNulSeparatedStatusWithIgnoredEntries() {
    let z = "!! api/bin/\0!! .env.local\0?? new file.txt\0R  renamed.txt\0old.txt\0!! web/node_modules/\0"
    let s = Worktrees.parseStatus(z)
    #expect(s.changes == ["new file.txt", "renamed.txt"])
    #expect(s.ignored == ["api/bin/", ".env.local", "web/node_modules/"])
    #expect(Worktrees.parseStatus("!! bin/\0!! obj/\0").changes.isEmpty)
    #expect(Worktrees.parseStatus("").ignored.isEmpty)
}

@Test func findsEditsThatGitStatusHides() {
    // ls-files -s -v: tags H cached, S skip-worktree, lower case = assume-unchanged; mode 160000 = submodule.
    let index = Worktrees.parseIndex("H 100644 aa 0\ta\0S 100644 bb 0\tb c\0h 100644 cc 0\td\0s 100644 dd 0\te\0H 160000 ee 0\tlib/sub\0")
    #expect(index.filter(\.hidesEdits).map(\.path) == ["b c", "d", "e"])
    #expect(index.filter(\.isGitlink).map(\.path) == ["lib/sub"])
    let z40 = String(repeating: "0", count: 40), a40 = String(repeating: "a", count: 40), b40 = String(repeating: "b", count: 40)
    #expect(Worktrees.reflogCommits("\(z40) \(a40) t <t@e> 1 -0500\tclone\n\(a40) \(b40) t <t@e> 2 -0500\tcommit: x y\n")
        == [a40, a40, b40])
    #expect(Worktrees.filterDrivers("filter.lfs.process git-lfs filter-process\nfilter.my.redact.clean sed x\n")
        == ["lfs", "my.redact"])
    let attrs = Worktrees.attributeValues("a.env\0filter\0redact\0b.txt\0filter\0unspecified\0")
    #expect(attrs.map(\.path) == ["a.env", "b.txt"])
    #expect(attrs.map(\.value) == ["redact", "unspecified"])
}

@Test func gitSubprocessesDropInheritedGitVariables() {
    let env = Worktrees.gitEnvironment(from: ["GIT_DIR": "/x/.git", "GIT_WORK_TREE": "/x", "GIT_INDEX_FILE": "/i", "PATH": "/bin"])
    #expect(env["GIT_DIR"] == nil && env["GIT_WORK_TREE"] == nil && env["GIT_INDEX_FILE"] == nil)
    #expect(env["PATH"] == "/bin" && env["GIT_OPTIONAL_LOCKS"] == "0")
}

// MARK: End to end against real git repositories

private struct Sandbox {
    let root: URL
    let repo: String

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cm-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("scan"), withIntermediateDirectories: true)
        let origin = root.appendingPathComponent("origin").path
        repo = root.appendingPathComponent("scan/app").path
        try sh("git init -q -b main \(origin)")
        try sh("printf 'bin/\\n.env.local\\n' > .gitignore && echo a > a && git add . && git \(Sandbox.id) commit -qm init", in: origin)
        try sh("git clone -q \(origin) \(repo)")
        // The main checkout is "built": it has bin/, so bin/ in a worktree counts as build output.
        try sh("echo SECRET=main > .env.local && mkdir bin && echo x > bin/out.dll", in: repo)
    }

    static let id = "-c user.email=test@example.com -c user.name=test -c commit.gpgsign=false"

    func worktree(_ name: String) throws -> String {
        let path = root.appendingPathComponent("scan/\(name)").path
        try sh("git worktree add -q -b \(name) \(path) origin/main", in: repo)
        return path
    }

    func sh(_ cmd: String, in dir: String? = nil) throws {
        let script = (dir.map { "cd '\($0)' && " } ?? "") + cmd
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw WorktreeError.gitFailed("sandbox command failed: \(cmd)") }
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Test func scannerFindsOnlyCleanIdleMergedWorktreesAndRemovesThem() throws {
    let box = try Sandbox()
    defer { box.cleanup() }

    let clean = try box.worktree("clean")
    try box.sh("mkdir -p bin && head -c 200000 /dev/zero > bin/out.dll", in: clean)   // ignored build output
    let dirty = try box.worktree("dirty")
    try box.sh("echo new > untracked.txt", in: dirty)
    let unmerged = try box.worktree("unmerged")
    try box.sh("echo b > b && git add b && git \(Sandbox.id) commit -qm feature", in: unmerged)
    let envSame = try box.worktree("envsame")
    try box.sh("echo SECRET=main > .env.local", in: envSame)        // identical to main checkout: fine
    let envDiff = try box.worktree("envdiff")
    try box.sh("echo SECRET=only-here > .env.local", in: envDiff)   // would be lost: keep
    let locked = try box.worktree("locked")
    try box.sh("git worktree lock \(locked)", in: box.repo)
    let busy = try box.worktree("busy")
    let sleeper = Process()
    sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
    sleeper.arguments = ["30"]
    sleeper.currentDirectoryURL = URL(fileURLWithPath: busy)
    try sleeper.run()
    defer { sleeper.terminate() }

    var policy = WorktreePolicy()
    policy.roots = [box.root.appendingPathComponent("scan").path]
    policy.searchDepth = 1
    policy.minIdleHours = 0
    policy.savedMessagesDirectory = box.root.appendingPathComponent("saved").path
    let scanner = WorktreeScanner(policy: policy)

    let scan = scanner.scan()
    #expect(scan.repoCount == 1)
    #expect(scan.worktreeCount == 7)
    #expect(scan.reclaimable.map { ($0.path as NSString).lastPathComponent } == ["clean", "envsame"])   // largest first
    #expect(scan.reclaimable.first?.baseRef == "refs/remotes/origin/main")
    #expect(scan.reclaimable.first?.baseName == "origin/main")
    #expect((scan.reclaimable.first?.sizeBytes ?? 0) >= 200_000)
    #expect(scan.skipped == ["has edits": 1, "not in origin/main": 1, "locked": 1, "in use": 1, "has local files": 1])
    _ = envDiff

    // Idle guard: with the default 24h policy, freshly created worktrees are left alone.
    var strict = policy
    strict.minIdleHours = 24
    #expect(WorktreeScanner(policy: strict).scan().reclaimable.isEmpty)

    // Re-verification at delete time: an edit made after the scan blocks removal.
    let item = try #require(scan.reclaimable.first)
    try box.sh("echo late > late.txt", in: clean)
    #expect(throws: WorktreeError.self) { try scanner.remove(item) }
    try box.sh("rm late.txt", in: clean)

    try scanner.remove(item)
    #expect(!FileManager.default.fileExists(atPath: clean))
    #expect(FileManager.default.fileExists(atPath: dirty))
    try box.sh("git rev-parse --verify -q refs/heads/clean", in: box.repo)   // branch kept
}
