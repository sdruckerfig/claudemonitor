import Foundation

public struct Snapshot: Sendable {
    public let takenAt: Date
    public let system: SystemMetrics
    public let hardware: [MetricStatus]
    /// Red/yellow/green for "is the hardware overloaded".
    public let rollup: Level
    /// Claude sessions and Codex threads, most urgent first.
    public let sessions: [SessionReport]
    /// Codex is used on this Mac: its threads get a section even when none is open.
    public let codexInstalled: Bool
    /// Process trees left behind by closed sessions; servers first.
    public let leftovers: [ProcessJob]
    /// Everything else listening on a TCP port, and detached build daemons, whoever started them.
    public let services: [ProcessJob]
    /// Heaviest process groups outside any session.
    public let otherGroups: [ProcessGroup]

    public var reasons: [String] { hardware.compactMap(\.reason) }
    public func sessions(of agent: Agent) -> [SessionReport] { sessions.filter { $0.usage.record.agent == agent } }

    /// - Parameter launchdJobs: pids launchd manages (`LaunchdJobs.pids()`); nil if unknown.
    public static func assemble(system: SystemMetrics, processes: [ProcessRow], records: [SessionRecord],
                                launchdJobs: Set<Int32>? = nil, now: Date, codexInstalled: Bool = false,
                                thresholds: Thresholds = Thresholds()) -> Snapshot {
        let hardware = Health.hardware(system, thresholds)
        let attribution = Attribution.build(processes: processes, records: records)
        let reports = attribution.sessions
            .map { Health.session($0, now: now, thresholds) }
            .sorted(by: moreUrgent)
        let jobs = Jobs.build(attribution, processes: processes, launchdJobs: launchdJobs)
        // Jobs listed as services aren't counted again in the app groups.
        let listed = Set(jobs.services.flatMap { $0.members.map(\.pid) })
        let groups = Attribution.groups(attribution.other.filter { !listed.contains($0.pid) })
            .filter { $0.cores >= 0.1 || $0.rssBytes >= 500 * 1_048_576 }
            .sorted { ($0.cores, $0.rssBytes) > ($1.cores, $1.rssBytes) }
        return Snapshot(takenAt: now, system: system, hardware: hardware, rollup: Health.rollup(hardware),
                        sessions: reports, codexInstalled: codexInstalled || reports.contains { $0.usage.record.agent == .codex },
                        leftovers: jobs.leftovers, services: jobs.services,
                        otherGroups: Array(groups.prefix(6)))
    }

    static func moreUrgent(_ a: SessionReport, _ b: SessionReport) -> Bool {
        if a.level != b.level { return a.level > b.level }
        if a.isStale != b.isStale { return !a.isStale }
        let rank: (SessionStatus) -> Int = { s in
            switch s {
            case .waiting: return 0
            case .busy: return 1
            case .shell: return 2
            default: return 3
            }
        }
        let (ra, rb) = (rank(a.usage.record.status), rank(b.usage.record.status))
        if ra != rb { return ra < rb }
        return a.usage.totalCores > b.usage.totalCores
    }
}

public enum MonitorError: Error, CustomStringConvertible {
    case psFailed(String)
    public var description: String {
        switch self {
        case .psFailed(let why): return "ps failed: \(why)"
        }
    }
}

/// Takes snapshots of the live system. Call `snapshot()` from a single serial queue
/// (hence `@unchecked Sendable`: the app hands it to exactly one queue).
public final class Monitor: @unchecked Sendable {
    public var thresholds: Thresholds
    private let sampler = SystemSampler()
    private let inspector = ProcessInspector()
    private let sessionsDirectory: URL

    public init(sessionsDirectory: URL = SessionFiles.defaultDirectory, thresholds: Thresholds = Thresholds()) {
        self.sessionsDirectory = sessionsDirectory
        self.thresholds = thresholds
    }

    public func snapshot() throws -> Snapshot {
        let now = Date()
        let system = sampler.sample(now: now)
        let processes = try processTable(takenAt: now)
        let records = SessionFiles.load(from: sessionsDirectory) + CodexSessions.load(processes: processes, now: now)
        return Snapshot.assemble(system: system, processes: processes, records: records,
                                 launchdJobs: LaunchdJobs.pids(), now: now,
                                 codexInstalled: CodexSessions.isInstalled(), thresholds: thresholds)
    }

    /// Every process, with the details `ProcessInspector` adds. `takenAt` should be read just
    /// before calling: it dates the rows' elapsed times.
    public func processTable(takenAt: Date) throws -> [ProcessRow] {
        let main = ProcessTable.parseMain(try Self.ps(ProcessTable.mainArguments))
        let comm = ProcessTable.parseComm(try Self.ps(ProcessTable.commArguments))
        return inspector.enrich(ProcessTable.merge(main: main, comm: comm))
    }

    static func ps(_ args: [String]) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = args
        task.environment = ["LC_ALL": "C"]   // keep %cpu as "12.5", never "12,5"
        let out = Pipe()
        task.standardOutput = out
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { throw MonitorError.psFailed("\(error)") }
        // Drain before waiting: `ps -ww` output can exceed the pipe buffer.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw MonitorError.psFailed("exit \(task.terminationStatus)") }
        return String(decoding: data, as: UTF8.self)
    }
}
