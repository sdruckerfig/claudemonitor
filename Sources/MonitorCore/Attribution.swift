import Foundation

/// A live session (Claude Code, or a Codex thread) plus every process it is responsible for.
public struct SessionUsage: Equatable, Sendable {
    public let record: SessionRecord
    /// The `claude` process itself; for Codex, the `codex` process hosting the thread, which may
    /// host other threads too and so isn't counted in the totals.
    public let process: ProcessRow
    /// Processes started by the session (excluding `process`), heaviest CPU first.
    /// Includes detached background jobs that were re-parented to launchd.
    public let descendants: [ProcessRow]
    /// Pids in `descendants` that are no longer in the session's process tree.
    public let detachedPids: Set<Int32>

    /// The session's own process is `process` (Claude). A Codex host is shared.
    public var ownsProcess: Bool { record.agent == .claude }
    public var key: String { record.key }
    public var totalCores: Double { (ownsProcess ? process.cores : 0) + descendants.reduce(0) { $0 + $1.cores } }
    public var totalRSSBytes: Int64 { (ownsProcess ? process.rssBytes : 0) + descendants.reduce(0) { $0 + $1.rssBytes } }
    public var childCores: Double { descendants.reduce(0) { $0 + $1.cores } }
    public var topChild: ProcessRow? { descendants.first }
}

/// Processes grouped by the app (or tool) they belong to.
public struct ProcessGroup: Equatable, Sendable {
    public let name: String
    public let count: Int
    public let cores: Double
    public let rssBytes: Int64
}

public struct Attribution: Sendable {
    public let sessions: [SessionUsage]
    /// Processes launched by Claude sessions or Codex threads that have since closed.
    public let orphans: [ProcessRow]
    /// `orphans` as trees: each root (the topmost process with evidence of a closed session) and
    /// every pid in its tree, root first.
    public let orphanTrees: [(root: Int32, pids: [Int32])]
    /// Everything not attributable to a session.
    public let other: [ProcessRow]

    public static func build(processes: [ProcessRow], records: [SessionRecord]) -> Attribution {
        let byPid = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var children: [Int32: [Int32]] = [:]
        for p in processes where p.pid != p.ppid { children[p.ppid, default: []].append(p.pid) }

        // A status file can outlive its process, and its pid can be reused by something else.
        let live = records.filter { r in
            guard let p = byPid[r.pid] else { return false }
            switch r.agent {
            case .claude: return isClaude(p)
            case .codex: return CodexSessions.isCodex(p)
            }
        }
        let claudeLive = live.filter { $0.agent == .claude }
        let codexLive = live.filter { $0.agent == .codex }
        // Walks stop at every session's process: a codex a Claude session started hosts its own threads.
        let sessionPids = Set(live.map(\.pid))
        var claimed = sessionPids

        /// Breadth-first walk that stops at other sessions and already-claimed processes.
        func collect(from roots: [Int32]) -> [Int32] {
            var out: [Int32] = []
            var queue = roots.filter { !claimed.contains($0) }
            queue.forEach { claimed.insert($0) }
            while let pid = queue.popLast() {
                out.append(pid)
                for child in children[pid] ?? [] where !claimed.contains(child) {
                    claimed.insert(child)
                    queue.append(child)
                }
            }
            return out
        }

        var treePids: [String: [Int32]] = [:]
        for r in claudeLive { treePids[r.key] = collect(from: children[r.pid] ?? []) }

        // Background jobs a session detached (nohup / reparented to launchd) still name the
        // session: in their environment, or in their command line via the scratchpad path.
        var detached: [String: [Int32]] = [:]
        for r in claudeLive {
            guard let session = byPid[r.pid] else { continue }
            let roots = processes.filter { !claimed.contains($0.pid) && started($0, by: r, process: session) }.map(\.pid)
            detached[r.key] = collect(from: roots)
        }

        // A Codex thread's processes are the ones its environment (or a command line naming its
        // shell snapshot) ties to it, and what they started. Not the host's whole tree: the host
        // serves every thread, and its MCP servers and helpers belong to none of them.
        func descends(_ pid: Int32, from ancestor: Int32) -> Bool {
            var cur = pid
            var hops = 0
            while let p = byPid[cur], p.ppid > 1, hops < 64 {
                if p.ppid == ancestor { return true }
                cur = p.ppid
                hops += 1
            }
            return false
        }
        for r in codexLive {
            let roots = processes.filter { !claimed.contains($0.pid) && started($0, byCodex: r) }.map(\.pid)
            let own = collect(from: roots)
            treePids[r.key] = own.filter { descends($0, from: r.pid) }
            detached[r.key] = own.filter { !descends($0, from: r.pid) }
        }

        // What closed sessions left behind. A root is the topmost process with that evidence:
        // its parent has none (usually it's launchd, after the session's shell exited).
        // Claude processes, interactive shells and tmux and the like are never part of a leftover.
        /// Something that started `p` is still running: a claude process without a session file
        /// (`claude -p`), named by CLAUDE_PID or above it in the tree, a codex process above it
        /// (one that may still be serving the thread), or an app it runs inside.
        func hasLiveOwner(_ p: ProcessRow) -> Bool {
            if let cp = p.details.claudePid, let owner = byPid[cp], isClaude(owner),
               owner.elapsedSeconds >= p.elapsedSeconds { return true }
            var cur = p
            var hops = 0
            while let parent = byPid[cur.ppid], parent.pid > 1, hops < 64 {
                if isClaude(parent) || CodexSessions.isCodex(parent) || ProcessKind.isAppOrSystem(parent) { return true }
                cur = parent
                hops += 1
            }
            return false
        }
        let candidates = Set(processes.filter { p in
            !claimed.contains(p.pid) && (looksClaudeLaunched(p) || looksCodexLaunched(p)) && !isClaude(p)
                && !CodexSessions.isCodex(p) && !ProcessKind.isBoundary(p) && !hasLiveOwner(p)
        }.map(\.pid))
        let orphanRoots = candidates.filter { pid in byPid[pid].map { !candidates.contains($0.ppid) } ?? false }.sorted()
        var orphanTrees: [(root: Int32, pids: [Int32])] = []
        for root in orphanRoots {
            let pids = collect(from: [root])
            if !pids.isEmpty { orphanTrees.append((root, pids)) }
        }
        let orphans = orphanTrees.flatMap(\.pids).compactMap { byPid[$0] }

        let sessions = live.compactMap { r -> SessionUsage? in
            guard let proc = byPid[r.pid] else { return nil }
            let det = detached[r.key] ?? []
            let rows = ((treePids[r.key] ?? []) + det).compactMap { byPid[$0] }
            return SessionUsage(record: r, process: proc,
                                descendants: rows.sorted(by: heavierFirst),
                                detachedPids: Set(det))
        }
        // A Codex host isn't charged to any one thread, so it stays among everything else.
        let hosts = Set(codexLive.map(\.pid)).subtracting(claudeLive.map(\.pid))
        let other = processes.filter { !claimed.contains($0.pid) || hosts.contains($0.pid) }
        return Attribution(sessions: sessions, orphans: orphans.sorted(by: heavierFirst), orphanTrees: orphanTrees, other: other)
    }

