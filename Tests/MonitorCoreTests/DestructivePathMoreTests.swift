import Darwin
import Foundation
import Testing
@testable import MonitorCore

// Third-round adversarial cases (same convention as DestructivePathTests: every test asserts
// the SAFE outcome, so a failing test is a way to make Claude Monitor delete work it should keep).

private struct SBox {
    let root: URL
    let repo: String
    let scanRoot: String

    init(_ tag: String, extraOrigin: String = "", cloneExtra: String = "") throws {
        let base = ProcessInfo.processInfo.environment["ADV_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        root = base.appendingPathComponent("sk-\(tag)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("scan"), withIntermediateDirectories: true)
        let origin = root.appendingPathComponent("origin").path
        repo = root.appendingPathComponent("scan/app").path
        scanRoot = root.appendingPathComponent("scan").path
        try SBox.run("git init -q -b main '\(origin)'")
        try SBox.run("printf 'bin/\\n.env.local\\n' > .gitignore && echo a > a && mkdir tracked && echo t > tracked/t \(extraOrigin.isEmpty ? "" : "&& " + extraOrigin) && git add -A && git \(SBox.id) commit -qm init", in: origin)
        try SBox.run("git \(SBox.allowFile) clone -q \(cloneExtra) '\(origin)' '\(repo)'")
        try SBox.run("echo SECRET=main > .env.local", in: repo)
    }

    static let id = "-c user.email=test@example.com -c user.name=test -c commit.gpgsign=false"
    static let allowFile = "-c protocol.file.allow=always"
    var origin: String { root.appendingPathComponent("origin").path }

    func worktree(_ name: String) throws -> String {
        let path = root.appendingPathComponent("scan/\(name)").path
        try sh("git worktree add -q -b '\(name)' '\(path)' origin/main", in: repo)
        return path
    }

    func detached(_ name: String, at ref: String = "origin/main") throws -> String {
        let path = root.appendingPathComponent("scan/\(name)").path
        try sh("git worktree add -q --detach '\(path)' \(ref)", in: repo)
        return path
    }

    @discardableResult
    func sh(_ cmd: String, in dir: String? = nil) throws -> String { try SBox.run(cmd, in: dir) }

