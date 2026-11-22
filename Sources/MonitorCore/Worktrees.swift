import Foundation

/// One entry of `git worktree list --porcelain`.
public struct GitWorktree: Equatable, Sendable {
    public let path: String
    public let head: String?
    /// Short branch name; nil when detached.
    public let branch: String?
    public let isMain: Bool
    public let isBare: Bool
    public let isLocked: Bool
    public let isPrunable: Bool

    public init(path: String, head: String?, branch: String?, isMain: Bool, isBare: Bool, isLocked: Bool, isPrunable: Bool) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isMain = isMain
        self.isBare = isBare
        self.isLocked = isLocked
        self.isPrunable = isPrunable
    }
}

/// Why a worktree is (or is not) safe to delete. Every rule fails closed: when a check
/// cannot prove the worktree holds nothing unique, the worktree is kept.
public enum WorktreeVerdict: Equatable, Sendable {
    case reclaimable
    case main, bare, locked, missing
    case inUse(String)
    /// Another registered worktree lives inside this one; removing it would take that one too.
    case containsWorktree(String)
    case recentlyActive
    case noBaseRef
    case unmerged
    /// Commits reachable only from this worktree's HEAD reflog or own refs, which removal deletes.
    case unreferencedCommits(Int)
    /// A rebase, am, merge, cherry-pick, revert or bisect is paused here.
    case operationInProgress(String)
    /// A git setup the scanner can't judge safely (e.g. core.worktree).
    case unsupported(String)
    case dirty
    /// Edits git status cannot see: skip-worktree / assume-unchanged files, or clean filters.
    case hiddenChanges([String])
    case submodules
    /// A git repository or worktree nested inside an ignored directory.
    case nestedRepository(String)
    /// Ignored files with no identical copy in the main checkout.
    case localFiles([String])
    case failed(String)

    /// Short label used to summarise skipped worktrees.
    public var category: String {
        switch self {
        case .reclaimable: return "reclaimable"
        case .main, .bare: return "main checkout"
        case .locked: return "locked"
        case .missing: return "missing"
        case .inUse: return "in use"
        case .containsWorktree, .nestedRepository: return "contains another repo"
        case .recentlyActive: return "recently active"
        case .noBaseRef: return "no origin/main"
        case .unmerged: return "not in origin/main"
        case .unreferencedCommits: return "unreferenced commits"
        case .operationInProgress: return "git operation in progress"
        case .unsupported: return "unusual git setup"
        case .dirty: return "has edits"
        case .hiddenChanges: return "hidden edits"
        case .submodules: return "has submodules"
        case .localFiles: return "has local files"
        case .failed: return "git error"
        }
    }

    /// Human-readable reason, for a refused deletion.
    public var explanation: String {
        switch self {
        case .inUse(let why): return why
        case .containsWorktree(let p): return "it contains another worktree: \(p)"
        case .nestedRepository(let p): return "it contains a git repository: \(p)"
        case .unreferencedCommits(let n): return "\(n) commit(s) exist only in its history"
        case .operationInProgress(let what): return what
        case .unsupported(let what): return what
        case .hiddenChanges(let files): return "edits git status can't see: \(files.prefix(3).joined(separator: ", "))"
        case .localFiles(let files): return "local files not in the main checkout: \(files.prefix(3).joined(separator: ", "))"
        case .failed(let msg): return "git error: \(msg)"
        default: return category
        }
    }
}

/// One entry of the index, from `git ls-files -s -v`.
public struct IndexEntry: Equatable, Sendable {
    /// H cached, S skip-worktree; lower case means assume-unchanged.
    public let tag: Character
    public let mode: String
    public let path: String

    /// git status does not look at this file's working copy.
    public var hidesEdits: Bool { tag == "S" || tag.isLowercase }
    public var isGitlink: Bool { mode == "160000" }
}

public struct ReclaimableWorktree: Equatable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    /// The repository's main checkout, used to run `git worktree remove`.
    public let repo: String
    public let branch: String?
    /// Fully qualified, e.g. refs/remotes/origin/main.
    public let baseRef: String
    public let lastActivity: Date?
    /// `du` size; approximate (hard links and APFS clones may be counted in full).
    public let sizeBytes: Int64?

    /// `baseRef` for display: origin/main.
    public var baseName: String { Worktrees.displayName(ofRef: baseRef) }
}

