import Darwin
import Foundation
import Testing
@testable import MonitorCore

// Fifth-round cases, from a review of the deletion path. Tests named *_safe assert the SAFE
// outcome (a failure is a way to lose work); tests named *_offered assert that an ordinary
// worktree IS offered (a failure is a false "kept").

private struct R5Box {
    let root: URL
    let repo: String
    let scanRoot: String

    init(_ tag: String) throws {
        let base = ProcessInfo.processInfo.environment["ADV_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        root = base.appendingPathComponent("r5-\(tag)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("scan"), withIntermediateDirectories: true)
        let origin = root.appendingPathComponent("origin").path
        repo = root.appendingPathComponent("scan/app").path
        scanRoot = root.appendingPathComponent("scan").path
        try R5Box.run("git init -q -b main '\(origin)'")
        try R5Box.run("printf 'bin/\\n.env.local\\n' > .gitignore && echo a > a && mkdir tracked && echo t > tracked/t && git add -A && git \(R5Box.id) commit -qm init", in: origin)
        try R5Box.run("git clone -q '\(origin)' '\(repo)'")
        try R5Box.run("echo SECRET=main > .env.local", in: repo)
    }

    static let id = "-c user.email=test@example.com -c user.name=test -c commit.gpgsign=false -c tag.gpgsign=false"

    func worktree(_ name: String) throws -> String {
        let path = root.appendingPathComponent("scan/\(name)").path
        try sh("git worktree add -q -b '\(name)' '\(path)' origin/main", in: repo)
        return path
    }

