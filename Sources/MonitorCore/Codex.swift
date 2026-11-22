import Foundation
import SQLite3

/// A Codex thread as recorded in Codex's state database (`threads` table). The format is internal
/// to Codex, so everything except the id is optional here.
public struct CodexThread: Equatable, Sendable {
    public let id: String
    public let cwd: String?
    /// Its name, title, or the start of its first message; nil when it has none yet.
    public let title: String?
    /// The thread that spawned it, for a subagent.
    public let parentId: String?
    public let createdAt: Date?
    public let updatedAt: Date?
    public let archived: Bool

    public init(id: String, cwd: String?, title: String?, parentId: String?, createdAt: Date?, updatedAt: Date?,
                archived: Bool = false) {
        self.id = id
        self.cwd = cwd
        self.title = title
        self.parentId = parentId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archived = archived
    }
}

/// Codex threads that are loaded right now (open in the Codex app, the ChatGPT app's Codex, or a
/// `codex` CLI), as sessions.
///
/// Codex has no per-session status file. A loaded thread is one whose writer lock,
/// `$CODEX_HOME/thread-writer-locks/<thread id>.lock`, a `codex` process holds open; that process
/// hosts it (an app server hosts many threads at once). The thread's folder, title and last
/// activity come from Codex's state database, read-only. Every command Codex runs gets
/// `CODEX_THREAD_ID`, which is how processes are charged to a thread.
public enum CodexSessions {
    /// `$CODEX_HOME`, or `~/.codex`.
    public static var home: URL {
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    /// Codex is (or was) used on this Mac.
    public static func isInstalled(home: URL = home) -> Bool {
        FileManager.default.fileExists(atPath: home.path)
    }

    /// A thread whose newest activity is this recent counts as busy. Codex doesn't record
    /// whether a thread is working or waiting, so this is inferred from its last update.
    public static let busyWindow: TimeInterval = 45

    static let lockFolder = "/thread-writer-locks/"

    /// A `codex` executable: the CLI, or the one the Codex and ChatGPT apps run as their server.
    public static func isCodex(_ p: ProcessRow) -> Bool {
        if p.name == "codex" { return true }
        return p.details.imagePath.map { ($0 as NSString).lastPathComponent == "codex" } ?? false
    }

    /// Loaded threads: thread id → pid of the codex process holding its writer lock.
    public static func liveThreads(in processes: [ProcessRow]) -> [String: Int32] {
        var out: [String: Int32] = [:]
        // Rows without the executable's path (args split at the first space) are checked with the kernel's.
        func codex(_ p: ProcessRow) -> Bool {
            isCodex(p) || (p.args.contains("codex")
                && ProcessInspector.imagePath(p.pid).map { ($0 as NSString).lastPathComponent == "codex" } == true)
        }
        for p in processes.sorted(by: { $0.pid < $1.pid }) where codex(p) {
            for path in ProcessInspector.openFiles(p.pid, containing: lockFolder) {
                if let id = threadId(fromLockPath: path), out[id] == nil { out[id] = p.pid }
            }
        }
        return out
    }

    /// `…/thread-writer-locks/<id>.lock` → `<id>`. Codex's own `.coordination.lock` isn't a thread.
    static func threadId(fromLockPath path: String) -> String? {
        guard let r = path.range(of: lockFolder, options: .backwards) else { return nil }
        let name = path[r.upperBound...]
        guard name.hasSuffix(".lock"), !name.contains("/"), !name.hasPrefix(".") else { return nil }
        let id = String(name.dropLast(".lock".count))
        return id.isEmpty ? nil : id
    }

    /// One record per loaded thread that isn't a subagent of another loaded thread. Its loaded
    /// subagents are folded into it (`threadIds`), as Claude Code's are into its session.
    public static func records(live: [String: Int32], threads: [String: CodexThread], now: Date) -> [SessionRecord] {
        func root(of id: String) -> String {
            var cur = id
            var hops = 0
            while let parent = threads[cur]?.parentId, live[parent] != nil, parent != cur, hops < 32 {
                cur = parent
                hops += 1
            }
            return cur
        }
        var families: [String: [String]] = [:]
        for id in live.keys { families[root(of: id), default: []].append(id) }

        return families.sorted { $0.key < $1.key }.compactMap { rootId, members -> SessionRecord? in
            guard let pid = live[rootId] else { return nil }
            let t = threads[rootId]
            let updated = members.compactMap { threads[$0]?.updatedAt }.max()
            let busy = updated.map { now.timeIntervalSince($0) <= busyWindow } ?? false
            let cwd = t?.cwd ?? members.lazy.compactMap { threads[$0]?.cwd }.first
            let fallback = cwd.map { ($0 as NSString).lastPathComponent } ?? "Codex thread \(rootId.prefix(8))"
            return SessionRecord(agent: .codex, pid: pid, sessionId: rootId, name: t?.title ?? fallback, cwd: cwd,
                                 status: busy ? .busy : .idle, statusUpdatedAt: updated, startedAt: t?.createdAt,
                                 waitingFor: nil, threadIds: Set(members))
        }
    }

    /// The loaded threads among `processes`, as sessions. Without the state database they're
    /// still listed, by id, with no folder and an idle status.
    public static func load(processes: [ProcessRow], now: Date, home: URL = home) -> [SessionRecord] {
        let live = liveThreads(in: processes)
        guard !live.isEmpty else { return [] }
        let threads = (try? CodexState.threads(home: home, ids: Set(live.keys)).get()) ?? [:]
        return records(live: live, threads: threads, now: now)
    }
}

/// Codex's state database, `$CODEX_HOME/state_<n>.sqlite`, opened read-only.
public enum CodexState {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// There's no state database (Codex isn't installed, or keeps it elsewhere).
        case missing
        case unreadable(String)

