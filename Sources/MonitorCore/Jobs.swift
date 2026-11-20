import Foundation

/// A process and everything it started: the unit that is listed and stopped together, so
/// stopping `npm run dev` also stops the vite server under it.
public struct ProcessJob: Equatable, Sendable, Identifiable {
    public enum Owner: Equatable, Sendable {
        /// A live Claude session started it.
        case session(pid: Int32, name: String)
        /// A Claude session started it and has since closed.
        case closedSession
        /// Started outside Claude, and whatever started it has exited (it was re-parented to
        /// launchd, which doesn't manage it). Build daemons do this on purpose.
        case detached
        /// Started outside Claude by something still running: Terminal, an editor, Codex…
        case launcher(String)
    }

    public var id: Int32 { root.pid }
    /// Usually one process. Several when identical jobs are listed as one ("MSBuild node ×11").
    public let roots: [ProcessRow]
    public var root: ProcessRow { roots[0] }
    /// Each root, followed by everything it started.
    public let members: [ProcessRow]
    public let owner: Owner
    /// What it runs: "vite", "http.server", "Gradle daemon".
    public let label: String
    /// TCP ports any member listens on, ascending.
    public let ports: [UInt16]
    /// The folder it runs in.
    public let cwd: String?

    public init(roots: [ProcessRow], members: [ProcessRow], owner: Owner, label: String, ports: [UInt16], cwd: String?) {
        precondition(!roots.isEmpty)
        self.roots = roots
        self.members = members
        self.owner = owner
        self.label = label
        self.ports = ports
        self.cwd = cwd
    }

    public var isLeftover: Bool { owner == .closedSession }
    public var totalCores: Double { members.reduce(0) { $0 + $1.cores } }
    public var totalRSSBytes: Int64 { members.reduce(0) { $0 + $1.rssBytes } }
    /// How long it has been running.
    public var elapsedSeconds: Int { members.map(\.elapsedSeconds).max() ?? root.elapsedSeconds }
    /// The ports as text: ":5173 :24678".
    public var portList: String { portList(max: .max) }

    /// The first `max` ports as text, then how many more: ":5554 :5555 :6402 +5".
    public func portList(max: Int) -> String {
        let shown = ports.prefix(max).map { ":\($0)" }.joined(separator: " ")
        return ports.count > max ? shown + " +\(ports.count - max)" : shown
    }

    /// Who started it, in a few words.
    public var ownerText: String {
        switch owner {
        case .session(_, let name): return "session “\(name)”"
        case .closedSession: return "closed session"
        case .detached: return "running on its own"
        case .launcher(let name): return "from \(name)"
        }
    }

    /// The label, how many there are, and ports: "MSBuild node ×11", "vite :5173".
    public var name: String {
        var s = label
        if roots.count > 1 { s += " ×\(roots.count)" }
        if !ports.isEmpty { s += " " + portList(max: 4) }
        return s
    }

    /// `name`, and the number of processes when that's more than it shows: "vite :5173 (3 processes)".
    public var title: String {
        members.count > roots.count ? "\(name) (\(members.count) processes)" : name
    }
}

