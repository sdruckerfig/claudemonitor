import Darwin
import Foundation

public enum WorktreeError: Error, CustomStringConvertible {
    case noLongerSafe(String, String)
    case gitFailed(String)
    /// `git worktree remove` deleted the worktree's git directory, then failed: what it couldn't
    /// delete is still on disk. `saved`: messages saved first whose originals git deleted.
    case partlyRemoved(path: String, git: String, saved: [String])

    public var description: String {
        switch self {
        case .noLongerSafe(let path, let why): return "\((path as NSString).lastPathComponent) was kept: \(why)"
        case .gitFailed(let msg): return msg
        case .partlyRemoved(let path, let git, let saved):
            let name = (path as NSString).lastPathComponent
            var text = "git stopped partway through deleting \(name) (\(git)). It is no longer a worktree; "
                + "the files git couldn't delete are still in \(Format.path(path))."
            if let note = WorktreeScanner.savedSummary(saved) { text += " " + note }
            return text
        }
    }
}

/// Finds linked git worktrees that are safe to delete: idle, unused, fully contained in
/// origin/main, and holding nothing git or the main checkout couldn't give back. Every rule
/// fails closed. Git runs at the caller's priority (background on a background queue). Call from one serial queue
/// (hence `@unchecked Sendable`: the app hands it to exactly one queue).
public final class WorktreeScanner: @unchecked Sendable {
    public var policy: WorktreePolicy
    /// `du` results keyed by path, reused while the worktree's git activity time is unchanged.
    private var sizeCache: [String: (activity: Date?, bytes: Int64?)] = [:]
    /// isContained results keyed by "<base sha> <head sha> <detached>": a pure function of the
    /// commits, so rescans and the re-check before deleting don't repeat `git cherry`.
    private var containedCache: [String: Bool] = [:]
    /// lstat keys of the files and folders the last classify() looked at, so remove() can tell
    /// whether anything in the worktree changed between checking and deleting.
    private var lastFileSnapshot: [String: String] = [:]
    /// Reads what is running. A property so tests can make it fail.
    var captureContext: () throws -> LiveContext = LiveContext.capture
    /// Tests only: runs right after `git status` in classify(), to land a write inside the checks.
    var afterStatus: (() -> Void)?

    public init(policy: WorktreePolicy = WorktreePolicy()) {
        self.policy = policy
    }