public struct WorktreeScan: Sendable {
    public let finishedAt: Date
    public let duration: TimeInterval
    public let repoCount: Int
    public let worktreeCount: Int
    public let reclaimable: [ReclaimableWorktree]
    /// Count of skipped worktrees per `WorktreeVerdict.category`.
    public let skipped: [String: Int]

    public var totalBytes: Int64 { reclaimable.reduce(0) { $0 + ($1.sizeBytes ?? 0) } }

    public func removing(_ paths: Set<String>) -> WorktreeScan {
        WorktreeScan(finishedAt: finishedAt, duration: duration, repoCount: repoCount, worktreeCount: worktreeCount,
                     reclaimable: reclaimable.filter { !paths.contains($0.path) }, skipped: skipped)
    }
}

public struct WorktreePolicy: Sendable {
    /// Directories searched (to `searchDepth` levels) for git repositories.
    public var roots: [String] = [NSHomeDirectory()]
    public var searchDepth = 2
    /// Worktrees whose git metadata changed more recently than this are left alone,
    /// so a session that just created one is not raced.
    public var minIdleHours = 24.0
    /// Where remove() saves commit messages that would otherwise be deleted with a worktree.
    public var savedMessagesDirectory = NSHomeDirectory() + "/Library/Application Support/ClaudeMonitor/Saved commit messages"
    /// At most this many repositories inside dependency folders are checked per worktree.
    public var maxNestedRepositories = 50
    /// Base refs tried in order; the first that exists in a repo is its "origin/main". Fully
    /// qualified, so a local branch or tag that happens to be named origin/main can't stand in.
    public var baseRefs = ["refs/remotes/origin/main", "refs/remotes/origin/HEAD", "refs/remotes/origin/master"]
    public var skipDirectories: Set<String> = ["Library", "Applications", "Movies", "Music", "Pictures",
                                               "node_modules", "Downloads", "Dropbox"]
    /// Ignored directories with these names hold dependencies or caches that a package manager
    /// or build recreates. Their contents are not compared (they are still searched for nested repos).
    public var regenerableDirectories: Set<String> = [
        "node_modules", ".build", "DerivedData", "Pods", ".swiftpm", ".gradle", ".dart_tool",
        "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".tox", ".venv", "venv",
        ".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache", ".expo",
    ]
    /// Usually build output, but common enough names that one could hold hand-written files.
    /// They count as regenerable only when the main checkout has a directory at the same path,
    /// i.e. the project really builds there. Otherwise each file is compared like any other.
    public var buildOutputDirectories: Set<String> = ["bin", "obj", "build", "dist", "out", "target", "coverage", ".cache"]
    /// A branch not merged by ancestry is checked commit by commit (`git cherry`) only when it has at
    /// most `maxCommitsToCompare` commits and the base has at most `maxBaseCommitsToCompare` commits
    /// since the fork point. Beyond either limit the worktree is kept.
    public var maxCommitsToCompare = 200
    public var maxBaseCommitsToCompare = 1000
    /// Above this many ignored files to compare (listed one by one or found in ignored folders
    /// that aren't build output), stop checking and keep the worktree.
    public var maxIgnoredFilesToVerify = 5000

    public init() {}
}

public enum Worktrees {
    /// Parses `git worktree list --porcelain`, with `-z` (NUL-terminated lines, so a path may
    /// contain newlines) or without.
    public static func parsePorcelain(_ text: String) -> [GitWorktree] {
        let separator: Character = text.contains("\0") ? "\0" : "\n"
        var blocks: [[Substring]] = [[]]
        for line in text.split(separator: separator, omittingEmptySubsequences: false) {
            if line.isEmpty { blocks.append([]) } else { blocks[blocks.count - 1].append(line) }
        }
        var out: [GitWorktree] = []
        for block in blocks where !block.isEmpty {
            var path: String?
            var head: String?
            var branch: String?
            var bare = false, locked = false, prunable = false
            for line in block {
                let (key, value) = splitOnce(line)
                switch key {
                case "worktree": path = value
                case "HEAD": head = value
                case "branch": branch = value.map { $0.hasPrefix("refs/heads/") ? String($0.dropFirst(11)) : $0 }
                case "bare": bare = true
                case "locked": locked = true
                case "prunable": prunable = true
                default: break
                }
            }
            guard let path else { continue }
            out.append(GitWorktree(path: path, head: head, branch: branch, isMain: out.isEmpty,
                                   isBare: bare, isLocked: locked, isPrunable: prunable))
        }
        return out
    }