public enum Jobs {
    /// - Returns: `leftovers`, every process tree a closed Claude session left behind, and
    ///   `services`, every other job that listens on a TCP port or is a detached build daemon,
    ///   whoever started it. Neither includes apps, macOS's own processes, other users'
    ///   processes, claude itself, interactive shells, tmux and the like, or launchd jobs.
    /// - Parameter launchdJobs: pids launchd manages (`LaunchdJobs.pids()`); nil if unknown,
    ///   in which case no job outside Claude counts as detached.
    public static func build(_ a: Attribution, processes: [ProcessRow], launchdJobs: Set<Int32>?,
                             selfPid: Int32 = getpid()) -> (leftovers: [ProcessJob], services: [ProcessJob]) {
        let byPid = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var children: [Int32: [Int32]] = [:]
        for p in processes where p.pid != p.ppid { children[p.ppid, default: []].append(p.pid) }
        let managed = launchdJobs ?? []
        func stoppable(_ p: ProcessRow) -> Bool {
            isStoppable(p, selfPid: selfPid) && !managed.contains(p.pid)
        }

        // Which scope each pid is in: a live session's processes, a closed session's leftovers, or neither.
        var sessionOf: [Int32: SessionUsage] = [:]
        for s in a.sessions { for d in s.descendants { sessionOf[d.pid] = s } }
        let otherPids = Set(a.other.map(\.pid))

        /// The root's tree within `scope`, stopping at (and leaving out) anything not stoppable.
        func tree(_ root: ProcessRow, within scope: (Int32) -> Bool) -> [ProcessRow] {
            var out = [root]
            var queue = [root.pid]
            var seen: Set<Int32> = [root.pid]
            while !queue.isEmpty {
                let pid = queue.removeFirst()
                for c in children[pid] ?? [] where !seen.contains(c) && scope(c) {
                    seen.insert(c)
                    guard let row = byPid[c], stoppable(row) else { continue }
                    out.append(row)
                    queue.append(c)
                }
            }
            return out
        }

        func job(_ members: [ProcessRow], owner: ProcessJob.Owner) -> ProcessJob {
            let listener = members.first { !$0.details.listeningPorts.isEmpty }
            let named = listener ?? members.first { !ProcessKind.isWrapper($0) } ?? members[0]
            let ports = Set(members.flatMap(\.details.listeningPorts)).sorted()
            return ProcessJob(roots: [members[0]], members: members, owner: owner, label: ProcessKind.label(named),
                              ports: ports, cwd: named.details.cwd ?? members[0].details.cwd)
        }

        var used = Set<Int32>()

        // 1. Left behind by closed sessions: one job per orphan tree.
        let orphanPids = Set(a.orphanTrees.flatMap(\.pids))
        var leftovers: [ProcessJob] = []
        for t in a.orphanTrees {
            guard let root = byPid[t.root], stoppable(root) else { continue }
            let members = tree(root, within: { orphanPids.contains($0) })
            used.formUnion(members.map(\.pid))
            leftovers.append(job(members, owner: .closedSession))
        }

        // 2. Servers (and detached build daemons), from wherever they came.
        /// Climbs from a listener to the top of its job: through parents that only started it
        /// (one child each), stopping at anything not stoppable or outside the same scope.
        func top(of p: ProcessRow, within scope: (Int32) -> Bool) -> ProcessRow {
            var cur = p
            var hops = 0
            while let parent = byPid[cur.ppid], parent.pid > 1, scope(parent.pid), stoppable(parent),
                  (children[parent.pid] ?? []).count == 1, hops < 64 {
                cur = parent
                hops += 1
            }
            return cur
        }
        /// The app (or, failing that, the process) that started `root` and is still running.
        func launcher(of root: ProcessRow) -> String? {
            var cur = root
            var hops = 0
            while let parent = byPid[cur.ppid], parent.pid > 1, hops < 64 {
                if ProcessKind.isAppOrSystem(parent) { return Attribution.groupName(for: parent) }
                cur = parent
                hops += 1
            }
            return byPid[root.ppid].flatMap { $0.pid > 1 ? ProcessKind.label($0) : nil }
        }

        var services: [ProcessJob] = []
        func add(root: ProcessRow, owner: ProcessJob.Owner, within scope: @escaping (Int32) -> Bool,
                 require: ([ProcessRow]) -> Bool) {
            guard !used.contains(root.pid), stoppable(root) else { return }
            let members = tree(root, within: scope).filter { !used.contains($0.pid) }
            guard !members.isEmpty, members[0].pid == root.pid, require(members) else { return }
            used.formUnion(members.map(\.pid))
            services.append(job(members, owner: owner))
        }
        let listens: ([ProcessRow]) -> Bool = { $0.contains { !$0.details.listeningPorts.isEmpty } }

        // Servers in live sessions' trees.
        for s in a.sessions {
            let scope: (Int32) -> Bool = { sessionOf[$0]?.process.pid == s.process.pid }
            for p in s.descendants where !p.details.listeningPorts.isEmpty && stoppable(p) {
                add(root: top(of: p, within: scope), owner: .session(pid: s.process.pid, name: s.record.name),
                    within: scope, require: listens)
            }
            // Build daemons a session detached (Gradle, Kotlin): they outlive the build on purpose.
            for p in s.descendants where s.detachedPids.contains(p.pid) && p.ppid == 1 && ProcessKind.isBuildTool(p) {
                add(root: p, owner: .session(pid: s.process.pid, name: s.record.name), within: scope, require: { _ in true })
            }
        }

        // Outside Claude: detached jobs (re-parented to launchd, which doesn't manage them) that
        // listen or build, then servers something still running started.
        let inOther: (Int32) -> Bool = { otherPids.contains($0) }
        if launchdJobs != nil {
            for p in a.other where p.ppid == 1 {
                add(root: p, owner: .detached, within: inOther, require: { members in
                    members.contains { !$0.details.listeningPorts.isEmpty || ProcessKind.isBuildTool($0) }
                })
            }
        }
        /// Under a launchd job: launchd may restart it, so it isn't offered.
        func underLaunchdJob(_ p: ProcessRow) -> Bool {
            var cur = p
            var hops = 0
            while let parent = byPid[cur.ppid], parent.pid > 1, hops < 64 {
                if managed.contains(parent.pid) { return true }
                cur = parent
                hops += 1
            }
            return false
        }
        for p in a.other where !p.details.listeningPorts.isEmpty && stoppable(p) && !underLaunchdJob(p) {
            let root = top(of: p, within: inOther)
            guard root.ppid != 1 else { continue }   // detached: decided above
            add(root: root, owner: launcher(of: root).map { .launcher($0) } ?? .detached, within: inOther, require: listens)
        }

        return (merged(leftovers).sorted(by: serversThenHeaviest), merged(services).sorted(by: serversThenHeaviest))
    }