    func gitdir(_ worktree: String) throws -> String {
        try sh("git rev-parse --absolute-git-dir", in: worktree).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An editor script that writes `text` into the file git hands it, then exits with `status`.
    func editor(_ name: String, writes text: String, exit status: Int = 0) throws -> String {
        let path = root.appendingPathComponent(name).path
        try "#!/bin/sh\nprintf '%s\\n' '\(text)' > \"$1\"\nexit \(status)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try sh("chmod +x '\(path)'")
        return path
    }

    @discardableResult
    func sh(_ cmd: String, in dir: String? = nil) throws -> String { try R5Box.run(cmd, in: dir) }

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

    /// Everything saved to the messages folder, concatenated.
    var savedText: String {
        let files = (try? FileManager.default.subpathsOfDirectory(atPath: savedMessages)) ?? []
        return files.compactMap { try? String(contentsOfFile: savedMessages + "/" + $0, encoding: .utf8) }.joined()
    }

    func scanner() -> WorktreeScanner {
        var policy = WorktreePolicy()
        policy.roots = [scanRoot]
        policy.searchDepth = 1
        policy.minIdleHours = 0
        policy.savedMessagesDirectory = savedMessages
        return WorktreeScanner(policy: policy)
    }

    /// Read-only folders inside the sandbox would stop removeItem.
    func cleanup() {
        _ = try? sh("chmod -R u+w '\(root.path)'")
        try? FileManager.default.removeItem(at: root)
    }
}

private func ex(_ p: String) -> Bool { FileManager.default.fileExists(atPath: p) }

private func item(_ scanner: WorktreeScanner, _ path: String) -> ReclaimableWorktree? {
    let real = WorktreeScanner.realPath(path)
    return scanner.scan().reclaimable.first { $0.path == path || $0.path == real }
}

private struct Failing: Error, CustomStringConvertible { var description: String { "ps failed: exit 1" } }

// MARK: 1. A file written while the re-check runs

/// An editor saves an ignored file into a tracked folder after `git status` ran but before the
/// walk reached that folder. The walk used to skip it as tracked, and its folder's snapshot
/// already included it, so the last check passed and git deleted the only copy.
@Test func r5a_ignoredFileWrittenDuringChecks_safe() throws {
    let box = try R5Box("race"); defer { box.cleanup() }
    let wt = try box.worktree("wrace")
    let scanner = box.scanner()
    let target = try #require(item(scanner, wt), "precondition: offered")
    let late = wt + "/tracked/.env.local"
    scanner.afterStatus = { try? "SECRET=only-copy\n".write(toFile: late, atomically: false, encoding: .utf8) }
    var err: String?
    do { try scanner.remove(target) } catch { err = "\(error)" }
    print("R5[a] remove -> \(err ?? "ok")")
    #expect(err != nil, "remove() deleted a worktree holding a file it never checked")
    #expect((try? String(contentsOfFile: late, encoding: .utf8)) == "SECRET=only-copy\n")
}

/// Control: a file that turns up the same way but has a copy in the main checkout is recoverable.
@Test func r5a2_lateFileWithACopyInMainStillRemoves_offered() throws {
    let box = try R5Box("racecopy"); defer { box.cleanup() }
    try box.sh("echo SECRET=shared > tracked/.env.local", in: box.repo)
    let wt = try box.worktree("wcopy")
    let scanner = box.scanner()
    let target = try #require(item(scanner, wt), "precondition: offered")
    scanner.afterStatus = { try? "SECRET=shared\n".write(toFile: wt + "/tracked/.env.local", atomically: false, encoding: .utf8) }
    #expect(throws: Never.self) { try scanner.remove(target) }
    #expect(!ex(wt))
}

/// Control: a tracked file stored on disk under a decomposed name still counts as tracked.
@Test func r5a3_decomposedTrackedNameIsStillTracked_offered() throws {
    let box = try R5Box("nfd"); defer { box.cleanup() }
    let nfc = "caf\u{E9}.txt", nfd = "cafe\u{301}.txt"
    let origin = box.root.appendingPathComponent("origin").path
    try "menu\n".write(toFile: origin + "/" + nfc, atomically: true, encoding: .utf8)
    try box.sh("git add -A && git \(R5Box.id) commit -qm menu", in: origin)
    try box.sh("git fetch -q", in: box.repo)
    let wt = try box.worktree("wnfd")
    // rename(2): FileManager would call the decomposed name taken, since the volume treats both as one.
    #expect(rename(wt + "/" + nfc, wt + "/" + nfd) == 0)
    let names = try FileManager.default.contentsOfDirectory(atPath: wt).filter { $0.hasPrefix("caf") }
    print("R5[a3] scalars on disk: \(names.map { $0.unicodeScalars.count }); git status: '\(try box.sh("git status --porcelain", in: wt))'")
    #expect(item(box.scanner(), wt) != nil, "a renamed-in-place tracked file made the worktree look unsafe")
}

// MARK: 2. git failing partway through removal

/// A hook rejected a commit (its message is in COMMIT_EDITMSG), and the worktree holds a folder
/// git can't delete. git deletes the git directory, message included, then fails. The saved
/// copy used to be deleted too, on the assumption that the original was still there.
@Test func r5b_messageSurvivesPartialRemoval_safe() throws {
    let box = try R5Box("partial"); defer { box.cleanup() }
    let wt = try box.worktree("wpart")
    let hooks = box.root.appendingPathComponent("hooks").path
    try box.sh("mkdir -p '\(hooks)' && printf '#!/bin/sh\\nexit 1\\n' > '\(hooks)/commit-msg' && chmod +x '\(hooks)/commit-msg'")
    _ = try? box.sh("git -c core.hooksPath='\(hooks)' \(R5Box.id) commit -q --allow-empty -m 'Why the cache must be warmed first'", in: wt)
    let gitdir = try box.gitdir(wt)
    try #require(ex(gitdir + "/COMMIT_EDITMSG"), "precondition: git kept the message")
    try box.sh("chmod a-w tracked", in: wt)
    let scanner = box.scanner()
    let target = try #require(item(scanner, wt), "precondition: offered")
    var thrown: Error?
    do { try scanner.remove(target) } catch { thrown = error }
    print("R5[b] remove -> \(thrown.map { "\($0)" } ?? "ok"); gitdir exists=\(ex(gitdir)); left on disk=\(ex(wt))")
    #expect(box.savedText.contains("Why the cache must be warmed first"), "the only copy of the message was deleted")
    guard case .partlyRemoved(_, _, let saved)? = thrown as? WorktreeError else {
        Issue.record("expected partlyRemoved, got \(thrown.map { "\($0)" } ?? "success")")
        return
    }
    #expect(saved.count == 1)
    #expect("\(thrown!)".contains("Saved 1 unsent message(s)"))
}

/// The copy is dropped only while its original is still in place.
@Test func r5b2_copiesAreDroppedOnlyWhileTheOriginalExists() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("r5-copies-\(UUID().uuidString.prefix(8))").path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    for name in ["copy1", "copy2", "original1"] { try "m\n".write(toFile: dir + "/" + name, atomically: true, encoding: .utf8) }
    let kept = WorktreeScanner.discardRedundantCopies([
        .init(copy: dir + "/copy1", original: dir + "/original1"),
        .init(copy: dir + "/copy2", original: dir + "/original2"),   // git deleted it
    ])
    #expect(kept == [dir + "/copy2"])
    #expect(!ex(dir + "/copy1"))
    #expect(ex(dir + "/copy2"))
}

