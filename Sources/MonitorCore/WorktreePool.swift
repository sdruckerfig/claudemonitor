import Darwin
import Foundation

public struct WorktreePoolError: Error, CustomStringConvertible {
    public let description: String
    init(_ message: String) { description = message }
}

/// An opt-in, per-repository limit on unfinished work. The runner becomes the
/// command with exec(), so its PID and start time remain the lease identity.
/// No daemon, timer, force checkout, branch deletion, or cache deletion.
public final class WorktreePool {
    public let repo: String
    public let directory: String
    public let size: Int
    private let state: String
    private let fm = FileManager.default

    private struct Lease: Codable {
        let pid: Int32
        let started: Date
        let branch: String
    }

    public init(in cwd: String) throws {
        let listed = try Self.git(["worktree", "list", "--porcelain", "-z"], in: cwd)
        guard let main = Worktrees.parsePorcelain(listed).first, !main.isBare else {
            throw WorktreePoolError("run from a repository with a main checkout")
        }
        repo = WorktreeScanner.realPath(main.path)
        directory = repo + "-claudemonitor-pool"
        let common = try Self.git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: repo)
        state = common + "/claudemonitor-pool"
        let config = WorktreeScanner.git(["config", "--get", "claudemonitor.poolSize"], in: repo)
        guard config.status == 0 || config.status == 1 else { throw WorktreePoolError(config.err) }
        let count = config.status == 1 ? 2 : Int(config.out.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let count, (1...32).contains(count) else {
            throw WorktreePoolError("claudemonitor.poolSize must be between 1 and 32")
        }
        size = count
    }

    /// Resume this branch's slot, or reuse a completed one. A full pool fails
    /// visibly: callers must finish/resume work, not silently create slot N+1.
    public func acquire(branch: String, pid: Int32 = getpid()) throws -> String {
        _ = try Self.git(["check-ref-format", "--branch", branch], in: repo)
        guard !branch.hasPrefix("-"), !branch.hasPrefix("@"), !branch.contains("\n"),
              let started = ProcessIdentity.startTime(of: pid) else {
            throw WorktreePoolError("a literal branch name and a live holder process are required")
        }
        return try locked {
            let trees = try worktrees()
            let context = LiveContext.capture()
            // A branch is a task identity: resume it before looking for a free slot.
            if let existing = trees.first(where: { $0.branch == branch }) {
                guard (1...size).contains(where: { existing.path == slot($0) }) else {
                    throw WorktreePoolError("\(branch) is already checked out at \(existing.path); resume it there")
                }
                try available(existing.path, context: context)
                try saveLease(Lease(pid: pid, started: started, branch: branch), at: existing.path)
                return existing.path
            }

            let base = try baseRef()
            var reasons: [String] = []
            for number in 1...size {
                let path = slot(number)
                do {
                    try available(path, context: context)
                    if let tree = trees.first(where: { $0.path == path }) {
                        guard let fingerprint = WorktreeScanner.fingerprint(path) else {
                            throw WorktreePoolError("cannot read slot metadata")
                        }
                        // Reuse the cleanup scanner's safety checks, but retain the tree,
                        // its branch, reflogs and caches. Our own git lock is intentional.
                        var policy = WorktreePolicy()
                        policy.minIdleHours = 0
                        let scanner = WorktreeScanner(policy: policy)
                        let unlocked = GitWorktree(path: tree.path, head: tree.head, branch: tree.branch,
                            isMain: false, isBare: tree.isBare, isLocked: false, isPrunable: tree.isPrunable)
                        let (verdict, _) = scanner.classify(unlocked, repo: repo, base: base, context: context,
                            allWorktreePaths: trees.map(\.path), now: Date())
                        guard verdict == .reclaimable else { throw WorktreePoolError(verdict.explanation) }
                        let exists = WorktreeScanner.git(["show-ref", "--verify", "--quiet", "refs/heads/" + branch], in: repo)
                        guard exists.status == 0 || exists.status == 1 else { throw WorktreePoolError(exists.err) }
                        let args = exists.status == 0 ? [branch] : ["-b", branch, base]
                        // A scan may take seconds. Check again just before checkout,
                        // rather than trusting the process table and index it began with.
                        try available(path, context: LiveContext.capture())
                        guard WorktreeScanner.fingerprint(path) == fingerprint else {
                            throw WorktreePoolError("slot changed while it was being checked")
                        }
                        _ = try Self.git(["checkout", "--no-overwrite-ignore"] + args, in: path)
                    } else {
                        guard !WorktreeScanner.exists(path) else {
                            throw WorktreePoolError("unregistered directory; kept")
                        }
                        let exists = WorktreeScanner.git(["show-ref", "--verify", "--quiet", "refs/heads/" + branch], in: repo)
                        guard exists.status == 0 || exists.status == 1 else { throw WorktreePoolError(exists.err) }
                        let args = exists.status == 0 ? [path, branch] : ["-b", branch, path, base]
                        _ = try Self.git(["worktree", "add", "--lock", "--reason", "Claude Monitor warm pool"] + args, in: repo)
                    }
                    // Keep warm trees out of the monitor's reclaimable list and git prune.
                    let updated = try worktrees()
                    if updated.first(where: { $0.path == path })?.isLocked != true {
                        _ = try Self.git(["worktree", "lock", "--reason", "Claude Monitor warm pool", path], in: repo)
                    }
                    try saveLease(Lease(pid: pid, started: started, branch: branch), at: path)
                    return path
                } catch {
                    reasons.append("slot-\(number): \(error)")
                }
            }
            throw WorktreePoolError("pool full (\(size) slots). Finish or resume existing work before starting more.\n" + reasons.joined(separator: "\n"))
        }
    }

