import Foundation

/// One row of the process table, as reported by `ps`.
public struct ProcessRow: Equatable, Sendable {
    public let pid: Int32
    public let ppid: Int32
    /// `ps` %cpu: 100 means one full core.
    public let cpuPercent: Double
    public let rssKB: Int64
    public let elapsedSeconds: Int
    /// `ps` stat column, e.g. "R+", "S", "Z", "T".
    public let state: String
    /// Full executable path from `ps -o comm` (may contain spaces).
    public let executablePath: String
    /// Full command line from `ps -o args`.
    public let args: String

    /// What the kernel adds to the `ps` row (owner, ports, folder…); filled by `ProcessInspector`.
    public var details: ProcessDetails

    public init(pid: Int32, ppid: Int32, cpuPercent: Double, rssKB: Int64, elapsedSeconds: Int,
                state: String, executablePath: String, args: String, details: ProcessDetails = ProcessDetails()) {
        self.pid = pid
        self.ppid = ppid
        self.cpuPercent = cpuPercent
        self.rssKB = rssKB
        self.elapsedSeconds = elapsedSeconds
        self.state = state
        self.executablePath = executablePath
        self.args = args
        self.details = details
    }

    public var name: String { (executablePath as NSString).lastPathComponent }
    public var cores: Double { cpuPercent / 100 }
    public var rssBytes: Int64 { rssKB * 1024 }

    /// When the process started, as of a snapshot taken at `takenAt` (to `ps`'s one-second resolution).
    public func startTime(takenAt: Date) -> Date { takenAt.addingTimeInterval(-TimeInterval(elapsedSeconds)) }
}

/// What `ps` doesn't show, read from the kernel by `ProcessInspector`. Left empty (and
/// `ownedByUser` false) for other users' processes, apps and system processes, and for a process
/// that exited mid-sample, so anything that acts on processes fails closed.
public struct ProcessDetails: Equatable, Sendable {
    /// The process runs as the current user (only those can be stopped).
    public var ownedByUser = false
    /// The real executable (`proc_pidpath`). `ProcessRow.executablePath` comes from `ps -o comm`,
    /// which can be just the name the process was started with.
    public var imagePath: String?
    /// Its current working folder.
    public var cwd: String?
    /// TCP ports it is listening on.
    public var listeningPorts: [UInt16] = []
    /// `CLAUDE_CODE_SESSION_ID` from its environment. Claude Code sets it for every command its
    /// Bash tool runs, and everything those commands start inherits it.
    public var claudeSessionId: String?
    /// `CLAUDE_PID` from its environment: the claude process that started it.
    public var claudePid: Int32?
    /// `CODEX_THREAD_ID` (or, failing that, `CODEX_SESSION_ID`) from its environment. Codex sets
    /// it for every command it runs, and everything those commands start inherits it.
    public var codexThreadId: String?

    public init(ownedByUser: Bool = false, imagePath: String? = nil, cwd: String? = nil,
                listeningPorts: [UInt16] = [], claudeSessionId: String? = nil, claudePid: Int32? = nil,
                codexThreadId: String? = nil) {
        self.ownedByUser = ownedByUser
        self.imagePath = imagePath
        self.cwd = cwd
        self.listeningPorts = listeningPorts
        self.claudeSessionId = claudeSessionId
        self.claudePid = claudePid
        self.codexThreadId = codexThreadId
    }

    /// Its environment says a Claude session started it.
    public var hasClaudeEnvironment: Bool { claudeSessionId != nil || claudePid != nil }
    /// Its environment says a Codex thread started it.
    public var hasCodexEnvironment: Bool { codexThreadId != nil }
}

public enum ProcessTable {
    /// Arguments for the main `ps` call; parse its output with `parseMain`.
    public static let mainArguments = ["-Axww", "-o", "pid=,ppid=,pcpu=,rss=,etime=,stat=,args="]
    /// Arguments for the executable-path `ps` call; parse its output with `parseComm`.
    public static let commArguments = ["-Axo", "pid=,comm="]

    /// Parses `ps -Axww -o pid=,ppid=,pcpu=,rss=,etime=,stat=,args=` output.
    /// Returns rows keyed by pid, without executable paths (see `merge`).
    public static func parseMain(_ text: String) -> [Int32: ProcessRow] {
        var rows: [Int32: ProcessRow] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let (fields, rest) = splitFields(line, count: 6),
                  let pid = Int32(fields[0]),
                  let ppid = Int32(fields[1]),
                  let cpu = Double(fields[2]),
                  let rss = Int64(fields[3]),
                  let elapsed = parseElapsed(String(fields[4]))
            else { continue }
            rows[pid] = ProcessRow(pid: pid, ppid: ppid, cpuPercent: cpu, rssKB: rss,
                                   elapsedSeconds: elapsed, state: String(fields[5]),
                                   executablePath: "", args: String(rest))
        }
        return rows
    }

    /// Parses `ps -Axo pid=,comm=` output into pid -> executable path.
    public static func parseComm(_ text: String) -> [Int32: String] {
        var paths: [Int32: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let (fields, rest) = splitFields(line, count: 1), let pid = Int32(fields[0]) else { continue }
            paths[pid] = String(rest)
        }
        return paths
    }

    /// Combines the two `ps` outputs. Processes that exited between the two calls are dropped.
    public static func merge(main: [Int32: ProcessRow], comm: [Int32: String]) -> [ProcessRow] {
        main.values.map { row in
            let path = comm[row.pid] ?? firstToken(row.args)
            return ProcessRow(pid: row.pid, ppid: row.ppid, cpuPercent: row.cpuPercent, rssKB: row.rssKB,
                              elapsedSeconds: row.elapsedSeconds, state: row.state,
                              executablePath: path, args: row.args)
        }
        .sorted { $0.pid < $1.pid }
    }

    /// Parses `ps` etime: `[[dd-]hh:]mm:ss`.
    public static func parseElapsed(_ s: String) -> Int? {
        var days = 0
        var clock = Substring(s)
        if let dash = s.firstIndex(of: "-") {
            guard let d = Int(s[..<dash]) else { return nil }
            days = d
            clock = s[s.index(after: dash)...]
        }
        let parts = clock.split(separator: ":").map { Int($0) }
        guard (2...3).contains(parts.count), parts.allSatisfy({ $0 != nil }) else { return nil }
        let nums = parts.map { $0! }
        let (h, m, sec) = nums.count == 3 ? (nums[0], nums[1], nums[2]) : (0, nums[0], nums[1])
        return ((days * 24 + h) * 60 + m) * 60 + sec
    }

    static func firstToken(_ s: String) -> String {
        String(s.split(separator: " ", maxSplits: 1).first ?? "")
    }

    /// Splits off `count` whitespace-separated fields; the remainder (spaces intact) is returned too.
    static func splitFields(_ line: Substring, count: Int) -> ([Substring], Substring)? {
        var fields: [Substring] = []
        var i = line.startIndex
        func isSpace(_ c: Character) -> Bool { c == " " || c == "\t" }
        while fields.count < count {
            while i < line.endIndex, isSpace(line[i]) { i = line.index(after: i) }
            guard i < line.endIndex else { return nil }
            let start = i
            while i < line.endIndex, !isSpace(line[i]) { i = line.index(after: i) }
            fields.append(line[start..<i])
        }
        while i < line.endIndex, isSpace(line[i]) { i = line.index(after: i) }
        return (fields, line[i...])
    }
}