    /// The gitdir a linked worktree's `.git` file points to, resolved against the worktree
    /// directory when relative (`git worktree add --relative-paths`).
    public static func gitdir(fromGitFile contents: String, worktree: String) -> String? {
        guard let line = contents.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        let raw = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        return raw.hasPrefix("/") ? raw : URL(fileURLWithPath: raw, relativeTo: URL(fileURLWithPath: worktree, isDirectory: true)).standardizedFileURL.path
    }

    /// `gitdir: /repo/.git/worktrees/name` (a linked worktree's `.git` file) -> `/repo`.
    public static func mainRepo(fromGitFile contents: String, worktree: String = "/") -> String? {
        guard let gitdir = gitdir(fromGitFile: contents, worktree: worktree),
              let r = gitdir.range(of: "/.git/worktrees/") else { return nil }
        return String(gitdir[..<r.lowerBound])
    }

    /// True when `path` is `root` or inside it. Case-insensitive, because macOS volumes
    /// usually are: a process can sit in /x/casewt while git records /x/CaseWT.
    public static func contains(_ root: String, _ path: String) -> Bool {
        // Same normal form (a cwd can be NFD where git recorded NFC), then compare bytes:
        // String.hasPrefix works on characters, and a "/" followed by a combining mark is one
        // character, so "/r/\u{301}x" wouldn't count as inside "/r".
        func normal(_ s: String) -> String { s.lowercased().precomposedStringWithCanonicalMapping }
        let r = normal(root), p = normal(path)
        let dir = r.utf8.last == UInt8(ascii: "/") ? r : r + "/"
        return p == r || p.utf8.starts(with: dir.utf8)
    }