// MARK: 3. A paused notes merge

@Test func r5c_pausedNotesMergeIsKept_safe() throws {
    let box = try R5Box("notesmerge"); defer { box.cleanup() }
    let wt = try box.worktree("wnotes")
    try box.sh("git notes --ref=a add -m 'note A' HEAD && git notes --ref=b add -m 'note B' HEAD", in: wt)
    _ = try? box.sh("git \(R5Box.id) notes --ref=a merge b", in: wt)   // conflicts, by design
    let resolution = try box.sh("ls \"$(git rev-parse --absolute-git-dir)\"/NOTES_MERGE_WORKTREE/*", in: wt)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    try #require(!resolution.isEmpty, "precondition: the notes merge is paused")
    try "note A, with B's caveat folded in\n".write(toFile: resolution, atomically: true, encoding: .utf8)
    let scan = box.scanner().scan()
    print("R5[c] skipped=\(scan.skipped)")
    #expect(!scan.reclaimable.contains { $0.path.hasSuffix("/wnotes") }, "a paused notes merge was offered")
    #expect(scan.skipped["git operation in progress"] == 1)
    #expect(ex(resolution))
}

// MARK: 4. Tag and note messages git left behind

/// A failed `git tag -s` (signing failed) leaves TAG_EDITMSG; a note whose editor failed leaves
/// NOTES_EDITMSG. Removal deletes both, so both are saved first.
@Test func r5d_tagAndNoteMessagesAreSaved_safe() throws {
    let box = try R5Box("tagmsg"); defer { box.cleanup() }
    let wt = try box.worktree("wtag")
    let tagEditor = try box.editor("tag-editor", writes: "Release notes for v1: the cache fix")
    let noteEditor = try box.editor("note-editor", writes: "Why this commit needed a second look", exit: 1)
    _ = try? box.sh("GIT_EDITOR='\(tagEditor)' git -c gpg.program=false tag -s v1", in: wt)
    _ = try? box.sh("GIT_EDITOR='\(noteEditor)' git notes add", in: wt)
    let gitdir = try box.gitdir(wt)
    try #require(ex(gitdir + "/TAG_EDITMSG") && ex(gitdir + "/NOTES_EDITMSG"), "precondition: git left both messages")
    let scanner = box.scanner()
    let target = try #require(item(scanner, wt), "precondition: offered")
    let saved = try scanner.remove(target)
    print("R5[d] saved=\(saved.map { ($0 as NSString).lastPathComponent })")
    #expect(!ex(wt))
    #expect(box.savedText.contains("Release notes for v1: the cache fix"))
    #expect(box.savedText.contains("Why this commit needed a second look"))
    #expect(WorktreeScanner.savedSummary(saved)?.hasPrefix("Saved 2 unsent message(s) to ") == true)
}

// MARK: 5. The process list can't be read

/// With no process list, no worktree can be shown to be unused, so none is offered or deleted.
@Test func r5e_unreadableProcessListKeepsEverything_safe() throws {
    let box = try R5Box("nops"); defer { box.cleanup() }
    let wt = try box.worktree("wnops")
    let scanner = box.scanner()
    let target = try #require(item(scanner, wt), "precondition: offered")
    scanner.captureContext = { throw Failing() }
    let scan = scanner.scan()
    #expect(scan.reclaimable.isEmpty)
    #expect(scan.skipped["git error"] == 1)
    var err: String?
    do { try scanner.remove(target) } catch { err = "\(error)" }
    print("R5[e] remove -> \(err ?? "ok")")
    #expect(err?.contains("running processes can't be listed") == true)
    #expect(ex(wt))
}

/// Output that names no processes, or missing working folders, is not a picture to trust.
@Test func r5e2_partialProcessPicturesAreRefused() throws {
    let ps = try Monitor.ps(ProcessTable.mainArguments)
    let cwds = try #require(ProcessCwd.all())
    #expect(throws: (any Error).self) { try LiveContext.make(ps: "", cwds: cwds, sessions: []) }
    #expect(throws: (any Error).self) { try LiveContext.make(ps: ps, cwds: nil, sessions: []) }
    #expect(throws: (any Error).self) { try LiveContext.make(ps: ps, cwds: [:], sessions: []) }
    let context = try LiveContext.make(ps: ps, cwds: cwds, sessions: [])
    #expect(context.processes.contains { $0.pid == getpid() })
}