    /// True when `p` (not in the session's process tree) was started by the live session `r`,
    /// whose claude process is `s`: its command line names the session, or its environment does.
    /// Apps are only matched by command line: one a session happened to launch is the user's.
    static func started(_ p: ProcessRow, by r: SessionRecord, process s: ProcessRow) -> Bool {
        if let id = r.sessionId, !id.isEmpty, p.args.contains(id) { return true }
        guard p.details.hasClaudeEnvironment, !ProcessKind.isAppOrSystem(p) else { return false }
        if let id = r.sessionId, !id.isEmpty, p.details.claudeSessionId == id { return true }
        // /clear gives the session a new id, but CLAUDE_PID still names its claude process. A
        // reused pid would belong to a claude that started after `p` did.
        return p.details.claudePid == s.pid && s.elapsedSeconds >= p.elapsedSeconds
    }

    /// True when `p` was started by the live Codex thread `r` (or a subagent folded into it): its
    /// environment names one of its threads, or its command line runs one of their shell
    /// snapshots. Apps are never matched by environment, as with Claude.
    static func started(_ p: ProcessRow, byCodex r: SessionRecord) -> Bool {
        if let t = p.details.codexThreadId, r.threadIds.contains(t), !ProcessKind.isAppOrSystem(p) { return true }
        guard p.args.contains("/shell_snapshots/") else { return false }
        return r.threadIds.contains { p.args.contains("/shell_snapshots/\($0)") }
    }

    public static func isClaude(_ p: ProcessRow) -> Bool {
        if p.name == "claude" { return true }
        // npm installs run as `node …/bin/claude`.
        let first = ProcessTable.firstToken(p.args)
        return (first as NSString).lastPathComponent == "node" && p.args.contains("/claude")
    }

    /// Started by Claude Code's Bash tool: its environment says so (apps excepted, as above), or
    /// its command line has a shell snapshot or a per-session temp folder in it.
    static func looksClaudeLaunched(_ p: ProcessRow) -> Bool {
        if p.details.hasClaudeEnvironment && !ProcessKind.isAppOrSystem(p) { return true }
        return p.args.contains("/.claude/shell-snapshots/") ||
            p.args.range(of: #"/claude-\d+/"#, options: .regularExpression) != nil
    }

    /// Started by a Codex thread: its environment says so (apps excepted), or its command line
    /// runs a Codex shell snapshot.
    static func looksCodexLaunched(_ p: ProcessRow) -> Bool {
        if p.details.hasCodexEnvironment && !ProcessKind.isAppOrSystem(p) { return true }
        return p.args.contains("/.codex/shell_snapshots/")
    }

    static func heavierFirst(_ a: ProcessRow, _ b: ProcessRow) -> Bool {
        a.cpuPercent != b.cpuPercent ? a.cpuPercent > b.cpuPercent : a.rssKB > b.rssKB
    }

    /// Groups processes by owning app so 120 Chrome helpers read as one line.
    public static func groups(_ rows: [ProcessRow]) -> [ProcessGroup] {
        var acc: [String: (Int, Double, Int64)] = [:]
        for r in rows {
            let key = groupName(for: r)
            let cur = acc[key] ?? (0, 0, 0)
            acc[key] = (cur.0 + 1, cur.1 + r.cores, cur.2 + r.rssBytes)
        }
        return acc.map { ProcessGroup(name: $0.key, count: $0.value.0, cores: $0.value.1, rssBytes: $0.value.2) }
    }

    public static func groupName(for p: ProcessRow) -> String {
        let path = p.executablePath
        if path.contains(".simruntime/") || path.contains("/CoreSimulator/") || p.name.hasPrefix("Sim") {
            return "Simulators"
        }
        if path.contains("Virtualization.framework") { return "Virtual machines" }
        if let app = path.split(separator: "/").first(where: { $0.hasSuffix(".app") }) {
            return String(app.dropLast(4))
        }
        return p.name.isEmpty ? "pid \(p.pid)" : p.name
    }
}
