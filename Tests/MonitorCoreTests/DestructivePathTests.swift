import Foundation
import Testing
@testable import MonitorCore

// Adversarial destructive-path tests. Convention: every test asserts the SAFE outcome,
// so a FAILING test is a way to make Claude Monitor delete work it should keep.
// Sandboxes live under $ADV_ROOT if set, else the temp directory, and are deleted afterwards.
// Cases marked "control" were already handled correctly when this suite was written.

private struct Box {
    let root: URL
    let repo: String
    let scanRoot: String

    /// origin (bare-ish working repo) + clone at scan/app. `extraOrigin` runs inside origin
    /// before the initial commit; `afterInit` runs in origin after it.
    init(_ tag: String, extraOrigin: String = "", afterInit: String = "", initExtra: String = "", cloneExtra: String = "") throws {
        let base = ProcessInfo.processInfo.environment["ADV_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        root = base.appendingPathComponent("adv-\(tag)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("scan"), withIntermediateDirectories: true)
        let origin = root.appendingPathComponent("origin").path
        repo = root.appendingPathComponent("scan/app").path
        scanRoot = root.appendingPathComponent("scan").path
        try Box.run("git init -q -b main \(initExtra) '\(origin)'")
        try Box.run("printf 'bin/\\n.env.local\\n' > .gitignore && echo a > a && mkdir tracked && echo t > tracked/t \(extraOrigin.isEmpty ? "" : "&& " + extraOrigin) && git add -A && git \(Box.id) commit -qm init", in: origin)
        if !afterInit.isEmpty { try Box.run(afterInit, in: origin) }
        try Box.run("git \(Box.allowFile) clone -q \(cloneExtra) '\(origin)' '\(repo)'")
        try Box.run("echo SECRET=main > .env.local", in: repo)
    }

    static let id = "-c user.email=test@example.com -c user.name=test -c commit.gpgsign=false"
    static let allowFile = "-c protocol.file.allow=always"

    var origin: String { root.appendingPathComponent("origin").path }

    func worktree(_ name: String, extra: String = "", at ref: String = "origin/main") throws -> String {
        let path = root.appendingPathComponent("scan/\(name)").path
        let branch = name.replacingOccurrences(of: " ", with: "-")
        try sh("git worktree add -q \(extra) -b '\(branch)' '\(path)' \(ref)", in: repo)
        return path
    }

    func detachedWorktree(_ name: String, at ref: String) throws -> String {
        let path = root.appendingPathComponent("scan/\(name)").path
        try sh("git worktree add -q --detach '\(path)' \(ref)", in: repo)
        return path
    }

    @discardableResult
    func sh(_ cmd: String, in dir: String? = nil) throws -> String { try Box.run(cmd, in: dir) }

