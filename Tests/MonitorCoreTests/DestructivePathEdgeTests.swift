import Darwin
import Foundation
import Testing
@testable import MonitorCore

// Fourth-round cases. Tests named *_safe assert the SAFE outcome (a failure is a way to lose work);
// tests named *_offered assert that an ordinary worktree IS offered (a failure is a false "kept").

private struct RBox {
    let root: URL
    let repo: String
    let scanRoot: String

    init(_ tag: String, extraOrigin: String = "", cloneExtra: String = "") throws {
        let base = ProcessInfo.processInfo.environment["ADV_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        root = base.appendingPathComponent("r4-\(tag)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("scan"), withIntermediateDirectories: true)
        let origin = root.appendingPathComponent("origin").path
        repo = root.appendingPathComponent("scan/app").path
        scanRoot = root.appendingPathComponent("scan").path
        try RBox.run("git init -q -b main '\(origin)'")
        try RBox.run("printf 'bin/\\n.env.local\\n' > .gitignore && printf '1\\n2\\n3\\n' > f && echo a > a && mkdir tracked && echo t > tracked/t \(extraOrigin.isEmpty ? "" : "&& " + extraOrigin) && git add -A && git \(RBox.id) commit -qm init", in: origin)
        try RBox.run("git \(RBox.allowFile) clone -q \(cloneExtra) '\(origin)' '\(repo)'")
        try RBox.run("echo SECRET=main > .env.local", in: repo)
    }

    static let id = "-c user.email=test@example.com -c user.name=test -c commit.gpgsign=false"
    static let allowFile = "-c protocol.file.allow=always"
    var origin: String { root.appendingPathComponent("origin").path }

    func worktree(_ name: String) throws -> String {
        let path = root.appendingPathComponent("scan/\(name)").path
        try sh("git worktree add -q -b '\(name)' '\(path)' origin/main", in: repo)
        return path
    }

    @discardableResult
    func sh(_ cmd: String, in dir: String? = nil) throws -> String { try RBox.run(cmd, in: dir) }

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

    var savedMessages: String { root.appendingPathComponent("saved").path }

