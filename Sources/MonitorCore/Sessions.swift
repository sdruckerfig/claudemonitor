import Foundation

public enum SessionStatus: Equatable, Sendable {
    case busy, idle, waiting, shell
    case other(String)

    public init(raw: String?) {
        switch raw {
        case "busy": self = .busy
        case "idle": self = .idle
        case "waiting": self = .waiting
        case "shell": self = .shell
        default: self = .other(raw ?? "unknown")
        }
    }

    public var label: String {
        switch self {
        case .busy: return "busy"
        case .idle: return "idle"
        case .waiting: return "waiting"
        case .shell: return "shell"
        case .other(let s): return s
        }
    }
}

/// Which coding agent a session belongs to.
public enum Agent: String, Equatable, Hashable, Sendable {
    case claude, codex

    /// "Claude", "Codex".
    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    /// What a session is called: "Claude session", "Codex thread".
    public var sessionNoun: String {
        switch self {
        case .claude: return "Claude session"
        case .codex: return "Codex thread"
        }
    }
}

/// A running session. For Claude Code, its status file: `~/.claude/sessions/<pid>.json`.
/// The format is internal to Claude Code, so every field except pid is optional here.
/// For Codex, a loaded thread (see `CodexSessions`): `pid` is the codex process hosting it, which
/// may host other threads too, and `sessionId` is the thread id.
public struct SessionRecord: Equatable, Sendable {
    public let agent: Agent
    /// Claude: the claude process. Codex: the codex process the thread is loaded in (an app server
    /// can host many threads, so this pid is not the session's own).
    public let pid: Int32
    public let sessionId: String?
    public let name: String
    public let cwd: String?
    public let status: SessionStatus
    public let statusUpdatedAt: Date?
    public let startedAt: Date?
    public let waitingFor: String?
    /// Codex: the thread and the subagent threads it spawned that are loaded too. Processes
    /// whose `CODEX_THREAD_ID` is one of these are the session's. Empty for Claude.
    public let threadIds: Set<String>

    public init(agent: Agent = .claude, pid: Int32, sessionId: String?, name: String, cwd: String?, status: SessionStatus,
                statusUpdatedAt: Date?, startedAt: Date?, waitingFor: String?, threadIds: Set<String> = []) {
        self.agent = agent
        self.pid = pid
        self.sessionId = sessionId
        self.name = name
        self.cwd = cwd
        self.status = status
        self.statusUpdatedAt = statusUpdatedAt
        self.startedAt = startedAt
        self.waitingFor = waitingFor
        self.threadIds = threadIds
    }

    /// Identifies the session across snapshots. Several Codex threads can share one pid.
    public var key: String {
        switch agent {
        case .claude: return "claude:\(pid)"
        case .codex: return "codex:\(sessionId ?? "pid \(pid)")"
        }
    }

    /// Codex subagent threads loaded alongside this one.
    public var subagentCount: Int { max(threadIds.count - 1, 0) }

    /// The command that resumes this session later, run from its folder.
    public var resumeCommand: String? {
        guard let id = sessionId, !id.isEmpty else { return nil }
        let cd = cwd.map { "cd \(Self.shellQuote($0)) && " } ?? ""
        switch agent {
        case .claude: return "\(cd)claude --resume \(id)"
        case .codex: return "\(cd)codex resume \(id)"
        }
    }

    static func shellQuote(_ s: String) -> String {
        s.allSatisfy { $0.isLetter || $0.isNumber || "/._-~".contains($0) }
            ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public enum SessionFiles {
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
    }

    public static func parse(_ data: Data) -> SessionRecord? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pidNum = obj["pid"] as? NSNumber
        else { return nil }
        let pid = pidNum.int32Value
        let cwd = obj["cwd"] as? String
        let fallbackName = cwd.map { ($0 as NSString).lastPathComponent } ?? "pid \(pid)"
        let name = (obj["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
        return SessionRecord(
            pid: pid,
            sessionId: obj["sessionId"] as? String,
            name: name,
            cwd: cwd,
            status: SessionStatus(raw: obj["status"] as? String),
            statusUpdatedAt: date(obj["statusUpdatedAt"] ?? obj["updatedAt"]),
            startedAt: date(obj["startedAt"]),
            waitingFor: describe(obj["waitingFor"])
        )
    }

    public static func load(from directory: URL = defaultDirectory) -> [SessionRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap(parse)
    }

    private static func date(_ value: Any?) -> Date? {
        guard let ms = (value as? NSNumber)?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    private static func describe(_ value: Any?) -> String? {
        switch value {
        case let s as String: return s
        case let d as [String: Any]: return (d["type"] ?? d["kind"] ?? d["tool"]).map { "\($0)" }
        default: return nil
        }
    }
}