    /// Path components split on "/" bytes. (Splitting a String on "/" goes by characters and
    /// misses a "/" that a following combining mark or joiner has merged into one character.)
    public static func components(_ path: String) -> [String] {
        path.utf8.split(separator: UInt8(ascii: "/")).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Whether anything is using the worktree: an open Claude session, a Codex thread that works
    /// in it (loaded or not: the Codex app reopens a thread in its folder until it's archived), a
    /// process whose working directory is inside it, or a process whose command line names it.
    public static func usage(of path: String, processes: [ProcessRow], cwds: [Int32: String],
                             sessions: [SessionRecord], codexThreads: [CodexThread] = []) -> String? {
        if let s = sessions.first(where: { $0.cwd.map { contains(path, $0) } ?? false }) {
            return "\(s.agent.sessionNoun) “\(s.name)” is open here"
        }
        if let t = codexThreads.sorted(by: { $0.id < $1.id }).first(where: { $0.cwd.map { contains(path, $0) } ?? false }) {
            return "Codex thread “\(t.title ?? t.id)” works here"
        }
        // Worktrees a session made in its own scratchpad (…/<sessionId>/scratchpad/…).
        if let s = sessions.first(where: { $0.sessionId.map { !$0.isEmpty && path.contains("/\($0)/") } ?? false }) {
            return "Belongs to Claude session “\(s.name)”"
        }
        let byPid = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        if let (pid, _) = cwds.sorted(by: { $0.key < $1.key }).first(where: { contains(path, $0.value) }) {
            return "\(byPid[pid]?.name ?? "pid \(pid)") (pid \(pid)) is running here"
        }
        if let p = processes.first(where: { mentions($0.args, path) }) {
            return "\(p.name) (pid \(p.pid)) references it"
        }
        return nil
    }

    /// Parses `git status --porcelain=v1 -z --ignored=matching`. Returns tracked/untracked
    /// changes, and ignored entries (directories keep their trailing "/").
    public static func parseStatus(_ z: String) -> (changes: [String], ignored: [String]) {
        var changes: [String] = []
        var ignored: [String] = []
        var tokens = z.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        while let entry = tokens.next() {
            // Bytes, not characters: a path that starts with a combining mark merges with the
            // separating space into one character.
            let bytes = Array(entry.utf8)
            guard bytes.count > 3 else { continue }
            let code = String(decoding: bytes[0..<2], as: UTF8.self)
            let path = String(decoding: bytes[3...], as: UTF8.self)
            if code == "!!" {
                ignored.append(path)
            } else {
                changes.append(path)
                if code.first == "R" || code.first == "C" { _ = tokens.next() }   // rename source path
            }
        }
        return (changes, ignored)
    }

    /// Entries of `git ls-files -s -v -z`: "<tag> <mode> <sha> <stage>\t<path>".
    public static func parseIndex(_ lsFiles: String) -> [IndexEntry] {
        lsFiles.split(separator: "\0", omittingEmptySubsequences: true).compactMap { entry in
            guard let tab = entry.firstIndex(of: "\t"), let tag = entry.first else { return nil }
            let fields = entry[..<tab].split(separator: " ")
            guard fields.count >= 2 else { return nil }
            return IndexEntry(tag: tag, mode: String(fields[1]), path: String(entry[entry.index(after: tab)...]))
        }
    }

    /// Commits named in a reflog file ("<old> <new> <who> <when>\t<message>" per line). Both
    /// old and new values count: git keeps both reachable. The all-zero "no commit" is skipped.
    public static func reflogCommits(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).flatMap { line in
            line.split(separator: " ", maxSplits: 2).prefix(2).map(String.init)
        }.filter { sha in
            (sha.count == 40 || sha.count == 64) && sha.allSatisfy(\.isHexDigit) && sha.contains { $0 != "0" }
        }
    }

    /// Driver names from `git config --get-regexp '^filter\..+\.(clean|process)$'`.
    public static func filterDrivers(_ config: String) -> Set<String> {
        Set(config.split(separator: "\n").compactMap { line -> String? in
            let key = line.split(separator: " ", maxSplits: 1).first ?? ""
            let parts = key.split(separator: ".", omittingEmptySubsequences: false)
            return parts.count >= 3 ? parts[1..<(parts.count - 1)].joined(separator: ".") : nil
        })
    }

    /// (path, value) pairs from `git check-attr -z` output (NUL-separated path, attribute, value).
    public static func attributeValues(_ checkAttr: String) -> [(path: String, value: String)] {
        let f = checkAttr.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        return stride(from: 0, to: f.count - 2, by: 3).map { (f[$0], f[$0 + 2]) }
    }

    /// refs/remotes/origin/main -> origin/main, refs/heads/x -> x.
    public static func displayName(ofRef ref: String) -> String {
        for prefix in ["refs/remotes/", "refs/heads/", "refs/tags/"] where ref.hasPrefix(prefix) {
            return String(ref.dropFirst(prefix.count))
        }
        return ref
    }

    /// Environment for git subprocesses: inherited GIT_* variables (GIT_DIR, GIT_WORK_TREE,
    /// GIT_INDEX_FILE, …) would point git at a different repository, so all are dropped.
    public static func gitEnvironment(from base: [String: String]) -> [String: String] {
        var env = base.filter { !$0.key.hasPrefix("GIT_") }
        env["GIT_OPTIONAL_LOCKS"] = "0"     // never rewrite the index while just looking
        env["GIT_TERMINAL_PROMPT"] = "0"
        return env
    }

    static func mentions(_ args: String, _ path: String) -> Bool {
        let a = args.lowercased(), p = path.lowercased()
        return a.contains(p + "/") || a.contains(p + " ") || a.hasSuffix(p)
    }

    private static func splitOnce(_ line: Substring) -> (Substring, String?) {
        guard let space = line.firstIndex(of: " ") else { return (line, nil) }
        return (line[..<space], String(line[line.index(after: space)...]))
    }
}