    @discardableResult
    static func run(_ cmd: String, in dir: String? = nil) throws -> String {
        let script = (dir.map { "cd '\($0)' && " } ?? "") + cmd
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
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

    func scanner() -> WorktreeScanner {
        var policy = WorktreePolicy()
        policy.roots = [scanRoot]
        policy.searchDepth = 1
        policy.savedMessagesDirectory = root.appendingPathComponent("saved").path
        policy.minIdleHours = 0
        return WorktreeScanner(policy: policy)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private extension String { var t: String { trimmingCharacters(in: .whitespacesAndNewlines) } }
private func ex(_ p: String) -> Bool { FileManager.default.fileExists(atPath: p) }
private func reachable(_ sha: String, _ repo: String) throws -> Bool {
    try SBox.run("git rev-list --all --reflog", in: repo).split(separator: "\n").contains { Substring(sha) == $0 }
}

/// (offered, deleted, error, skipped)
@discardableResult
private func tryDelete(_ box: SBox, _ path: String, _ label: String) -> (Bool, Bool, String?) {
    let scanner = box.scanner()
    let scan = scanner.scan()
    let real = WorktreeScanner.realPath(path)
    guard let item = scan.reclaimable.first(where: { $0.path == path || $0.path == real }) else {
        print("ADV[\(label)] NOT offered; skipped=\(scan.skipped)")
        return (false, false, nil)
    }
    var err: String?
    do { try scanner.remove(item) } catch { err = "\(error)" }
    let deleted = !ex(path)
    print("ADV[\(label)] OFFERED; remove() -> \(err ?? "ok"); deleted=\(deleted)")
    return (true, deleted, err)
}

// MARK: R3-01

@Test func adv55_userFilesInFolderNamedDotGit() throws {
    let box = try SBox("01a"); defer { box.cleanup() }
    let wt = try box.worktree("w01a")
    try box.sh("mkdir -p research/.git && echo 'two weeks of notes' > research/.git/NOTES.md", in: wt)
    let (o, d, _) = tryDelete(box, wt, "01a folder named .git with notes")
    print("ADV[01a] NOTES.md survives=\(ex(wt + "/research/.git/NOTES.md"))")
    #expect(!(o && d))
}

@Test func adv56_brokenNestedRepoWithCommits() throws {
    let box = try SBox("01b"); defer { box.cleanup() }
    let wt = try box.worktree("w01b")
    try box.sh("mkdir lib && cd lib && git init -q -b main . && echo code > c.txt && git add . && git \(SBox.id) commit -qm 'local only' && rm c.txt && : > .git/HEAD", in: wt)
    let (o, d, _) = tryDelete(box, wt, "01b broken nested repo, only .git left")
    #expect(!(o && d))
}

/// Bound the scope: the same broken repo but with its working file still there is seen (untracked).
@Test func adv57_brokenNestedRepoWithWorkingFileIsKept() throws {
    let box = try SBox("01c"); defer { box.cleanup() }
    let wt = try box.worktree("w01c")
    try box.sh("mkdir lib && cd lib && git init -q -b main . && echo code > c.txt && git add . && git \(SBox.id) commit -qm 'local only' && : > .git/HEAD", in: wt)
    let (o, d, _) = tryDelete(box, wt, "01c broken nested repo + working file")
    #expect(!(o && d))
}

@Test func adv58_fileNamedDotGitAndDotGITFile() throws {
    let box = try SBox("01d"); defer { box.cleanup() }
    let wt = try box.worktree("w01d")
    try box.sh("echo 'odd name' > tracked/.git && mkdir other && echo 'upper' > other/.GIT", in: wt)
    let (o, d, _) = tryDelete(box, wt, "01d tracked/.git file + other/.GIT file")
    #expect(!(o && d))
}

// MARK: R3-02

/// trustctime=false; a same-size edit after which the original mtime is restored (touch -r).
@Test func adv60_trustctimeFalseEditWithRestoredMtime() throws {
    let box = try SBox("02", extraOrigin: "echo 'API_KEY=aaaaaaaa' > config.env"); defer { box.cleanup() }
    let wt = try box.worktree("w02")
    try box.sh("git config core.trustctime false", in: box.repo)
    try box.sh("sleep 1.2 && git update-index --refresh >/dev/null", in: wt)   // index written >1s after checkout
    let stamp = box.root.appendingPathComponent("stamp").path
    try box.sh("touch -r config.env '\(stamp)' && printf 'API_KEY=bbbbbbbb\\n' > config.env && touch -r '\(stamp)' config.env", in: wt)
    let (o, d, _) = tryDelete(box, wt, "02 trustctime=false same-size edit, mtime restored")
    #expect(!(o && d))
}

/// Control: default config catches the same edit.
@Test func adv59_defaultConfigCatchesIt() throws {
    let box = try SBox("02c", extraOrigin: "echo 'API_KEY=aaaaaaaa' > config.env"); defer { box.cleanup() }
    let wt = try box.worktree("w02c")
    try box.sh("sleep 1.2 && git update-index --refresh >/dev/null", in: wt)
    let stamp = box.root.appendingPathComponent("stamp").path
    try box.sh("touch -r config.env '\(stamp)' && printf 'API_KEY=bbbbbbbb\\n' > config.env && touch -r '\(stamp)' config.env", in: wt)
    let (o, d, _) = tryDelete(box, wt, "02c default config")
    #expect(!(o && d))
}

// MARK: R3-03

@Test func adv61_submoduleGitdirLeftInWorktreeGitdir() throws {
    let box = try SBox("03"); defer { box.cleanup() }
    let subOrigin = box.root.appendingPathComponent("suborigin").path
    try box.sh("git init -q -b main '\(subOrigin)' && cd '\(subOrigin)' && echo s > s && git add s && git \(SBox.id) commit -qm s")
    try box.sh("git \(SBox.allowFile) submodule add -q '\(subOrigin)' sub && git \(SBox.id) commit -qm 'add sub'", in: box.origin)
    try box.sh("git fetch -q", in: box.repo)
    let wt = try box.detached("w03")
    try box.sh("git \(SBox.allowFile) submodule update -q --init && cd sub && git checkout -q -b feat && echo p > p && git add p && git \(SBox.id) commit -qm 'sub work'", in: wt)
    let subSHA = try box.sh("git -C sub rev-parse HEAD", in: wt).t
    try box.sh("git \(SBox.allowFile) submodule update -q", in: wt)
    try box.sh("git rm -q sub && git \(SBox.id) commit -qm 'drop sub'", in: box.origin)
    try box.sh("git fetch -q", in: box.repo)
    try box.sh("git \(SBox.allowFile) checkout -q --recurse-submodules --detach origin/main", in: wt)
    let modules = try box.sh("git rev-parse --path-format=absolute --git-path modules", in: wt).t
    print("ADV[03] modules dir=\(modules) exists=\(ex(modules + "/sub")) status='\(try box.sh("git status --porcelain --ignored", in: wt).t)'")
    let (o, d, err) = tryDelete(box, wt, "03 submodule gitdir in worktree gitdir")
    let survives = (try? box.sh("git --git-dir='\(modules)/sub' cat-file -t \(subSHA)")) != nil
    print("ADV[03] offered=\(o) deleted=\(d) err=\(err ?? "-") submodule commit survives=\(survives)")
    // Rescan: is it offered again?
    let again = box.scanner().scan().reclaimable.contains { $0.path.hasSuffix("/w03") }
    print("ADV[03] offered again on next scan=\(again)")
    #expect(!o)
}

// MARK: R3-04 (deterministic trigger: write when remove()'s SECOND ps starts, i.e. after classify)

private func childPsCount(seen: inout Set<Int32>) -> Int {
    var pids = [Int32](repeating: 0, count: 256)
    let n = proc_listchildpids(getpid(), &pids, Int32(pids.count * MemoryLayout<Int32>.size))
    guard n > 0 else { return seen.count }
    for pid in pids.prefix(Int(n)) where pid > 0 && !seen.contains(pid) {
        var buf = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0, String(cString: buf) == "/bin/ps" { seen.insert(pid) }
    }
    return seen.count
}

@Test func adv62_ignoredFileWrittenAfterClassifyIsDeleted() throws {
    let box = try SBox("04"); defer { box.cleanup() }
    let wt = try box.detached("w04")
    try box.sh("cp '\(box.repo)/.env.local' .env.local", in: wt)
    let scanner = box.scanner()
    let item = try #require(scanner.scan().reclaimable.first { $0.path.hasSuffix("/w04") }, "precondition: offered")
    let done = DispatchSemaphore(value: 0)
    var wroteAt = -1
    let started = Date()
    var t0: TimeInterval = 0
    Thread.detachNewThread {
        var seen = Set<Int32>()
        while Date().timeIntervalSince(started) < 60 {
            if childPsCount(seen: &seen) >= 2 {
                t0 = Date().timeIntervalSince(started)
                if (try? "SECRET=rotated-only-copy\n".write(toFile: wt + "/.env.local", atomically: false, encoding: .utf8)) != nil { wroteAt = 2 }
                break
            }
            usleep(200)
        }
        done.signal()
    }
    var err: String?
    do { try scanner.remove(item) } catch { err = "\(error)" }
    let total = Date().timeIntervalSince(started)
    done.wait()
    print("ADV[04] wrote after ps#\(wroteAt) at \(t0)s of \(total)s; remove -> \(err ?? "ok"); worktree gone=\(!ex(wt))")
    #expect(!(wroteAt == 2 && err == nil && !ex(wt)), "ignored file written after the comparison was deleted unverified")
}

// MARK: R3-05

@Test func adv63_fingerprintNewRefInExistingSubdir() throws {
    let box = try SBox("05a"); defer { box.cleanup() }
    let wt = try box.worktree("w05a")
    try box.sh("git update-ref refs/worktree/keep HEAD", in: wt)
    let sha = try box.sh("git \(SBox.id) commit-tree -p HEAD -m parked $(git rev-parse 'HEAD^{tree}')", in: wt).t
    let before = try #require(WorktreeScanner.fingerprint(wt))
    Thread.sleep(forTimeInterval: 1.1)
    try box.sh("git update-ref refs/worktree/parked \(sha)", in: wt)
    let after = WorktreeScanner.fingerprint(wt)
    print("ADV[05a] same=\(before == after)")
    #expect(before != after)
}

@Test func adv64_fingerprintReftableDetachedHeadMove() throws {
    let box = try SBox("05b", cloneExtra: "--ref-format=reftable"); defer { box.cleanup() }
    let wt = try box.detached("w05b")
    let sha = try box.sh("git \(SBox.id) commit-tree -p HEAD -m late $(git rev-parse 'HEAD^{tree}')", in: wt).t
    let gd = try box.sh("git rev-parse --absolute-git-dir", in: wt).t
    print("ADV[05b] gitdir HEAD='\((try? String(contentsOfFile: gd + "/HEAD", encoding: .utf8))?.t ?? "-")' has reftable=\(ex(gd + "/reftable"))")
    let before = try #require(WorktreeScanner.fingerprint(wt))
    Thread.sleep(forTimeInterval: 1.1)
    try box.sh("git update-ref -m late HEAD \(sha)", in: wt)
    let after = WorktreeScanner.fingerprint(wt)
    print("ADV[05b] same=\(before == after) HEAD now=\(try box.sh("git rev-parse HEAD", in: wt).t.prefix(8)) sha=\(sha.prefix(8))")
    #expect(before != after)
}

// MARK: R3-06

@Test func adv67_perWorktreeRefReflogOldValue() throws {
    let box = try SBox("06"); defer { box.cleanup() }
    let wt = try box.worktree("w06")
    try box.sh("git config core.logAllRefUpdates always", in: box.repo)
    let sha = try box.sh("git \(SBox.id) commit-tree -p HEAD -m parked $(git rev-parse 'HEAD^{tree}')", in: wt).t
    try box.sh("git update-ref refs/worktree/p \(sha) && git update-ref refs/worktree/p HEAD", in: wt)
    let gd = try box.sh("git rev-parse --absolute-git-dir", in: wt).t
    print("ADV[06] per-worktree reflog exists=\(ex(gd + "/logs/refs/worktree/p")) reachable before=\(try reachable(sha, box.repo))")
    let (o, d, _) = tryDelete(box, wt, "06 commit only in refs/worktree/p reflog")
    let after = try reachable(sha, box.repo)
    print("ADV[06] reachable after=\(after)")
    #expect(!(o && d && !after))
}

// MARK: R3-07

@Test func adv68_crlfSplitUnit() {
    let a = String(repeating: "1", count: 40), b = String(repeating: "2", count: 40), c = String(repeating: "3", count: 40)
    let text = "\(a) \(b) t <t@e> 1 +0000\tx\r\n\(b) \(c) t <t@e> 2 +0000\ty\r\n"
    let got = Set(Worktrees.reflogCommits(text))
    print("ADV[07a] got \(got.count) shas; c present=\(got.contains(c))")
    #expect(got == [a, b, c])
}

@Test func adv69_crlfReflogEndToEnd() throws {
    let box = try SBox("07b"); defer { box.cleanup() }
    let wt = try box.detached("w07b")
    try box.sh("echo w > w && git add w && git \(SBox.id) commit -qm work && git checkout -q --detach origin/main", in: wt)
    let sha = try box.sh("git rev-parse HEAD@{1}", in: wt).t
    let gd = try box.sh("git rev-parse --absolute-git-dir", in: wt).t
    try box.sh("perl -pi -e 's/\\n/\\r\\n/' '\(gd)/logs/HEAD'")
    let (o, d, _) = tryDelete(box, wt, "07b CRLF reflog")
    let after = try reachable(sha, box.repo)
    print("ADV[07b] reachable after=\(after)")
    #expect(!(o && d && !after))
}

// MARK: R3-08

@Test func adv70_newlinePathImpersonation() throws {
    let box = try SBox("08"); defer { box.cleanup() }
    try box.sh("git config core.logAllRefUpdates false", in: box.repo)
    let victim = try box.detached("victim")
    try box.sh("echo w > w && git add w && git \(SBox.id) commit -qm 'unmerged' ", in: victim)
    let sha = try box.sh("git rev-parse HEAD", in: victim).t
    let vreal = WorktreeScanner.realPath(victim)
    try box.sh("git worktree add -q --detach $'\(box.scanRoot)/e\\nworktree \(vreal)' origin/main", in: box.repo)
    let (o, d, _) = tryDelete(box, victim, "08 newline path impersonation")
    let after = try reachable(sha, box.repo)
    print("ADV[08] reachable after=\(after)")
    #expect(!(o && d && !after))
}

// MARK: R3-09

@Test func adv71_rejectedAmendMessageDraft() throws {
    let box = try SBox("09"); defer { box.cleanup() }
    let wt = try box.worktree("w09")
    let hooks = box.root.appendingPathComponent("hooks").path
    let editor = box.root.appendingPathComponent("ed.sh").path
    try box.sh("mkdir -p '\(hooks)' && printf '#!/bin/sh\\nexit 1\\n' > '\(hooks)/commit-msg' && chmod +x '\(hooks)/commit-msg'")
    try box.sh("printf '#!/bin/sh\\nprintf \"Long hand-written message\\\\n\\\\nrationale\\\\n\" > \"$1\"\\n' > '\(editor)' && chmod +x '\(editor)'")
    _ = try? box.sh("GIT_EDITOR='\(editor)' git -c core.hooksPath='\(hooks)' \(SBox.id) commit -q --amend", in: wt)
    let gd = try box.sh("git rev-parse --absolute-git-dir", in: wt).t
    let draft = (try? String(contentsOfFile: gd + "/COMMIT_EDITMSG", encoding: .utf8)) ?? "-"
    print("ADV[09] COMMIT_EDITMSG='\(draft.t)' HEAD msg='\(try box.sh("git log -1 --format=%s", in: wt).t)'")
    let (o, d, _) = tryDelete(box, wt, "09 rejected amend draft")
    // Removal may go ahead only after saving the draft.
    let folder = box.root.appendingPathComponent("saved").path
    let saved = ((try? FileManager.default.subpathsOfDirectory(atPath: folder)) ?? [])
        .compactMap { try? String(contentsOfFile: folder + "/" + $0, encoding: .utf8) }.joined()
    #expect(!(o && d) || saved.contains("Long hand-written message"))
}

// MARK: R3-10

@Test func adv72_symlinkedRefsWorktreeDir() throws {
    let box = try SBox("10"); defer { box.cleanup() }
    let wt = try box.worktree("w10")
    let gd = try box.sh("git rev-parse --absolute-git-dir", in: wt).t
    let ext = box.root.appendingPathComponent("ext").path
    let sha = try box.sh("git \(SBox.id) commit-tree -p HEAD -m parked $(git rev-parse 'HEAD^{tree}')", in: wt).t
    try box.sh("mkdir -p '\(ext)' '\(gd)/refs' && echo \(sha) > '\(ext)/p' && ln -s '\(ext)' '\(gd)/refs/worktree'")
    print("ADV[10] git sees: \(try box.sh("git for-each-ref --format=\'%(objectname)\' refs/worktree/", in: wt).t.prefix(8))")
    let (o, d, _) = tryDelete(box, wt, "10 symlinked refs/worktree")
    let after = try reachable(sha, box.repo)
    print("ADV[10] reachable after=\(after)")
    #expect(!(o && d && !after))
}

// MARK: R3-11

@Test func adv73_upperCaseGITInNodeModules() throws {
    let box = try SBox("11"); defer { box.cleanup() }
    try box.sh("echo node_modules/ >> .git/info/exclude", in: box.repo)
    let wt = try box.worktree("w11")
    try box.sh("mkdir -p node_modules/fork && cd node_modules/fork && git init -q -b main . && echo f > f && git add f && git \(SBox.id) commit -qm fork && mv .git .tmpg && mv .tmpg .GIT && git log --oneline -1 >/dev/null", in: wt)
    let (o, d, _) = tryDelete(box, wt, "11 .GIT repo in node_modules")
    #expect(!(o && d))
}

@Test func adv65_fingerprintReftablePlainCommit() throws {
    let box = try SBox("05c", cloneExtra: "--ref-format=reftable"); defer { box.cleanup() }
    let wt = try box.detached("w05c")
    let before = try #require(WorktreeScanner.fingerprint(wt))
    Thread.sleep(forTimeInterval: 1.1)
    try box.sh("git \(SBox.id) commit -q --allow-empty -m late", in: wt)
    let after = WorktreeScanner.fingerprint(wt)
    print("ADV[05c] plain commit in reftable worktree: fingerprint same=\(before == after)\n before=\(before)\n after =\(after ?? "nil")")
    #expect(before != after)
}

@Test func adv66_fingerprintFilesPlainCommitControl() throws {
    let box = try SBox("05d"); defer { box.cleanup() }
    let wt = try box.detached("w05d")
    let before = try #require(WorktreeScanner.fingerprint(wt))
    Thread.sleep(forTimeInterval: 1.1)
    try box.sh("git \(SBox.id) commit -q --allow-empty -m late", in: wt)
    let after = WorktreeScanner.fingerprint(wt)
    print("ADV[05d] plain commit, files backend: fingerprint same=\(before == after)")
    #expect(before != after)
}

/// The draft rule must not keep ordinary worktrees: a commit whose message was used, then merged.
@Test func adv74_usedCommitMessageIsNotADraft() throws {
    let box = try SBox("74"); defer { box.cleanup() }
    let wt = try box.worktree("w74")
    try box.sh("echo n > n && git add n && git \(SBox.id) commit -qm 'real work' && git push -q origin HEAD:refs/heads/w74", in: wt)
    try box.sh("git merge -q --ff-only w74", in: box.origin)
    try box.sh("git fetch -q", in: box.repo)
    let scan = box.scanner().scan()
    print("ADV[74] skipped=\(scan.skipped)")
    #expect(scan.reclaimable.contains { $0.path.hasSuffix("/w74") }, "a merged worktree with a normal COMMIT_EDITMSG should be offered")
}

/// A walk of the whole worktree must still offer an ordinary checkout with ignored dependency folders.
@Test func adv75_wholeTreeWalkStillOffersCleanWorktree() throws {
    let box = try SBox("75"); defer { box.cleanup() }
    try box.sh("echo node_modules/ >> .git/info/exclude", in: box.repo)
    let wt = try box.worktree("w75")
    try box.sh("mkdir -p node_modules/x/lib deep/a/b && echo 1 > node_modules/x/lib/i.js && cp ../app/.env.local .env.local", in: wt)
    let scan = box.scanner().scan()
    print("ADV[75] skipped=\(scan.skipped)")
    #expect(scan.reclaimable.contains { $0.path.hasSuffix("/w75") })
}
