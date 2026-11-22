import Foundation

/// Everything the YOLO button cleans up, planned from one snapshot and the last worktree scan:
/// processes closed sessions left running, every server and build daemon, stale sessions (and
/// what they started that isn't listed elsewhere), and reclaimable worktrees. Each step re-checks
/// its target right before acting, as the individual buttons do; the plan only decides what to try.
public struct CleanupPlan {
    /// The snapshot the jobs and sessions came from: what identity checks compare against.
    public let takenAt: Date
    public let leftovers: [ProcessJob]
    /// Every server and build daemon, including ones live sessions or other apps started.
    public let services: [ProcessJob]
    /// Claude sessions idle long enough to be marked stale. Codex threads are never ended: their
    /// host process serves other threads (and, for the apps, the app itself).
    public let staleSessions: [SessionUsage]
    /// What each stale session started that isn't already a leftover or a service.
    public let staleSessionJobs: [ProcessJob]
    public let worktrees: [ReclaimableWorktree]

    /// `skipping`: root pids of jobs already being stopped.
    public init(snapshot: Snapshot, worktrees: [ReclaimableWorktree], skipping: Set<Int32> = [],
                selfPid: Int32 = getpid()) {
        takenAt = snapshot.takenAt
        leftovers = snapshot.leftovers.filter { !skipping.contains($0.id) }
        services = snapshot.services.filter { !skipping.contains($0.id) }
        staleSessions = snapshot.sessions.filter { $0.isStale && $0.usage.record.agent == .claude }.map(\.usage)
        var listed = Set((leftovers + services).flatMap { $0.members.map(\.pid) })
        var extra: [ProcessJob] = []
        for u in staleSessions {
            guard let job = Self.started(by: u, excluding: listed, selfPid: selfPid), !skipping.contains(job.id) else { continue }
            extra.append(job)
            listed.formUnion(job.members.map(\.pid))
        }
        staleSessionJobs = extra
        self.worktrees = worktrees
    }

    /// The stoppable processes a session started, descending only through stoppable ones: never
    /// into tmux, an interactive shell or an app, so nothing the user runs in them is touched.
    /// Roots are the ones whose parent isn't in the session's tree (claude's own children, and
    /// detached processes now under launchd). "Detached" alone isn't enough: everything inside a
    /// tmux the session started is detached too. nil when there are none.
    static func started(by u: SessionUsage, excluding listed: Set<Int32>, selfPid: Int32) -> ProcessJob? {
        func stoppable(_ p: ProcessRow) -> Bool { !listed.contains(p.pid) && Jobs.isStoppable(p, selfPid: selfPid) }
        let inTree = Set(u.descendants.map(\.pid))
        let roots = u.descendants
            .filter { !inTree.contains($0.ppid) && stoppable($0) }
            .sorted { $0.pid < $1.pid }
        guard !roots.isEmpty else { return nil }
        var members = roots
        var seen = Set(roots.map(\.pid))
        var queue = roots.map(\.pid)
        while !queue.isEmpty {
            let pid = queue.removeFirst()
            for c in u.descendants where c.ppid == pid && !seen.contains(c.pid) && stoppable(c) {
                members.append(c)
                seen.insert(c.pid)
                queue.append(c.pid)
            }
        }
        return ProcessJob(roots: roots, members: members,
                          owner: .session(pid: u.process.pid, name: u.record.name, agent: u.record.agent),
                          label: ProcessKind.label(roots[0]),
                          ports: Set(members.flatMap(\.details.listeningPorts)).sorted(), cwd: roots[0].details.cwd)
    }

    public var jobs: [ProcessJob] { leftovers + services + staleSessionJobs }
    public var isEmpty: Bool { jobs.isEmpty && staleSessions.isEmpty && worktrees.isEmpty }
    public var processCount: Int { jobs.reduce(0) { $0 + $1.members.count } }
    public var memoryBytes: Int64 {
        jobs.reduce(0) { $0 + $1.totalRSSBytes } + staleSessions.reduce(0) { $0 + $1.process.rssBytes }
    }
    public var diskBytes: Int64 { worktrees.reduce(0) { $0 + ($1.sizeBytes ?? 0) } }

    /// Services something still running started (a live session, an app): it may be using them.
    /// A stale session's services don't count; that session is ending too.
    public var servicesInUse: [ProcessJob] {
        let ending = Set(staleSessions.map(\.process.pid))
        return services.filter {
            switch $0.owner {
            case .session(let pid, _, let agent): return agent != .claude || !ending.contains(pid)
            case .launcher: return true
            case .closedSession, .detached: return false
            }
        }
    }

    /// The dialog's lines, one per kind of cleanup, then what it frees and how it stays safe.
    public var summary: [String] {
        func n(_ count: Int, _ one: String, _ many: String) -> String { "\(count) \(count == 1 ? one : many)" }
        var lines: [String] = []
        if !leftovers.isEmpty {
            let count = leftovers.reduce(0) { $0 + $1.members.count }
            lines.append("• Stop \(n(count, "process", "processes")) left behind by closed sessions.")
        }
        if !services.isEmpty {
            var line = "• Stop \(n(services.count, "server or build daemon", "servers and build daemons"))."
            let inUse = servicesInUse
            if !inUse.isEmpty {
                let names = inUse.prefix(3).map { "\($0.name) (\($0.ownerText))" }.joined(separator: ", ")
                let which = services.count == 1 ? "It may be"
                    : inUse.count == services.count ? "All \(inUse.count) may be" : "\(inUse.count) may be"
                line += " \(which) in use: \(names)"
                line += inUse.count > 3 ? ", …" : "."
            }
            lines.append(line)
        }
        if !staleSessions.isEmpty {
            let names = staleSessions.prefix(3).map { "“\($0.record.name)”" }.joined(separator: ", ")
            var line = "• End \(n(staleSessions.count, "stale Claude session", "stale Claude sessions")): \(names)"
            line += staleSessions.count > 3 ? ", …" : ""
            let count = staleSessionJobs.reduce(0) { $0 + $1.members.count }
            if count > 0 { line += ", and stop \(n(count, "process", "processes")) \(staleSessions.count == 1 ? "it" : "they") started" }
            line += ". Resume later with claude --resume."
            lines.append(line)
        }
        if !worktrees.isEmpty {
            lines.append("• Delete \(n(worktrees.count, "reclaimable worktree", "reclaimable worktrees")) (\(Format.bytes(diskBytes))).")
        }
        var frees: [String] = []
        if memoryBytes > 0 { frees.append("\(Format.bytes(memoryBytes)) of memory") }
        if diskBytes > 0 { frees.append("\(Format.bytes(diskBytes)) of disk") }
        var footer = frees.isEmpty ? "" : "Frees about \(frees.joined(separator: " and ")). "
        footer += "Each process, session and worktree is checked again right before it's stopped or deleted, "
        footer += "and any that changed are left alone."
        if !worktrees.isEmpty { footer += " Branches are kept." }
        return lines + ["", footer]
    }
}