        public var description: String {
            switch self {
            case .missing: return "Codex's state database wasn't found"
            case .unreadable(let why): return "Codex's state database can't be read: \(why)"
            }
        }
    }

    /// The newest-format state database: the highest `<n>` in `state_<n>.sqlite`.
    public static func databaseURL(home: URL) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        let best = names.compactMap { name -> (Int, String)? in
            guard name.hasPrefix("state_"), name.hasSuffix(".sqlite"),
                  let n = Int(name.dropFirst("state_".count).dropLast(".sqlite".count)) else { return nil }
            return (n, name)
        }.max { $0.0 < $1.0 }
        return best.map { home.appendingPathComponent($0.1) }
    }

    /// The threads with these ids, plus every thread not archived when `unarchived` is true.
    public static func threads(home: URL, ids: Set<String>, unarchived: Bool = false) -> Result<[String: CodexThread], Failure> {
        guard let url = databaseURL(home: home) else { return .failure(.missing) }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return .failure(.unreadable(db.map { String(cString: sqlite3_errmsg($0)) } ?? "can't open"))
        }
        sqlite3_busy_timeout(db, 250)

        // Select only the columns this version of Codex has, so a schema change loses detail
        // rather than everything.
        let columns = Set(query(db, "PRAGMA table_info(threads)", bind: []) { stmt in text(stmt, 1) }?.compactMap { $0 } ?? [])
        guard columns.contains("id"), columns.contains("cwd") else {
            return .failure(.unreadable("its threads table has no id or cwd"))
        }
        let wanted = ["id", "cwd", "name", "title", "preview", "source", "created_at", "updated_at", "updated_at_ms", "archived"]
        let selected = wanted.filter(columns.contains)
        var conditions: [String] = []
        let idList = Array(ids)
        if !idList.isEmpty { conditions.append("id IN (" + idList.map { _ in "?" }.joined(separator: ",") + ")") }
        if unarchived { conditions.append(columns.contains("archived") ? "archived = 0" : "1") }
        guard !conditions.isEmpty else { return .success([:]) }
        let sql = "SELECT " + selected.joined(separator: ", ") + " FROM threads WHERE " + conditions.joined(separator: " OR ")

        let rows = query(db, sql, bind: idList) { stmt -> CodexThread? in
            var value: [String: Int32] = [:]
            for (i, c) in selected.enumerated() { value[c] = Int32(i) }
            func str(_ c: String) -> String? { value[c].flatMap { text(stmt, $0) }.flatMap { $0.isEmpty ? nil : $0 } }
            func int(_ c: String) -> Int64? {
                guard let i = value[c], sqlite3_column_type(stmt, i) != SQLITE_NULL else { return nil }
                return sqlite3_column_int64(stmt, i)
            }
            guard let id = str("id") else { return nil }
            let updated = int("updated_at_ms").map { Double($0) / 1000 } ?? int("updated_at").map(Double.init)
            return CodexThread(id: id, cwd: str("cwd"),
                               title: (str("name") ?? str("title") ?? str("preview")).map(headline),
                               parentId: str("source").flatMap(parentId(fromSource:)),
                               createdAt: int("created_at").map { Date(timeIntervalSince1970: Double($0)) },
                               updatedAt: updated.map { Date(timeIntervalSince1970: $0) },
                               archived: (int("archived") ?? 0) != 0)
        }
        guard let rows else { return .failure(.unreadable(String(cString: sqlite3_errmsg(db)))) }
        var out: [String: CodexThread] = [:]
        for case let t? in rows { out[t.id] = t }
        return .success(out)
    }

    /// A subagent's `source` is JSON naming the thread that spawned it:
    /// `{"subagent":{"thread_spawn":{"parent_thread_id":"…",…}}}`. Other sources are plain words.
    static func parentId(fromSource source: String) -> String? {
        guard source.hasPrefix("{"), let data = source.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = obj["subagent"] as? [String: Any],
              let spawn = sub["thread_spawn"] as? [String: Any],
              let parent = spawn["parent_thread_id"] as? String, !parent.isEmpty else { return nil }
        return parent
    }

    /// The first line of a title or message, at most 80 characters.
    static func headline(_ s: String) -> String {
        let line = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 80 ? String(trimmed.prefix(79)) + "…" : trimmed
    }

    private static func text(_ stmt: OpaquePointer, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }

    /// Runs `sql` with `bind` as its text parameters; nil on any error.
    private static func query<T>(_ db: OpaquePointer, _ sql: String, bind: [String],
                                 _ row: (OpaquePointer) -> T) -> [T]? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, v) in bind.enumerated() {
            guard sqlite3_bind_text(stmt, Int32(i + 1), v, -1, transient) == SQLITE_OK else { return nil }
        }
        var out: [T] = []
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW: out.append(row(stmt))
            case SQLITE_DONE: return out
            default: return nil
            }
        }
    }
}