    /// Lists identical jobs once: the same label, owner and folder, and no ports (servers on
    /// different ports are told apart by them). Eleven MSBuild nodes become "MSBuild node ×11".
    static func merged(_ jobs: [ProcessJob]) -> [ProcessJob] {
        struct Key: Hashable { let label: String; let owner: String; let cwd: String? }
        func key(_ j: ProcessJob) -> Key? {
            j.ports.isEmpty ? Key(label: j.label, owner: "\(j.owner)", cwd: j.cwd) : nil
        }
        var groups: [Key: [ProcessJob]] = [:]
        for j in jobs { if let k = key(j) { groups[k, default: []].append(j) } }
        var emitted = Set<Key>()
        return jobs.compactMap { j in
            guard let k = key(j), let group = groups[k], group.count > 1 else { return j }
            guard emitted.insert(k).inserted else { return nil }
            let ordered = group.sorted { $0.root.pid < $1.root.pid }
            return ProcessJob(roots: ordered.flatMap(\.roots), members: ordered.flatMap(\.members), owner: j.owner,
                              label: j.label, ports: [], cwd: j.cwd)
        }
    }

    /// Can be stopped by this app: the user's own, not launchd or this app, and not something
    /// that is never stopped as part of a job (claude, an app or part of macOS, an interactive
    /// shell, tmux and the like).
    public static func isStoppable(_ p: ProcessRow, selfPid: Int32 = getpid()) -> Bool {
        p.details.ownedByUser && p.pid > 1 && p.pid != selfPid && !Attribution.isClaude(p)
            && !ProcessKind.isAppOrSystem(p) && !ProcessKind.isBoundary(p)
    }

    static func serversThenHeaviest(_ a: ProcessJob, _ b: ProcessJob) -> Bool {
        if a.ports.isEmpty != b.ports.isEmpty { return !a.ports.isEmpty }
        if !a.ports.isEmpty, a.ports.first != b.ports.first { return (a.ports.first ?? 0) < (b.ports.first ?? 0) }
        if a.totalRSSBytes != b.totalRSSBytes { return a.totalRSSBytes > b.totalRSSBytes }
        return a.root.pid < b.root.pid
    }
}