    public func scan(now: Date = Date()) -> WorktreeScan {
        let started = Date()
        let context = Result { try captureContext() }
        let registered = registeredWorktrees()
        let allPaths = Self.allPaths(registered)
        var skipped: [String: Int] = [:]
        var reclaimable: [ReclaimableWorktree] = []
        var total = 0

        for (repo, worktrees) in registered {
            let base = baseRef(in: repo)
            for wt in worktrees where !wt.isMain {
                total += 1
                let (verdict, activity): (WorktreeVerdict, Date?)
                switch context {
                case .success(let context):
                    (verdict, activity) = classify(wt, repo: repo, base: base?.ref, baseSHA: base?.sha, context: context,
                                                   allWorktreePaths: allPaths, now: now)
                case .failure(let error):
                    // Without the list, nothing could be shown to be unused.
                    (verdict, activity) = (.failed("running processes can't be listed: \(error)"), nil)
                }
                guard verdict == .reclaimable, let base = base?.ref else {
                    skipped[verdict.category, default: 0] += 1
                    continue
                }
                let size: Int64?
                if let cached = sizeCache[wt.path], cached.activity == activity {
                    size = cached.bytes
                } else {
                    size = Self.diskUsage(wt.path)
                    sizeCache[wt.path] = (activity, size)
                }
                reclaimable.append(ReclaimableWorktree(path: wt.path, repo: repo, branch: wt.branch, baseRef: base,
                                                       lastActivity: activity, sizeBytes: size))
            }
        }
        let current = Set(reclaimable.map(\.path))
        sizeCache = sizeCache.filter { current.contains($0.key) }
        reclaimable.sort { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
        return WorktreeScan(finishedAt: Date(), duration: Date().timeIntervalSince(started), repoCount: registered.count,
                            worktreeCount: total, reclaimable: reclaimable, skipped: skipped)
    }

    /// Re-checks every rule against the live system, then runs `git worktree remove`
    /// (never `--force`, so git itself refuses if edits appeared in the meantime).
    /// The branch is left in place. Returns the files any unsent commit messages were saved to.
    @discardableResult
    public func remove(_ item: ReclaimableWorktree, now: Date = Date()) throws -> [String] {
        let registered = registeredWorktrees(including: item.repo)
        guard let wt = registered.first(where: { $0.repo == item.repo })?.worktrees.first(where: { $0.path == item.path }) else {
            throw WorktreeError.noLongerSafe(item.path, "git no longer lists it")
        }
        guard let before = Self.fingerprint(wt.path), let gitdir = Self.gitdir(of: wt.path) else {
            throw WorktreeError.noLongerSafe(item.path, "its git metadata can't be read")
        }
        let (verdict, _) = classify(wt, repo: item.repo, base: item.baseRef, context: try liveContext(item.path),
                                    allWorktreePaths: Self.allPaths(registered), now: now)
        guard verdict == .reclaimable else { throw WorktreeError.noLongerSafe(item.path, verdict.explanation) }
        let files = lastFileSnapshot
        // The checks take a while. Right before deleting, make sure nothing started using the
        // worktree and nothing moved its HEAD, reflog, index or refs in the meantime (git
        // worktree remove refuses edited files, but not new commits).
        let last = try liveContext(item.path)
        for path in Set([Self.realPath(wt.path), wt.path]) {
            if let why = Worktrees.usage(of: path, processes: last.processes, cwds: last.cwds, sessions: last.sessions,
                                         codexThreads: last.codexThreads) {
                throw WorktreeError.noLongerSafe(item.path, why)
            }
        }
        guard Self.fingerprint(wt.path) == before,
              files.allSatisfy({ Self.statKey($0.key) == $0.value }) else {
            throw WorktreeError.noLongerSafe(item.path, "it changed while it was being checked")
        }
        let saved = try saveUnsentMessages(gitdir: gitdir, worktree: wt.path, repo: item.repo)
        let result = Self.git(["worktree", "remove", item.path], in: item.repo)
        guard result.status == 0 else {
            let message = result.err.trimmingCharacters(in: .whitespacesAndNewlines)
            let kept = Self.discardRedundantCopies(saved)
            // Once git starts deleting it carries on: a file it can't delete doesn't stop it from
            // deleting the git directory (and the messages in it) and unregistering the worktree.
            if !Self.exists(gitdir) { throw WorktreeError.partlyRemoved(path: item.path, git: message, saved: kept) }
            throw WorktreeError.gitFailed(([message] + [Self.savedSummary(kept)].compactMap { $0 }).joined(separator: " "))
        }
        return saved.map(\.copy)
    }

    private func liveContext(_ path: String) throws -> LiveContext {
        do { return try captureContext() } catch {
            throw WorktreeError.noLongerSafe(path, "running processes can't be listed (\(error))")
        }
    }

    /// "Saved N unsent message(s) to <folder>.", or nil for none.
    public static func savedSummary(_ files: [String]) -> String? {
        guard let folder = files.first.map({ ($0 as NSString).deletingLastPathComponent }) else { return nil }
        return "Saved \(files.count) unsent message(s) to \(Format.path(folder))."
    }

    struct SavedMessage {
        let copy: String
        let original: String
    }

    /// After a failed removal: deletes each copy whose original is still in the worktree's git
    /// directory, and returns the rest (git deleted those originals before it failed).
    static func discardRedundantCopies(_ saved: [SavedMessage]) -> [String] {
        var kept: [String] = []
        for message in saved {
            if exists(message.original) {
                try? FileManager.default.removeItem(atPath: message.copy)
            } else {
                kept.append(message.copy)
            }
        }
        return kept
    }

    /// The worktree's git directory can hold a message that was never used: COMMIT_EDITMSG after
    /// a commit a hook rejected (or that had nothing to commit), MERGE_MSG, SQUASH_MSG, and
    /// TAG_EDITMSG or NOTES_EDITMSG, which git leaves when it can't create the tag or note.
    /// Removal deletes them, so each one that isn't the message of a recent commit is copied to
    /// `policy.savedMessagesDirectory` first. Throws when one can't be read or saved.
    private func saveUnsentMessages(gitdir: String, worktree: String, repo: String) throws -> [SavedMessage] {
        var drafts: [(name: String, text: String)] = []
        for name in ["COMMIT_EDITMSG", "MERGE_MSG", "SQUASH_MSG", "TAG_EDITMSG", "NOTES_EDITMSG"] where Self.exists(gitdir + "/" + name) {
            guard let data = FileManager.default.contents(atPath: gitdir + "/" + name) else {
                throw WorktreeError.noLongerSafe(worktree, "its \(name) can't be read")
            }
            let text = String(decoding: data, as: UTF8.self)
            if !Self.messageBody(text).isEmpty { drafts.append((name, text)) }
        }
        guard !drafts.isEmpty else { return [] }
        let log = Self.git(["log", "-n", "500", "--format=%B%x00", "HEAD", "--branches", "--remotes", "--"], in: worktree)
        let used = Set(log.out.split(separator: "\0").map { Self.messageBody(String($0)) })
        let stamp: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HHmmss"
            return f.string(from: Date())
        }()
        let folder = policy.savedMessagesDirectory + "/" + (repo as NSString).lastPathComponent
        var saved: [SavedMessage] = []
        do {
            for draft in drafts where !used.contains(Self.messageBody(draft.text)) {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                let file = folder + "/\((worktree as NSString).lastPathComponent) \(stamp) \(draft.name).txt"
                try Data(draft.text.utf8).write(to: URL(fileURLWithPath: file), options: .withoutOverwriting)
                saved.append(SavedMessage(copy: file, original: gitdir + "/" + draft.name))
            }
        } catch {
            for message in saved { try? FileManager.default.removeItem(atPath: message.copy) }
            throw WorktreeError.noLongerSafe(worktree, "its unsent commit message couldn't be saved: \(error.localizedDescription)")
        }
        return saved
    }

    /// A commit message without git's comment lines and blank lines, for comparing.
    static func messageBody(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("#") && !$0.allSatisfy(\.isWhitespace) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
    }

    // MARK: Rules

