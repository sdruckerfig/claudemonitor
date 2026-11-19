import Foundation

/// A live Claude session plus every process it is responsible for.
public struct SessionUsage: Equatable, Sendable {
    public let record: SessionRecord
    /// The `claude` process itself.
    public let process: ProcessRow
    /// Processes started by the session (excluding `process`), heaviest CPU first.
    /// Includes detached background jobs that were re-parented to launchd.
    public let descendants: [ProcessRow]
    /// Pids in `descendants` that are no longer in the session's process tree.
    public let detachedPids: Set<Int32>

    public var totalCores: Double { process.cores + descendants.reduce(0) { $0 + $1.cores } }
    public var totalRSSBytes: Int64 { process.rssBytes + descendants.reduce(0) { $0 + $1.rssBytes } }
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
    /// Processes launched by Claude sessions that have since exited.
    public let orphans: [ProcessRow]
    /// Everything not attributable to Claude.
    public let other: [ProcessRow]

    public static func build(processes: [ProcessRow], records: [SessionRecord]) -> Attribution {
        let byPid = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var children: [Int32: [Int32]] = [:]
        for p in processes where p.pid != p.ppid { children[p.ppid, default: []].append(p.pid) }

        // A status file can outlive its process, and its pid can be reused by something else.
        let live = records.filter { r in byPid[r.pid].map(isClaude) ?? false }
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

        var treePids: [Int32: [Int32]] = [:]
        for r in live { treePids[r.pid] = collect(from: children[r.pid] ?? []) }

        // Background jobs a session detached (nohup / reparented to launchd) still carry the
        // session id in their command line, usually via the session's scratchpad path.
        var detached: [Int32: [Int32]] = [:]
        for r in live {
            guard let id = r.sessionId, !id.isEmpty else { continue }
            let roots = processes.filter { !claimed.contains($0.pid) && $0.args.contains(id) }.map(\.pid)
            detached[r.pid] = collect(from: roots)
        }

        let orphanRoots = processes.filter { !claimed.contains($0.pid) && looksClaudeLaunched($0) }.map(\.pid)
        let orphans = collect(from: orphanRoots).compactMap { byPid[$0] }

        let sessions = live.compactMap { r -> SessionUsage? in
            guard let proc = byPid[r.pid] else { return nil }
            let det = detached[r.pid] ?? []
            let rows = ((treePids[r.pid] ?? []) + det).compactMap { byPid[$0] }
            return SessionUsage(record: r, process: proc,
                                descendants: rows.sorted(by: heavierFirst),
                                detachedPids: Set(det))
        }
        let other = processes.filter { !claimed.contains($0.pid) }
        return Attribution(sessions: sessions, orphans: orphans.sorted(by: heavierFirst), other: other)
    }

    public static func isClaude(_ p: ProcessRow) -> Bool {
        if p.name == "claude" { return true }
        // npm installs run as `node …/bin/claude`.
        let first = ProcessTable.firstToken(p.args)
        return (first as NSString).lastPathComponent == "node" && p.args.contains("/claude")
    }

    /// Command lines Claude Code's Bash tool produces: shell snapshots or per-session temp dirs.
    static func looksClaudeLaunched(_ p: ProcessRow) -> Bool {
        p.args.contains("/.claude/shell-snapshots/") ||
            p.args.range(of: #"/claude-\d+/"#, options: .regularExpression) != nil
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
