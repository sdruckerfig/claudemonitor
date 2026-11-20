import Darwin
import Foundation
import Testing
@testable import MonitorCore

private final class PoolFixture {
    let root: URL
    let repo: String
    let holder: Process

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pool-\(UUID().uuidString)")
        repo = root.appendingPathComponent("app").path
        holder = Process()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let origin = root.appendingPathComponent("origin").path
        try git(["init", "-q", "-b", "main", origin], in: root.path)
        try Data("initial\n".utf8).write(to: URL(fileURLWithPath: origin + "/file.txt"))
        try Data("node_modules/\n.env\n".utf8).write(to: URL(fileURLWithPath: origin + "/.gitignore"))
        try git(["add", "."], in: origin)
        try git(["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false", "commit", "-qm", "initial"], in: origin)
        try git(["clone", "-q", origin, repo], in: root.path)
        try git(["config", "claudemonitor.poolSize", "1"])
        holder.executableURL = URL(fileURLWithPath: "/bin/sleep")
        holder.arguments = ["3600"]
        try holder.run()
    }

    deinit {
        stop()
        try? FileManager.default.removeItem(at: root)
    }

    func stop() {
        if holder.isRunning { holder.terminate(); holder.waitUntilExit() }
    }

    @discardableResult
    func git(_ args: [String], in cwd: String? = nil) throws -> String {
        let result = WorktreeScanner.git(args, in: cwd ?? repo)
        guard result.status == 0 else { throw WorktreePoolError(result.err) }
        return result.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func acquire(_ branch: String) throws -> String {
        try WorktreePool(in: repo).acquire(branch: branch, pid: holder.processIdentifier)
    }

    func refusal(_ branch: String) -> String {
        do {
            _ = try WorktreePool(in: repo).acquire(branch: branch)
            Issue.record("unexpectedly acquired a slot for \(branch)")
            return ""
        } catch { return String(describing: error) }
    }
}

@Test func poolBoundsLiveSessionsAndProtectsWarmTreesFromCleanup() throws {
    let fixture = try PoolFixture()
    let path = try fixture.acquire("first")
    #expect(fixture.refusal("second").contains("pool full"))
    #expect(fixture.refusal("first").contains("running"))
    let trees = Worktrees.parsePorcelain(try fixture.git(["worktree", "list", "--porcelain", "-z"]))
    #expect(trees.count == 2)
    #expect(trees.first(where: { $0.path == path })?.isLocked == true)
    #expect(try WorktreePool(in: path).status().contains("first  running pid"))
}

@Test func poolReusesCompletedSlotWithoutRemovingCachesOrBranches() throws {
    let fixture = try PoolFixture()
    let first = try fixture.acquire("first")
    let cache = first + "/node_modules/cache.txt"
    try FileManager.default.createDirectory(atPath: first + "/node_modules", withIntermediateDirectories: true)
    try Data("warm".utf8).write(to: URL(fileURLWithPath: cache))
    fixture.stop()
    let second = try WorktreePool(in: fixture.repo).acquire(branch: "second")
    #expect(first == second)
    #expect(try String(contentsOfFile: cache) == "warm")
    #expect(try fixture.git(["rev-parse", "--verify", "refs/heads/first"]).count == 40)
    #expect(Worktrees.parsePorcelain(try fixture.git(["worktree", "list", "--porcelain", "-z"])).count == 2)
}

@Test func poolKeepsDirtySlotButAllowsExplicitResume() throws {
    let fixture = try PoolFixture()
    let path = try fixture.acquire("unfinished")
    try Data("work in progress".utf8).write(to: URL(fileURLWithPath: path + "/file.txt"))
    fixture.stop()
    #expect(fixture.refusal("another").contains("has edits"))
    #expect(try WorktreePool(in: fixture.repo).acquire(branch: "unfinished") == path)
    #expect(try String(contentsOfFile: path + "/file.txt") == "work in progress")
}

@Test func poolDoesNotTreatCommandExitAsTaskCompletion() throws {
    let fixture = try PoolFixture()
    let path = try fixture.acquire("unmerged")
    try Data("committed work".utf8).write(to: URL(fileURLWithPath: path + "/file.txt"))
    try fixture.git(["add", "."], in: path)
    try fixture.git(["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false", "commit", "-qm", "pending review"], in: path)
    fixture.stop()
    #expect(fixture.refusal("another").contains("not in origin/main"))
    #expect(try String(contentsOfFile: path + "/file.txt") == "committed work")
    // Simulate a fetch observing delivery. No PR/network calls in the fixture.
    let delivered = try fixture.git(["rev-parse", "HEAD"], in: path)
    try fixture.git(["update-ref", "refs/remotes/origin/main", delivered])
    #expect(try WorktreePool(in: fixture.repo).acquire(branch: "next") == path)
}