    /// `allWorktreePaths`: every worktree path registered in any scanned repo, so a worktree
    /// that contains another one (Claude Code nests agent worktrees under .claude/worktrees/) is kept.
    /// `baseSHA` is `base` resolved (looked up when nil).
    func classify(_ wt: GitWorktree, repo: String, base: String?, baseSHA: String? = nil, context: LiveContext,
                  allWorktreePaths: [String] = [], now: Date) -> (WorktreeVerdict, Date?) {
        lastFileSnapshot = [:]
        if wt.isMain { return (.main, nil) }
        if wt.isBare { return (.bare, nil) }
        if wt.isLocked { return (.locked, nil) }
        if wt.isPrunable || !FileManager.default.fileExists(atPath: wt.path) { return (.missing, nil) }

        let real = Self.realPath(wt.path)
        for path in Set([real, wt.path]) {
            if let why = Worktrees.usage(of: path, processes: context.processes, cwds: context.cwds, sessions: context.sessions,
                                         codexThreads: context.codexThreads) {
                return (.inUse(why), nil)
            }
        }
        let own = Set([real.lowercased(), wt.path.lowercased()])
        if let nested = allWorktreePaths.first(where: { p in
            !own.contains(p.lowercased()) && (Worktrees.contains(real, p) || Worktrees.contains(wt.path, p))
        }) {
            return (.containsWorktree(nested), nil)
        }

        // An unknown activity time (unreadable .git file) counts as recent.
        let activity = lastActivity(wt.path)
        guard let activity, now.timeIntervalSince(activity) >= policy.minIdleHours * 3600 else {
            return (.recentlyActive, activity)
        }
        guard let gitdir = Self.gitdir(of: wt.path) else { return (.failed("can't read its .git file"), activity) }
        // A paused rebase, am, merge, cherry-pick, revert, bisect or notes merge keeps its state
        // (patches, todo lists, good/bad verdicts, conflict resolutions) in the worktree's gitdir,
        // and git status shows nothing.
        if let op = Self.operationInProgress(gitdir: gitdir) { return (.operationInProgress(op), activity) }
        // Submodules initialised in this worktree keep their own repositories in <gitdir>/modules.
        if Self.exists(gitdir + "/modules") { return (.submodules, activity) }

        guard let base, let baseSHA = baseSHA ?? Self.commit(base, in: wt.path),
              let headSHA = wt.head ?? Self.commit("HEAD", in: wt.path) else { return (.noBaseRef, activity) }
        if !isContainedCached(head: headSHA, base: baseSHA, worktree: wt.path, detached: wt.branch == nil) {
            return (.unmerged, activity)
        }

        guard let orphans = unreferencedCommits(worktree: wt.path, gitdir: gitdir, branch: wt.branch) else {
            return (.failed("could not read the worktree's reflog"), activity)
        }
        if orphans > 0 { return (.unreferencedCommits(orphans), activity) }

        // core.worktree (shared, or per worktree with extensions.worktreeConfig) would point every
        // git command below at another directory. Clean/process filters are checked further down.
        let config = Self.git(["config", "--get-regexp", #"^(filter\..+\.(clean|process)|core\.worktree)$"#], in: wt.path)
        guard config.status == 0 || config.status == 1 else { return (.failed(config.err), activity) }   // 1: none set
        if Self.lines(config.out).contains(where: { $0.lowercased().hasPrefix("core.worktree") }) {
            return (.unsupported("core.worktree is set in its git config"), activity)
        }

        // Explicit flags override status.showUntrackedFiles and submodule.*.ignore; the -c settings
        // stop caches (untracked cache, a possibly stale fsmonitor) and core.ignoreStat hiding changes.
        // core.trustctime/checkStat: with those relaxed, git trusts size and mtime alone and misses
        // a same-size edit that kept an old mtime (cp -p, rsync -t, tar, unzip). core.fileMode is
        // left as the repo has it: a mode-only change loses nothing, and volumes without exec bits
        // (exFAT, SMB) would otherwise show every file as changed.
        let status = Self.git(["-c", "core.untrackedCache=false", "-c", "core.fsmonitor=false", "-c", "core.ignoreStat=false",
                               "-c", "core.trustctime=true", "-c", "core.checkStat=default",
                               "status", "--porcelain=v1", "-z",
                               "--untracked-files=normal", "--ignored=matching", "--ignore-submodules=none"], in: wt.path)
        guard status.status == 0 else { return (.failed(status.err), activity) }
        afterStatus?()
        let parsed = Worktrees.parseStatus(status.out)
        if !parsed.changes.isEmpty { return (.dirty, activity) }

        let ls = Self.git(["ls-files", "-s", "-v", "-z"], in: wt.path)
        guard ls.status == 0 else { return (.failed(ls.err), activity) }
        let index = Worktrees.parseIndex(ls.out)
        let hidden = index.filter { $0.hidesEdits && Self.exists(wt.path + "/" + $0.path) }.map(\.path)
        if !hidden.isEmpty { return (.hiddenChanges(hidden), activity) }
        if index.contains(where: \.isGitlink) { return (.submodules, activity) }

        guard let filtered = filteredFiles(worktree: wt.path, config: config.out, paths: index.map(\.path)) else {
            return (.failed("could not check clean filters"), activity)
        }
        if !filtered.isEmpty { return (.hiddenChanges(filtered), activity) }

        let (fileVerdict, snapshot) = checkFiles(ignored: parsed.ignored, tracked: index.map(\.path),
                                                 worktree: wt.path, mainCheckout: repo)
        if let fileVerdict { return (fileVerdict, activity) }
        lastFileSnapshot = snapshot
        return (.reclaimable, activity)
    }

    /// Containment is a pure function of the two commits, so it is cached: rescans and the
    /// re-check before deleting don't repeat `git cherry`.
    private func isContainedCached(head: String, base: String, worktree: String, detached: Bool) -> Bool {
        let key = "\(base) \(head) \(detached)"
        if let hit = containedCache[key] { return hit }
        let result = isContained(head: head, base: base, worktree: worktree, detached: detached)
        containedCache[key] = result
        return result
    }

    /// `head` is an ancestor of `base`; or, on a branch (which is kept, so its commits stay
    /// reachable), every commit has a patch-identical counterpart in base and none is a merge.
    /// A detached HEAD must be a strict ancestor: nothing else would keep its commits alive.
    private func isContained(head: String, base: String, worktree: String, detached: Bool) -> Bool {
        if Self.git(["merge-base", "--is-ancestor", head, base], in: worktree).status == 0 { return true }
        if detached { return false }
        let ahead = Self.git(["rev-list", "--count", "\(base)..\(head)"], in: worktree)
        guard ahead.status == 0, let n = Int(ahead.out.trimmingCharacters(in: .whitespacesAndNewlines)),
              n <= policy.maxCommitsToCompare else { return false }
        let merges = Self.git(["rev-list", "--merges", "--count", "\(base)..\(head)"], in: worktree)
        guard merges.status == 0, merges.out.trimmingCharacters(in: .whitespacesAndNewlines) == "0" else { return false }
        // `git cherry` diffs every base commit since the fork point; past this many, don't try to
        // prove containment (the worktree is kept).
        let behind = Self.git(["rev-list", "--count", "\(head)..\(base)"], in: worktree)
        guard behind.status == 0, let b = Int(behind.out.trimmingCharacters(in: .whitespacesAndNewlines)),
              b <= policy.maxBaseCommitsToCompare else { return false }
        let cherry = Self.git(["cherry", base, head], in: worktree)
        return cherry.status == 0 && !cherry.out.split(separator: "\n").contains { $0.hasPrefix("+") }
    }

    /// Commits named by anything `git worktree remove` deletes: the worktree's HEAD reflog and its
    /// own refs and reflogs (refs/worktree/*, refs/bisect/*, refs/rewritten/*). Counts those no
    /// branch, tag, remote ref, or (for a branch worktree) the branch's own reflog still reaches;
    /// gc would delete them after removal. nil when they can't be read.
    private func unreferencedCommits(worktree: String, gitdir: String, branch: String?) -> Int? {
        guard let shas = perWorktreeCommits(worktree: worktree, gitdir: gitdir).map(Set.init) else { return nil }
        if shas.isEmpty { return 0 }
        // Revisions go through stdin (a long reflog could overflow argv). Plain lines are
        // positive and "^sha" lines negative in every git version; the ref globs after
        // --not are command-line arguments, so they never flip the stdin revisions.
        var input = shas.sorted()
        if let branch {
            // The branch and its reflog survive removal, so commits they reach are not lost.
            if let own = reflog(of: branch, worktree: worktree) { input += Set(own).sorted().map { "^" + $0 } }
        }
        let result = Self.git(["rev-list", "--ignore-missing", "--stdin", "--not", "--branches", "--tags", "--remotes"],
                              in: worktree, stdin: Data((input.joined(separator: "\n") + "\n").utf8))
        guard result.status == 0 else { return nil }
        return Self.lines(result.out).count
    }

    /// Every commit in the worktree's own reflogs and refs. Read from the files under <gitdir>/logs
    /// and <gitdir>/refs (git never packs per-worktree refs), or through git for reftable or a
    /// packed-refs file there. nil when unreadable, or when a symlink shows up in those folders
    /// (git would follow it; the walk can't vouch for it).
    private func perWorktreeCommits(worktree: String, gitdir: String) -> [String]? {
        let fm = FileManager.default
        if fm.fileExists(atPath: Self.commonDir(gitdir: gitdir) + "/reftable") || fm.fileExists(atPath: gitdir + "/packed-refs") {
            let refs = Self.git(["for-each-ref", "--format=%(objectname) %(refname)", "refs/worktree/", "refs/bisect/", "refs/rewritten/"],
                                in: worktree)
            guard refs.status == 0 else { return nil }
            let pairs = Self.lines(refs.out).map { $0.split(separator: " ", maxSplits: 1).map(String.init) }
            var out = pairs.compactMap(\.first)
            for ref in ["HEAD"] + pairs.compactMap({ $0.count == 2 ? $0[1] : nil }) {
                guard let log = reflogViaGit(ref, worktree: worktree) else { return nil }
                out += log
            }
            return out
        }
        var out: [String] = []
        guard let logs = Self.files(under: gitdir + "/logs"), let refs = Self.files(under: gitdir + "/refs") else { return nil }
        for file in logs {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
            out += Worktrees.reflogCommits(text)
        }
        for file in refs {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
            let sha = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if sha.hasPrefix("ref:") { continue }   // symbolic: points at another ref
            guard sha.allSatisfy(\.isHexDigit), sha.count == 40 || sha.count == 64 else { return nil }
            out.append(sha)
        }
        return out
    }

    /// `git log -g` for one ref: [] when the ref or its reflog doesn't exist, nil on other errors.
    private func reflogViaGit(_ ref: String, worktree: String) -> [String]? {
        let r = Self.git(["log", "-g", "--format=%H", ref, "--"], in: worktree)
        if r.status == 0 { return Self.lines(r.out) }
        return Self.commit(ref, in: worktree) == nil ? [] : nil
    }

    /// Commits in a branch's reflog (in the shared git dir). Read from the file directly, or via
    /// git for the reftable format. Empty when there is no reflog; nil when it can't be read.
    private func reflog(of branch: String, worktree: String) -> [String]? {
        let ref = "refs/heads/\(branch)"
        guard let gitdir = Self.gitdir(of: worktree) else { return reflogViaGit(ref, worktree: worktree) }
        let common = Self.commonDir(gitdir: gitdir)
        if FileManager.default.fileExists(atPath: common + "/reftable") { return reflogViaGit(ref, worktree: worktree) }
        let file = common + "/logs/" + ref
        guard Self.exists(file) else { return [] }
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
        return Worktrees.reflogCommits(text)
    }

    /// Tracked files run through a configured clean filter (other than Git LFS): a filter can
    /// make a modified file look clean, e.g. one that redacts a secret before staging.
    /// nil when git fails.
    private func filteredFiles(worktree: String, config: String, paths: [String]) -> [String]? {
        let drivers = Worktrees.filterDrivers(config).subtracting(["lfs"])
        if drivers.isEmpty { return [] }
        let attrs = Self.git(["check-attr", "-z", "--stdin", "filter"], in: worktree,
                             stdin: Data(paths.map { $0 + "\0" }.joined().utf8))
        guard attrs.status == 0 else { return nil }
        return Worktrees.attributeValues(attrs.out).filter { drivers.contains($0.value) }.map(\.path)
    }

    /// Everything git status doesn't vouch for must be recoverable.
    /// - Ignored files need a byte-identical copy (for a symlink, the same target) really inside the
    ///   main checkout. Files in an ignored folder count the same way, unless the folder is
    ///   regenerable: a dependency or cache folder, or a build-output folder the main checkout also has.
    ///   So does any other file that isn't tracked: git status didn't list it, so it appeared after
    ///   status ran (the snapshot of its folder, taken during this walk, would already include it).
    ///   Finder's metadata files (.DS_Store, ._*, Icon\r) are disposable.
    /// - Nothing named .git (any case) may exist below the root. Git skips such entries without a
    ///   word unless they hold a valid repository, so status can't be trusted to report them. The
    ///   one exception is a repository inside a regenerable folder that holds nothing of its own
    ///   (SwiftPM keeps every dependency as a clone in .build/checkouts).
    /// Walks the whole worktree once and returns, with any verdict, lstat keys of every folder and
    /// compared file, for remove() to re-check right before deleting.
    private func checkFiles(ignored: [String], tracked: [String], worktree: String,
                            mainCheckout: String) -> (WorktreeVerdict?, [String: String]) {
        // Tracked files (git status found them unchanged, and git worktree remove checks them
        // again) and the ignored files compared below. Swift compares strings by canonical
        // equivalence, so a name stored decomposed on disk still matches git's precomposed one.
        let vouched = Set(tracked).union(ignored.filter { $0.utf8.last != UInt8(ascii: "/") })
        var unique: [String] = []
        var budget = policy.maxIgnoredFilesToVerify
        var nestedBudget = policy.maxNestedRepositories
        var inMain = MainCheckoutPaths(root: mainCheckout)
        var snapshot: [String: String] = [:]
        var ignoredDirs: [String: Bool] = [:]   // relative path -> regenerable
        // The directory git worktree remove empties, with symlinks in its path resolved, so the
        // walk's paths share its prefix.
        let rootPath = Self.realPath(worktree)

        func compare(_ rel: String, at path: String) -> WorktreeVerdict? {
            if Self.isFinderMetadata((rel as NSString).lastPathComponent) { return nil }
            budget -= 1
            if budget < 0 { return .localFiles(["(too many ignored files to verify)"]) }
            snapshot[path] = Self.statKey(path)
            if !(inMain.contains(rel) && Self.isCopy(path, of: mainCheckout + "/" + rel)) { unique.append(rel) }
            return unique.count >= 10 ? .localFiles(unique) : nil
        }

        for entry in ignored {
            guard entry.utf8.last == UInt8(ascii: "/") else {
                if let verdict = compare(entry, at: rootPath + "/" + entry) { return (verdict, snapshot) }
                continue
            }
            let rel = String(decoding: entry.utf8.dropLast(), as: UTF8.self)
            let name = (rel as NSString).lastPathComponent
            ignoredDirs[rel] = policy.regenerableDirectories.contains(name)
                || (policy.buildOutputDirectories.contains(name) && inMain.contains(rel) && Self.isDirectory(mainCheckout + "/" + rel))
        }

        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let rootComponents = root.pathComponents
        var unreadable = false
        // The enumerator does not follow symbolic links.
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [], errorHandler: { _, _ in unreadable = true; return true })
        else { return (.failed("cannot read the worktree"), snapshot) }
        snapshot[rootPath] = Self.statKey(rootPath)
        for case let url as URL in walker {
            let components = url.pathComponents
            guard components.count > rootComponents.count,
                  Array(components.prefix(rootComponents.count)) == rootComponents
            else { return (.failed("unexpected path \(url.path)"), snapshot) }
            let rel = components.dropFirst(rootComponents.count).joined(separator: "/")
            if rel.lowercased() == ".git" { continue }   // the worktree's own .git file
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let isDirectory = values?.isDirectory == true && values?.isSymbolicLink != true
            let enclosing = Self.enclosingIgnoredDir(rel, in: ignoredDirs)
            if url.lastPathComponent.lowercased() == ".git" {
                let repo = (url.path as NSString).deletingLastPathComponent
                nestedBudget -= 1
                guard enclosing == true, url.lastPathComponent == ".git", isDirectory, nestedBudget >= 0,
                      nestedRepoIsDisposable(repo)
                else { return (.nestedRepository((rel as NSString).deletingLastPathComponent), snapshot) }
                walker.skipDescendants()
                continue
            }
            if isDirectory {
                snapshot[url.path] = Self.statKey(url.path)   // a new entry anywhere changes its folder
                continue
            }
            if enclosing == true { continue }                        // regenerable folder
            if enclosing == nil && vouched.contains(rel) { continue }
            // Inside an ignored folder that isn't regenerable, or a file git status never listed:
            // needs a copy like any ignored file.
            if let verdict = compare(rel, at: url.path) { return (verdict, snapshot) }
        }
        if unreadable { return (.failed("cannot read everything in the worktree"), snapshot) }
        return (unique.isEmpty ? nil : .localFiles(unique), snapshot)
    }

    /// Files Finder creates on its own: folder view settings, AppleDouble attribute files and
    /// custom folder icons. They hold no user content.
    static func isFinderMetadata(_ name: String) -> Bool {
        name == ".DS_Store" || name == "Icon\r" || name.utf8.starts(with: "._".utf8)
    }

    /// A repository inside a dependency or cache folder holds nothing of its own when its working
    /// tree is clean, it has no stash, and every commit its HEAD, branches and reflogs name is on
    /// a remote-tracking branch or tag (a package manager's clone at a release, for instance).
    private func nestedRepoIsDisposable(_ dir: String) -> Bool {
        // Explicit --git-dir: if this .git isn't a valid repository, git must fail rather than
        // fall back to the enclosing worktree.
        let at = ["--git-dir=" + dir + "/.git", "--work-tree=" + dir]
        let status = Self.git(at + ["-c", "core.untrackedCache=false", "-c", "core.fsmonitor=false",
                                    "status", "--porcelain=v1", "-z", "--untracked-files=normal", "--ignore-submodules=none"], in: dir)
        guard status.status == 0, status.out.isEmpty else { return false }
        let stash = Self.git(at + ["rev-parse", "-q", "--verify", "refs/stash"], in: dir)
        guard stash.status == 1 else { return false }
        let own = Self.git(at + ["rev-list", "-n", "1", "--reflog", "HEAD", "--branches", "--not", "--remotes", "--tags"], in: dir)
        return own.status == 0 && own.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether `rel` lies in one of git's ignored folders: nil if none, else that folder's
    /// "regenerable" flag.
    static func enclosingIgnoredDir(_ rel: String, in dirs: [String: Bool]) -> Bool? {
        guard !dirs.isEmpty else { return nil }
        var prefix = ""
        for part in Worktrees.components(rel).dropLast() {
            prefix = prefix.isEmpty ? part : prefix + "/" + part
            if let regenerable = dirs[prefix] { return regenerable }
        }
        return nil
    }

    /// Answers "is <root>/<rel> really inside the main checkout?": every directory between the root
    /// and the item must be a real directory, not a symlink. Otherwise the "copy" could be the
    /// worktree's own file (or a sibling worktree's), reached through a symlinked folder.
    struct MainCheckoutPaths {
        let root: String
        private let realRoot: String
        private var cache: [String: Bool] = [:]

        init(root: String) {
            self.root = root
            realRoot = WorktreeScanner.realPath(root)
        }

        mutating func contains(_ rel: String) -> Bool {
            let parent = (rel as NSString).deletingLastPathComponent
            if parent.isEmpty { return true }
            if let hit = cache[parent] { return hit }
            let resolved = WorktreeScanner.realPath(root + "/" + parent)
            let ok = Self.same(resolved, realRoot + "/" + parent)
            cache[parent] = ok
            return ok
        }

        private static func same(_ a: String, _ b: String) -> Bool {
            a.precomposedStringWithCanonicalMapping.lowercased() == b.precomposedStringWithCanonicalMapping.lowercased()
        }
    }

    /// True when `path` is recoverable from `copy` in the main checkout. Symlinks are compared,
    /// not followed: a main-checkout symlink pointing into the worktree is not a copy.
    static func isCopy(_ path: String, of copy: String) -> Bool {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let copyAttrs = try? fm.attributesOfItem(atPath: copy) else { return false }
        let type = attrs[.type] as? FileAttributeType
        let copyType = copyAttrs[.type] as? FileAttributeType
        if type == .typeSymbolicLink {
            guard copyType == .typeSymbolicLink,
                  let a = try? fm.destinationOfSymbolicLink(atPath: path),
                  let b = try? fm.destinationOfSymbolicLink(atPath: copy) else { return false }
            return a == b
        }
        guard type == .typeRegular, copyType == .typeRegular else { return false }
        return fm.contentsEqual(atPath: path, andPath: copy)
    }

    /// The first of `policy.baseRefs` that exists in the repo, with the commit it points to.
    private func baseRef(in repo: String) -> (ref: String, sha: String)? {
        for ref in policy.baseRefs {
            if let sha = Self.commit(ref, in: repo) { return (ref, sha) }
        }
        return nil
    }

    /// The commit `rev` names, or nil.
    static func commit(_ rev: String, in dir: String) -> String? {
        let r = git(["rev-parse", "--verify", "--quiet", "\(rev)^{commit}"], in: dir)
        let sha = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.status == 0 && !sha.isEmpty ? sha : nil
    }

    /// Latest change to the worktree's own git metadata (checkout, commit, index update).
    private func lastActivity(_ path: String) -> Date? {
        guard let gitdir = Self.gitdir(of: path) else { return nil }
        func mtime(_ name: String) -> Date? {
            (try? FileManager.default.attributesOfItem(atPath: gitdir + "/" + name))?[.modificationDate] as? Date
        }
        var dates = ["HEAD", "index", "reftable/tables.list"].compactMap(mtime)
        // git gc and reflog expire in the main checkout rewrite every worktree's logs/HEAD, so its
        // mtime says nothing about this worktree. Use the time in its newest entry instead.
        if Self.exists(gitdir + "/logs/HEAD") {
            guard let last = Self.lastReflogTime(gitdir + "/logs/HEAD") ?? mtime("logs/HEAD") else { return nil }
            dates.append(last)
        }
        return dates.max()
    }

    /// The timestamp of a reflog's newest entry ("<old> <new> <name> <email> <unix-time> <tz>\t<message>").
    /// distantPast when it has no entries (gc expired them all: no activity to report); nil when
    /// it can't be read or parsed.
    static func lastReflogTime(_ file: String) -> Date? {
        guard let handle = FileHandle(forReadingAtPath: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 8192 ? size - 8192 : 0)
        let data: Data
        do { data = try handle.readToEnd() ?? Data() } catch { return nil }   // nil means end of file
        let lines = data.split(separator: UInt8(ascii: "\n")).filter { !$0.allSatisfy { $0 == UInt8(ascii: "\r") } }
        guard let last = lines.last else { return .distantPast }
        let head = last.split(separator: UInt8(ascii: "\t"), maxSplits: 1).first ?? last
        let fields = head.split(separator: UInt8(ascii: " "))
        guard fields.count >= 2, let seconds = TimeInterval(String(decoding: fields[fields.count - 2], as: UTF8.self)) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// The linked worktree's private git directory (.git/worktrees/<name>), from its .git file.
    static func gitdir(of worktree: String) -> String? {
        guard let gitFile = try? String(contentsOfFile: worktree + "/.git", encoding: .utf8) else { return nil }
        return Worktrees.gitdir(fromGitFile: gitFile, worktree: worktree)
    }

    /// The repository's shared git directory, from <gitdir>/commondir.
    static func commonDir(gitdir: String) -> String {
        guard let raw = (try? String(contentsOfFile: gitdir + "/commondir", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return gitdir }
        return raw.hasPrefix("/") ? raw
            : URL(fileURLWithPath: raw, relativeTo: URL(fileURLWithPath: gitdir, isDirectory: true)).standardizedFileURL.path
    }

    /// A git operation paused in this worktree, from the state files git leaves in its gitdir.
    static func operationInProgress(gitdir: String) -> String? {
        let markers: [(String, String)] = [
            ("rebase-merge", "a rebase"), ("rebase-apply", "a rebase or git am"), ("MERGE_HEAD", "a merge"),
            ("CHERRY_PICK_HEAD", "a cherry-pick"), ("REVERT_HEAD", "a revert"), ("sequencer", "a cherry-pick or revert"),
            ("BISECT_LOG", "a bisect"), ("BISECT_START", "a bisect"),
            // git notes merge: conflict resolutions in progress, and the partial merge commit.
            ("NOTES_MERGE_WORKTREE", "a notes merge"), ("NOTES_MERGE_PARTIAL", "a notes merge"),
            ("NOTES_MERGE_REF", "a notes merge"),
        ]
        return markers.first { exists(gitdir + "/" + $0.0) }.map { "\($0.1) is in progress" }
    }

    /// Identity and change marker for one path, without following a final symlink.
    static func statKey(_ path: String) -> String {
        var st = Darwin.stat()
        guard lstat(path, &st) == 0 else { return "missing" }
        return "\(st.st_dev):\(st.st_ino):\(st.st_mode):\(st.st_size):\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec):\(st.st_ctimespec.tv_sec).\(st.st_ctimespec.tv_nsec)"
    }

    /// Regular files below `dir`, recursively. [] when it doesn't exist; nil when something can't
    /// be read or a symlink appears.
    static func files(under dir: String) -> [String]? {
        guard exists(dir) else { return [] }
        let fm = FileManager.default
        guard let walker = fm.enumerator(atPath: dir) else { return nil }
        var out: [String] = []
        for case let rel as String in walker {
            let path = dir + "/" + rel
            guard let type = (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType else { return nil }
            if type == .typeSymbolicLink { return nil }
            if type == .typeRegular { out.append(path) }
        }
        return out
    }

    /// Changes whenever anything in the worktree's private git dir changes: HEAD, index, its own
    /// refs, reflogs and reftable stack, operation state. (Ref changes elsewhere in the repository
    /// don't count: branches survive removal.)
    static func fingerprint(_ worktree: String) -> String? {
        guard let gitdir = gitdir(of: worktree) else { return nil }
        var parts = [(try? String(contentsOfFile: gitdir + "/HEAD", encoding: .utf8)) ?? "-"]
        guard let walker = FileManager.default.enumerator(atPath: gitdir) else { return nil }
        for case let rel as String in walker {
            let path = gitdir + "/" + rel
            if (rel as NSString).lastPathComponent.hasPrefix("sharedindex.") {
                // Split index: content-addressed and immutable, but git touches its mtime on every read.
                let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber
                parts.append(rel + "=" + "\(size?.int64Value ?? -1)")
            } else {
                parts.append(rel + "=" + statKey(path))
            }
        }
        return parts.joined(separator: "|")
    }

    // MARK: Discovery

    func discoverRepos() -> [String] {
        var repos = Set<String>()
        let fm = FileManager.default
        func visit(_ dir: String, depth: Int) {
            guard depth <= policy.searchDepth,
                  let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for name in entries where !name.hasPrefix(".") && !policy.skipDirectories.contains(name) {
                let child = dir + "/" + name
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: child, isDirectory: &isDir), isDir.boolValue else { continue }
                let dotGit = child + "/.git"
                var gitIsDir: ObjCBool = false
                if fm.fileExists(atPath: dotGit, isDirectory: &gitIsDir) {
                    // Resolve symlinks so one repo reached by two paths is scanned once.
                    if gitIsDir.boolValue {
                        repos.insert(Self.realPath(child))
                    } else if let contents = try? String(contentsOfFile: dotGit, encoding: .utf8),
                              let main = Worktrees.mainRepo(fromGitFile: contents, worktree: child),
                              fm.fileExists(atPath: main + "/.git") {
                        repos.insert(Self.realPath(main))   // a linked worktree: its main repo may live elsewhere
                    }
                    continue
                }
                visit(child, depth: depth + 1)
            }
        }
        for root in policy.roots { visit(root, depth: 1) }
        return repos.sorted()
    }

    /// `git worktree list` for every discovered repo (plus `extra`), skipping repos git can't read.
    private func registeredWorktrees(including extra: String? = nil) -> [(repo: String, worktrees: [GitWorktree])] {
        var repos = discoverRepos()
        if let extra, !repos.contains(extra) { repos.append(extra) }
        return repos.compactMap { repo in
            let list = Self.git(["worktree", "list", "--porcelain", "-z"], in: repo)   // -z: paths may hold newlines
            return list.status == 0 ? (repo, Worktrees.parsePorcelain(list.out)) : nil
        }
    }

    private static func allPaths(_ registered: [(repo: String, worktrees: [GitWorktree])]) -> [String] {
        registered.flatMap { $0.worktrees.flatMap { [$0.path, realPath($0.path)] } }
    }

    // MARK: Subprocesses

    struct GitResult {
        let status: Int32
        let out: String
        let err: String
    }

    static func git(_ args: [String], in dir: String, stdin: Data? = nil) -> GitResult {
        run("/usr/bin/git", ["-C", dir] + args, env: Worktrees.gitEnvironment(from: ProcessInfo.processInfo.environment), stdin: stdin)
    }

    static func diskUsage(_ path: String) -> Int64? {
        let r = run("/usr/bin/du", ["-sk", path], env: nil)
        guard let kb = r.out.split(whereSeparator: { $0 == "\t" || $0 == " " }).first.flatMap({ Int64($0) }) else { return nil }
        return kb * 1024
    }

    static func run(_ exe: String, _ args: [String], env: [String: String]?, stdin: Data? = nil) -> GitResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: exe)
        task.arguments = args
        if let env { task.environment = env }
        // Background (throttled I/O) when called from a background queue, like the periodic scan;
        // utility when someone is waiting: the CLI, or a deletion the user asked for.
        task.qualityOfService = Thread.current.qualityOfService == .background ? .background : .utility
        // stdin and stderr go through temp files rather than pipes: feeding or draining a second
        // pipe needs another thread, and borrowing one from GCD's background pool can starve.
        let tmp = FileManager.default.temporaryDirectory
        let errURL = tmp.appendingPathComponent("claudemonitor-\(UUID().uuidString).err")
        let inURL = tmp.appendingPathComponent("claudemonitor-\(UUID().uuidString).in")
        defer {
            try? FileManager.default.removeItem(at: errURL)
            try? FileManager.default.removeItem(at: inURL)
        }
        guard FileManager.default.createFile(atPath: errURL.path, contents: nil),
              let errHandle = try? FileHandle(forWritingTo: errURL) else {
            return GitResult(status: -1, out: "", err: "cannot create a temp file for stderr")
        }
        defer { try? errHandle.close() }
        if let stdin {
            guard FileManager.default.createFile(atPath: inURL.path, contents: stdin),
                  let inHandle = try? FileHandle(forReadingFrom: inURL) else {
                return GitResult(status: -1, out: "", err: "cannot create a temp file for stdin")
            }
            task.standardInput = inHandle
        } else {
            task.standardInput = FileHandle.nullDevice
        }
        let out = Pipe()
        task.standardOutput = out
        task.standardError = errHandle
        do { try task.run() } catch { return GitResult(status: -1, out: "", err: "\(error)") }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let errData = (try? Data(contentsOf: errURL)) ?? Data()
        return GitResult(status: task.terminationStatus, out: String(decoding: outData, as: UTF8.self),
                         err: String(decoding: errData, as: UTF8.self))
    }

    /// Canonical path as the kernel reports process cwds. Uses realpath(3), not Foundation's
    /// resolvingSymlinksInPath, which strips "/private" and so would never match a cwd.
    static func realPath(_ path: String) -> String {
        guard let resolved = Darwin.realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// A real directory (not a symlink to one).
    static func isDirectory(_ path: String) -> Bool {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType) == .typeDirectory
    }

    /// Exists without following a final symlink (a dangling link still counts).
    static func exists(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)) != nil
    }