    public func status() throws -> String {
        // Advisory snapshot. Atomic lease writes let this remain read-only, even
        // before the repository has opted into running anything through the pool.
        let trees = try worktrees()
        return try (1...size).map { number in
            let path = slot(number)
            let branch = trees.first(where: { $0.path == path })?.branch ?? "not created"
            let lease = try readLease(at: path)
            let holder = lease.map { isAlive($0) ? "running pid \($0.pid)" : "stopped; checked before reuse" } ?? "unleased"
            return "slot-\(number)  \(branch)  \(holder)\n  \(path)"
        }.joined(separator: "\n")
    }

    private func slot(_ number: Int) -> String { directory + "/slot-\(number)" }

    private func leasePath(_ path: String) -> String {
        state + "/" + (path as NSString).lastPathComponent + ".json"
    }

    private func readLease(at path: String) throws -> Lease? {
        let file = leasePath(path)
        guard WorktreeScanner.exists(file) else { return nil }
        // An unreadable lease is not a free slot.
        return try JSONDecoder().decode(Lease.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
    }

    private func saveLease(_ lease: Lease, at path: String) throws {
        try JSONEncoder().encode(lease).write(to: URL(fileURLWithPath: leasePath(path)), options: .atomic)
    }

    private func isAlive(_ lease: Lease) -> Bool {
        if let start = ProcessIdentity.startTime(of: lease.pid) { return start == lease.started }
        // Permission or inspection failures must not make a live holder free.
        return kill(lease.pid, 0) == 0 || errno == EPERM
    }

    private func available(_ path: String, context: LiveContext) throws {
        if let lease = try readLease(at: path), isAlive(lease) {
            throw WorktreePoolError("\(lease.branch) is running (pid \(lease.pid))")
        }
        if WorktreeScanner.exists(path) {
            guard WorktreeScanner.isDirectory(path), WorktreeScanner.realPath(path) == path else {
                throw WorktreePoolError("slot is not a real directory")
            }
            if let why = Worktrees.usage(of: path, processes: context.processes, cwds: context.cwds, sessions: context.sessions) {
                throw WorktreePoolError(why)
            }
        }
    }

    private func baseRef() throws -> String {
        // Prefer the remote's default branch. Never fetch on behalf of a session.
        for ref in ["refs/remotes/origin/HEAD", "refs/remotes/origin/main", "refs/remotes/origin/master"] {
            if WorktreeScanner.commit(ref, in: repo) != nil { return ref }
        }
        throw WorktreePoolError("no origin default branch; fetch origin and set its HEAD before using the pool")
    }

    private func worktrees() throws -> [GitWorktree] {
        Worktrees.parsePorcelain(try Self.git(["worktree", "list", "--porcelain", "-z"], in: repo))
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        for path in [state, directory] {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            guard WorktreeScanner.isDirectory(path), WorktreeScanner.realPath(path) == path else {
                throw WorktreePoolError("pool directory must not be a symlink: \(path)")
            }
        }
        let fd = open(state + "/lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw WorktreePoolError("cannot open pool lock") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            throw WorktreePoolError("another pool operation is running; retry when it finishes")
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private static func git(_ args: [String], in dir: String) throws -> String {
        let result = WorktreeScanner.git(args, in: dir)
        guard result.status == 0 else { throw WorktreePoolError(result.err.trimmingCharacters(in: .whitespacesAndNewlines)) }
        // Preserve NUL-delimited worktree output; trim only line-oriented results.
        return result.out.contains("\0") ? result.out : result.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