@Test func poolKeepsUniqueIgnoredFilesAndHiddenEdits() throws {
    let fixture = try PoolFixture()
    let path = try fixture.acquire("first")
    fixture.stop()
    try Data("secret".utf8).write(to: URL(fileURLWithPath: path + "/.env"))
    #expect(fixture.refusal("second").contains("local files"))
    try FileManager.default.removeItem(atPath: path + "/.env")
    try fixture.git(["update-index", "--assume-unchanged", "file.txt"], in: path)
    try Data("hidden work".utf8).write(to: URL(fileURLWithPath: path + "/file.txt"))
    #expect(fixture.refusal("second").contains("edits git status can't see"))
    #expect(try String(contentsOfFile: path + "/file.txt") == "hidden work")
}

@Test func poolRefusesSymlinksAndCorruptLeases() throws {
    let fixture = try PoolFixture()
    let pool = try WorktreePool(in: fixture.repo)
    let outside = fixture.root.appendingPathComponent("outside").path
    try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: pool.directory, withDestinationPath: outside)
    #expect(fixture.refusal("first").contains("symlink"))
    try FileManager.default.removeItem(atPath: pool.directory)
    _ = try fixture.acquire("first")
    fixture.stop()
    let common = try fixture.git(["rev-parse", "--path-format=absolute", "--git-common-dir"])
    try Data("broken lease".utf8).write(to: URL(fileURLWithPath: common + "/claudemonitor-pool/slot-1.json"))
    #expect(fixture.refusal("second").contains("pool full"))
}

@Test func poolRejectsBranchAlreadyCheckedOutElsewhere() throws {
    let fixture = try PoolFixture()
    #expect(fixture.refusal("main").contains("already checked out"))
}

@Test func poolDoesNotOverwriteIgnoredCacheWhenNextBranchTracksIt() throws {
    let fixture = try PoolFixture()
    let path = try fixture.acquire("first")
    let cache = "/node_modules/cache.txt"
    for directory in [fixture.repo, path] {
        try FileManager.default.createDirectory(atPath: directory + "/node_modules", withIntermediateDirectories: true)
        try Data("keep this cache".utf8).write(to: URL(fileURLWithPath: directory + cache))
    }
    try fixture.git(["checkout", "-qb", "tracks-cache"])
    try fixture.git(["add", "-f", "." + cache])
    try fixture.git(["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false", "commit", "-qm", "tracks cache"])
    try fixture.git(["checkout", "-q", "main"])
    fixture.stop()
    #expect(fixture.refusal("tracks-cache").contains("pool full"))
    #expect(try String(contentsOfFile: path + cache) == "keep this cache")
    #expect(try fixture.git(["branch", "--show-current"], in: path) == "first")
}

@Test func poolChecksLeftoverProcessesAfterHolderExits() throws {
    let fixture = try PoolFixture()
    let path = try fixture.acquire("first")
    let background = Process()
    background.executableURL = URL(fileURLWithPath: "/bin/sleep")
    background.arguments = ["3600"]
    background.currentDirectoryURL = URL(fileURLWithPath: path)
    try background.run()
    defer { background.terminate(); background.waitUntilExit() }
    fixture.stop()
    #expect(fixture.refusal("second").contains("running here"))
    #expect(fixture.refusal("first").contains("running here"))
}

@Test func poolMutexPreventsConcurrentAllocation() throws {
    let fixture = try PoolFixture()
    let common = try fixture.git(["rev-parse", "--path-format=absolute", "--git-common-dir"])
    let state = common + "/claudemonitor-pool"
    try FileManager.default.createDirectory(atPath: state, withIntermediateDirectories: true)
    let fd = open(state + "/lock", O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    #expect(fd >= 0)
    defer { close(fd) }
    #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
    #expect(fixture.refusal("first").contains("another pool operation"))
    #expect(Worktrees.parsePorcelain(try fixture.git(["worktree", "list", "--porcelain", "-z"])).count == 1)
}