    private static func lines(_ s: String) -> [String] {
        s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// What is running right now: processes, their working directories, open Claude sessions, and
/// the Codex threads that aren't archived.
struct LiveContext {
    let processes: [ProcessRow]
    let cwds: [Int32: String]
    let sessions: [SessionRecord]
    var codexThreads: [CodexThread] = []

    struct Unavailable: Error, CustomStringConvertible {
        let description: String
    }

    /// Throws rather than return a partial picture: with no processes listed, every "in use"
    /// check would pass.
    static func capture() throws -> LiveContext {
        var context = try make(ps: Monitor.ps(ProcessTable.mainArguments), cwds: ProcessCwd.all(), sessions: SessionFiles.load())
        context.codexThreads = try codexThreads(processes: context.processes)
        return context
    }

    /// Codex threads that may be using a folder: every thread not archived, and every loaded one.
    /// Throws when that can't be known, so no worktree is offered: a loaded thread whose folder
    /// can't be read, or a state database that exists but can't be read.
    static func codexThreads(processes: [ProcessRow], home: URL = CodexSessions.home) throws -> [CodexThread] {
        let live = CodexSessions.liveThreads(in: processes)
        switch CodexState.threads(home: home, ids: Set(live.keys), unarchived: true) {
        case .success(let threads):
            if let unknown = live.keys.sorted().first(where: { threads[$0]?.cwd == nil }) {
                throw Unavailable(description: "the folder of open Codex thread \(unknown) is unknown")
            }
            return threads.values.sorted { $0.id < $1.id }
        case .failure(.missing) where live.isEmpty:
            return []
        case .failure(let why):
            throw Unavailable(description: "\(why)")
        }
    }

    static func make(ps: String, cwds: [Int32: String]?, sessions: [SessionRecord],
                     selfPid: Int32 = getpid()) throws -> LiveContext {
        let main = ProcessTable.parseMain(ps)
        // Both lists always include the process asking. Without it, neither is a real list.
        guard main[selfPid] != nil else { throw Unavailable(description: "ps listed no processes") }
        guard let cwds, cwds[selfPid] != nil else {
            throw Unavailable(description: "their working folders can't be read")
        }
        let live = Set(main.keys)
        return LiveContext(processes: ProcessTable.merge(main: main, comm: [:]), cwds: cwds,
                           sessions: sessions.filter { live.contains($0.pid) })
    }
}

public enum ProcessCwd {
    /// Working directory of every process this user can inspect (via libproc); nil when the list
    /// of processes can't be read.
    public static func all() -> [Int32: String]? {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return nil }
        var pids = [Int32](repeating: 0, count: Int(n) + 128)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard got > 0 else { return nil }
        var out: [Int32: String] = [:]
        for pid in pids.prefix(Int(max(got, 0))) where pid > 0 {
            if let cwd = cwd(of: pid) { out[pid] = cwd }
        }
        return out
    }

    public static func cwd(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return path.isEmpty ? nil : path
    }
}