    @discardableResult
    static func run(_ cmd: String, in dir: String? = nil) throws -> String {
        let script = (dir.map { "cd '\($0)' && " } ?? "") + cmd
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        env["GIT_AUTHOR_NAME"] = "t"; env["GIT_AUTHOR_EMAIL"] = "t@e.com"
        env["GIT_COMMITTER_NAME"] = "t"; env["GIT_COMMITTER_EMAIL"] = "t@e.com"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let edata = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw WorktreeError.gitFailed("sandbox command failed: \(cmd)\n\(String(decoding: edata, as: UTF8.self))")
        }
        return String(decoding: data, as: UTF8.self)
    }

    func scanner(minIdleHours: Double = 0) -> WorktreeScanner {
        var policy = WorktreePolicy()
        policy.roots = [scanRoot]
        policy.searchDepth = 1
        policy.savedMessagesDirectory = root.appendingPathComponent("saved").path
        policy.minIdleHours = minIdleHours
        return WorktreeScanner(policy: policy)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

/// Scans; if `path` is offered as reclaimable, calls remove() on it. Returns (offered, deleted, removeError).
private func attack(_ box: Box, _ path: String, minIdleHours: Double = 0, label: String) -> (Bool, Bool, String?) {
    let scanner = box.scanner(minIdleHours: minIdleHours)
    let scan = scanner.scan()
    let real = WorktreeScanner.realPath(path)
    guard let item = scan.reclaimable.first(where: { $0.path == path || $0.path == real }) else {
        print("ADV[\(label)] not offered; skipped=\(scan.skipped)")
        return (false, false, nil)
    }
    var errText: String?
    do { try scanner.remove(item) } catch { errText = "\(error)" }
    let deleted = !FileManager.default.fileExists(atPath: path)
    print("ADV[\(label)] OFFERED as reclaimable; remove() -> \(errText ?? "ok"); deleted=\(deleted)")
    return (true, deleted, errText)
}

/// The categories a scan skipped worktrees for (all worktrees in the sandbox).
private func skipReasons(_ box: Box) -> Set<String> { Set(box.scanner().scan().skipped.keys) }

// MARK: - Hidden edits / files

@Test func adv01_skipWorktreeEditIsKept() throws {
    let box = try Box("skipwt"); defer { box.cleanup() }
    let wt = try box.worktree("skipwt")
    try box.sh("git update-index --skip-worktree a && echo 'precious local edit' > a", in: wt)
    let (offered, deleted, _) = attack(box, wt, label: "skip-worktree")
    #expect(!offered, "worktree with a modified --skip-worktree file was offered as reclaimable")
    #expect(!deleted, "modified --skip-worktree file was deleted")
}

@Test func adv02_assumeUnchangedEditIsKept() throws {
    let box = try Box("assume"); defer { box.cleanup() }
    let wt = try box.worktree("assume")
    try box.sh("git update-index --assume-unchanged a && echo 'precious local edit' > a", in: wt)
    let (offered, deleted, _) = attack(box, wt, label: "assume-unchanged")
    #expect(!offered)
    #expect(!deleted)
}

@Test func adv03_showUntrackedFilesNoHidesEverything() throws {
    let box = try Box("showu"); defer { box.cleanup() }
    let wt = try box.worktree("showu")
    try box.sh("git config status.showUntrackedFiles no", in: box.repo)
    try box.sh("echo 'my notes' > NOTES.md && echo SECRET=only-here > .env.local", in: wt)
    let (offered, deleted, _) = attack(box, wt, label: "status.showUntrackedFiles=no")
    #expect(!offered, "untracked NOTES.md and unique .env.local hidden by status.showUntrackedFiles=no")
    #expect(!deleted)
}

@Test func adv04_untrackedDirHoldingOnlyIgnoredFilesIsKept() throws {
    let box = try Box("collapse"); defer { box.cleanup() }
    let wt = try box.worktree("collapse")
    // .env.local is exactly the kind of file the localFiles rule protects; here it is one level down.
    try box.sh("mkdir config && echo SECRET=only-here > config/.env.local", in: wt)
    let (offered, deleted, _) = attack(box, wt, label: "untracked dir of ignored files (config/.env.local)")
    #expect(!offered, "git collapses config/ to '!! config/' and the scanner treats it as build output")
    #expect(!deleted)
}

@Test func adv05_uniqueFileInsideIgnoredDirectoryIsKept() throws {
    let box = try Box("igndir"); defer { box.cleanup() }
    let wt = try box.worktree("igndir")
    try box.sh("mkdir bin && echo 'hand-written, not build output' > bin/deploy-notes.txt", in: wt)
    let (offered, deleted, _) = attack(box, wt, label: "unique file in ignored dir bin/")
    #expect(!offered)
    #expect(!deleted)
}

@Test func adv06_nestedRepoWithUnpushedCommitsInIgnoredDirIsKept() throws {
    let box = try Box("nested"); defer { box.cleanup() }
    let wt = try box.worktree("nested")
    try box.sh("mkdir -p bin && git init -q -b main bin/tool && cd bin/tool && echo work > work.txt && git add . && git \(Box.id) commit -qm 'unpushed work'", in: wt)
    let (offered, deleted, _) = attack(box, wt, label: "nested repo w/ commits inside ignored dir")
    #expect(!offered)
    #expect(!deleted)
}

@Test func adv07_nestedRepoNotIgnoredIsKept() throws {   // control: expected to pass
    let box = try Box("nested2"); defer { box.cleanup() }
    let wt = try box.worktree("nested2")
    try box.sh("git init -q -b main tool && cd tool && echo work > work.txt && git add . && git \(Box.id) commit -qm w", in: wt)
    let (offered, deleted, _) = attack(box, wt, label: "nested repo (not ignored)")
    #expect(!offered)
    #expect(!deleted)
}

@Test func adv08_cleanFilterHidesRealSecret() throws {
    // A common secrets pattern: a clean filter redacts the value before it is staged,
    // so the real value lives only in the working tree.
    let box = try Box("filter",
                      extraOrigin: "printf 'config.env filter=redact\\n' > .gitattributes && echo 'API_KEY=REDACTED' > config.env")
    defer { box.cleanup() }
    try box.sh("git config filter.redact.clean \"sed -e 's/^API_KEY=.*/API_KEY=REDACTED/'\" && git config filter.redact.smudge cat", in: box.repo)
    let wt = try box.worktree("filter")
    // Once the index is refreshed (git add, or any index update), status shows nothing.
    try box.sh("echo 'API_KEY=sk-real-only-copy' > config.env && git add config.env", in: wt)
    let status = try box.sh("git status --porcelain", in: wt)
    #expect(status.isEmpty, "precondition: git status hides the edit")
    #expect(skipReasons(box) == ["hidden edits"])
    let (offered, deleted, _) = attack(box, wt, label: "clean filter hides real secret")
    #expect(!offered)
    #expect(!deleted)
}

@Test func adv09_sparseCheckoutFileOutsideConeIsKept() throws {
    let box = try Box("sparse"); defer { box.cleanup() }
    let wt = try box.worktree("sparse")
    try box.sh("git sparse-checkout set --no-cone '/tracked/' '/.gitignore'", in: wt)
    try box.sh("test ! -e a && echo 'precious, written at a sparse path' > a && echo 'x' > outside.txt", in: wt)
    let (offered, deleted, _) = attack(box, wt, label: "sparse: file at skipped path + untracked")
    #expect(!offered)
    #expect(!deleted)
}

// MARK: - Commits only reachable from the worktree

private func reachable(_ sha: String, in repo: String) throws -> Bool {
    let all = try Box.run("git rev-list --all --reflog", in: repo)
    return all.split(separator: "\n").contains { $0 == sha }
}

@Test func adv10_detachedCommitLeftBehindIsKept() throws {
    let box = try Box("detached"); defer { box.cleanup() }
    let wt = try box.detachedWorktree("detached", at: "origin/main")
    try box.sh("echo work > work.txt && git add work.txt && git \(Box.id) commit -qm 'detached work'", in: wt)
    let sha = try box.sh("git rev-parse HEAD", in: wt).trimmingCharacters(in: .whitespacesAndNewlines)
    try box.sh("git checkout -q --detach origin/main", in: wt)   // git warns "leaving 1 commit behind"
    #expect(try reachable(sha, in: box.repo), "precondition: reachable through the worktree's HEAD reflog")
    let (offered, deleted, _) = attack(box, wt, label: "detached commit only in worktree reflog")
    let stillReachable = try reachable(sha, in: box.repo)
    print("ADV[detached] commit \(sha.prefix(8)) reachable after: \(stillReachable)")
    #expect(!(offered && deleted && !stillReachable), "commit became unreachable (gc will prune it)")
}

@Test func adv11_detachedEvilMergeIsKept() throws {
    let box = try Box("evil", afterInit: "echo c1 > c1 && git add c1 && git \(Box.id) commit -qm c1")
    defer { box.cleanup() }
    try box.sh("git fetch -q", in: box.repo)
    let wt = try box.detachedWorktree("evil", at: "origin/main~1")
    try box.sh("git \(Box.id) merge -q --no-ff --no-commit origin/main && echo 'resolution work' > evil.txt && git add evil.txt && git \(Box.id) commit -qm 'merge with extra work'", in: wt)
    let sha = try box.sh("git rev-parse HEAD", in: wt).trimmingCharacters(in: .whitespacesAndNewlines)
    print("ADV[evil merge] cherry: '\(try box.sh("git cherry origin/main HEAD", in: wt))'")
    let (offered, deleted, _) = attack(box, wt, label: "detached HEAD = merge commit with extra content")
    let stillReachable = try reachable(sha, in: box.repo)
    #expect(!(offered && deleted && !stillReachable), "merge commit with unique content became unreachable")
}

@Test func adv12_detachedWhitespaceOnlyPatchIdTwinIsKept() throws {
    // origin/main has the "same" patch modulo whitespace; in Python that is a different program.
    let box = try Box("ws", afterInit: "printf 'if x:\\n    y = 1\\nz = 2\\n' > f.py && git add f.py && git \(Box.id) commit -qm f")
    defer { box.cleanup() }
    try box.sh("git fetch -q", in: box.repo)
    let wt = try box.detachedWorktree("ws", at: "origin/main~1")
    try box.sh("printf 'if x:\\n    y = 1\\n    z = 2\\n' > f.py && git add f.py && git \(Box.id) commit -qm 'f, z inside the if'", in: wt)
    let sha = try box.sh("git rev-parse HEAD", in: wt).trimmingCharacters(in: .whitespacesAndNewlines)
    print("ADV[whitespace] cherry: '\(try box.sh("git cherry origin/main HEAD", in: wt))'")
    let (offered, deleted, _) = attack(box, wt, label: "detached commit patch-id-equal modulo whitespace")
    let stillReachable = try reachable(sha, in: box.repo)
    #expect(!(offered && deleted && !stillReachable), "semantically different commit lost")
}

@Test func adv13_detachedEmptyCommitIsKept() throws {
    let box = try Box("empty"); defer { box.cleanup() }
    let wt = try box.detachedWorktree("empty", at: "origin/main")
    try box.sh("git \(Box.id) commit -q --allow-empty -m 'decision log: why we did X'", in: wt)
    let sha = try box.sh("git rev-parse HEAD", in: wt).trimmingCharacters(in: .whitespacesAndNewlines)
    print("ADV[empty] cherry: '\(try box.sh("git cherry origin/main HEAD", in: wt))'")
    let (offered, deleted, _) = attack(box, wt, label: "detached empty commit")
    let stillReachable = try reachable(sha, in: box.repo)
    #expect(!(offered && deleted && !stillReachable))
}

@Test func adv14_branchCommitsSurviveBecauseBranchIsKept() throws {   // control
    let box = try Box("branch", afterInit: "printf 'if x:\\n    y = 1\\nz = 2\\n' > f.py && git add f.py && git \(Box.id) commit -qm f")
    defer { box.cleanup() }
    try box.sh("git fetch -q", in: box.repo)
    let wt = try box.worktree("br", at: "origin/main~1")
    try box.sh("printf 'if x:\\n    y = 1\\n    z = 2\\n' > f.py && git add f.py && git \(Box.id) commit -qm 'z inside'", in: wt)
    let sha = try box.sh("git rev-parse HEAD", in: wt).trimmingCharacters(in: .whitespacesAndNewlines)
    _ = attack(box, wt, label: "branch commit patch-id twin")
    #expect(try box.sh("git rev-parse refs/heads/br", in: box.repo).hasPrefix(sha))
}

@Test func adv15_stashSurvives() throws {   // control: refs/stash is shared
    let box = try Box("stash"); defer { box.cleanup() }
    let wt = try box.worktree("stash")
    try box.sh("echo wip >> a && git \(Box.id) stash -q", in: wt)
    _ = attack(box, wt, label: "stash in worktree")
    #expect((try? box.sh("git rev-parse -q --verify refs/stash", in: box.repo)) != nil)
}

// MARK: - Ignored-file comparison

@Test func adv16_mainCheckoutSymlinkIntoWorktreeIsNotACopy() throws {
    let box = try Box("symlink"); defer { box.cleanup() }
    let wt = try box.worktree("symlink")
    try box.sh("echo SECRET=only-here > .env.local", in: wt)
    try box.sh("rm .env.local && ln -s '\(wt)/.env.local' .env.local", in: box.repo)
    let (offered, deleted, _) = attack(box, wt, label: "main .env.local symlinks into worktree")
    let dangling = (try? String(contentsOfFile: box.repo + "/.env.local", encoding: .utf8)) == nil
    print("ADV[symlink] main checkout .env.local now dangling: \(dangling)")
    #expect(!offered)
    #expect(!deleted)
}

@Test func adv17_infoExcludeUniqueFileIsKept() throws {   // control
    let box = try Box("exclude"); defer { box.cleanup() }
    let wt = try box.worktree("exclude")
    try box.sh("echo 'scratch.txt' >> .git/info/exclude", in: box.repo)
    try box.sh("echo mine > scratch.txt", in: wt)
    let (offered, deleted, _) = attack(box, wt, label: "file ignored via info/exclude")
    #expect(!offered)
    #expect(!deleted)
}

// MARK: - Guards: submodules, idle, in use

@Test func adv18_submoduleWithLocalCommitsIgnoreAll() throws {
    let box = try Box("submod")
    defer { box.cleanup() }
    let subOrigin = box.root.appendingPathComponent("suborigin").path
    try box.sh("git init -q -b main '\(subOrigin)' && cd '\(subOrigin)' && echo s > s && git add s && git \(Box.id) commit -qm s")
    try box.sh("git \(Box.allowFile) submodule add -q '\(subOrigin)' sub && git \(Box.id) commit -qm 'add sub'", in: box.origin)
    try box.sh("git fetch -q && git merge -q --ff-only origin/main", in: box.repo)
    let wt = try box.worktree("submod")
    try box.sh("git \(Box.allowFile) submodule update -q --init && cd sub && echo local > local.txt && git add . && git \(Box.id) commit -qm 'unpushed submodule work' && cd .. && git config submodule.sub.ignore all", in: wt)
    let (offered, deleted, err) = attack(box, wt, label: "submodule with unpushed commits, ignore=all")
    print("ADV[submodule] offered=\(offered) err=\(err ?? "-")")
    #expect(!deleted)
}

@Test func adv19_relativePathWorktreeBypassesIdleGuard() throws {
    let box = try Box("relpath"); defer { box.cleanup() }
    let wt = try box.worktree("relpath", extra: "--relative-paths")
    print("ADV[relpath] .git file: \(try String(contentsOfFile: wt + "/.git", encoding: .utf8))")
    // Created a second ago; with the default 24 h idle policy it must not be offered.
    let (offered, deleted, _) = attack(box, wt, minIdleHours: 24, label: "relative-path worktree, 24h idle policy")
    #expect(!offered, "idle guard skipped: lastActivity() returned nil for a relative gitdir")
    #expect(!deleted)
}

@Test func adv20_pathWithSpacesInUseIsKept() throws {   // control
    let box = try Box("spaces"); defer { box.cleanup() }
    let wt = try box.worktree("with space")
    let sleeper = Process()
    sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
    sleeper.arguments = ["30"]
    sleeper.currentDirectoryURL = URL(fileURLWithPath: wt)
    try sleeper.run()
    defer { sleeper.terminate() }
    let (offered, deleted, _) = attack(box, wt, label: "path with spaces + process cwd inside")
    #expect(!offered)
    #expect(!deleted)
}

@Test func adv21_caseMismatchedProcessCwdIsKept() throws {   // control
    let box = try Box("case"); defer { box.cleanup() }
    let wt = try box.worktree("CaseWT")
    let sleeper = Process()
    sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
    sleeper.arguments = ["30"]
    sleeper.currentDirectoryURL = URL(fileURLWithPath: box.scanRoot + "/casewt")
    try sleeper.run()
    defer { sleeper.terminate() }
    print("ADV[case] kernel cwd=\(ProcessCwd.cwd(of: sleeper.processIdentifier) ?? "nil") realPath=\(WorktreeScanner.realPath(wt))")
    let (offered, deleted, _) = attack(box, wt, label: "process entered worktree via different case")
    #expect(!offered)
    #expect(!deleted)
}

@Test func adv22_caseMismatchedSessionCwdOnly() throws {
    // classify() with a session whose recorded cwd differs only in case, and no process cwd.
    let box = try Box("casesess"); defer { box.cleanup() }
    let wt = try box.worktree("CaseSess")
    let list = Worktrees.parsePorcelain(try box.sh("git worktree list --porcelain", in: box.repo))
    let entry = try #require(list.first { $0.path.hasSuffix("/CaseSess") })
    let lower = (entry.path as NSString).deletingLastPathComponent + "/casesess"
    let s = SessionRecord(pid: 1, sessionId: "abc", name: "x", cwd: lower, status: .busy, statusUpdatedAt: nil, startedAt: nil, waitingFor: nil)
    let ctx = LiveContext(processes: [], cwds: [:], sessions: [s])
    let (verdict, _) = box.scanner().classify(entry, repo: box.repo, base: "origin/main", context: ctx, now: Date())
    print("ADV[case session] verdict=\(verdict)")
    _ = wt
    #expect(verdict != .reclaimable)
}

@Test func adv23_noOriginMainIsKept() throws {   // control
    let box = try Box("noorigin"); defer { box.cleanup() }
    let wt = try box.worktree("noorigin")
    try box.sh("git remote remove origin", in: box.repo)
    let (offered, deleted, _) = attack(box, wt, label: "no origin remote")
    #expect(!offered)
    #expect(!deleted)
}

@Test func adv24_gitEnvironmentLeak() throws {
    // If GIT_DIR / GIT_WORK_TREE leaked into the app, git would inspect a different repository than
    // the worktree being classified. (Not tested via setenv: that would leak into parallel tests.)
    let box = try Box("gitenv"); defer { box.cleanup() }
    let wt = try box.worktree("gitenv")
    try box.sh("echo 'my notes' > NOTES.md", in: wt)
    let leaky = ProcessInfo.processInfo.environment.merging(["GIT_WORK_TREE": box.origin, "GIT_DIR": box.origin + "/.git"]) { $1 }
    let status = WorktreeScanner.run("/usr/bin/git", ["-C", wt, "status", "--porcelain"], env: Worktrees.gitEnvironment(from: leaky))
    #expect(status.out.contains("NOTES.md"))
}

@Test func adv25_parentWorktreeDeletionTakesNestedDirtyWorktree() throws {
    // Claude Code puts agent worktrees under <checkout>/.claude/worktrees/. If .claude/ is ignored,
    // the parent worktree looks clean ("!! .claude/") and removing it deletes the nested one too.
    let box = try Box("nestedwt"); defer { box.cleanup() }
    try box.sh("echo '.claude/' >> .git/info/exclude", in: box.repo)
    let parent = try box.worktree("parent")
    let child = parent + "/.claude/worktrees/agent-1"
    try box.sh("git worktree add -q -b agent-1 '\(child)' origin/main", in: box.repo)
    try box.sh("echo 'agent edit, uncommitted' >> a && echo 'new module' > new.txt", in: child)
    let (offered, deleted, _) = attack(box, parent, label: "parent of nested dirty worktree (.claude/ ignored)")
    let childAlive = FileManager.default.fileExists(atPath: child + "/new.txt")
    print("ADV[nested wt] child uncommitted files survive: \(childAlive)")
    #expect(!(offered && deleted))
    #expect(childAlive, "uncommitted edits in the nested agent worktree were deleted")
}

@Test func adv26_symlinkToOutsideDataIsNotFollowed() throws {   // control
    let box = try Box("symout"); defer { box.cleanup() }
    let outside = box.root.appendingPathComponent("outside-data").path
    try box.sh("mkdir -p '\(outside)' && echo precious > '\(outside)/db.sqlite'")
    try box.sh("echo 'data' >> .git/info/exclude && ln -s '\(outside)' data", in: box.repo)
    let wt = try box.worktree("symout")
    try box.sh("ln -s '\(outside)' data", in: wt)
    let (offered, deleted, _) = attack(box, wt, label: "ignored symlink to outside dir")
    let survives = FileManager.default.fileExists(atPath: outside + "/db.sqlite")
    print("ADV[symout] offered=\(offered) deleted=\(deleted) outside data survives=\(survives)")
    #expect(survives)
}

@Test func adv27_claudeSettingsLocalInUntrackedClaudeDir() throws {
    // Claude Code writes .claude/settings.local.json and it is usually ignored by name.
    let box = try Box("claudelocal"); defer { box.cleanup() }
    try box.sh("echo '**/.claude/settings.local.json' >> .git/info/exclude", in: box.repo)
    let wt = try box.worktree("claudelocal")
    try box.sh("mkdir .claude && echo '{\"permissions\":{\"allow\":[\"Bash(make:*)\"]}}' > .claude/settings.local.json", in: wt)
    print("ADV[claude local] status: \(try box.sh("git status --porcelain --ignored", in: wt))")
    let (offered, deleted, _) = attack(box, wt, label: ".claude/settings.local.json (untracked .claude/)")
    #expect(!offered)
    #expect(!deleted)
}

// MARK: - Still useful: build output and dependencies do not block deletion

@Test func adv28_dependenciesAndBuiltOutputAreReclaimable() throws {
    let box = try Box("deps"); defer { box.cleanup() }
    try box.sh("mkdir bin && echo built > bin/app.dll && echo node_modules/ >> .git/info/exclude", in: box.repo)   // builds into bin/
    let wt = try box.worktree("deps")
    try box.sh("mkdir -p node_modules/left-pad bin && echo 'module.exports=1' > node_modules/left-pad/index.js && echo other > bin/app.dll && echo SECRET=main > .env.local", in: wt)
    let (offered, deleted, err) = attack(box, wt, label: "node_modules + bin/ (main has bin/) + identical .env.local")
    #expect(offered && deleted, "regenerable directories should not block deletion (error: \(err ?? "-"))")
}

@Test func adv29_repoInsideDependencyDirectoryIsKept() throws {
    let box = try Box("depsrepo"); defer { box.cleanup() }
    try box.sh("echo node_modules/ >> .git/info/exclude", in: box.repo)
    let wt = try box.worktree("depsrepo")
    try box.sh("mkdir -p node_modules && git init -q -b main node_modules/forked && cd node_modules/forked && echo fix > fix.js && git add . && git \(Box.id) commit -qm 'local fork'", in: wt)
    #expect(skipReasons(box) == ["contains another repo"])
    let (offered, deleted, _) = attack(box, wt, label: "git repo inside node_modules")
    #expect(!offered)
    #expect(!deleted)
}

@Test func adv30_userFilesInUnknownIgnoredDirectoryAreKept() throws {
    let box = try Box("notes"); defer { box.cleanup() }
    try box.sh("echo 'scratch/' >> .git/info/exclude", in: box.repo)
    let wt = try box.worktree("notes")
    try box.sh("mkdir scratch && echo 'design notes' > scratch/plan.md", in: wt)
    let (offered, deleted, _) = attack(box, wt, label: "file in an ignored dir that is not build output")
    #expect(!offered)
    #expect(!deleted)
}

// MARK: - Second review: symlinked copies, paused operations, per-worktree refs, races, core.worktree

private func exists(_ p: String) -> Bool { FileManager.default.fileExists(atPath: p) }

/// The main checkout reaches the worktree's ignored directory through a directory symlink,
/// so the "copy" in the main checkout IS the worktree's file.
@Test func adv31_mainCheckoutDirSymlinkIntoWorktree() throws {
    let box = try Box("dirlink"); defer { box.cleanup() }
    try box.sh("echo 'secrets/' >> .git/info/exclude", in: box.repo)
    let wt = try box.worktree("dirlink")
    try box.sh("mkdir secrets && echo 'PROD_KEY=only-copy' > secrets/prod.key", in: wt)
    try box.sh("ln -s '\(wt)/secrets' secrets", in: box.repo)
    let (offered, deleted, err) = attack(box, wt, label: "main secrets/ is a dir symlink into the worktree")
    let survives = exists(box.repo + "/secrets/prod.key") || exists(wt + "/secrets/prod.key")
    print("ADV[dirlink] offered=\(offered) deleted=\(deleted) err=\(err ?? "-") prod.key survives anywhere=\(survives)")
    #expect(!offered)
    #expect(survives)
}

/// Same with a relative symlink into a sibling worktree: both worktrees look like copies of each other.
@Test func adv32_mainCheckoutDirSymlinkIntoOtherWorktree() throws {
    let box = try Box("dirlink2"); defer { box.cleanup() }
    try box.sh("echo 'secrets/' >> .git/info/exclude", in: box.repo)
    let w1 = try box.worktree("w1"), w2 = try box.worktree("w2")
    for w in [w1, w2] { try box.sh("mkdir secrets && echo 'PROD_KEY=only-copy' > secrets/prod.key", in: w) }
    try box.sh("ln -s ../w2/secrets secrets", in: box.repo)
    let scanner = box.scanner()
    let scan = scanner.scan()
    print("ADV[dirlink2] reclaimable=\(scan.reclaimable.map { ($0.path as NSString).lastPathComponent }) skipped=\(scan.skipped)")
    for item in scan.reclaimable { try? scanner.remove(item) }
    let survives = exists(w1 + "/secrets/prod.key") || exists(w2 + "/secrets/prod.key")
    print("ADV[dirlink2] prod.key survives anywhere=\(survives)")
    #expect(survives)
}

/// Control/false-negative check: an identical file in an ignored, non-build directory is a copy.
@Test func adv33_identicalFileInIgnoredDirIsReclaimable() throws {
    let box = try Box("samefile"); defer { box.cleanup() }
    try box.sh("echo 'scratch/' >> .git/info/exclude && mkdir scratch && echo 'design notes' > scratch/plan.md", in: box.repo)
    let wt = try box.worktree("samefile")
    try box.sh("mkdir scratch && echo 'design notes' > scratch/plan.md", in: wt)
    let scan = box.scanner().scan()
    print("ADV[samefile] reclaimable=\(scan.reclaimable.map(\.path)) skipped=\(scan.skipped)")
    #expect(scan.reclaimable.count == 1)
}

/// `git am` from a pipe stopped on a patch that does not apply: the only copy of the patch
/// series is in the worktree's gitdir (rebase-apply/), and `git status --porcelain` is clean.
@Test func adv34_gitAmInProgressFromStdin() throws {
    let box = try Box("am"); defer { box.cleanup() }
    let wt = try box.worktree("am")
    let patch = box.root.appendingPathComponent("mail.patch").path
    try box.sh("printf 'From 1111111111111111111111111111111111111111 Mon Sep 17 00:00:00 2001\\nFrom: Dev <dev@example.com>\\nDate: Mon, 1 Jan 2024 00:00:00 +0000\\nSubject: [PATCH] precious emailed work\\n\\n---\\n a | 2 +-\\n\\ndiff --git a/a b/a\\n--- a/a\\n+++ b/a\\n@@ -1 +1 @@\\n-not-what-is-there\\n+precious emailed work\\n-- \\n2.40.0\\n\\n' > '\(patch)'")
    _ = try? box.sh("cat '\(patch)' | git \(Box.id) am", in: wt)   // fails: patch does not apply
    try box.sh("rm '\(patch)'")
    let gitdir = try box.sh("git rev-parse --git-dir", in: wt).trimmingCharacters(in: .whitespacesAndNewlines)
    print("ADV[am] status='\(try box.sh("git status --porcelain", in: wt))' rebase-apply exists=\(exists(gitdir + "/rebase-apply"))")
    #expect(exists(gitdir + "/rebase-apply"), "precondition: am is in progress")
    let (offered, deleted, err) = attack(box, wt, label: "git am in progress (patch only in rebase-apply/)")
    print("ADV[am] offered=\(offered) deleted=\(deleted) err=\(err ?? "-") rebase-apply survives=\(exists(gitdir + "/rebase-apply"))")
    #expect(!offered)
    #expect(!deleted)
}

/// A bisect in progress: HEAD is a commit of origin/main, status is clean, refs/bisect/* and
/// BISECT_LOG (the user's good/bad verdicts) live only in the worktree's gitdir.
@Test func adv35_bisectInProgress() throws {
    let box = try Box("bisect", afterInit: "for i in 1 2 3 4 5 6; do echo $i > n && git add n && git \(Box.id) commit -qm c$i; done"); defer { box.cleanup() }
    let wt = try box.detachedWorktree("bisect", at: "origin/main")
    try box.sh("git bisect start origin/main origin/main~6 >/dev/null && git bisect good >/dev/null", in: wt)
    let gitdir = try box.sh("git rev-parse --git-dir", in: wt).trimmingCharacters(in: .whitespacesAndNewlines)
    print("ADV[bisect] status='\(try box.sh("git status --porcelain", in: wt))' BISECT_LOG=\(exists(gitdir + "/BISECT_LOG"))")
    let (offered, deleted, err) = attack(box, wt, label: "bisect in progress")
    print("ADV[bisect] offered=\(offered) deleted=\(deleted) err=\(err ?? "-")")
    #expect(!offered)
    #expect(!deleted)
}

/// An interactive rebase paused with a hand-edited todo list.
@Test func adv36_interactiveRebasePaused() throws {
    let box = try Box("rebase", afterInit: "for i in 1 2 3; do echo $i > n && git add n && git \(Box.id) commit -qm c$i; done"); defer { box.cleanup() }
    let wt = try box.worktree("rb")
    try box.sh("GIT_SEQUENCE_EDITOR='sed -i \"\" -e \"1i\\\\\nbreak\" -e \"s/^pick/reword/\"' git \(Box.id) rebase -q -i origin/main~3 >/dev/null 2>&1 || true", in: wt)
    let gitdir = try box.sh("git rev-parse --git-dir", in: wt).trimmingCharacters(in: .whitespacesAndNewlines)
    print("ADV[rebase] status='\(try box.sh("git status --porcelain", in: wt))' rebase-merge=\(exists(gitdir + "/rebase-merge"))")
    let (offered, deleted, err) = attack(box, wt, label: "interactive rebase paused")
    print("ADV[rebase] offered=\(offered) deleted=\(deleted) err=\(err ?? "-")")
    #expect(!offered)
}

/// reftable: a detached commit only in the worktree's HEAD reflog must be kept (reflog read via git).
@Test func adv37_reftableDetachedOrphanIsKept() throws {
    let box = try Box("reftable", cloneExtra: "--ref-format=reftable"); defer { box.cleanup() }
    let wt = try box.detachedWorktree("rt", at: "origin/main")
    try box.sh("echo work > work.txt && git add work.txt && git \(Box.id) commit -qm 'detached work' && git checkout -q --detach origin/main", in: wt)
    let clean = try box.worktree("rtclean")
    let scan = box.scanner().scan()
    print("ADV[reftable] reclaimable=\(scan.reclaimable.map { ($0.path as NSString).lastPathComponent }) skipped=\(scan.skipped)")
    #expect(!scan.reclaimable.contains { $0.path.hasSuffix("/rt") })
    #expect(scan.reclaimable.contains { $0.path.hasSuffix("/rtclean") }, "clean reftable worktree should be reclaimable")
    _ = clean
}

/// SHA-256 repository.
@Test func adv38_sha256DetachedOrphanIsKept() throws {
    let box = try Box("sha256", initExtra: "--object-format=sha256"); defer { box.cleanup() }
    let wt = try box.detachedWorktree("s", at: "origin/main")
    try box.sh("echo work > work.txt && git add work.txt && git \(Box.id) commit -qm 'detached work' && git checkout -q --detach origin/main", in: wt)
    _ = try box.worktree("sclean")
    let scan = box.scanner().scan()
    print("ADV[sha256] reclaimable=\(scan.reclaimable.map { ($0.path as NSString).lastPathComponent }) skipped=\(scan.skipped)")
    #expect(!scan.reclaimable.contains { $0.path.hasSuffix("/s") })
    #expect(scan.reclaimable.contains { $0.path.hasSuffix("/sclean") })
}

/// A clean submodule worktree is kept (git worktree remove would refuse anyway).
@Test func adv39_cleanSubmoduleIsKept() throws {
    let box = try Box("submod2"); defer { box.cleanup() }
    let subOrigin = box.root.appendingPathComponent("suborigin").path
    try box.sh("git init -q -b main '\(subOrigin)' && cd '\(subOrigin)' && echo s > s && git add s && git \(Box.id) commit -qm s")
    try box.sh("git \(Box.allowFile) submodule add -q '\(subOrigin)' sub && git \(Box.id) commit -qm 'add sub'", in: box.origin)
    try box.sh("git fetch -q && git merge -q --ff-only origin/main", in: box.repo)
    let wt = try box.worktree("submod2")
    try box.sh("git \(Box.allowFile) submodule update -q --init", in: wt)
    let scan = box.scanner().scan()
    print("ADV[clean submodule] skipped=\(scan.skipped)")
    #expect(scan.reclaimable.isEmpty)
}

/// NFD vs NFC: a process whose kernel cwd is the decomposed spelling of the worktree path.
@Test func adv40_unicodeNormalizationCwdIsInUse() throws {
    let box = try Box("nfd"); defer { box.cleanup() }
    let wt = try box.worktree("caf\u{00E9}")
    let list = Worktrees.parsePorcelain(try box.sh("git worktree list --porcelain", in: box.repo))
    let entry = try #require(list.first { !$0.isMain })
    let nfd = entry.path.decomposedStringWithCanonicalMapping
    let nfc = entry.path.precomposedStringWithCanonicalMapping
    for cwd in [nfd + "/src", nfc + "/src"] {
        let ctx = LiveContext(processes: [], cwds: [4242: cwd], sessions: [])
        let (verdict, _) = box.scanner().classify(entry, repo: box.repo, base: "origin/main", context: ctx, now: Date())
        print("ADV[nfd] cwd utf8 count=\(cwd.utf8.count) verdict=\(verdict)")
        #expect(verdict != .reclaimable)
    }
    _ = wt
}

/// HEAD moves (new detached commit) between scan and remove(): the cached containment of the
/// old HEAD must not be reused.
@Test func adv41_headMovesAfterScanIsKept() throws {
    let box = try Box("headmove"); defer { box.cleanup() }
    let wt = try box.detachedWorktree("hm", at: "origin/main")
    let scanner = box.scanner()
    let item = try #require(scanner.scan().reclaimable.first)
    try box.sh("git \(Box.id) commit -q --allow-empty -m 'late work'", in: wt)
    var err: String?
    do { try scanner.remove(item) } catch { err = "\(error)" }
    print("ADV[headmove] remove -> \(err ?? "ok")")
    #expect(err != nil)
    #expect(exists(wt))
}

/// The branch disappears (update-ref -d) between scan and remove().
@Test func adv42_branchDeletedAfterScanIsKept() throws {
    let box = try Box("brdel"); defer { box.cleanup() }
    let wt = try box.worktree("brdel")
    let scanner = box.scanner()
    let item = try #require(scanner.scan().reclaimable.first)
    try box.sh("git update-ref -d refs/heads/brdel", in: box.repo)
    var err: String?
    do { try scanner.remove(item) } catch { err = "\(error)" }
    print("ADV[brdel] remove -> \(err ?? "ok") exists=\(exists(wt))")
    #expect(err != nil)
}

/// Worktree registered through a symlinked parent directory; a process sits in it via the real path.
@Test func adv43_symlinkedParentPathInUse() throws {
    let box = try Box("symparent"); defer { box.cleanup() }
    let real = box.root.appendingPathComponent("realdir").path
    try box.sh("mkdir -p '\(real)' && ln -s '\(real)' '\(box.scanRoot)/link'")
    let wt = box.scanRoot + "/link/wt"
    try box.sh("git worktree add -q -b symwt '\(wt)' origin/main", in: box.repo)
    let sleeper = Process()
    sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
    sleeper.arguments = ["30"]
    sleeper.currentDirectoryURL = URL(fileURLWithPath: real + "/wt")
    try sleeper.run()
    defer { sleeper.terminate() }
    let (offered, deleted, _) = attack(box, wt, label: "worktree via symlinked parent, process in real path")
    #expect(!offered)
    #expect(!deleted)
}

/// core.worktree in the shared config (here: the main checkout's own path) redirects
/// `git -C <linked worktree> status` to the main checkout, so the worktree's own files go unchecked.
@Test func adv44_coreWorktreeRedirectsStatus() throws {
    let box = try Box("coreworktree"); defer { box.cleanup() }
    let wt = try box.worktree("cw")
    try box.sh("git config core.worktree '\(box.repo)'", in: box.repo)
    // The worktree mirrors main's ignored .env.local (identical) and has its own unique ignored notes.
    try box.sh("echo SECRET=main > .env.local && mkdir bin && echo 'hand-written runbook' > bin/RUNBOOK.md", in: wt)
    let (offered, deleted, err) = attack(box, wt, label: "core.worktree set in shared config")
    print("ADV[core.worktree] offered=\(offered) deleted=\(deleted) err=\(err ?? "-")")
    #expect(!offered)
    #expect(!deleted)
}

/// Same, with extensions.worktreeConfig on (git sparse-checkout turns it on): now the shared
/// core.worktree applies to linked worktrees too.
@Test func adv45_coreWorktreeWithWorktreeConfig() throws {
    let box = try Box("coreworktree2"); defer { box.cleanup() }
    let wt = try box.worktree("cw2")
    try box.sh("git config extensions.worktreeConfig true && git config core.worktree '\(box.repo)'", in: box.repo)
    try box.sh("echo SECRET=main > .env.local && mkdir bin && echo 'hand-written runbook' > bin/RUNBOOK.md", in: wt)
    print("ADV[core.worktree2] status in wt: '\(try box.sh("git status --porcelain --ignored", in: wt))'")
    let (offered, deleted, err) = attack(box, wt, label: "core.worktree + extensions.worktreeConfig")
    print("ADV[core.worktree2] offered=\(offered) deleted=\(deleted) err=\(err ?? "-")")
    #expect(!offered)
    #expect(!deleted)
}

/// Per-worktree core.worktree (config.worktree) pointing at the main checkout.
@Test func adv46_perWorktreeCoreWorktree() throws {
    let box = try Box("coreworktree3"); defer { box.cleanup() }
    let wt = try box.worktree("cw3")
    try box.sh("git config extensions.worktreeConfig true", in: box.repo)
    try box.sh("git config --worktree core.worktree '\(box.repo)'", in: wt)
    try box.sh("echo SECRET=main > .env.local && mkdir bin && echo 'hand-written runbook' > bin/RUNBOOK.md", in: wt)
    let (offered, deleted, err) = attack(box, wt, label: "per-worktree core.worktree")
    print("ADV[core.worktree3] offered=\(offered) deleted=\(deleted) err=\(err ?? "-")")
    #expect(!offered)
    #expect(!deleted)
}

/// A commit reachable only from a per-worktree ref (refs/worktree/*), never checked out.
@Test func adv47_perWorktreeRefIsKept() throws {
    let box = try Box("wtref"); defer { box.cleanup() }
    let wt = try box.worktree("wtref")
    let sha = try box.sh("git \(Box.id) commit-tree -p HEAD -m 'parked work' $(git write-tree)", in: wt).trimmingCharacters(in: .whitespacesAndNewlines)
    try box.sh("git update-ref refs/worktree/parked \(sha)", in: wt)
    let (offered, deleted, _) = attack(box, wt, label: "commit only on refs/worktree/parked")
    let all = try Box.run("git rev-list --all --reflog", in: box.repo)
    let reachable = all.split(separator: "\n").contains { $0 == sha }
    print("ADV[wtref] offered=\(offered) deleted=\(deleted) commit reachable after=\(reachable)")
    #expect(!(offered && deleted && !reachable))
}

/// Check-then-act: a commit lands on the detached HEAD while remove() is still verifying
/// ignored files, i.e. after the containment/reflog checks and before `git worktree remove`.
@Test func adv48_commitDuringRemoveRecheck() throws {
    let box = try Box("toctou"); defer { box.cleanup() }
    try box.sh("echo 'scratch/' >> .git/info/exclude && mkdir scratch && for i in $(seq 1 4000); do echo \"note $i\" > scratch/n$i.txt; done", in: box.repo)
    let wt = try box.detachedWorktree("tt", at: "origin/main")
    try box.sh("cp -R '\(box.repo)/scratch' scratch", in: wt)
    let scanner = box.scanner()
    let item = try #require(scanner.scan().reclaimable.first, "precondition: offered")
    // Measure how long one remove()-style re-check takes, to aim the commit into its second half.
    let list = Worktrees.parsePorcelain(try box.sh("git worktree list --porcelain", in: box.repo))
    let entry = try #require(list.first { !$0.isMain })
    let t0 = Date()
    _ = scanner.classify(entry, repo: box.repo, base: "origin/main", context: LiveContext(processes: [], cwds: [:], sessions: []), now: Date())
    let classifyTime = Date().timeIntervalSince(t0)
    let t1 = Date()
    _ = try LiveContext.capture()
    let captureTime = Date().timeIntervalSince(t1)
    print("ADV[toctou] classify=\(classifyTime)s capture=\(captureTime)s")
    let delay = captureTime + classifyTime * 0.6
    let committer = Process()
    committer.executableURL = URL(fileURLWithPath: "/bin/sh")
    committer.arguments = ["-c", "sleep \(delay) && cd '\(wt)' && git \(Box.id) commit -q --allow-empty -m 'late work' && git rev-parse HEAD > '\(box.root.path)/late.sha'"]
    try committer.run()
    var err: String?
    do { try scanner.remove(item) } catch { err = "\(error)" }
    committer.waitUntilExit()
    let sha = (try? String(contentsOfFile: box.root.path + "/late.sha", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let all = try Box.run("git rev-list --all --reflog", in: box.repo)
    let reachable = !sha.isEmpty && all.split(separator: "\n").contains { $0 == sha }
    print("ADV[toctou] remove -> \(err ?? "ok") deleted=\(!exists(wt)) late commit=\(sha.prefix(8)) committed=\(committer.terminationStatus == 0) reachable after=\(reachable)")
    #expect(!(err == nil && !exists(wt) && !sha.isEmpty && !reachable), "commit made during the re-check was lost")
}

@Test func adv49_weirdNamesAreSeen() throws {
    let box = try Box("names"); defer { box.cleanup() }
    let wt = try box.worktree("names")
    try box.sh("printf 'x' > \"$(printf '!! evil\\nname')\"", in: wt)            // untracked, starts with "!! ", has a newline
    let (offered, deleted, _) = attack(box, wt, label: "untracked file named '!! evil\\nname'")
    #expect(!offered && !deleted)
}

@Test func adv50_ignoredWeirdNamesCompared() throws {
    let box = try Box("names2"); defer { box.cleanup() }
    try box.sh("echo 'scratch/' >> .git/info/exclude", in: box.repo)
    let wt = try box.worktree("names2")
    try box.sh("mkdir scratch && printf 'unique' > \"scratch/$(printf '!! a\\nb')\"", in: wt)
    let (offered, deleted, _) = attack(box, wt, label: "ignored file with newline name")
    #expect(!offered && !deleted)
}

@Test func adv51_tooManyIgnoredFilesKept() throws {
    let box = try Box("many"); defer { box.cleanup() }
    try box.sh("echo 'scratch/' >> .git/info/exclude && mkdir scratch && cd scratch && for i in $(seq 1 5100); do echo $i > f$i; done", in: box.repo)
    let wt = try box.worktree("many")
    try box.sh("cp -R '\(box.repo)/scratch' scratch", in: wt)
    print("ADV[many] skipped=\(box.scanner().scan().skipped)")
    #expect(box.scanner().scan().reclaimable.isEmpty)
}

@Test func adv52_hardLinkToMainSurvives() throws {
    let box = try Box("hardlink"); defer { box.cleanup() }
    let wt = try box.worktree("hardlink")
    try box.sh("ln '\(box.repo)/.env.local' .env.local", in: wt)
    let (offered, deleted, _) = attack(box, wt, label: "hard link to main .env.local")
    let mainOK = (try? String(contentsOfFile: box.repo + "/.env.local", encoding: .utf8)) == "SECRET=main\n"
    print("ADV[hardlink] offered=\(offered) deleted=\(deleted) main intact=\(mainOK)")
    #expect(mainOK)
}

@Test func adv53_manyIndividuallyIgnoredFilesAreKept() throws {
    // The 5,000-file limit also counts ignored files git lists one by one (here *.log), not only folders.
    let box = try Box("manylogs", extraOrigin: "printf '*.log\\n' >> .gitignore"); defer { box.cleanup() }
    let wt = try box.worktree("manylogs")
    let make = "i=1; while [ $i -le 5100 ]; do echo $i > f$i.log; i=$((i+1)); done"
    try box.sh(make, in: wt)
    try box.sh(make, in: box.repo)
    #expect(skipReasons(box) == ["has local files"])
}

@Test func adv54_localBranchNamedOriginMainDoesNotCount() throws {
    // `git checkout -b origin/main` is a common slip; a local branch (or tag) by that name must not
    // stand in for the remote-tracking ref.
    let box = try Box("shadow"); defer { box.cleanup() }
    let wt = try box.worktree("feat")
    try box.sh("echo unpushed > u && git add u && git \(Box.id) commit -qm 'unpushed work'", in: wt)
    try box.sh("git branch origin/main feat", in: box.repo)
    #expect(skipReasons(box) == ["not in origin/main"])
}