    func scanner(minIdleHours: Double = 0) -> WorktreeScanner {
        var policy = WorktreePolicy()
        policy.roots = [scanRoot]
        policy.searchDepth = 1
        policy.minIdleHours = minIdleHours
        policy.savedMessagesDirectory = savedMessages
        return WorktreeScanner(policy: policy)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private extension String { var t: String { trimmingCharacters(in: .whitespacesAndNewlines) } }
private func ex(_ p: String) -> Bool { FileManager.default.fileExists(atPath: p) }

/// (offered, deleted, error)
@discardableResult
private func tryDelete(_ box: RBox, _ path: String, _ label: String) -> (Bool, Bool, String?) {
    let scanner = box.scanner()
    let scan = scanner.scan()
    let real = WorktreeScanner.realPath(path)
    guard let item = scan.reclaimable.first(where: { $0.path == path || $0.path == real }) else {
        print("R4[\(label)] NOT offered; skipped=\(scan.skipped)")
        return (false, false, nil)
    }
    var err: String?
    do { try scanner.remove(item) } catch { err = "\(error)" }
    let deleted = !ex(path) || !ex(path + "/.git")
    print("R4[\(label)] OFFERED; remove() -> \(err ?? "ok"); deleted=\(deleted)")
    return (true, deleted, err)
}

/// The scanner's verdict for one worktree, with its explanation.
private func verdict(_ box: RBox, _ path: String) -> WorktreeVerdict? {
    let list = WorktreeScanner.git(["worktree", "list", "--porcelain", "-z"], in: box.repo)
    let wts = Worktrees.parsePorcelain(list.out)
    let real = WorktreeScanner.realPath(path)
    guard let wt = wts.first(where: { $0.path == path || $0.path == real }),
          let context = try? LiveContext.capture() else { return nil }
    return box.scanner().classify(wt, repo: WorktreeScanner.realPath(box.repo), base: "refs/remotes/origin/main",
                                  context: context, allWorktreePaths: wts.map(\.path), now: Date()).0
}

private func offered(_ box: RBox, _ suffix: String) -> Bool {
    box.scanner().scan().reclaimable.contains { $0.path.hasSuffix("/" + suffix) }
}

/// Merged work, then `git commit -am` again with nothing to commit (an agent's or user's habitual
/// final commit). git writes COMMIT_EDITMSG and fails; logs/HEAD is older.
@Test func r4a_noOpCommitAfterMergedWork_offered() throws {
    let box = try RBox("noop"); defer { box.cleanup() }
    let wt = try box.worktree("wnoop")
    try box.sh("echo n > n && git add n && git \(RBox.id) commit -qm 'real work' && git push -q origin HEAD:refs/heads/wnoop", in: wt)
    try box.sh("git merge -q --ff-only wnoop", in: box.origin)
    try box.sh("git fetch -q", in: box.repo)
    #expect(offered(box, "wnoop"), "precondition: merged worktree offered")
    _ = try? box.sh("git \(RBox.id) commit -qam 'final commit'", in: wt)   // "nothing to commit", exit 1
    let v = verdict(box, wt)
    print("R4[a] verdict after no-op commit: \(v.map { "\($0.category): \($0.explanation)" } ?? "nil")")
    #expect(offered(box, "wnoop"), "a failed 'nothing to commit' commit keeps a merged clean worktree forever")
}

/// `git commit` whose editor leaves the message empty ("Aborting commit due to empty commit message").

/// `git commit` whose editor leaves the message empty ("Aborting commit due to empty commit message").
@Test func r4b_abortedEmptyMessageCommit_offered() throws {
    let box = try RBox("abort"); defer { box.cleanup() }
    let wt = try box.worktree("wabort")
    _ = try? box.sh("GIT_EDITOR=true git \(RBox.id) commit -q --allow-empty", in: wt)
    let v = verdict(box, wt)
    print("R4[b] verdict after aborted commit: \(v.map { "\($0.category): \($0.explanation)" } ?? "nil")")
    #expect(offered(box, "wabort"))
}

/// A squash merge or a cherry-pick -n that the user discarded with restore/clean instead of reset.

/// A squash merge or a cherry-pick -n that the user discarded with restore/clean instead of reset.
@Test func r4c_discardedSquashAndNoCommitPick_offered() throws {
    let box = try RBox("squash"); defer { box.cleanup() }
    try box.sh("git checkout -q -b side && echo s > s && git add s && git \(RBox.id) commit -qm side && git checkout -q main", in: box.repo)
    let w1 = try box.worktree("wsq")
    try box.sh("git \(RBox.id) merge -q --squash side >/dev/null && git restore --staged --worktree . && git clean -qfd", in: w1)
    let w2 = try box.worktree("wcp")
    try box.sh("git \(RBox.id) cherry-pick -n side && git restore --staged --worktree . && git clean -qfd", in: w2)
    print("R4[c] status w1='\(try box.sh("git status --porcelain", in: w1).t)' w2='\(try box.sh("git status --porcelain", in: w2).t)'")
    print("R4[c] w1: \(verdict(box, w1).map(\.explanation) ?? "nil"); w2: \(verdict(box, w2).map(\.explanation) ?? "nil")")
    #expect(offered(box, "wsq"))
    #expect(offered(box, "wcp"))
}

/// Gap (unsafe direction): a rejected commit's message draft in a reftable repo (no logs/HEAD file).

/// A rejected commit's message in a reftable repo (no logs/HEAD file) is saved before removal.
@Test func r4c2_reftableRejectedDraftIsSaved_safe() throws {
    let box = try RBox("rtdraft", cloneExtra: "--ref-format=reftable"); defer { box.cleanup() }
    let wt = try box.worktree("wrtd")
    let hooks = box.root.appendingPathComponent("hooks").path
    try box.sh("mkdir -p '\(hooks)' && printf '#!/bin/sh\\nexit 1\\n' > '\(hooks)/commit-msg' && chmod +x '\(hooks)/commit-msg'")
    _ = try? box.sh("git -c core.hooksPath='\(hooks)' \(RBox.id) commit -q --allow-empty -m 'Long hand-written message'", in: wt)
    let gd = try box.sh("git rev-parse --absolute-git-dir", in: wt).t
    print("R4[c2] COMMIT_EDITMSG='\(((try? String(contentsOfFile: gd + "/COMMIT_EDITMSG", encoding: .utf8)) ?? "-").t)' logs/HEAD exists=\(ex(gd + "/logs/HEAD"))")
    print("R4[c2] verdict: \(verdict(box, wt).map(\.explanation) ?? "nil")")
    let (o, d, _) = tryDelete(box, wt, "c2 reftable rejected draft")
    let saved = (try? FileManager.default.subpathsOfDirectory(atPath: box.savedMessages)) ?? []
    let text = saved.compactMap { try? String(contentsOfFile: box.savedMessages + "/" + $0, encoding: .utf8) }.joined()
    print("R4[c2] offered=\(o) deleted=\(d) saved=\(saved)")
    #expect(!(o && d) || text.contains("Long hand-written message"), "the draft was deleted without being saved")
}

@Test func r4d_reftableNoReflogs_offered() throws {
    let box = try RBox("rtnolog", cloneExtra: "--ref-format=reftable"); defer { box.cleanup() }
    try box.sh("git config core.logAllRefUpdates false", in: box.repo)
    let wt = try box.worktree("wrtn")
    let r = WorktreeScanner.git(["log", "-g", "--format=%H", "HEAD", "--"], in: wt)
    print("R4[d] git log -g HEAD: status=\(r.status) out=\(r.out.t.prefix(12)) err=\(r.err.t)")
    print("R4[d] verdict: \(verdict(box, wt).map { "\($0.category): \($0.explanation)" } ?? "nil")")
    #expect(offered(box, "wrtn"))
}

@Test func r4e_perWorktreeRefWithoutReflog() throws {
    for (tag, extra) in [("files", ""), ("reftable", "--ref-format=reftable")] {
        let box = try RBox("pwref-\(tag)", cloneExtra: extra); defer { box.cleanup() }
        let wt = try box.worktree("wpw")
        try box.sh("git update-ref refs/worktree/keep HEAD && git update-ref refs/bisect/good HEAD", in: wt)
        let r = WorktreeScanner.git(["log", "-g", "--format=%H", "refs/worktree/keep", "--"], in: wt)
        print("R4[e/\(tag)] log -g refs/worktree/keep status=\(r.status) err=\(r.err.t)")
        print("R4[e/\(tag)] verdict: \(verdict(box, wt).map { "\($0.category): \($0.explanation)" } ?? "nil")")
        #expect(offered(box, "wpw"), "\(tag): refs pointing into origin/main shouldn't block")
    }
}

/// A file whose name starts with a combining mark, inside an ignored folder that is NOT regenerable.
@Test func r4f_combiningMarkFileInIgnoredDir_safe() throws {
    let box = try RBox("comb"); defer { box.cleanup() }
    try box.sh("echo 'notes/' >> .git/info/exclude", in: box.repo)
    let wt = try box.worktree("wcomb")
    try box.sh("mkdir notes && printf 'the only copy' > \"notes/$(printf '\\xcc\\x81')draft.txt\"", in: wt)
    print("R4[f] status: \(try box.sh("git status --porcelain --ignored", in: wt).t)")
    let (o, d, err) = tryDelete(box, wt, "f combining-mark file in ignored notes/")
    #expect(!(o && d), "unique file deleted: \(err ?? "-")")
}

/// Same with a sub-folder whose name starts with a zero-width joiner; everything under it is skipped.

/// Same with a sub-folder whose name starts with a zero-width joiner; everything under it is skipped.
@Test func r4g_zwjSubfolderInIgnoredDir_safe() throws {
    let box = try RBox("zwj"); defer { box.cleanup() }
    try box.sh("echo 'notes/' >> .git/info/exclude", in: box.repo)
    let wt = try box.worktree("wzwj")
    try box.sh("mkdir -p \"notes/$(printf '\\xe2\\x80\\x8d')drafts\" && printf 'the only copy' > \"notes/$(printf '\\xe2\\x80\\x8d')drafts/plan.md\"", in: wt)
    let (o, d, err) = tryDelete(box, wt, "g ZWJ subfolder in ignored notes/")
    #expect(!(o && d), "unique file deleted: \(err ?? "-")")
}

/// Control: untracked top-level file named with a lone combining mark (parseStatus drops it).

/// Control: untracked top-level file named with a lone combining mark (parseStatus drops it).
@Test func r4h_combiningTopLevelUntracked_safe() throws {
    let box = try RBox("combtop"); defer { box.cleanup() }
    let wt = try box.worktree("wct")
    try box.sh("printf 'the only copy' > \"$(printf '\\xcc\\x81')\"", in: wt)
    print("R4[h] parseStatus: \(Worktrees.parseStatus(try box.sh("git status --porcelain=v1 -z --ignored=matching", in: wt)))")
    print("R4[h] verdict: \(verdict(box, wt).map { "\($0.category): \($0.explanation)" } ?? "nil")")
    let (o, d, _) = tryDelete(box, wt, "h lone combining mark top level")
    #expect(!(o && d))
}

@Test func r4u_unitGraphemeSplits() {
    let dirs: [String: Bool] = ["notes": false, "a/b": true]
    #expect(WorktreeScanner.enclosingIgnoredDir("a/bc/x", in: dirs) == nil)
    #expect(WorktreeScanner.enclosingIgnoredDir("a/b/x", in: dirs) == true)
    #expect(WorktreeScanner.enclosingIgnoredDir("notes/x/y", in: dirs) == false)
    let comb = WorktreeScanner.enclosingIgnoredDir("notes/\u{301}draft.txt", in: dirs)
    let zwj = WorktreeScanner.enclosingIgnoredDir("notes/\u{200D}drafts/plan.md", in: dirs)
    let tone = WorktreeScanner.enclosingIgnoredDir("notes/\u{1F3FD}x", in: dirs)
    print("R4[u] combining=\(String(describing: comb)) zwj=\(String(describing: zwj)) skin-tone=\(String(describing: tone))")
    #expect(comb == false)
    #expect(zwj == false)
    #expect(tone == false)
    let st = Worktrees.parseStatus("?? \u{301}\0!! \u{200D}\0")
    print("R4[u] parseStatus lone marks: changes=\(st.changes.count) ignored=\(st.ignored.count)")
    #expect(st.changes.count == 1 && st.ignored.count == 1)
}

/// The worktree folder was moved and a symlink left at the registered path (git still works there).
@Test func r4i_symlinkedWorktreeRoot_safe() throws {
    let box = try RBox("symroot"); defer { box.cleanup() }
    try box.sh("echo 'notes/' >> .git/info/exclude", in: box.repo)
    let wt = try box.worktree("wsym")
    try box.sh("mkdir notes && echo 'the only copy' > notes/plan.md", in: wt)
    let moved = box.root.appendingPathComponent("elsewhere").path
    try box.sh("mkdir -p '\(moved)' && mv '\(wt)' '\(moved)/wsym' && ln -s '\(moved)/wsym' '\(wt)'")
    print("R4[i] git status via link: '\(try box.sh("git status --porcelain --ignored", in: wt).t)'")
    print("R4[i] verdict: \(verdict(box, wt).map { "\($0.category): \($0.explanation)" } ?? "nil")")
    let (o, _, err) = tryDelete(box, wt, "i symlinked worktree root")
    let survived = ex(moved + "/wsym/notes/plan.md")
    print("R4[i] offered=\(o) err=\(err ?? "-") notes/plan.md survived=\(survived)")
    #expect(survived)
    #expect(!o)
}

/// Worktree folder whose name is NFD on disk (git records the NFC form).

/// Worktree folder whose name is NFD on disk (git records the NFC form).
@Test func r4j_nfdWorktreeName_offered() throws {
    let box = try RBox("nfd"); defer { box.cleanup() }
    try box.sh("echo 'notes/' >> .git/info/exclude && mkdir notes && echo same > notes/n.txt", in: box.repo)
    try box.sh("cd '\(box.scanRoot)' && mkdir \"$(printf 'cafe\\xcc\\x81')\" && git -C app worktree add -q -b nfd \"$PWD/$(printf 'cafe\\xcc\\x81')\" origin/main")
    let wt = box.scanRoot + "/cafe\u{301}"
    try box.sh("mkdir notes && echo same > notes/n.txt && cp ../app/.env.local .", in: wt)
    let listed = try box.sh("git worktree list --porcelain | grep caf | od -c | head -3", in: box.repo)
    print("R4[j] listed bytes:\n\(listed)")
    print("R4[j] verdict: \(verdict(box, wt).map { "\($0.category): \($0.explanation)" } ?? "nil")")
    #expect(box.scanner().scan().reclaimable.contains { $0.path.hasSuffix("/caf\u{e9}") })
}

/// Ignored folder and file with NFD names; an identical copy in main is accepted, a unique one is not.

/// Ignored folder and file with NFD names; an identical copy in main is accepted, a unique one is not.
@Test func r4k_nfdIgnoredNames() throws {
    let box = try RBox("nfdign"); defer { box.cleanup() }
    try box.sh("printf 'caf\\xc3\\xa9/\\n' >> .git/info/exclude && mkdir \"$(printf 'cafe\\xcc\\x81')\" && echo same > \"$(printf 'cafe\\xcc\\x81')/r\\xcc\\x81.txt\"", in: box.repo)
    let w1 = try box.worktree("wk1")
    try box.sh("mkdir \"$(printf 'cafe\\xcc\\x81')\" && echo same > \"$(printf 'cafe\\xcc\\x81')/r\\xcc\\x81.txt\" && cp ../app/.env.local .", in: w1)
    let w2 = try box.worktree("wk2")
    try box.sh("mkdir \"$(printf 'cafe\\xcc\\x81')\" && echo unique > \"$(printf 'cafe\\xcc\\x81')/other.txt\"", in: w2)
    print("R4[k] w1: \(verdict(box, w1).map(\.category) ?? "nil"); w2: \(verdict(box, w2).map(\.category) ?? "nil")")
    #expect(offered(box, "wk1"))
    #expect(!offered(box, "wk2"))
}

@Test func r4r_prefixAndNesting_safe() throws {
    let box = try RBox("prefix"); defer { box.cleanup() }
    try box.sh("printf 'd/node_modules/\\nd/node_modulesx/\\nlogs/\\n' >> .git/info/exclude", in: box.repo)
    let w1 = try box.worktree("wp1")
    try box.sh("mkdir -p d/node_modules/m d/node_modulesx && echo 1 > d/node_modules/m/i.js && echo mine > d/node_modulesx/plan.md", in: w1)
    let w2 = try box.worktree("wp2")
    try box.sh("mkdir -p logs/node_modules && echo mine > logs/node_modules/plan.md", in: w2)
    print("R4[r] w1: \(verdict(box, w1).map(\.explanation) ?? "nil"); w2: \(verdict(box, w2).map(\.explanation) ?? "nil")")
    #expect(!offered(box, "wp1"))
    #expect(!offered(box, "wp2"))
}

/// Finder writes .DS_Store into every folder it opens; most Mac developers ignore it globally.
@Test func r4l_dsStore_offered() throws {
    let box = try RBox("dss"); defer { box.cleanup() }
    try box.sh("echo .DS_Store >> .git/info/exclude && printf 'Bud1main' > .DS_Store", in: box.repo)
    let wt = try box.worktree("wds")
    try box.sh("printf 'Bud1wt' > .DS_Store && printf 'Bud1wt2' > tracked/.DS_Store", in: wt)
    print("R4[l] verdict: \(verdict(box, wt).map { "\($0.category): \($0.explanation)" } ?? "nil")")
    #expect(offered(box, "wds"), "a worktree opened in Finder is never reclaimable")
}

/// SwiftPM keeps dependency checkouts as git clones in .build/checkouts/<dep>/.git.

/// SwiftPM keeps dependency checkouts as git clones in .build/checkouts/<dep>/.git.
@Test func r4m_swiftpmCheckouts_offered() throws {
    let box = try RBox("spm"); defer { box.cleanup() }
    try box.sh("echo '.build/' >> .git/info/exclude", in: box.repo)
    let wt = try box.worktree("wspm")
    try box.sh("mkdir -p .build/checkouts .build/repositories && git clone -q '\(box.origin)' .build/checkouts/dep && git clone -q --mirror '\(box.origin)' .build/repositories/dep-1234", in: wt)
    print("R4[m] verdict: \(verdict(box, wt).map { "\($0.category): \($0.explanation)" } ?? "nil")")
    #expect(offered(box, "wspm"), "every built Swift package with dependencies is kept")
}

/// core.fileMode=false in the repo (exFAT/SMB, or set by hand); a file's exec bit differs.

/// core.fileMode=false in the repo (exFAT/SMB, or set by hand); a file's exec bit differs.
@Test func r4o_fileModeFalseRepo() throws {
    let box = try RBox("fmode"); defer { box.cleanup() }
    try box.sh("git config core.fileMode false", in: box.repo)
    let wt = try box.worktree("wfm")
    try box.sh("chmod +x a", in: wt)
    print("R4[o] repo-config status='\(try box.sh("git status --porcelain", in: wt).t)' verdict=\(verdict(box, wt).map(\.category) ?? "nil")")
    #expect(offered(box, "wfm"), "a mode-only change in a fileMode=false repo loses nothing")
}

@Test func r4n_removeNoFalseRefusal() throws {
    let box = try RBox("nofalse"); defer { box.cleanup() }
    try box.sh("git config core.untrackedCache true && git config core.splitIndex true && echo node_modules/ >> .git/info/exclude", in: box.repo)
    let wt = try box.worktree("wnf")
    try box.sh("git update-index --untracked-cache && git update-index --split-index && git status >/dev/null && mkdir -p node_modules/x && echo 1 > node_modules/x/i.js && cp ../app/.env.local . && sleep 1.1 && touch a tracked/t f", in: wt)
    let (o, d, err) = tryDelete(box, wt, "n untracked cache + split index + stale stat")
    #expect(o && d, "false refusal: \(err ?? "-")")

    let rt = try RBox("nofalse-rt", cloneExtra: "--ref-format=reftable"); defer { rt.cleanup() }
    let wt2 = try rt.worktree("wnf2")
    try rt.sh("cp ../app/.env.local . && git status >/dev/null", in: wt2)
    let (o2, d2, err2) = tryDelete(rt, wt2, "n reftable clean")
    #expect(o2 && d2, "reftable false refusal: \(err2 ?? "-")")
}

@Test func r4p_parsePorcelainFields() {
    let a = String(repeating: "a", count: 40), b = String(repeating: "b", count: 40), c = String(repeating: "c", count: 40)
    let z = "worktree /r\0HEAD \(a)\0branch refs/heads/main\0\0worktree /r/w 1\0HEAD \(b)\0detached\0locked because\nreasons\0\0worktree /r/w2\nx\0HEAD \(c)\0branch refs/heads/feat/x\0prunable gitdir file points to non-existent location\0\0"
    let w = Worktrees.parsePorcelain(z)
    print("R4[p] -z: \(w)")
    #expect(w.count == 3)
    #expect(w[0].isMain && w[0].branch == "main" && w[0].head == a)
    #expect(w[1].path == "/r/w 1" && w[1].branch == nil && w[1].isLocked && !w[1].isMain)
    #expect(w[2].path == "/r/w2\nx" && w[2].branch == "feat/x" && w[2].isPrunable)
    let n = "worktree /bare\nbare\n\nworktree /r/w\nHEAD \(a)\nbranch refs/heads/m\nlocked\n\n"
    let w2 = Worktrees.parsePorcelain(n)
    print("R4[p] newline: \(w2)")
    #expect(w2.count == 2 && w2[0].isBare && w2[1].isLocked && w2[1].branch == "m")
}

/// The folder holding the worktree was moved to another disk and a symlink left behind
/// (git keeps working through it and still lists the old, now non-canonical, path).
@Test func r4x_movedParentLeftSymlink_offered() throws {
    let box = try RBox("movedparent"); defer { box.cleanup() }
    try box.sh("mkdir -p '\(box.scanRoot)/sub'")
    let wt = box.scanRoot + "/sub/wmp"
    try box.sh("git worktree add -q -b wmp '\(wt)' origin/main && cp .env.local '\(wt)/'", in: box.repo)
    let moved = box.root.appendingPathComponent("disk2").path
    try box.sh("mkdir -p '\(moved)' && mv '\(box.scanRoot)/sub' '\(moved)/sub' && ln -s '\(moved)/sub' '\(box.scanRoot)/sub'")
    let listed = try box.sh("git worktree list --porcelain | grep wmp", in: box.repo).t
    print("R4[x] git lists: \(listed); git status: '\(try box.sh("git status --porcelain", in: wt).t)'")
    let list = WorktreeScanner.git(["worktree", "list", "--porcelain", "-z"], in: box.repo)
    let wts = Worktrees.parsePorcelain(list.out)
    let w = try #require(wts.first { $0.path.hasSuffix("/wmp") })
    let v = box.scanner().classify(w, repo: WorktreeScanner.realPath(box.repo), base: "refs/remotes/origin/main",
                                   context: try LiveContext.capture(), allWorktreePaths: wts.map(\.path), now: Date()).0
    print("R4[x] verdict=\(v.category): \(v.explanation)")
    #expect(v == .reclaimable)
}

/// A repository in a dependency folder with a commit of its own is still kept.
@Test func r4m2_dependencyCheckoutWithLocalCommit_safe() throws {
    let box = try RBox("spmlocal"); defer { box.cleanup() }
    try box.sh("echo '.build/' >> .git/info/exclude", in: box.repo)
    let wt = try box.worktree("wspl")
    try box.sh("mkdir -p .build/checkouts && git clone -q '\(box.origin)' .build/checkouts/dep && cd .build/checkouts/dep && echo p > p && git add p && git \(RBox.id) commit -qm 'local patch'", in: wt)
    let (o, d, _) = tryDelete(box, wt, "m2 dependency checkout with a local commit")
    #expect(!(o && d))
}

/// ...and so is one with an uncommitted edit, or a stash.
@Test func r4m3_dependencyCheckoutWithEditOrStash_safe() throws {
    let box = try RBox("spmedit"); defer { box.cleanup() }
    try box.sh("echo '.build/' >> .git/info/exclude", in: box.repo)
    let w1 = try box.worktree("wse")
    try box.sh("mkdir -p .build/checkouts && git clone -q '\(box.origin)' .build/checkouts/dep && echo edit >> .build/checkouts/dep/a", in: w1)
    let w2 = try box.worktree("wss")
    try box.sh("mkdir -p .build/checkouts && git clone -q '\(box.origin)' .build/checkouts/dep && cd .build/checkouts/dep && echo edit >> a && git \(RBox.id) stash -q", in: w2)
    #expect(!offered(box, "wse"))
    #expect(!offered(box, "wss"))
}

/// git gc in the main checkout rewrites every worktree's logs/HEAD; an idle worktree stays idle.
/// 5 days: gc keeps the entry (new file mtime, old entry time). 2020: gc expires every entry.
@Test(arguments: [5, 2000])
func r4s_gcDoesNotMakeWorktreesRecentlyActive_offered(daysIdle: Int) throws {
    let box = try RBox("gc\(daysIdle)"); defer { box.cleanup() }
    let path = box.root.appendingPathComponent("scan/wgc").path
    let when = Date().addingTimeInterval(-Double(daysIdle) * 86400)
    let iso = ISO8601DateFormatter().string(from: when)
    let f = DateFormatter(); f.dateFormat = "yyyyMMddHHmm"; let stamp = f.string(from: when)
    try box.sh("GIT_COMMITTER_DATE='\(iso)' git worktree add -q -b wgc '\(path)' origin/main && cp .env.local '\(path)/'", in: box.repo)
    let gd = try box.sh("git rev-parse --absolute-git-dir", in: path).t
    try box.sh("touch -t \(stamp) '\(gd)/HEAD' '\(gd)/index' '\(gd)/logs/HEAD'")
    #expect(box.scanner(minIdleHours: 24).scan().reclaimable.contains { $0.path.hasSuffix("/wgc") }, "precondition: idle worktree offered")
    try box.sh("git gc -q", in: box.repo)
    let scan = box.scanner(minIdleHours: 24).scan()
    print("R4[s/\(daysIdle)d] after gc skipped=\(scan.skipped) logs/HEAD bytes=\(((try? FileManager.default.attributesOfItem(atPath: gd + "/logs/HEAD"))?[.size] as? NSNumber)?.intValue ?? -1)")
    #expect(scan.reclaimable.contains { $0.path.hasSuffix("/wgc") })
}

/// A hook-rejected commit leaves its hand-written message; removal saves it first.
@Test func r4t_rejectedCommitMessageIsSavedBeforeRemoval() throws {
    let box = try RBox("savemsg"); defer { box.cleanup() }
    let wt = try box.worktree("wsave")
    let hooks = box.root.appendingPathComponent("hooks").path
    try box.sh("mkdir -p '\(hooks)' && printf '#!/bin/sh\\nexit 1\\n' > '\(hooks)/commit-msg' && chmod +x '\(hooks)/commit-msg'")
    _ = try? box.sh("git -c core.hooksPath='\(hooks)' \(RBox.id) commit -q --allow-empty -m 'Why the cache must be warmed first'", in: wt)
    let (o, d, err) = tryDelete(box, wt, "t rejected commit message")
    let saved = (try? FileManager.default.subpathsOfDirectory(atPath: box.savedMessages)) ?? []
    let text = saved.compactMap { try? String(contentsOfFile: box.savedMessages + "/" + $0, encoding: .utf8) }.joined()
    print("R4[t] offered=\(o) deleted=\(d) err=\(err ?? "-") saved=\(saved)")
    #expect(o && d)
    #expect(text.contains("Why the cache must be warmed first"))
}

/// A normal commit's message (already in history) isn't saved again.
@Test func r4t2_usedCommitMessageIsNotSaved() throws {
    let box = try RBox("nosave"); defer { box.cleanup() }
    let wt = try box.worktree("wns")
    try box.sh("echo n > n && git add n && git \(RBox.id) commit -qm 'real work' && git push -q origin HEAD:refs/heads/wns", in: wt)
    try box.sh("git merge -q --ff-only wns", in: box.origin)
    try box.sh("git fetch -q", in: box.repo)
    let (o, d, _) = tryDelete(box, wt, "t2 used message")
    #expect(o && d)
    #expect(!FileManager.default.fileExists(atPath: box.savedMessages))
}

/// Split index: git touches sharedindex.* on every read; remove() must not refuse because of it.
@Test func r4w_splitIndexRemoves() throws {
    let box = try RBox("split"); defer { box.cleanup() }
    try box.sh("git config core.splitIndex true", in: box.repo)
    let wt = try box.worktree("wsplit")
    try box.sh("git update-index --split-index && cp ../app/.env.local .", in: wt)
    let (o, d, err) = tryDelete(box, wt, "w split index")
    #expect(o && d, "false refusal: \(err ?? "-")")
}

/// A process working in a folder whose name starts with a combining mark is inside the worktree.
@Test func r4y_containsIsByteBased() {
    #expect(Worktrees.contains("/r/wt", "/r/wt/\u{301}sub"))
    #expect(Worktrees.contains("/r/wt", "/r/wt/\u{200D}x/y"))
    #expect(!Worktrees.contains("/r/wt", "/r/wtx"))
    #expect(Worktrees.contains("/R/WT", "/r/wt/a"))
}
